// both soundio and cpal use wasapi on windows and coreaudio on mac, they do not support loopback.
// libpulseaudio support loopback because pulseaudio is a standalone audio service with some
// configuration, but need to install the library and start the service on OS, not a good choice.
// windows: https://docs.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording
// mac: https://github.com/mattingalls/Soundflower
// https://docs.microsoft.com/en-us/windows/win32/api/audioclient/nn-audioclient-iaudioclient
// https://github.com/ExistentialAudio/BlackHole

// if pactl not work, please run
// sudo apt-get --purge --reinstall install pulseaudio
// https://askubuntu.com/questions/403416/how-to-listen-live-sounds-from-input-from-external-sound-card
// https://wiki.debian.org/audio-loopback
// https://github.com/krruzic/pulsectl

use super::*;
#[cfg(not(any(target_os = "linux", target_os = "android")))]
use hbb_common::anyhow::anyhow;
use magnum_opus::{Application::*, Channels::*, Encoder};
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};

pub const NAME: &'static str = "audio";
pub const AUDIO_DATA_SIZE_U8: usize = 960 * 4; // 10ms in 48000 stereo
#[cfg(target_os = "android")]
const ANDROID_OPUS_FRAME_SAMPLES: usize = AUDIO_DATA_SIZE_U8 / 4;
#[cfg(not(any(target_os = "linux", target_os = "android")))]
const INPUT_QUEUE_CHUNKS: usize = 32;
static RESTARTING: AtomicBool = AtomicBool::new(false);

lazy_static::lazy_static! {
    static ref VOICE_CALL_INPUT_DEVICE: Arc::<Mutex::<Option<String>>> = Default::default();
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
pub fn new() -> GenericService {
    let svc = EmptyExtraFieldService::new(NAME.to_owned(), true);
    GenericService::repeat::<cpal_impl::State, _, _>(&svc.clone(), 33, cpal_impl::run);
    svc.sp
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn new() -> GenericService {
    let svc = EmptyExtraFieldService::new(NAME.to_owned(), true);
    GenericService::run(&svc.clone(), pa_impl::run);
    svc.sp
}

#[inline]
pub fn get_voice_call_input_device() -> Option<String> {
    VOICE_CALL_INPUT_DEVICE.lock().unwrap().clone()
}

#[inline]
pub fn set_voice_call_input_device(device: Option<String>, set_if_present: bool) {
    if !set_if_present && VOICE_CALL_INPUT_DEVICE.lock().unwrap().is_some() {
        return;
    }

    if *VOICE_CALL_INPUT_DEVICE.lock().unwrap() == device {
        return;
    }
    *VOICE_CALL_INPUT_DEVICE.lock().unwrap() = device;
    restart();
}

#[inline]
fn get_audio_input() -> String {
    VOICE_CALL_INPUT_DEVICE
        .lock()
        .unwrap()
        .clone()
        .unwrap_or(Config::get_option("audio-input"))
}

pub fn restart() {
    log::info!("restart the audio service, freezing now...");
    if RESTARTING.load(Ordering::SeqCst) {
        return;
    }
    RESTARTING.store(true, Ordering::SeqCst);
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod pa_impl {
    use super::*;

    // SAFETY: constrains of hbb_common::mem::aligned_u8_vec must be held
    #[cfg(target_os = "linux")]
    unsafe fn align_to_32(data: Vec<u8>) -> Vec<u8> {
        if (data.as_ptr() as usize & 3) == 0 {
            return data;
        }

        let mut buf = vec![];
        buf = unsafe { hbb_common::mem::aligned_u8_vec(data.len(), 4) };
        buf.extend_from_slice(data.as_ref());
        buf
    }

    #[tokio::main(flavor = "current_thread")]
    pub async fn run(sp: EmptyExtraFieldService) -> ResultType<()> {
        hbb_common::sleep(0.1).await; // one moment to wait for _pa ipc
        RESTARTING.store(false, Ordering::SeqCst);
        #[cfg(target_os = "linux")]
        let mut stream = crate::ipc::connect(1000, "_pa").await?;
        AUDIO_ZERO_COUNT.store(0, Ordering::Relaxed);
        let mut encoder = Encoder::new(crate::platform::PA_SAMPLE_RATE, Stereo, LowDelay)?;
        #[cfg(target_os = "linux")]
        allow_err!(
            stream
                .send(&crate::ipc::Data::Config((
                    "audio-input".to_owned(),
                    Some(super::get_audio_input())
                )))
                .await
        );
        #[cfg(target_os = "linux")]
        let zero_audio_frame: Vec<f32> = vec![0.; AUDIO_DATA_SIZE_U8 / 4];
        #[cfg(target_os = "android")]
        let mut android_frame = vec![0f32; ANDROID_OPUS_FRAME_SAMPLES];
        while sp.ok() && !RESTARTING.load(Ordering::SeqCst) {
            sp.snapshot(|sps| {
                sps.send(create_format_msg(crate::platform::PA_SAMPLE_RATE, 2));
                Ok(())
            })?;

            #[cfg(target_os = "linux")]
            if let Ok(data) = stream.next_raw().await {
                if data.len() == 0 {
                    send_f32(&zero_audio_frame, &mut encoder, &sp);
                    continue;
                }

                if data.len() != AUDIO_DATA_SIZE_U8 {
                    continue;
                }

                let data = unsafe { align_to_32(data.into()) };
                let data = unsafe {
                    std::slice::from_raw_parts::<f32>(data.as_ptr() as _, data.len() / 4)
                };
                send_f32(data, &mut encoder, &sp);
            }

            #[cfg(target_os = "android")]
            {
                let mut sent = false;
                while scrap::android::ffi::take_audio_frame(&mut android_frame) {
                    send_f32(&android_frame, &mut encoder, &sp);
                    sent = true;
                }
                if !sent {
                    // Chunks arrive every 10 ms; poll at that cadence instead of
                    // sleeping long enough to back up the capture queue.
                    hbb_common::sleep(0.01).await;
                }
            }
        }
        Ok(())
    }
}

#[inline]
#[cfg(feature = "screencapturekit")]
pub fn is_screen_capture_kit_available() -> bool {
    cpal::available_hosts()
        .iter()
        .any(|host| *host == cpal::HostId::ScreenCaptureKit)
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
mod cpal_impl {
    use self::service::{Reset, ServiceSwap};
    use super::*;
    use cpal::{
        traits::{DeviceTrait, HostTrait, StreamTrait},
        BufferSize, Device, Host, InputCallbackInfo, StreamConfig, SupportedStreamConfig,
    };

    lazy_static::lazy_static! {
        static ref HOST: Host = cpal::default_host();
    }

    #[cfg(feature = "screencapturekit")]
    lazy_static::lazy_static! {
        static ref HOST_SCREEN_CAPTURE_KIT: Result<Host, cpal::HostUnavailable> = cpal::host_from_id(cpal::HostId::ScreenCaptureKit);
    }

    #[derive(Default)]
    pub struct State {
        stream: Option<(Box<dyn StreamTrait>, Arc<Message>)>,
    }

    impl super::service::Reset for State {
        fn reset(&mut self) {
            self.stream.take();
        }
    }

    fn run_restart(sp: EmptyExtraFieldService, state: &mut State) -> ResultType<()> {
        state.reset();
        sp.snapshot(|_sps: ServiceSwap<_>| Ok(()))?;
        match &state.stream {
            None => {
                state.stream = Some(play(&sp)?);
            }
            _ => {}
        }
        if let Some((_, format)) = &state.stream {
            sp.send_shared(format.clone());
        }
        RESTARTING.store(false, Ordering::SeqCst);
        Ok(())
    }

    fn run_serv_snapshot(sp: EmptyExtraFieldService, state: &mut State) -> ResultType<()> {
        sp.snapshot(|sps| {
            match &state.stream {
                None => {
                    state.stream = Some(play(&sp)?);
                }
                _ => {}
            }
            if let Some((_, format)) = &state.stream {
                sps.send_shared(format.clone());
            }
            Ok(())
        })?;
        Ok(())
    }

    pub fn run(sp: EmptyExtraFieldService, state: &mut State) -> ResultType<()> {
        if !RESTARTING.load(Ordering::SeqCst) {
            run_serv_snapshot(sp, state)
        } else {
            run_restart(sp, state)
        }
    }

    #[cfg(feature = "screencapturekit")]
    fn get_device() -> ResultType<(Device, SupportedStreamConfig)> {
        let audio_input = super::get_audio_input();
        if !audio_input.is_empty() {
            return get_audio_input(&audio_input);
        }
        if !is_screen_capture_kit_available() {
            return get_audio_input("");
        }
        let device = HOST_SCREEN_CAPTURE_KIT
            .as_ref()?
            .default_input_device()
            .with_context(|| "Failed to get default input device for loopback")?;
        let format = device
            .default_input_config()
            .map_err(|e| anyhow!(e))
            .with_context(|| "Failed to get input output format")?;
        log::info!("Default input format: {:?}", format);
        Ok((device, format))
    }

    #[cfg(windows)]
    fn get_device() -> ResultType<(Device, SupportedStreamConfig)> {
        let audio_input = super::get_audio_input();
        if !audio_input.is_empty() {
            return get_audio_input(&audio_input);
        }
        let device = HOST
            .default_output_device()
            .with_context(|| "Failed to get default output device for loopback")?;
        log::info!(
            "Default output device: {}",
            device.name().unwrap_or("".to_owned())
        );
        let format = device
            .default_output_config()
            .map_err(|e| anyhow!(e))
            .with_context(|| "Failed to get default output format")?;
        log::info!("Default output format: {:?}", format);
        Ok((device, format))
    }

    #[cfg(not(any(windows, feature = "screencapturekit")))]
    fn get_device() -> ResultType<(Device, SupportedStreamConfig)> {
        let audio_input = super::get_audio_input();
        get_audio_input(&audio_input)
    }

    fn get_audio_input(audio_input: &str) -> ResultType<(Device, SupportedStreamConfig)> {
        let mut device = None;
        #[cfg(feature = "screencapturekit")]
        if !audio_input.is_empty() && is_screen_capture_kit_available() {
            for d in HOST_SCREEN_CAPTURE_KIT
                .as_ref()?
                .devices()
                .with_context(|| "Failed to get audio devices")?
            {
                if d.name().unwrap_or("".to_owned()) == audio_input {
                    device = Some(d);
                    break;
                }
            }
        }
        if device.is_none() && !audio_input.is_empty() {
            for d in HOST
                .devices()
                .with_context(|| "Failed to get audio devices")?
            {
                if d.name().unwrap_or("".to_owned()) == audio_input {
                    device = Some(d);
                    break;
                }
            }
        }
        let device = device.unwrap_or(
            HOST.default_input_device()
                .with_context(|| "Failed to get default input device for loopback")?,
        );
        log::info!("Input device: {}", device.name().unwrap_or("".to_owned()));
        let format = device
            .default_input_config()
            .map_err(|e| anyhow!(e))
            .with_context(|| "Failed to get default input format")?;
        log::info!("Default input format: {:?}", format);
        Ok((device, format))
    }

    fn play(sp: &GenericService) -> ResultType<(Box<dyn StreamTrait>, Arc<Message>)> {
        use cpal::SampleFormat::*;
        let (device, config) = get_device()?;
        let sp = sp.clone();
        let sample_rate = opus_sample_rate(config.sample_rate().0);
        let ch = if config.channels() > 1 { Stereo } else { Mono };
        let stream = match config.sample_format() {
            I8 => build_input_stream::<i8>(device, &config, sp, sample_rate, ch)?,
            I16 => build_input_stream::<i16>(device, &config, sp, sample_rate, ch)?,
            I32 => build_input_stream::<i32>(device, &config, sp, sample_rate, ch)?,
            I64 => build_input_stream::<i64>(device, &config, sp, sample_rate, ch)?,
            U8 => build_input_stream::<u8>(device, &config, sp, sample_rate, ch)?,
            U16 => build_input_stream::<u16>(device, &config, sp, sample_rate, ch)?,
            U32 => build_input_stream::<u32>(device, &config, sp, sample_rate, ch)?,
            U64 => build_input_stream::<u64>(device, &config, sp, sample_rate, ch)?,
            F32 => build_input_stream::<f32>(device, &config, sp, sample_rate, ch)?,
            F64 => build_input_stream::<f64>(device, &config, sp, sample_rate, ch)?,
            f => bail!("unsupported audio format: {:?}", f),
        };
        stream.play()?;
        Ok((
            Box::new(stream),
            Arc::new(create_format_msg(sample_rate, ch as _)),
        ))
    }

    fn build_input_stream<T>(
        device: cpal::Device,
        config: &cpal::SupportedStreamConfig,
        sp: GenericService,
        sample_rate: u32,
        encode_channel: magnum_opus::Channels,
    ) -> ResultType<cpal::Stream>
    where
        T: cpal::SizedSample + dasp::sample::ToSample<f32>,
    {
        let err_fn = move |err| {
            // too many UnknownErrno, will improve later
            log::trace!("an error occurred on stream: {}", err);
        };
        let sample_rate_0 = config.sample_rate().0;
        log::debug!("Audio sample rate : {} -> {}", sample_rate_0, sample_rate);
        AUDIO_ZERO_COUNT.store(0, Ordering::Relaxed);
        let device_channel = config.channels();
        let mut encoder = Encoder::new(sample_rate, encode_channel, LowDelay)?;
        let mut framer = CapturedPcmFramer::new(
            sample_rate_0,
            device_channel,
            sample_rate,
            encode_channel as u16,
        );
        // Resampling, Opus encoding and sending run off the realtime capture
        // callback. The worker ends when the stream drops the sender.
        let (mut capture, mut chunks) = capture_channel(INPUT_QUEUE_CHUNKS);
        std::thread::Builder::new()
            .name("audio-input-encoder".to_owned())
            .spawn(move || {
                while chunks.process_next(|chunk| {
                    framer.push(chunk, |frame| send_f32(frame, &mut encoder, &sp))
                }) {}
            })?;
        let timeout = None;
        let stream_config = StreamConfig {
            channels: device_channel,
            sample_rate: config.sample_rate(),
            buffer_size: BufferSize::Default,
        };
        let stream = device.build_input_stream(
            &stream_config,
            move |data: &[T], _: &InputCallbackInfo| {
                capture.send(data.iter().map(|s| T::to_sample(*s)));
            },
            err_fn,
            timeout,
        )?;
        Ok(stream)
    }
}

fn create_format_msg(sample_rate: u32, channels: u16) -> Message {
    let format = AudioFormat {
        sample_rate,
        channels: channels as _,
        ..Default::default()
    };
    let mut misc = Misc::new();
    misc.set_audio_format(format);
    let mut msg = Message::new();
    msg.set_misc(misc);
    msg
}

/// Opus accepts 8, 12, 16, 24 and 48 kHz. Use the highest supported rate that
/// does not exceed the device bandwidth class; 32 kHz and above (including
/// 44.1 kHz devices) use 48 kHz instead of being reduced to 24 kHz.
#[cfg(any(test, not(any(target_os = "linux", target_os = "android"))))]
fn opus_sample_rate(device_rate: u32) -> u32 {
    match device_rate {
        0..=11_999 => 8000,
        12_000..=15_999 => 12000,
        16_000..=23_999 => 16000,
        24_000..=31_999 => 24000,
        _ => 48000,
    }
}

/// Turns captured device PCM into exact 10 ms Opus frames: resamples with a
/// persistent phase, converts channels and re-chunks across callbacks.
#[cfg(any(test, not(any(target_os = "linux", target_os = "android"))))]
struct CapturedPcmFramer {
    resampler: scrap::pcm::StreamingResampler,
    frames: scrap::pcm::PcmQueue,
    frame: Vec<f32>,
    sample_rate: u32,
    device_channels: u16,
    encode_channels: u16,
}

#[cfg(any(test, not(any(target_os = "linux", target_os = "android"))))]
impl CapturedPcmFramer {
    fn new(device_rate: u32, device_channels: u16, sample_rate: u32, encode_channels: u16) -> Self {
        let channels = usize::from(encode_channels.max(1));
        Self {
            resampler: scrap::pcm::StreamingResampler::new(
                device_rate,
                sample_rate,
                device_channels,
            ),
            // At most one second waits for a complete Opus frame.
            frames: scrap::pcm::PcmQueue::new(encode_channels, sample_rate as usize * channels),
            frame: vec![0.0; (sample_rate / 100) as usize * channels],
            sample_rate,
            device_channels,
            encode_channels,
        }
    }

    fn push(&mut self, input: &[f32], mut emit: impl FnMut(&[f32])) {
        let mut resampled = Vec::with_capacity(input.len() + self.frame.len());
        self.resampler.process(input, &mut resampled);
        let data = if self.device_channels != self.encode_channels {
            crate::common::audio_rechannel(
                resampled,
                self.sample_rate,
                self.sample_rate,
                self.device_channels,
                self.encode_channels,
            )
        } else {
            resampled
        };
        self.frames.push(&data);
        while self.frames.pop_exact(&mut self.frame) {
            emit(&self.frame);
        }
    }
}

/// Creates the bounded handoff between the realtime capture callback and the
/// encoder worker. Buffers travel back to the callback for reuse, so steady
/// capture neither allocates nor logs on the callback thread.
#[cfg(any(test, not(any(target_os = "linux", target_os = "android"))))]
fn capture_channel(capacity: usize) -> (CaptureSender, CaptureReceiver) {
    let (chunk_tx, chunk_rx) = std::sync::mpsc::sync_channel(capacity);
    let (recycle_tx, recycle_rx) = std::sync::mpsc::sync_channel(capacity);
    let dropped = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    (
        CaptureSender {
            chunks: chunk_tx,
            recycled: recycle_rx,
            spare: None,
            dropped: dropped.clone(),
        },
        CaptureReceiver {
            chunks: chunk_rx,
            recycle: recycle_tx,
            dropped,
            next_drop_report: 1,
        },
    )
}

#[cfg(any(test, not(any(target_os = "linux", target_os = "android"))))]
struct CaptureSender {
    chunks: std::sync::mpsc::SyncSender<Vec<f32>>,
    recycled: std::sync::mpsc::Receiver<Vec<f32>>,
    spare: Option<Vec<f32>>,
    dropped: std::sync::Arc<std::sync::atomic::AtomicU64>,
}

#[cfg(any(test, not(any(target_os = "linux", target_os = "android"))))]
impl CaptureSender {
    /// Queues one callback's samples without blocking; counts a drop when the
    /// worker is behind and keeps the rejected buffer for the next call.
    fn send(&mut self, samples: impl Iterator<Item = f32>) {
        let mut buffer = self
            .spare
            .take()
            .or_else(|| self.recycled.try_recv().ok())
            .unwrap_or_default();
        buffer.clear();
        buffer.extend(samples);
        match self.chunks.try_send(buffer) {
            Ok(()) => {}
            Err(
                std::sync::mpsc::TrySendError::Full(buffer)
                | std::sync::mpsc::TrySendError::Disconnected(buffer),
            ) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
                self.spare = Some(buffer);
            }
        }
    }
}

#[cfg(any(test, not(any(target_os = "linux", target_os = "android"))))]
struct CaptureReceiver {
    chunks: std::sync::mpsc::Receiver<Vec<f32>>,
    recycle: std::sync::mpsc::SyncSender<Vec<f32>>,
    dropped: std::sync::Arc<std::sync::atomic::AtomicU64>,
    next_drop_report: u64,
}

#[cfg(any(test, not(any(target_os = "linux", target_os = "android"))))]
impl CaptureReceiver {
    /// Waits for the next captured chunk, passes it to `process` and returns
    /// the buffer for reuse. Returns false once the capture side is gone.
    fn process_next(&mut self, process: impl FnOnce(&[f32])) -> bool {
        let Ok(chunk) = self.chunks.recv() else {
            return false;
        };
        process(&chunk);
        let _ = self.recycle.try_send(chunk);
        // Report callback drops here, with exponential backoff: 1, 2, 4, ...
        let dropped = self.dropped.load(Ordering::Relaxed);
        if dropped >= self.next_drop_report {
            log::warn!("audio input encoder is behind, dropped {} chunks", dropped);
            self.next_drop_report = dropped.saturating_mul(2);
        }
        true
    }
}

// use AUDIO_ZERO_COUNT for the Noise(Zero) Gate Attack Time
// every audio data length is set to 480
// MAX_AUDIO_ZERO_COUNT=800 is similar as Gate Attack Time 3~5s(Linux) || 6~8s(Windows)
const MAX_AUDIO_ZERO_COUNT: u16 = 800;
static AUDIO_ZERO_COUNT: AtomicU16 = AtomicU16::new(0);

fn send_f32(data: &[f32], encoder: &mut Encoder, sp: &GenericService) {
    if data.iter().any(|x| *x != 0.) {
        AUDIO_ZERO_COUNT.store(0, Ordering::Relaxed);
    } else {
        let count = AUDIO_ZERO_COUNT.load(Ordering::Relaxed);
        if count > MAX_AUDIO_ZERO_COUNT {
            if count == MAX_AUDIO_ZERO_COUNT + 1 {
                log::debug!("Audio Zero Gate Attack");
                AUDIO_ZERO_COUNT.store(count + 1, Ordering::Relaxed);
            }
            return;
        }
        AUDIO_ZERO_COUNT.store(count + 1, Ordering::Relaxed);
    }
    #[cfg(target_os = "android")]
    {
        // the permitted opus data size are 120, 240, 480, 960, 1920, and 2880
        // if data size is bigger than BATCH_SIZE, AND is an integer multiple of BATCH_SIZE
        // then upload in batches
        const BATCH_SIZE: usize = 960;
        let input_size = data.len();
        if input_size >= BATCH_SIZE && input_size % BATCH_SIZE == 0 {
            let n = input_size / BATCH_SIZE;
            for i in 0..n {
                match encoder
                    .encode_vec_float(&data[i * BATCH_SIZE..(i + 1) * BATCH_SIZE], BATCH_SIZE)
                {
                    Ok(data) => {
                        let mut msg_out = Message::new();
                        msg_out.set_audio_frame(AudioFrame {
                            data: data.into(),
                            ..Default::default()
                        });
                        sp.send(msg_out);
                    }
                    Err(_) => {}
                }
            }
        } else {
            log::debug!("invalid audio data size:{} ", input_size);
            return;
        }
    }

    #[cfg(not(target_os = "android"))]
    match encoder.encode_vec_float(data, data.len() * 6) {
        Ok(data) => {
            let mut msg_out = Message::new();
            msg_out.set_audio_frame(AudioFrame {
                data: data.into(),
                ..Default::default()
            });
            sp.send(msg_out);
        }
        Err(_) => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_handoff_reuses_buffers() {
        let (mut capture, mut chunks) = capture_channel(4);
        let mut first = std::ptr::null();
        capture.send([1.0, 2.0, 3.0].iter().copied());
        assert!(chunks.process_next(|chunk| {
            assert_eq!(chunk, [1.0, 2.0, 3.0]);
            first = chunk.as_ptr();
        }));
        capture.send([4.0, 5.0].iter().copied());
        assert!(chunks.process_next(|chunk| {
            assert_eq!(chunk, [4.0, 5.0]);
            assert_eq!(chunk.as_ptr(), first, "recycled buffer is reused");
        }));
    }

    #[test]
    fn capture_handoff_counts_drops_without_blocking() {
        let (mut capture, mut chunks) = capture_channel(1);
        capture.send([1.0].iter().copied());
        capture.send([2.0].iter().copied());
        capture.send([3.0].iter().copied());
        assert_eq!(chunks.dropped.load(Ordering::Relaxed), 2);
        assert!(chunks.process_next(|chunk| assert_eq!(chunk, [1.0])));
        assert_eq!(chunks.next_drop_report, 4);
        capture.send([4.0].iter().copied());
        assert!(chunks.process_next(|chunk| assert_eq!(chunk, [4.0])));
        drop(capture);
        assert!(!chunks.process_next(|_| panic!("no chunk after disconnect")));
    }

    #[test]
    fn opus_rate_keeps_full_band_for_common_device_rates() {
        for (device, expected) in [
            (8000, 8000),
            (11025, 8000),
            (12000, 12000),
            (16000, 16000),
            (22050, 16000),
            (24000, 24000),
            (32000, 48000),
            (44100, 48000),
            (48000, 48000),
            (96000, 48000),
        ] {
            assert_eq!(opus_sample_rate(device), expected, "device={device}");
        }
    }

    fn frames_for(device_rate: u32, device_channels: u16, callback_frames: usize) -> Vec<usize> {
        let sample_rate = opus_sample_rate(device_rate);
        let mut framer = CapturedPcmFramer::new(device_rate, device_channels, sample_rate, 2);
        let input = vec![0.25f32; callback_frames * usize::from(device_channels)];
        let mut emitted = Vec::new();
        // One second of capture.
        for _ in 0..(device_rate as usize / callback_frames) {
            framer.push(&input, |frame| emitted.push(frame.len()));
        }
        emitted
    }

    #[test]
    fn framer_emits_exact_opus_frames_for_441_khz_capture() {
        let emitted = frames_for(44100, 2, 441);
        assert!(emitted.iter().all(|len| *len == 960), "{emitted:?}");
        assert!((99..=100).contains(&emitted.len()), "frames={}", emitted.len());
    }

    #[test]
    fn framer_rechunks_odd_callback_sizes() {
        let emitted = frames_for(48000, 2, 512);
        assert!(emitted.iter().all(|len| *len == 960));
        // 93 callbacks * 512 frames = 47616 frames -> 99 full 10 ms frames.
        assert_eq!(emitted.len(), 99);
    }

    #[test]
    fn framer_downmixes_surround_capture_to_the_encoder_layout() {
        let emitted = frames_for(48000, 6, 480);
        assert_eq!(emitted.len(), 100);
        assert!(emitted.iter().all(|len| *len == 960));
    }
}
