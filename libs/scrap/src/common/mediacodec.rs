use hbb_common::{anyhow::Error, bail, log, ResultType};
use ndk::media::media_codec::{MediaCodec, MediaCodecDirection, MediaFormat};
use std::ops::Deref;
use std::{
    io::Write,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

use crate::ImageFormat;
use crate::{CodecFormat, I420ToABGR, I420ToARGB, ImageRgb, NV12ToABGR, NV12ToARGB};

/// MediaCodec mime type name
const H264_MIME_TYPE: &str = "video/avc";
const H265_MIME_TYPE: &str = "video/hevc";
const COLOR_FORMAT_YUV420_PLANAR: i32 = 19;
const COLOR_FORMAT_YUV420_SEMIPLANAR: i32 = 21;
// const VP8_MIME_TYPE: &str = "video/x-vnd.on2.vp8";
// const VP9_MIME_TYPE: &str = "video/x-vnd.on2.vp9";

// TODO MediaCodecEncoder

pub static H264_DECODER_SUPPORT: AtomicBool = AtomicBool::new(false);
pub static H265_DECODER_SUPPORT: AtomicBool = AtomicBool::new(false);

pub struct MediaCodecDecoder {
    decoder: MediaCodec,
    name: String,
    decoded_frames: u64,
    last_diag_log: Option<Instant>,
}

struct MediaCodecDecoders {
    h264: Option<MediaCodecDecoder>,
    h265: Option<MediaCodecDecoder>,
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

impl MediaCodecDecoder {
    pub fn new(format: CodecFormat) -> Option<MediaCodecDecoder> {
        match format {
            CodecFormat::H264 => create_media_codec(H264_MIME_TYPE, MediaCodecDirection::Decoder),
            CodecFormat::H265 => create_media_codec(H265_MIME_TYPE, MediaCodecDirection::Decoder),
            _ => {
                log::error!("Unsupported codec format: {:?}", format);
                None
            }
        }
    }

    fn new_decoders() -> MediaCodecDecoders {
        MediaCodecDecoders {
            h264: Self::new(CodecFormat::H264),
            h265: Self::new(CodecFormat::H265),
        }
    }

    // rgb [in/out] fmt and stride must be set in ImageRgb
    pub fn decode(&mut self, data: &[u8], rgb: &mut ImageRgb) -> ResultType<bool> {
        let total_start = Instant::now();
        let input_start = Instant::now();
        match self.dequeue_input_buffer(Duration::from_millis(10))? {
            Some(mut input_buffer) => {
                let mut buf = input_buffer.buffer_mut();
                if data.len() > buf.len() {
                    log::error!("Failed to decode, the input data size is bigger than input buf");
                    bail!("The input data size is bigger than input buf");
                }
                buf.write_all(&data)?;
                self.queue_input_buffer(input_buffer, 0, data.len(), 0, 0)?;
            }
            None => {
                log::debug!("Failed to dequeue_input_buffer: No available input_buffer");
            }
        };
        let input_queue_elapsed = input_start.elapsed();

        let output_dequeue_start = Instant::now();
        return match self.dequeue_output_buffer(Duration::from_millis(100))? {
            Some(output_buffer) => {
                let output_dequeue_elapsed = output_dequeue_start.elapsed();
                let res_format = self.output_format();
                let convert_start = Instant::now();
                let convert_result = (|| {
                    let layout = output_layout(&res_format)?;
                    let buf = output_buffer.buffer();
                    copy_output_to_rgba(buf, &layout, rgb)?;
                    Ok((layout, buf.len()))
                })();
                let convert_elapsed = convert_start.elapsed();
                let release_result = self.release_output_buffer(output_buffer, false);
                release_result?;
                let (layout, output_bytes) = convert_result?;
                self.decoded_frames = self.decoded_frames.saturating_add(1);
                if self.should_log_diag() {
                    log::info!(
                        "diag android mediacodec frame: decoder={}, codec={}, coded={}x{}, visible={}x{}, stride={}, slice_height={}, crop=({},{}), color_format={}, input_queue_ms={}, output_dequeue_ms={}, convert_ms={}, total_ms={}, input_bytes={}, output_bytes={}, dst_stride={}, render_path=rgba-soft, output_format={}",
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
                        rgba_stride(layout.visible_w, rgb.align()),
                        res_format,
                    );
                }
                Ok(true)
            }
            None => {
                log::debug!("Failed to dequeue_output: No available dequeue_output");
                Ok(false)
            }
        };
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

fn create_media_codec(name: &str, direction: MediaCodecDirection) -> Option<MediaCodecDecoder> {
    let codec = MediaCodec::from_decoder_type(name)?;
    let media_format = MediaFormat::new();
    media_format.set_str("mime", name);
    // This decoder is created before SPS/PPS-derived dimensions are available.
    // Keep the legacy zero-size configure path for now and log the actual output
    // dimensions once MediaCodec reports them.
    media_format.set_i32("width", 0);
    media_format.set_i32("height", 0);
    media_format.set_i32("color-format", COLOR_FORMAT_YUV420_PLANAR);
    if let Err(e) = codec.configure(&media_format, None, direction) {
        log::error!("Failed to init decoder: {:?}", e);
        return None;
    };
    log::info!("MediaCodec decoder init success: {name}, format={media_format}");
    if let Err(e) = codec.start() {
        log::error!("Failed to start decoder: {:?}", e);
        return None;
    };
    log::debug!("Init decoder succeeded!: {:?}", name);
    return Some(MediaCodecDecoder {
        decoder: codec,
        name: name.to_owned(),
        decoded_frames: 0,
        last_diag_log: None,
    });
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
        .unwrap_or(coded_w.saturating_sub(1) as i32)
        .max(crop_left as i32) as usize;
    let crop_bottom = format
        .i32("crop-bottom")
        .unwrap_or(coded_h.saturating_sub(1) as i32)
        .max(crop_top as i32) as usize;
    let visible_w = crop_right.saturating_sub(crop_left).saturating_add(1);
    let visible_h = crop_bottom.saturating_sub(crop_top).saturating_add(1);
    let color_format = format
        .i32("color-format")
        .unwrap_or(COLOR_FORMAT_YUV420_PLANAR);
    if visible_w == 0 || visible_h == 0 {
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
            _ => bail!("Unsupported image format"),
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
            _ => bail!("Unsupported image format"),
        }
    };
    if res != 0 {
        bail!("NV12 to RGBA conversion failed: {}", res);
    }
    Ok(())
}

pub fn check_mediacodec() {
    std::thread::spawn(move || {
        // check decoders
        let decoders = MediaCodecDecoder::new_decoders();
        H264_DECODER_SUPPORT.swap(decoders.h264.is_some(), Ordering::SeqCst);
        H265_DECODER_SUPPORT.swap(decoders.h265.is_some(), Ordering::SeqCst);
        decoders.h264.map(|d| d.stop());
        decoders.h265.map(|d| d.stop());
        // TODO encoders
    });
}
