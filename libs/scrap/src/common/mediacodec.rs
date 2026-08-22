use hbb_common::{anyhow::Error, bail, libc, log, ResultType};
use lazy_static::lazy_static;
use ndk::media::{
    media_codec::{
        DequeuedInputBufferResult, DequeuedOutputBufferInfoResult, MediaCodec, MediaCodecDirection,
    },
    media_format::MediaFormat,
};
use ndk::native_window::NativeWindow;
use std::ops::Deref;
use std::{
    collections::{HashMap, VecDeque},
    ops::Range,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        RwLock,
    },
    time::{Duration, Instant},
};

use super::video_presentation_clock::VideoPresentationClock;
use crate::ImageFormat;
use crate::{CodecFormat, I420ToABGR, I420ToARGB, ImageRgb, NV12ToABGR, NV12ToARGB};

/// MediaCodec mime type name
const H264_MIME_TYPE: &str = "video/avc";
const H265_MIME_TYPE: &str = "video/hevc";
const COLOR_FORMAT_YUV420_PLANAR: i32 = 19;
const COLOR_FORMAT_YUV420_SEMIPLANAR: i32 = 21;
const COLOR_FORMAT_SURFACE: i32 = 0x7F000789;
const MAX_PENDING_INPUTS: usize = 16;
const MAX_PENDING_INPUT_BYTES: usize = 16 * 1024 * 1024;
const MAX_INPUT_DEQUEUE_EVENTS: usize = 4;
const MAX_OUTPUT_DEQUEUE_EVENTS: usize = 4;
const MAX_IN_FLIGHT_FRAMES: usize = 128;
const SURFACE_CONFIGURE_RETRY_DELAYS: [Duration; 2] =
    [Duration::from_millis(20), Duration::from_millis(60)];
// const VP8_MIME_TYPE: &str = "video/x-vnd.on2.vp8";
// const VP9_MIME_TYPE: &str = "video/x-vnd.on2.vp9";

// TODO MediaCodecEncoder

pub static H264_DECODER_SUPPORT: AtomicBool = AtomicBool::new(false);
pub static H265_DECODER_SUPPORT: AtomicBool = AtomicBool::new(false);

struct OutputSurface {
    generation: u64,
    window: NativeWindow,
    refresh_period_ns: i64,
}

lazy_static! {
    static ref OUTPUT_SURFACES: RwLock<HashMap<usize, OutputSurface>> = RwLock::new(HashMap::new());
    static ref MOVIE_PRESENTATION_MODES: RwLock<HashMap<usize, bool>> = RwLock::new(HashMap::new());
}

static NEXT_SURFACE_GENERATION: AtomicU64 = AtomicU64::new(1);

pub fn set_output_surface(display: usize, window: NativeWindow, refresh_period_ns: i64) -> u64 {
    let generation = NEXT_SURFACE_GENERATION.fetch_add(1, Ordering::SeqCst);
    OUTPUT_SURFACES.write().unwrap().insert(
        display,
        OutputSurface {
            generation,
            window,
            refresh_period_ns,
        },
    );
    log::info!(
        "Android MediaCodec output surface registered: display={}, generation={}, refresh_period_ns={}",
        display,
        generation,
        refresh_period_ns
    );
    generation
}

pub fn clear_output_surface(display: usize) {
    MOVIE_PRESENTATION_MODES.write().unwrap().remove(&display);
    if let Some(surface) = OUTPUT_SURFACES.write().unwrap().remove(&display) {
        log::info!(
            "Android MediaCodec output surface cleared: display={}, generation={}",
            display,
            surface.generation
        );
    }
}

pub fn set_movie_presentation_mode(display: usize, enabled: bool) {
    MOVIE_PRESENTATION_MODES
        .write()
        .unwrap()
        .insert(display, enabled);
}

fn movie_presentation_mode(display: usize) -> bool {
    MOVIE_PRESENTATION_MODES
        .read()
        .unwrap()
        .get(&display)
        .copied()
        .unwrap_or(false)
}

pub fn output_surface_refresh_millihz(display: usize) -> u32 {
    let period_ns = output_surface_refresh_period(display);
    if period_ns <= 0 {
        return 0;
    }
    (1_000_000_000_000i64 / period_ns).clamp(0, i64::from(u32::MAX)) as u32
}

pub fn update_output_surface_refresh_period(display: usize, refresh_period_ns: i64) -> bool {
    let mut surfaces = OUTPUT_SURFACES.write().unwrap();
    let Some(surface) = surfaces.get_mut(&display) else {
        return false;
    };
    surface.refresh_period_ns = refresh_period_ns;
    true
}

fn output_surface_refresh_period(display: usize) -> i64 {
    OUTPUT_SURFACES
        .read()
        .unwrap()
        .get(&display)
        .map(|surface| surface.refresh_period_ns)
        .unwrap_or(0)
}

fn output_surface(display: usize) -> (Option<NativeWindow>, u64, i64) {
    OUTPUT_SURFACES
        .read()
        .unwrap()
        .get(&display)
        .map(|surface| {
            (
                Some(surface.window.clone()),
                surface.generation,
                surface.refresh_period_ns,
            )
        })
        .unwrap_or((None, 0, 0))
}

pub fn output_surface_generation(display: usize) -> u64 {
    OUTPUT_SURFACES
        .read()
        .unwrap()
        .get(&display)
        .map(|surface| surface.generation)
        .unwrap_or(0)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MediaCodecDecodeOutcome {
    FrameReady { frame_id: Option<u64> },
    OutputPending,
    InputBackpressure,
}

struct PendingInput {
    data: Vec<u8>,
    frame_id: u64,
    capture_time_ms: u64,
}

pub struct MediaCodecDecoder {
    decoder: MediaCodec,
    name: String,
    decoded_frames: u64,
    last_diag_log: Option<Instant>,
    pending_inputs: VecDeque<PendingInput>,
    pending_input_bytes: usize,
    in_flight_frames: VecDeque<(i64, u64, u64)>,
    next_input_token: u64,
    display: usize,
    width: usize,
    height: usize,
    surface_output: bool,
    surface_generation: u64,
    output_surface: Option<NativeWindow>,
    presentation_clock: VideoPresentationClock,
}

struct OutputLayout {
    coded_w: usize,
    coded_h: usize,
    visible_w: usize,
    visible_h: usize,
    stride: usize,
    slice_height: usize,
    crop_left: usize,
    crop_top: usize,
    color_format: i32,
}

impl Deref for MediaCodecDecoder {
    type Target = MediaCodec;

    fn deref(&self) -> &Self::Target {
        &self.decoder
    }
}

impl Drop for MediaCodecDecoder {
    fn drop(&mut self) {
        if let Err(error) = self.decoder.stop() {
            log::debug!(
                "Android MediaCodec stop during decoder release returned: {:?}",
                error
            );
        }
    }
}

impl MediaCodecDecoder {
    pub fn new(
        format: CodecFormat,
        dimensions: Option<(usize, usize)>,
        display: usize,
    ) -> Option<MediaCodecDecoder> {
        let Some((width, height)) = dimensions.filter(|(width, height)| *width > 0 && *height > 0)
        else {
            log::warn!("MediaCodec decoder requires a valid remote video size");
            return None;
        };
        match format {
            CodecFormat::H264 => create_media_codec(H264_MIME_TYPE, width, height, display),
            CodecFormat::H265 => create_media_codec(H265_MIME_TYPE, width, height, display),
            _ => {
                log::error!("Unsupported codec format: {:?}", format);
                None
            }
        }
    }

    // rgb [in/out] fmt and stride must be set in ImageRgb
    pub fn decode(
        &mut self,
        data: &[u8],
        frame_id: u64,
        capture_time_ms: u64,
        rgb: &mut ImageRgb,
    ) -> ResultType<MediaCodecDecodeOutcome> {
        let total_start = Instant::now();
        let input_start = Instant::now();
        self.enqueue_input(data, frame_id, capture_time_ms)?;
        let input_backpressure = self.queue_pending_inputs()?;
        let input_queue_elapsed = input_start.elapsed();

        let output_dequeue_start = Instant::now();
        for attempt in 0..MAX_OUTPUT_DEQUEUE_EVENTS {
            let timeout = if attempt == 0 {
                Duration::from_millis(100)
            } else {
                Duration::ZERO
            };
            match self.decoder.dequeue_output_buffer(timeout)? {
                DequeuedOutputBufferInfoResult::Buffer(output_buffer) => {
                    let output_dequeue_elapsed = output_dequeue_start.elapsed();
                    let presentation_time_us = output_buffer.info().presentation_time_us();
                    let res_format = self.decoder.output_format();
                    if self.surface_output {
                        self.presentation_clock
                            .update_refresh_period(output_surface_refresh_period(self.display));
                        self.presentation_clock
                            .set_movie_mode(movie_presentation_mode(self.display));
                        let output_metadata = self.output_frame_metadata(presentation_time_us);
                        let (release_mode, presentation_reset, presentation_lead_us) =
                            if let Some(now_ns) = monotonic_now_ns() {
                                let schedule = self
                                    .presentation_clock
                                    .schedule(output_metadata.map(|(_, value)| value), now_ns);
                                self.decoder.release_output_buffer_at_time(
                                    output_buffer,
                                    schedule.target_ns,
                                )?;
                                (
                                    if schedule.source_clock {
                                        "source-clock-scheduled"
                                    } else {
                                        "immediate-no-source-clock"
                                    },
                                    schedule.reset,
                                    schedule.target_ns.saturating_sub(now_ns) / 1_000,
                                )
                            } else {
                                self.decoder.release_output_buffer(output_buffer, true)?;
                                ("immediate-no-monotonic-clock", false, 0)
                            };
                        let output_frame_id = self
                            .take_output_frame_metadata(presentation_time_us)
                            .map(|(frame_id, _)| frame_id);
                        self.decoded_frames = self.decoded_frames.saturating_add(1);
                        if self.should_log_diag() {
                            log::info!(
                                "diag android mediacodec frame: decoder={}, codec={}, visible={}x{}, input_queue_ms={}, output_dequeue_ms={}, total_ms={}, input_bytes={}, pending_inputs={}, render_path=surface-texture, release_mode={}, presentation_reset={}, presentation_lead_us={}, movie_playout_delay_ms={}, refresh_period_ns={}, surface_generation={}, output_format={:?}",
                                self.name,
                                self.codec_label(),
                                self.width,
                                self.height,
                                input_queue_elapsed.as_millis(),
                                output_dequeue_elapsed.as_millis(),
                                total_start.elapsed().as_millis(),
                                data.len(),
                                self.pending_inputs.len(),
                                release_mode,
                                presentation_reset,
                                presentation_lead_us,
                                self.presentation_clock.playout_delay_ms(),
                                self.presentation_clock.refresh_period_ns(),
                                self.surface_generation,
                                res_format,
                            );
                        }
                        return Ok(MediaCodecDecodeOutcome::FrameReady {
                            frame_id: output_frame_id,
                        });
                    }
                    let convert_start = Instant::now();
                    let convert_result: ResultType<(OutputLayout, usize, usize)> = (|| {
                        let layout = output_layout(&res_format)?;
                        let raw_buffer = output_buffer.buffer();
                        let range = output_buffer_range(
                            raw_buffer.len(),
                            output_buffer.info().offset(),
                            output_buffer.info().size(),
                        )?;
                        if range.is_empty() {
                            return Ok((layout, 0, raw_buffer.len()));
                        }
                        let buf = &raw_buffer[range];
                        copy_output_to_rgba(buf, &layout, rgb)?;
                        Ok((layout, buf.len(), raw_buffer.len()))
                    })(
                    );
                    let convert_elapsed = convert_start.elapsed();
                    self.decoder.release_output_buffer(output_buffer, false)?;
                    let (layout, output_bytes, output_capacity) = convert_result?;
                    let output_frame_id = self
                        .take_output_frame_metadata(presentation_time_us)
                        .map(|(frame_id, _)| frame_id);
                    if output_bytes == 0 {
                        log::debug!("MediaCodec returned an empty output buffer");
                        continue;
                    }
                    if output_frame_id.is_none() {
                        log::warn!(
                            "MediaCodec output has no matching input token: decoder={}, codec={}, presentation_time_us={}",
                            self.name,
                            self.codec_label(),
                            presentation_time_us
                        );
                    }
                    self.decoded_frames = self.decoded_frames.saturating_add(1);
                    if self.should_log_diag() {
                        log::info!(
                            "diag android mediacodec frame: decoder={}, codec={}, coded={}x{}, visible={}x{}, stride={}, slice_height={}, crop=({},{}), color_format={}, input_queue_ms={}, output_dequeue_ms={}, convert_ms={}, total_ms={}, input_bytes={}, output_bytes={}, output_capacity={}, dst_stride={}, pending_inputs={}, render_path=rgba-soft, output_format={:?}",
                            self.name,
                            self.codec_label(),
                            layout.coded_w,
                            layout.coded_h,
                            layout.visible_w,
                            layout.visible_h,
                            layout.stride,
                            layout.slice_height,
                            layout.crop_left,
                            layout.crop_top,
                            layout.color_format,
                            input_queue_elapsed.as_millis(),
                            output_dequeue_elapsed.as_millis(),
                            convert_elapsed.as_millis(),
                            total_start.elapsed().as_millis(),
                            data.len(),
                            output_bytes,
                            output_capacity,
                            rgba_stride(layout.visible_w, rgb.align()),
                            self.pending_inputs.len(),
                            res_format,
                        );
                    }
                    return Ok(MediaCodecDecodeOutcome::FrameReady {
                        frame_id: output_frame_id,
                    });
                }
                DequeuedOutputBufferInfoResult::TryAgainLater => break,
                DequeuedOutputBufferInfoResult::OutputFormatChanged => {
                    log::info!(
                        "MediaCodec output format changed: decoder={}, codec={}, format={:?}",
                        self.name,
                        self.codec_label(),
                        self.decoder.output_format()
                    );
                }
                DequeuedOutputBufferInfoResult::OutputBuffersChanged => {
                    log::debug!(
                        "MediaCodec output buffers changed: decoder={}, codec={}",
                        self.name,
                        self.codec_label()
                    );
                }
            }
        }
        Ok(if input_backpressure || !self.pending_inputs.is_empty() {
            MediaCodecDecodeOutcome::InputBackpressure
        } else {
            MediaCodecDecodeOutcome::OutputPending
        })
    }

    fn output_frame_metadata(&self, presentation_time_us: i64) -> Option<(u64, u64)> {
        self.in_flight_frames
            .iter()
            .find(|(token, _, _)| *token == presentation_time_us)
            .map(|(_, frame_id, capture_time_ms)| (*frame_id, *capture_time_ms))
    }

    fn take_output_frame_metadata(&mut self, presentation_time_us: i64) -> Option<(u64, u64)> {
        let index = self
            .in_flight_frames
            .iter()
            .position(|(token, _, _)| *token == presentation_time_us)?;
        self.in_flight_frames
            .remove(index)
            .map(|(_, frame_id, capture_time_ms)| (frame_id, capture_time_ms))
    }

    pub fn uses_surface_output(&self) -> bool {
        self.surface_output
    }

    pub fn surface_generation(&self) -> u64 {
        self.surface_generation
    }

    pub fn output_size(&self) -> (usize, usize) {
        (self.width, self.height)
    }

    pub fn update_output_surface(&mut self) -> bool {
        let (surface, generation, refresh_period_ns) = output_surface(self.display);
        if generation == self.surface_generation {
            return true;
        }
        let Some(surface) = surface else {
            return false;
        };
        if !self.surface_output {
            return false;
        }
        match self.decoder.set_output_surface(&surface) {
            Ok(()) => {
                self.output_surface = Some(surface);
                self.surface_generation = generation;
                self.presentation_clock
                    .update_refresh_period(refresh_period_ns);
                log::info!(
                    "Android MediaCodec output surface updated: display={}, generation={}, decoder={}",
                    self.display,
                    generation,
                    self.name
                );
                true
            }
            Err(error) => {
                log::warn!(
                    "Failed to update Android MediaCodec output surface: display={}, generation={}, decoder={}, error={:?}",
                    self.display,
                    generation,
                    self.name,
                    error
                );
                false
            }
        }
    }

    fn enqueue_input(
        &mut self,
        data: &[u8],
        frame_id: u64,
        capture_time_ms: u64,
    ) -> ResultType<()> {
        if self.pending_inputs.len() >= MAX_PENDING_INPUTS
            || self.pending_input_bytes.saturating_add(data.len()) > MAX_PENDING_INPUT_BYTES
        {
            bail!(
                "MediaCodec input queue limit exceeded: pending={}, pending_bytes={}, input_bytes={}",
                self.pending_inputs.len(),
                self.pending_input_bytes,
                data.len()
            );
        }
        self.pending_input_bytes = self.pending_input_bytes.saturating_add(data.len());
        self.pending_inputs.push_back(PendingInput {
            data: data.to_vec(),
            frame_id,
            capture_time_ms,
        });
        Ok(())
    }

    fn queue_pending_inputs(&mut self) -> ResultType<bool> {
        for attempt in 0..MAX_INPUT_DEQUEUE_EVENTS {
            if self.pending_inputs.is_empty() {
                return Ok(false);
            }
            let timeout = if attempt == 0 {
                Duration::from_millis(10)
            } else {
                Duration::ZERO
            };
            let token = self.next_input_token();
            match self.decoder.dequeue_input_buffer(timeout)? {
                DequeuedInputBufferResult::Buffer(mut input_buffer) => {
                    let Some(pending) = self.pending_inputs.pop_front() else {
                        return Ok(false);
                    };
                    self.pending_input_bytes =
                        self.pending_input_bytes.saturating_sub(pending.data.len());
                    let buf = input_buffer.buffer_mut();
                    if pending.data.len() > buf.len() {
                        bail!(
                            "MediaCodec input exceeds buffer capacity: input_bytes={}, capacity={}",
                            pending.data.len(),
                            buf.len()
                        );
                    }
                    for (destination, source) in buf.iter_mut().zip(pending.data.iter()) {
                        destination.write(*source);
                    }
                    self.decoder.queue_input_buffer(
                        input_buffer,
                        0,
                        pending.data.len(),
                        token as u64,
                        0,
                    )?;
                    self.in_flight_frames.push_back((
                        token,
                        pending.frame_id,
                        pending.capture_time_ms,
                    ));
                    while self.in_flight_frames.len() > MAX_IN_FLIGHT_FRAMES {
                        self.in_flight_frames.pop_front();
                    }
                }
                DequeuedInputBufferResult::TryAgainLater => return Ok(true),
            }
        }
        Ok(!self.pending_inputs.is_empty())
    }

    fn next_input_token(&mut self) -> i64 {
        self.next_input_token = if self.next_input_token >= i64::MAX as u64 {
            1
        } else {
            self.next_input_token.saturating_add(1).max(1)
        };
        self.next_input_token as i64
    }

    fn codec_label(&self) -> &'static str {
        match self.name.as_str() {
            H264_MIME_TYPE => "H264",
            H265_MIME_TYPE => "H265",
            _ => "unknown",
        }
    }

    fn should_log_diag(&mut self) -> bool {
        if self.decoded_frames <= 3 {
            return true;
        }
        if self
            .last_diag_log
            .map(|last| last.elapsed() < Duration::from_secs(5))
            .unwrap_or(false)
        {
            return false;
        }
        self.last_diag_log = Some(Instant::now());
        true
    }
}

fn output_buffer_range(buffer_len: usize, offset: i32, size: i32) -> ResultType<Range<usize>> {
    if offset < 0 || size < 0 {
        bail!(
            "Invalid MediaCodec output buffer range: offset={}, size={}, capacity={}",
            offset,
            size,
            buffer_len
        );
    }
    let start = offset as usize;
    let end = start.checked_add(size as usize).ok_or_else(|| {
        Error::msg(format!(
            "MediaCodec output buffer range overflow: offset={}, size={}, capacity={}",
            offset, size, buffer_len
        ))
    })?;
    if end > buffer_len {
        bail!(
            "MediaCodec output buffer range exceeds capacity: offset={}, size={}, capacity={}",
            offset,
            size,
            buffer_len
        );
    }
    Ok(start..end)
}

fn create_media_codec(
    name: &str,
    width: usize,
    height: usize,
    display: usize,
) -> Option<MediaCodecDecoder> {
    let (registered_surface, surface_generation, refresh_period_ns) = output_surface(display);
    let texture_render_enabled = hbb_common::config::LocalConfig::get_option(
        hbb_common::config::keys::OPTION_TEXTURE_RENDER,
    ) != "N";
    let requested_surface =
        registered_surface.filter(|_| texture_render_enabled && surface_codec_supported(name));
    let surface_requested = requested_surface.is_some();
    let mut configure_result =
        configure_media_codec(name, width, height, requested_surface.as_ref());
    if requested_surface.is_some() {
        for (attempt, delay) in SURFACE_CONFIGURE_RETRY_DELAYS.iter().enumerate() {
            if configure_result.is_ok() {
                break;
            }
            log::warn!(
                "Android MediaCodec surface configure retry: display={}, mime={}, size={}x{}, attempt={}, delay_ms={}",
                display,
                name,
                width,
                height,
                attempt + 1,
                delay.as_millis()
            );
            std::thread::sleep(*delay);
            configure_result =
                configure_media_codec(name, width, height, requested_surface.as_ref());
        }
    }
    let (codec, output_surface, surface_output) = match configure_result {
        Ok(codec) => (codec, requested_surface, surface_requested),
        Err(error) if requested_surface.is_some() => {
            log::warn!(
                "Android MediaCodec surface configure failed, falling back to CPU output: display={}, mime={}, size={}x{}, error={:?}",
                display,
                name,
                width,
                height,
                error
            );
            match configure_media_codec(name, width, height, None) {
                Ok(codec) => (codec, None, false),
                Err(error) => {
                    log::error!("Failed to init MediaCodec decoder: {:?}", error);
                    return None;
                }
            }
        }
        Err(error) => {
            log::error!("Failed to init MediaCodec decoder: {:?}", error);
            return None;
        }
    };
    log::info!(
        "MediaCodec decoder configure success: mime={}, size={}x{}, display={}, render_path={}, surface_generation={}",
        name,
        width,
        height,
        display,
        if surface_output { "surface-texture" } else { "rgba-soft" },
        surface_generation
    );
    Some(MediaCodecDecoder {
        decoder: codec,
        name: name.to_owned(),
        decoded_frames: 0,
        last_diag_log: None,
        pending_inputs: VecDeque::new(),
        pending_input_bytes: 0,
        in_flight_frames: VecDeque::new(),
        next_input_token: 0,
        display,
        width,
        height,
        surface_output,
        surface_generation,
        output_surface,
        presentation_clock: VideoPresentationClock::new(refresh_period_ns),
    })
}

fn configure_media_codec(
    name: &str,
    width: usize,
    height: usize,
    surface: Option<&NativeWindow>,
) -> ResultType<MediaCodec> {
    let codec = MediaCodec::from_decoder_type(name)
        .ok_or_else(|| Error::msg(format!("MediaCodec decoder is unavailable: {}", name)))?;
    let mut media_format = MediaFormat::new();
    media_format.set_str("mime", name);
    media_format.set_i32("width", width as i32);
    media_format.set_i32("height", height as i32);
    media_format.set_i32(
        "color-format",
        if surface.is_some() {
            COLOR_FORMAT_SURFACE
        } else {
            COLOR_FORMAT_YUV420_PLANAR
        },
    );
    codec.configure(&media_format, surface, MediaCodecDirection::Decoder)?;
    codec.start()?;
    Ok(codec)
}

fn monotonic_now_ns() -> Option<i64> {
    let mut timestamp = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut timestamp) } != 0 {
        return None;
    }
    let seconds = timestamp.tv_sec as i64;
    let nanoseconds = timestamp.tv_nsec as i64;
    if seconds < 0 || !(0..1_000_000_000).contains(&nanoseconds) {
        return None;
    }
    seconds
        .checked_mul(1_000_000_000)
        .and_then(|value| value.checked_add(nanoseconds))
}

fn surface_codec_supported(mime_type: &str) -> bool {
    crate::android::ffi::get_codec_info()
        .map(|infos| {
            infos.codecs.iter().any(|codec| {
                !codec.is_encoder
                    && codec.hw == Some(true)
                    && codec.surface
                    && codec.mime_type == mime_type
            })
        })
        .unwrap_or(false)
}

fn positive_i32(format: &MediaFormat, key: &str) -> Option<usize> {
    format
        .i32(key)
        .filter(|value| *value > 0)
        .map(|value| value as usize)
}

fn output_layout(format: &MediaFormat) -> ResultType<OutputLayout> {
    let coded_w = positive_i32(format, "width").ok_or(Error::msg(
        "Failed to dequeue_output_buffer, width is invalid",
    ))?;
    let coded_h = positive_i32(format, "height").ok_or(Error::msg(
        "Failed to dequeue_output_buffer, height is invalid",
    ))?;
    let stride = positive_i32(format, "stride").unwrap_or(coded_w);
    let slice_height = positive_i32(format, "slice-height").unwrap_or(coded_h);
    let crop_left = format.i32("crop-left").unwrap_or(0).max(0) as usize;
    let crop_top = format.i32("crop-top").unwrap_or(0).max(0) as usize;
    let crop_right = format
        .i32("crop-right")
        .unwrap_or(coded_w.saturating_sub(1) as i32);
    let crop_bottom = format
        .i32("crop-bottom")
        .unwrap_or(coded_h.saturating_sub(1) as i32);
    if crop_right < crop_left as i32
        || crop_bottom < crop_top as i32
        || crop_right >= coded_w as i32
        || crop_bottom >= coded_h as i32
    {
        bail!(
            "Invalid MediaCodec output crop: coded={}x{}, crop=({},{} - {},{})",
            coded_w,
            coded_h,
            crop_left,
            crop_top,
            crop_right,
            crop_bottom
        );
    }
    let visible_w = crop_right as usize - crop_left + 1;
    let visible_h = crop_bottom as usize - crop_top + 1;
    let color_format = format
        .i32("color-format")
        .unwrap_or(COLOR_FORMAT_YUV420_PLANAR);
    Ok(OutputLayout {
        coded_w,
        coded_h,
        visible_w,
        visible_h,
        stride,
        slice_height,
        crop_left,
        crop_top,
        color_format,
    })
}

fn rgba_stride(width: usize, align: usize) -> usize {
    let bytes = width * 4;
    if align <= 1 {
        bytes
    } else {
        (bytes + align - 1) & !(align - 1)
    }
}

fn copy_output_to_rgba(buf: &[u8], layout: &OutputLayout, rgb: &mut ImageRgb) -> ResultType<()> {
    match layout.color_format {
        COLOR_FORMAT_YUV420_PLANAR => copy_i420_output_to_rgba(buf, layout, rgb),
        COLOR_FORMAT_YUV420_SEMIPLANAR => copy_nv12_output_to_rgba(buf, layout, rgb),
        _ => bail!(
            "Unsupported MediaCodec output color format: {}, layout={}x{} stride={} slice_height={}",
            layout.color_format,
            layout.visible_w,
            layout.visible_h,
            layout.stride,
            layout.slice_height
        ),
    }
}

fn copy_i420_output_to_rgba(
    buf: &[u8],
    layout: &OutputLayout,
    rgb: &mut ImageRgb,
) -> ResultType<()> {
    let uv_stride = (layout.stride + 1) / 2;
    let uv_height = (layout.slice_height + 1) / 2;
    let y_size = layout.stride * layout.slice_height;
    let uv_size = uv_stride * uv_height;
    let min_size = y_size + uv_size * 2;
    if buf.len() < min_size {
        bail!(
            "MediaCodec I420 output too small: bytes={}, required={}, stride={}, slice_height={}",
            buf.len(),
            min_size,
            layout.stride,
            layout.slice_height
        );
    }
    let dst_stride = rgba_stride(layout.visible_w, rgb.align());
    rgb.w = layout.visible_w;
    rgb.h = layout.visible_h;
    rgb.raw.resize(layout.visible_h * dst_stride, 0);
    let y_offset = layout.crop_top * layout.stride + layout.crop_left;
    let uv_offset = (layout.crop_top / 2) * uv_stride + layout.crop_left / 2;
    let y_ptr = unsafe { buf.as_ptr().add(y_offset) };
    let u_ptr = unsafe { buf.as_ptr().add(y_size + uv_offset) };
    let v_ptr = unsafe { buf.as_ptr().add(y_size + uv_size + uv_offset) };
    let res = unsafe {
        match rgb.fmt() {
            ImageFormat::ARGB => I420ToARGB(
                y_ptr,
                layout.stride as _,
                u_ptr,
                uv_stride as _,
                v_ptr,
                uv_stride as _,
                rgb.raw.as_mut_ptr(),
                dst_stride as _,
                layout.visible_w as _,
                layout.visible_h as _,
            ),
            ImageFormat::ABGR => I420ToABGR(
                y_ptr,
                layout.stride as _,
                u_ptr,
                uv_stride as _,
                v_ptr,
                uv_stride as _,
                rgb.raw.as_mut_ptr(),
                dst_stride as _,
                layout.visible_w as _,
                layout.visible_h as _,
            ),
            ImageFormat::Raw => bail!("Unsupported MediaCodec image format: Raw"),
        }
    };
    if res != 0 {
        bail!("I420 to RGBA conversion failed: {}", res);
    }
    Ok(())
}

fn copy_nv12_output_to_rgba(
    buf: &[u8],
    layout: &OutputLayout,
    rgb: &mut ImageRgb,
) -> ResultType<()> {
    let y_size = layout.stride * layout.slice_height;
    let uv_height = (layout.slice_height + 1) / 2;
    let min_size = y_size + layout.stride * uv_height;
    if buf.len() < min_size {
        bail!(
            "MediaCodec NV12 output too small: bytes={}, required={}, stride={}, slice_height={}",
            buf.len(),
            min_size,
            layout.stride,
            layout.slice_height
        );
    }
    let dst_stride = rgba_stride(layout.visible_w, rgb.align());
    rgb.w = layout.visible_w;
    rgb.h = layout.visible_h;
    rgb.raw.resize(layout.visible_h * dst_stride, 0);
    let y_offset = layout.crop_top * layout.stride + layout.crop_left;
    let uv_offset = (layout.crop_top / 2) * layout.stride + (layout.crop_left / 2) * 2;
    let y_ptr = unsafe { buf.as_ptr().add(y_offset) };
    let uv_ptr = unsafe { buf.as_ptr().add(y_size + uv_offset) };
    let res = unsafe {
        match rgb.fmt() {
            ImageFormat::ARGB => NV12ToARGB(
                y_ptr,
                layout.stride as _,
                uv_ptr,
                layout.stride as _,
                rgb.raw.as_mut_ptr(),
                dst_stride as _,
                layout.visible_w as _,
                layout.visible_h as _,
            ),
            ImageFormat::ABGR => NV12ToABGR(
                y_ptr,
                layout.stride as _,
                uv_ptr,
                layout.stride as _,
                rgb.raw.as_mut_ptr(),
                dst_stride as _,
                layout.visible_w as _,
                layout.visible_h as _,
            ),
            ImageFormat::Raw => bail!("Unsupported MediaCodec image format: Raw"),
        }
    };
    if res != 0 {
        bail!("NV12 to RGBA conversion failed: {}", res);
    }
    Ok(())
}

pub fn update_decoder_support(infos: &crate::android::ffi::MediaCodecInfos) {
    let supports = |mime_type: &str| {
        infos.codecs.iter().any(|codec| {
            !codec.is_encoder
                && codec.hw == Some(true)
                && (codec.yuv420 || codec.surface)
                && codec.mime_type == mime_type
        })
    };
    let h264 = supports(H264_MIME_TYPE);
    let h265 = supports(H265_MIME_TYPE);
    H264_DECODER_SUPPORT.store(h264, Ordering::SeqCst);
    H265_DECODER_SUPPORT.store(h265, Ordering::SeqCst);
    log::info!(
        "Android MediaCodec decoder capabilities: h264={}, h265={}, codec_entries={}",
        h264,
        h265,
        infos.codecs.len()
    );
}

pub fn check_mediacodec() {
    if let Some(infos) = crate::android::ffi::get_codec_info() {
        update_decoder_support(&infos);
    } else {
        log::info!("Android MediaCodec capability check is waiting for the Java codec list");
    }
}

#[cfg(test)]
mod tests {
    use super::output_buffer_range;

    #[test]
    fn output_buffer_range_validates_offset_size_and_capacity() {
        assert_eq!(output_buffer_range(64, 8, 16).unwrap(), 8..24);
        assert!(output_buffer_range(64, -1, 16).is_err());
        assert!(output_buffer_range(64, 8, -1).is_err());
        assert!(output_buffer_range(64, 60, 8).is_err());
    }
}
