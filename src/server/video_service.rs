// 24FPS (actually 23.976FPS) is what video professionals ages ago determined to be the
// slowest playback rate that still looks smooth enough to feel real.
// Our eyes can see a slight difference and even though 30FPS actually shows
// more information and is more realistic.
// 60FPS is commonly used in game, teamviewer 12 support this for video editing user.

// how to capture with mouse cursor:
// https://docs.microsoft.com/zh-cn/windows/win32/direct3ddxgi/desktop-dup-api?redirectedfrom=MSDN

// RECORD: The following Project has implemented audio capture, hardware codec and mouse cursor drawn.
// https://github.com/PHZ76/DesktopSharing

// dxgi memory leak issue
// https://stackoverflow.com/questions/47801238/memory-leak-in-creating-direct2d-device
// but per my test, it is more related to AcquireNextFrame,
// https://forums.developer.nvidia.com/t/dxgi-outputduplication-memory-leak-when-using-nv-but-not-amd-drivers/108582

// to-do:
// https://slhck.info/video/2017/03/01/rate-control.html

use super::{display_service::check_display_changed, service::ServiceTmpl, video_qos::VideoQoS, *};
#[cfg(target_os = "linux")]
use crate::common::SimpleCallOnReturn;
#[cfg(target_os = "linux")]
use crate::platform::linux::is_x11;
use crate::privacy_mode::{get_privacy_mode_conn_id, INVALID_PRIVACY_MODE_CONN_ID};
#[cfg(windows)]
use crate::{
    platform::windows::is_process_consent_running,
    privacy_mode::{is_current_privacy_mode_impl, PRIVACY_MODE_IMPL_WIN_MAG},
    ui_interface::is_installed,
};
use hbb_common::{
    anyhow::anyhow,
    config,
    tokio::sync::{
        mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender},
        Mutex as TokioMutex,
    },
};
#[cfg(feature = "hwcodec")]
use scrap::hwcodec::{HwRamEncoder, HwRamEncoderConfig};
#[cfg(feature = "vram")]
use scrap::vram::{VRamEncoder, VRamEncoderConfig};
use scrap::{
    aom::AomEncoderConfig,
    codec::{Encoder, EncoderCfg},
    record::{Recorder, RecorderContext},
    vpxcodec::{VpxEncoderConfig, VpxVideoCodecId},
    Capturer, CodecFormat, Display, EncodeInput, Pixfmt, TraitCapturer, TraitPixelBuffer,
};
#[cfg(windows)]
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Once,
};
use std::{
    collections::HashSet,
    io::ErrorKind::WouldBlock,
    ops::{Deref, DerefMut},
    time::{self, Duration, Instant},
};

pub const OPTION_REFRESH: &'static str = "refresh";
const ENCODE_NO_VALID_FRAME: &str = "no valid frame";
const HW_ENCODER_WARMUP_TIMEOUT: Duration = Duration::from_secs(3);
const HOST_VIDEO_DIAG_INTERVAL: Duration = Duration::from_secs(5);
#[cfg(windows)]
const USER_CAPTURE_HELPER_STARTUP_TIMEOUT: Duration = Duration::from_secs(3);

fn capture_frame_label(frame: &scrap::Frame<'_>) -> &'static str {
    match frame {
        scrap::Frame::Texture(_) => "GPU texture frame",
        scrap::Frame::PixelBuffer(pixelbuffer) => match pixelbuffer.pixfmt() {
            Pixfmt::BGRA => "CPU BGRA frame",
            Pixfmt::RGBA => "CPU RGBA frame",
            Pixfmt::RGB565LE => "CPU RGB565 frame",
            Pixfmt::I420 => "CPU I420 frame",
            Pixfmt::NV12 => "CPU NV12 frame",
            Pixfmt::I444 => "CPU I444 frame",
        },
    }
}

#[cfg(windows)]
static USER_CAPTURE_HELPER_DISABLED: AtomicBool = AtomicBool::new(false);

type FrameFetchedNotifierSender = UnboundedSender<(i32, Option<Instant>)>;
type FrameFetchedNotifierReceiver = Arc<TokioMutex<UnboundedReceiver<(i32, Option<Instant>)>>>;

lazy_static::lazy_static! {
    static ref FRAME_FETCHED_NOTIFIERS: Mutex<HashMap<usize, (FrameFetchedNotifierSender, FrameFetchedNotifierReceiver)>> = Mutex::new(HashMap::default());

    // display_idx -> set of conn id.
    // Used to record which connections need to be notified when
    // 1. A new frame is received from a web client.
    //   Because web client does not send the display index in message `VideoReceived`.
    // 2. The client is closing.
    static ref DISPLAY_CONN_IDS: Arc<Mutex<HashMap<usize, HashSet<i32>>>> = Default::default();
    pub static ref VIDEO_QOS: Arc<Mutex<VideoQoS>> = Default::default();
    pub static ref IS_UAC_RUNNING: Arc<Mutex<bool>> = Default::default();
    pub static ref IS_FOREGROUND_WINDOW_ELEVATED: Arc<Mutex<bool>> = Default::default();
    static ref SCREENSHOTS: Mutex<HashMap<usize, Screenshot>> = Default::default();
}

struct Screenshot {
    sid: String,
    tx: Sender,
    restore_vram: bool,
}

#[inline]
pub fn notify_video_frame_fetched(display_idx: usize, conn_id: i32, frame_tm: Option<Instant>) {
    if let Some(notifier) = FRAME_FETCHED_NOTIFIERS.lock().unwrap().get(&display_idx) {
        notifier.0.send((conn_id, frame_tm)).ok();
    }
}

#[inline]
pub fn notify_video_frame_fetched_by_conn_id(conn_id: i32, frame_tm: Option<Instant>) {
    let vec_display_idx: Vec<usize> = {
        let display_conn_ids = DISPLAY_CONN_IDS.lock().unwrap();
        display_conn_ids
            .iter()
            .filter_map(|(display_idx, conn_ids)| {
                if conn_ids.contains(&conn_id) {
                    Some(*display_idx)
                } else {
                    None
                }
            })
            .collect()
    };
    let notifiers = FRAME_FETCHED_NOTIFIERS.lock().unwrap();
    for display_idx in vec_display_idx {
        if let Some(notifier) = notifiers.get(&display_idx) {
            notifier.0.send((conn_id, frame_tm)).ok();
        }
    }
}

struct VideoFrameController {
    display_idx: usize,
    cur: Instant,
    send_conn_ids: HashSet<i32>,
}

impl VideoFrameController {
    fn new(display_idx: usize) -> Self {
        Self {
            display_idx,
            cur: Instant::now(),
            send_conn_ids: HashSet::new(),
        }
    }

    fn reset(&mut self) {
        self.send_conn_ids.clear();
    }

    fn set_send(&mut self, tm: Instant, conn_ids: HashSet<i32>) {
        if !conn_ids.is_empty() {
            self.cur = tm;
            self.send_conn_ids = conn_ids;
            DISPLAY_CONN_IDS
                .lock()
                .unwrap()
                .insert(self.display_idx, self.send_conn_ids.clone());
        }
    }

    #[tokio::main(flavor = "current_thread")]
    async fn try_wait_next(&mut self, fetched_conn_ids: &mut HashSet<i32>, timeout_millis: u64) {
        if self.send_conn_ids.is_empty() {
            return;
        }

        let timeout_dur = Duration::from_millis(timeout_millis as u64);
        let receiver = {
            match FRAME_FETCHED_NOTIFIERS
                .lock()
                .unwrap()
                .get(&self.display_idx)
            {
                Some(notifier) => notifier.1.clone(),
                None => {
                    return;
                }
            }
        };
        let mut receiver_guard = receiver.lock().await;
        match tokio::time::timeout(timeout_dur, receiver_guard.recv()).await {
            Err(_) => {
                // break if timeout
                // log::error!("blocking wait frame receiving timeout {}", timeout_millis);
            }
            Ok(Some((id, instant))) => {
                if let Some(tm) = instant {
                    log::trace!("Channel recv latency: {}", tm.elapsed().as_secs_f32());
                }
                fetched_conn_ids.insert(id);
            }
            Ok(None) => {
                // this branch would never be reached
            }
        }
        while !receiver_guard.is_empty() {
            if let Some((id, instant)) = receiver_guard.recv().await {
                if let Some(tm) = instant {
                    log::trace!("Channel recv latency: {}", tm.elapsed().as_secs_f32());
                }
                fetched_conn_ids.insert(id);
            }
        }
    }
}

struct HostVideoDiagnostics {
    last_log: Instant,
    valid_capture: usize,
    invalid_capture: usize,
    would_block: usize,
    encode_calls: usize,
    repeat_encode_calls: usize,
    sent_batches: usize,
    sent_targets: usize,
    empty_send_results: usize,
    wait_frames: usize,
    wait_timeouts: usize,
    wait_total_ms: u128,
    wait_max_ms: u128,
}

impl HostVideoDiagnostics {
    fn new() -> Self {
        Self {
            last_log: Instant::now(),
            valid_capture: 0,
            invalid_capture: 0,
            would_block: 0,
            encode_calls: 0,
            repeat_encode_calls: 0,
            sent_batches: 0,
            sent_targets: 0,
            empty_send_results: 0,
            wait_frames: 0,
            wait_timeouts: 0,
            wait_total_ms: 0,
            wait_max_ms: 0,
        }
    }

    fn record_send_result(&mut self, send_conn_count: usize) {
        self.encode_calls += 1;
        if send_conn_count == 0 {
            self.empty_send_results += 1;
            return;
        }
        self.sent_batches += 1;
        self.sent_targets += send_conn_count;
    }

    fn record_wait(&mut self, expected: usize, fetched: usize, elapsed: Duration) {
        if expected == 0 {
            return;
        }
        let elapsed_ms = elapsed.as_millis();
        self.wait_frames += 1;
        self.wait_total_ms += elapsed_ms;
        self.wait_max_ms = self.wait_max_ms.max(elapsed_ms);
        if fetched < expected {
            self.wait_timeouts += 1;
        }
    }

    fn maybe_log(
        &mut self,
        service_name: &str,
        source: VideoSource,
        display_idx: usize,
        negotiated_codec: CodecFormat,
        hardware: bool,
        bitrate: u32,
        quality: f32,
        spf: Duration,
        gdi: bool,
    ) {
        if self.last_log.elapsed() < HOST_VIDEO_DIAG_INTERVAL {
            return;
        }
        let target_fps = if spf.as_nanos() == 0 {
            0.0
        } else {
            1.0 / spf.as_secs_f64()
        };
        let wait_avg_ms = if self.wait_frames == 0 {
            0
        } else {
            self.wait_total_ms / self.wait_frames as u128
        };
        log::info!(
            "diag host fps: service={}, source={:?}, display_idx={}, codec={:?}, hardware={}, bitrate={}, quality={:.3}, target_fps={:.1}, gdi={}, valid_capture={}, invalid_capture={}, would_block={}, encode_calls={}, repeat_encode_calls={}, sent_batches={}, sent_targets={}, empty_send_results={}, wait_frames={}, wait_timeouts={}, wait_avg_ms={}, wait_max_ms={}",
            service_name,
            source,
            display_idx,
            negotiated_codec,
            hardware,
            bitrate,
            quality,
            target_fps,
            gdi,
            self.valid_capture,
            self.invalid_capture,
            self.would_block,
            self.encode_calls,
            self.repeat_encode_calls,
            self.sent_batches,
            self.sent_targets,
            self.empty_send_results,
            self.wait_frames,
            self.wait_timeouts,
            wait_avg_ms,
            self.wait_max_ms
        );
        *self = Self::new();
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VideoSource {
    Monitor,
    Camera,
}

impl VideoSource {
    pub fn service_name_prefix(&self) -> &'static str {
        match self {
            VideoSource::Monitor => "monitor",
            VideoSource::Camera => "camera",
        }
    }

    pub fn is_monitor(&self) -> bool {
        matches!(self, VideoSource::Monitor)
    }

    pub fn is_camera(&self) -> bool {
        matches!(self, VideoSource::Camera)
    }
}

#[derive(Clone)]
pub struct VideoService {
    sp: GenericService,
    idx: usize,
    source: VideoSource,
}

impl Deref for VideoService {
    type Target = ServiceTmpl<ConnInner>;

    fn deref(&self) -> &Self::Target {
        &self.sp
    }
}

impl DerefMut for VideoService {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.sp
    }
}

pub fn get_service_name(source: VideoSource, idx: usize) -> String {
    format!("{}{}", source.service_name_prefix(), idx)
}

pub fn new(source: VideoSource, idx: usize) -> GenericService {
    let _ = FRAME_FETCHED_NOTIFIERS
        .lock()
        .unwrap()
        .entry(idx)
        .or_insert_with(|| {
            let (tx, rx) = unbounded_channel();
            (tx, Arc::new(TokioMutex::new(rx)))
        });
    let vs = VideoService {
        sp: GenericService::new(get_service_name(source, idx), true),
        idx,
        source,
    };
    GenericService::run(&vs, run);
    vs.sp
}

// Capturer object is expensive, avoiding to create it frequently.
#[cfg(windows)]
fn should_use_user_capture_helper(portable_service_running: bool, privacy_mode_id: i32) -> bool {
    let privacy_mode_ok = privacy_mode_id == INVALID_PRIVACY_MODE_CONN_ID;
    let helper_disabled = USER_CAPTURE_HELPER_DISABLED.load(Ordering::Relaxed);
    let is_root = crate::platform::is_root();
    let installed = is_installed();
    let prelogin = crate::platform::windows::is_prelogin();
    let locked = crate::platform::windows::is_locked();
    let desktop_changed = crate::platform::windows::desktop_changed();
    let use_helper = privacy_mode_ok
        && !helper_disabled
        && !portable_service_running
        && is_root
        && installed
        && !prelogin
        && !locked
        && !desktop_changed;
    let mut blocked_by = Vec::new();
    if !privacy_mode_ok {
        blocked_by.push("privacy_mode");
    }
    if helper_disabled {
        blocked_by.push("helper_disabled");
    }
    if portable_service_running {
        blocked_by.push("portable_service");
    }
    if !is_root {
        blocked_by.push("not_service");
    }
    if !installed {
        blocked_by.push("not_installed");
    }
    if prelogin {
        blocked_by.push("prelogin");
    }
    if locked {
        blocked_by.push("locked");
    }
    if desktop_changed {
        blocked_by.push("desktop_changed");
    }
    let blocked_by = if blocked_by.is_empty() {
        "none".to_owned()
    } else {
        blocked_by.join(",")
    };
    log::info!(
        "user capture helper decision: use_helper={}, blocked_by={}, privacy_mode_id={}, portable_service_running={}, is_root={}, installed={}, prelogin={}, locked={}, desktop_changed={}",
        use_helper,
        blocked_by,
        privacy_mode_id,
        portable_service_running,
        is_root,
        installed,
        prelogin,
        locked,
        desktop_changed
    );
    use_helper
}

#[cfg(windows)]
fn can_use_direct_wgc(privacy_mode_id: i32) -> bool {
    privacy_mode_id == INVALID_PRIVACY_MODE_CONN_ID
        && !crate::platform::windows::is_prelogin()
        && !crate::platform::windows::is_locked()
        && !crate::platform::windows::desktop_changed()
}

#[cfg(windows)]
fn create_wgc_priority_capturer(
    privacy_mode_id: i32,
    current: usize,
    portable_service_running: bool,
    width: usize,
    height: usize,
) -> ResultType<Box<dyn TraitCapturer>> {
    if should_use_user_capture_helper(portable_service_running, privacy_mode_id) {
        match crate::server::user_capture_helper::client::create_capturer(current, width, height) {
            Ok(capturer) => {
                log::info!("Create capturer via user WGC helper");
                return Ok(capturer);
            }
            Err(err) => {
                log::warn!(
                    "Failed to create user WGC helper capturer, falling back to direct WGC: {}",
                    err
                );
            }
        }
    }

    if !can_use_direct_wgc(privacy_mode_id) {
        bail!("direct WGC is not valid for current desktop state");
    }
    if !scrap::CapturerWgc::is_supported() {
        bail!("WGC is not supported");
    }
    let mut displays = Display::all().with_context(|| "Failed to enumerate displays for WGC")?;
    if displays.len() <= current {
        bail!(
            "Failed to get display {} for WGC capturer, display_count={}",
            current,
            displays.len()
        );
    }
    let wgc_display = displays.remove(current);
    let capturer = scrap::CapturerWgc::new(wgc_display)
        .with_context(|| "Failed to create direct WGC capturer")?;
    log::info!("Create direct WGC capturer");
    Ok(Box::new(capturer))
}

#[cfg(windows)]
fn create_magnifier_priority_capturer(
    privacy_mode_id: i32,
    origin: (i32, i32),
    width: usize,
    height: usize,
) -> ResultType<Box<dyn TraitCapturer>> {
    if privacy_mode_id != INVALID_PRIVACY_MODE_CONN_ID {
        bail!("magnifier priority capture is skipped in privacy mode");
    }
    if !can_try_magnifier_fallback("auto_priority") {
        bail!("magnifier priority capture is not valid for current desktop state");
    }
    let mag = scrap::CapturerMag::new(origin, width, height)
        .with_context(|| "Failed to create magnifier capturer")?;
    log::info!(
        "Create magnifier capturer by priority: origin={:?}, width={}, height={}",
        origin,
        width,
        height
    );
    Ok(Box::new(mag))
}

#[cfg(windows)]
fn create_dxgi_priority_capturer(
    display: Display,
    current: usize,
    portable_service_running: bool,
) -> ResultType<Box<dyn TraitCapturer>> {
    log::debug!("Create capturer dxgi|gdi");
    crate::portable_service::client::create_capturer(current, display, portable_service_running)
}

#[cfg(any(windows, test))]
fn should_force_portable_secure_capturer(
    portable_service_running: bool,
    prelogin: bool,
    locked: bool,
    desktop_changed: bool,
) -> bool {
    portable_service_running && (prelogin || locked || desktop_changed)
}

#[cfg(test)]
mod tests {
    use super::should_force_portable_secure_capturer;

    #[test]
    fn test_portable_secure_capture_routing_requires_secure_desktop() {
        assert!(!should_force_portable_secure_capturer(
            false, true, true, true
        ));
        assert!(!should_force_portable_secure_capturer(
            true, false, false, false
        ));
        assert!(should_force_portable_secure_capturer(
            true, true, false, false
        ));
        assert!(should_force_portable_secure_capturer(
            true, false, true, false
        ));
        assert!(should_force_portable_secure_capturer(
            true, false, false, true
        ));
    }
}

#[cfg(windows)]
fn create_gdi_priority_capturer(current: usize) -> ResultType<Box<dyn TraitCapturer>> {
    let mut displays = Display::all().with_context(|| "Failed to enumerate displays for GDI")?;
    if displays.len() <= current {
        bail!(
            "Failed to get display {} for GDI capturer, display_count={}",
            current,
            displays.len()
        );
    }
    let display = displays.remove(current);
    let mut capturer =
        Capturer::new(display).with_context(|| "Failed to create fallback GDI capturer")?;
    if !capturer.set_gdi() {
        bail!("Failed to enable fallback GDI capturer");
    }
    log::info!("Create GDI capturer by final priority fallback");
    Ok(Box::new(capturer))
}

#[cfg(windows)]
fn create_windows_capturer(
    privacy_mode_id: i32,
    display: Display,
    current: usize,
    portable_service_running: bool,
) -> ResultType<Box<dyn TraitCapturer>> {
    let origin = display.origin();
    let width = display.width();
    let height = display.height();
    log::info!(
        "capture auto backend priority requested: display={}, size={}x{}, priority=WGC,WinMag,DXGI,GDI",
        current,
        width,
        height
    );

    let prelogin = crate::platform::windows::is_prelogin();
    let locked = crate::platform::windows::is_locked();
    let desktop_changed = crate::platform::windows::desktop_changed();
    if should_force_portable_secure_capturer(
        portable_service_running,
        prelogin,
        locked,
        desktop_changed,
    ) {
        log::info!(
            "capture auto backend selected: Portable SYSTEM helper before WGC/WinMag, prelogin={}, locked={}, desktop_changed={}",
            prelogin,
            locked,
            desktop_changed
        );
        return create_dxgi_priority_capturer(display, current, portable_service_running);
    }

    match create_wgc_priority_capturer(
        privacy_mode_id,
        current,
        portable_service_running,
        width,
        height,
    ) {
        Ok(capturer) => {
            log::info!("capture auto backend selected: WGC");
            return Ok(capturer);
        }
        Err(err) => {
            log::info!("capture auto backend WGC skipped: {}", err);
        }
    }

    match create_magnifier_priority_capturer(privacy_mode_id, origin, width, height) {
        Ok(capturer) => {
            log::info!("capture auto backend selected: WinMag");
            return Ok(capturer);
        }
        Err(err) => {
            log::info!("capture auto backend WinMag skipped: {}", err);
        }
    }

    match create_dxgi_priority_capturer(display, current, portable_service_running) {
        Ok(capturer) => {
            log::info!(
                "capture auto backend selected: {}",
                capturer.capture_backend()
            );
            Ok(capturer)
        }
        Err(dxgi_err) => {
            log::warn!("capture auto backend DXGI/GDI failed: {}", dxgi_err);
            create_gdi_priority_capturer(current)
        }
    }
}

fn create_capturer(
    privacy_mode_id: i32,
    display: Display,
    current: usize,
    portable_service_running: bool,
) -> ResultType<Box<dyn TraitCapturer>> {
    #[cfg(not(windows))]
    let _ = (current, portable_service_running);
    #[cfg(not(windows))]
    let c: Option<Box<dyn TraitCapturer>> = None;
    #[cfg(windows)]
    let mut c: Option<Box<dyn TraitCapturer>> = None;
    if privacy_mode_id > 0 {
        #[cfg(windows)]
        {
            if let Some(c1) = crate::privacy_mode::win_mag::create_capturer(
                privacy_mode_id,
                display.origin(),
                display.width(),
                display.height(),
            )? {
                c = Some(Box::new(c1));
            }
        }
    }

    match c {
        Some(c1) => return Ok(c1),
        None => {
            #[cfg(windows)]
            {
                return create_windows_capturer(
                    privacy_mode_id,
                    display,
                    current,
                    portable_service_running,
                );
            }
            #[cfg(not(windows))]
            {
                log::debug!("Create capturer from scrap");
                return Ok(Box::new(
                    Capturer::new(display).with_context(|| "Failed to create capturer")?,
                ));
            }
        }
    };
}

// This function works on privacy mode. Windows only for now.
pub fn test_create_capturer(
    privacy_mode_id: i32,
    display_idx: usize,
    timeout_millis: u64,
) -> String {
    let test_begin = Instant::now();
    loop {
        let err = match Display::all() {
            Ok(mut displays) => {
                if displays.len() <= display_idx {
                    anyhow!(
                        "Failed to get display {}, the displays' count is {}",
                        display_idx,
                        displays.len()
                    )
                } else {
                    let display = displays.remove(display_idx);
                    match create_capturer(privacy_mode_id, display, display_idx, false) {
                        Ok(_) => return "".to_owned(),
                        Err(e) => e,
                    }
                }
            }
            Err(e) => e.into(),
        };
        if test_begin.elapsed().as_millis() >= timeout_millis as _ {
            return err.to_string();
        }
        std::thread::sleep(Duration::from_millis(300));
    }
}

// Note: This function is extremely expensive, do not call it frequently.
#[cfg(windows)]
fn check_uac_switch(privacy_mode_id: i32, capturer_privacy_mode_id: i32) -> ResultType<()> {
    if capturer_privacy_mode_id != INVALID_PRIVACY_MODE_CONN_ID
        && is_current_privacy_mode_impl(PRIVACY_MODE_IMPL_WIN_MAG)
    {
        if !is_installed() {
            if privacy_mode_id != capturer_privacy_mode_id {
                if !is_process_consent_running()? {
                    bail!("consent.exe is not running");
                }
            }
            if is_process_consent_running()? {
                bail!("consent.exe is running");
            }
        }
    }
    Ok(())
}

pub(super) struct CapturerInfo {
    pub origin: (i32, i32),
    pub width: usize,
    pub height: usize,
    pub ndisplay: usize,
    pub current: usize,
    pub privacy_mode_id: i32,
    pub _capturer_privacy_mode_id: i32,
    pub capturer: Box<dyn TraitCapturer>,
}

impl Deref for CapturerInfo {
    type Target = Box<dyn TraitCapturer>;

    fn deref(&self) -> &Self::Target {
        &self.capturer
    }
}

impl DerefMut for CapturerInfo {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.capturer
    }
}

fn get_capturer_monitor(
    current: usize,
    portable_service_running: bool,
) -> ResultType<CapturerInfo> {
    #[cfg(target_os = "linux")]
    {
        if !is_x11() {
            return super::wayland::get_capturer_for_display(current);
        }
    }

    let mut displays = Display::all()?;
    let ndisplay = displays.len();
    if ndisplay <= current {
        bail!(
            "Failed to get display {}, displays len: {}",
            current,
            ndisplay
        );
    }

    let display = displays.remove(current);

    #[cfg(target_os = "linux")]
    if let Display::X11(inner) = &display {
        if let Err(err) = inner.get_shm_status() {
            log::warn!(
                "MIT-SHM extension not working properly on select X11 server: {:?}",
                err
            );
        }
    }

    let (origin, width, height) = (display.origin(), display.width(), display.height());
    let name = display.name();
    log::debug!(
        "#displays={}, current={}, origin: {:?}, width={}, height={}, cpus={}/{}, name:{}",
        ndisplay,
        current,
        &origin,
        width,
        height,
        num_cpus::get_physical(),
        num_cpus::get(),
        &name,
    );

    let privacy_mode_id = get_privacy_mode_conn_id().unwrap_or(INVALID_PRIVACY_MODE_CONN_ID);
    #[cfg(not(windows))]
    let capturer_privacy_mode_id = privacy_mode_id;
    #[cfg(windows)]
    let mut capturer_privacy_mode_id = privacy_mode_id;
    #[cfg(windows)]
    {
        if capturer_privacy_mode_id != INVALID_PRIVACY_MODE_CONN_ID
            && is_current_privacy_mode_impl(PRIVACY_MODE_IMPL_WIN_MAG)
        {
            if crate::platform::windows::is_prelogin()
                || crate::platform::windows::desktop_changed()
                || (crate::platform::is_root() && crate::platform::windows::is_locked())
            {
                log::warn!(
                    "WinMag privacy capture disabled on prelogin/service-locked/changed desktop; using normal service capture"
                );
                capturer_privacy_mode_id = INVALID_PRIVACY_MODE_CONN_ID;
            }
            if !is_installed() {
                if is_process_consent_running()? {
                    capturer_privacy_mode_id = INVALID_PRIVACY_MODE_CONN_ID;
                }
            }
        }
    }
    log::debug!(
        "Try create capturer with capturer privacy mode id {}",
        capturer_privacy_mode_id,
    );

    if privacy_mode_id != INVALID_PRIVACY_MODE_CONN_ID {
        if privacy_mode_id != capturer_privacy_mode_id {
            log::info!(
                "In privacy mode, but current desktop requires normal service capture for now"
            );
        } else {
            log::info!("In privacy mode, the peer side cannot watch the screen");
        }
    }
    let capturer = create_capturer(
        capturer_privacy_mode_id,
        display,
        current,
        portable_service_running,
    )?;
    Ok(CapturerInfo {
        origin,
        width,
        height,
        ndisplay,
        current,
        privacy_mode_id,
        _capturer_privacy_mode_id: capturer_privacy_mode_id,
        capturer,
    })
}

fn get_capturer_camera(current: usize) -> ResultType<CapturerInfo> {
    let cameras = camera::Cameras::get_sync_cameras();
    let ncamera = cameras.len();
    if ncamera <= current {
        bail!("Failed to get camera {}, cameras len: {}", current, ncamera,);
    }
    let Some(camera) = cameras.get(current) else {
        bail!(
            "Camera of index {} doesn't exist or platform not supported",
            current
        );
    };
    let capturer = camera::Cameras::get_capturer(current)?;
    let (width, height) = (camera.width as usize, camera.height as usize);
    let origin = (camera.x as i32, camera.y as i32);
    let name = &camera.name;
    let privacy_mode_id = get_privacy_mode_conn_id().unwrap_or(INVALID_PRIVACY_MODE_CONN_ID);
    let _capturer_privacy_mode_id = privacy_mode_id;
    log::debug!(
        "#cameras={}, current={}, origin: {:?}, width={}, height={}, cpus={}/{}, name:{}",
        ncamera,
        current,
        &origin,
        width,
        height,
        num_cpus::get_physical(),
        num_cpus::get(),
        name,
    );
    return Ok(CapturerInfo {
        origin,
        width,
        height,
        ndisplay: ncamera,
        current,
        privacy_mode_id,
        _capturer_privacy_mode_id: privacy_mode_id,
        capturer,
    });
}
fn get_capturer(
    source: VideoSource,
    current: usize,
    portable_service_running: bool,
) -> ResultType<CapturerInfo> {
    match source {
        VideoSource::Monitor => get_capturer_monitor(current, portable_service_running),
        VideoSource::Camera => get_capturer_camera(current),
    }
}

#[cfg(windows)]
fn can_try_magnifier_fallback(reason: &str) -> bool {
    let prelogin = crate::platform::windows::is_prelogin();
    let locked = crate::platform::windows::is_locked();
    let desktop_changed = crate::platform::windows::desktop_changed();
    let local_system = crate::platform::is_root();
    let can_try = !prelogin && !desktop_changed && !(local_system && locked);
    if !can_try {
        log::info!(
            "capture magnifier fallback skipped: reason={}, prelogin={}, locked={}, desktop_changed={}, local_system={}",
            reason,
            prelogin,
            locked,
            desktop_changed,
            local_system
        );
    }
    can_try
}

#[cfg(windows)]
fn try_set_magnifier_fallback(c: &mut CapturerInfo, reason: &str) -> bool {
    if c._capturer_privacy_mode_id != INVALID_PRIVACY_MODE_CONN_ID || c.is_mag() {
        return false;
    }
    if !can_try_magnifier_fallback(reason) {
        return false;
    }
    match scrap::CapturerMag::new(c.origin, c.width, c.height) {
        Ok(mag) => {
            c.capturer = Box::new(mag);
            log::info!(
                "capture magnifier fallback enabled: reason={}, origin={:?}, width={}, height={}",
                reason,
                c.origin,
                c.width,
                c.height
            );
            true
        }
        Err(err) => {
            log::warn!(
                "capture magnifier fallback failed: reason={}, origin={:?}, width={}, height={}, err={}",
                reason,
                c.origin,
                c.width,
                c.height,
                err
            );
            false
        }
    }
}

#[cfg(windows)]
fn try_recreate_magnifier_capture(c: &mut CapturerInfo, reason: &str) -> bool {
    if c._capturer_privacy_mode_id != INVALID_PRIVACY_MODE_CONN_ID || !c.is_mag() {
        return false;
    }
    let prelogin = crate::platform::windows::is_prelogin();
    let locked_service = crate::platform::is_root() && crate::platform::windows::is_locked();
    if prelogin || locked_service {
        log::info!(
            "capture magnifier recreate skipped: reason={}, prelogin={}, locked_service={}",
            reason,
            prelogin,
            locked_service
        );
        return false;
    }
    match scrap::CapturerMag::new(c.origin, c.width, c.height) {
        Ok(mag) => {
            c.capturer = Box::new(mag);
            log::info!(
                "capture magnifier recreated: reason={}, origin={:?}, width={}, height={}",
                reason,
                c.origin,
                c.width,
                c.height
            );
            true
        }
        Err(err) => {
            log::warn!(
                "capture magnifier recreate failed: reason={}, origin={:?}, width={}, height={}, err={}",
                reason,
                c.origin,
                c.width,
                c.height,
                err
            );
            false
        }
    }
}

#[cfg(windows)]
fn try_set_gdi_fallback(c: &mut CapturerInfo, reason: &str) -> bool {
    if c.is_gdi() {
        return true;
    }
    if c.set_gdi() {
        log::info!("capture gdi fallback enabled: reason={}", reason);
        return true;
    }

    let mut displays = match Display::all() {
        Ok(displays) => displays,
        Err(err) => {
            log::warn!(
                "capture gdi fallback failed to enumerate displays: reason={}, err={}",
                reason,
                err
            );
            return false;
        }
    };
    if displays.len() <= c.current {
        log::warn!(
            "capture gdi fallback failed: reason={}, current={}, display_count={}",
            reason,
            c.current,
            displays.len()
        );
        return false;
    }
    let display = displays.remove(c.current);
    match scrap::Capturer::new(display) {
        Ok(mut capturer) => {
            if !capturer.set_gdi() {
                log::warn!(
                    "capture gdi fallback failed to enable gdi on recreated capturer: reason={}",
                    reason
                );
                return false;
            }
            c.capturer = Box::new(capturer);
            log::info!("capture gdi fallback enabled: reason={}", reason);
            true
        }
        Err(err) => {
            log::warn!(
                "capture gdi fallback failed to recreate capturer: reason={}, err={}",
                reason,
                err
            );
            false
        }
    }
}

fn run(vs: VideoService) -> ResultType<()> {
    let mut _raii = Raii::new(vs.idx, vs.sp.name());
    // Wayland only support one video capturer for now. It is ok to call ensure_inited() here.
    //
    // ensure_inited() is needed because clear() may be called.
    // to-do: wayland ensure_inited should pass current display index.
    // But for now, we do not support multi-screen capture on wayland.
    #[cfg(target_os = "linux")]
    super::wayland::ensure_inited()?;
    #[cfg(target_os = "linux")]
    let _wayland_call_on_ret = {
        // Increment active display count when starting
        let _display_count = super::wayland::increment_active_display_count();

        SimpleCallOnReturn {
            b: true,
            f: Box::new(|| {
                // Decrement active display count and only clear if this was the last display
                let remaining_count = super::wayland::decrement_active_display_count();
                if remaining_count == 0 {
                    super::wayland::clear();
                }
            }),
        }
    };

    #[cfg(windows)]
    let last_portable_service_running = crate::portable_service::client::running();
    #[cfg(not(windows))]
    let last_portable_service_running = false;

    let display_idx = vs.idx;
    let sp = vs.sp;
    let mut c = get_capturer(vs.source, display_idx, last_portable_service_running)?;
    #[cfg(windows)]
    if !scrap::codec::enable_directx_capture() && !c.is_gdi() {
        log::info!("disable dxgi with option, fall back to gdi");
        c.set_gdi();
    }
    #[cfg(windows)]
    let capturer_is_gdi = c.is_gdi();
    #[cfg(not(windows))]
    let capturer_is_gdi = false;
    log::info!(
        "diag video service capturer ready: service={}, source={:?}, display_idx={}, current={}, ndisplay={}, origin={:?}, width={}, height={}, gdi={}",
        sp.name(),
        vs.source,
        display_idx,
        c.current,
        c.ndisplay,
        c.origin,
        c.width,
        c.height,
        capturer_is_gdi
    );
    #[cfg(windows)]
    let mut capture_backend = c.capture_backend();
    #[cfg(not(windows))]
    let capture_backend = "Unknown";
    let mut video_qos = VIDEO_QOS.lock().unwrap();
    let mut spf = video_qos.spf();
    let mut quality = video_qos.ratio();
    let record_incoming = config::option2bool(
        "allow-auto-record-incoming",
        &Config::get_option("allow-auto-record-incoming"),
    );
    let client_record = video_qos.record();
    drop(video_qos);
    let (mut encoder, encoder_cfg, codec_format, use_i444, recorder) = match setup_encoder(
        &c,
        sp.name(),
        quality,
        client_record,
        record_incoming,
        last_portable_service_running,
        vs.source,
        display_idx,
    ) {
        Ok(result) => result,
        Err(err) => {
            log::error!("Failed to create encoder: {err:?}, fallback to VP9");
            Encoder::set_fallback(&EncoderCfg::VPX(VpxEncoderConfig {
                width: c.width as _,
                height: c.height as _,
                quality,
                codec: VpxVideoCodecId::VP9,
                keyframe_interval: None,
            }));
            setup_encoder(
                &c,
                sp.name(),
                quality,
                client_record,
                record_incoming,
                last_portable_service_running,
                vs.source,
                display_idx,
            )?
        }
    };
    #[cfg(feature = "vram")]
    let encoder_input_texture = encoder.input_texture();
    #[cfg(not(feature = "vram"))]
    let encoder_input_texture = false;
    let encoder_backend = Encoder::backend_label(&encoder_cfg);
    let encoder_input = if encoder_input_texture {
        "GPU texture"
    } else {
        "CPU YUV frame"
    };
    log::info!(
        "diag video service encoder ready: service={}, source={:?}, display_idx={}, negotiated={:?}, cfg={:?}, capture_backend={}, encoder_backend={}, encoder_input={}, hardware={}, input_texture={}, bitrate={}, use_i444={}, quality={:?}",
        sp.name(),
        vs.source,
        display_idx,
        codec_format,
        encoder_cfg,
        capture_backend,
        encoder_backend,
        encoder_input,
        encoder.is_hardware(),
        encoder_input_texture,
        encoder.bitrate(),
        use_i444,
        quality
    );
    #[cfg(feature = "vram")]
    c.set_output_texture(encoder.input_texture());
    #[cfg(target_os = "android")]
    if vs.source.is_monitor() {
        if let Err(e) = check_change_scale(encoder.is_hardware()) {
            try_broadcast_display_changed(&sp, display_idx, &c, true).ok();
            bail!(e);
        }
    }
    {
        let mut video_qos = VIDEO_QOS.lock().unwrap();
        video_qos.store_bitrate(encoder.bitrate());
        video_qos.store_pipeline_status(capture_backend, encoder_backend, encoder_input);
        video_qos.set_support_changing_quality(&sp.name(), encoder.support_changing_quality());
    }
    log::info!("initial quality: {quality:?}");

    if sp.is_option_true(OPTION_REFRESH) {
        sp.set_option_bool(OPTION_REFRESH, false);
    }

    let mut frame_controller = VideoFrameController::new(display_idx);

    let start = time::Instant::now();
    let mut last_check_displays = time::Instant::now();
    #[cfg(windows)]
    let mut try_gdi = 1;
    #[cfg(windows)]
    let mut user_capture_helper_no_frame_since: Option<Instant> = None;
    #[cfg(windows)]
    let mut mag_no_frame_count = 0u32;
    #[cfg(windows)]
    let mut last_desktop_capture_state = (
        crate::platform::windows::is_prelogin(),
        crate::platform::windows::is_locked(),
        crate::platform::windows::desktop_changed(),
    );
    #[cfg(windows)]
    log::info!(
        "gdi: {}, mag: {}, user_helper: {}, cpu_only: {}",
        c.is_gdi(),
        c.is_mag(),
        c.is_user_capture_helper(),
        c.is_cpu_only()
    );
    #[cfg(windows)]
    start_uac_elevation_check();

    #[cfg(target_os = "linux")]
    let mut would_block_count = 0u32;
    let mut yuv = Vec::new();
    let mut mid_data = Vec::new();
    let mut repeat_encode_counter = 0;
    let repeat_encode_max = 10;
    let mut encode_fail_counter = 0;
    let mut hw_no_valid_frame_since: Option<Instant> = None;
    let mut first_frame = true;
    let capture_width = c.width;
    let capture_height = c.height;
    let (mut second_instant, mut send_counter) = (Instant::now(), 0);
    let mut host_diag = HostVideoDiagnostics::new();

    while sp.ok() {
        #[cfg(windows)]
        check_uac_switch(c.privacy_mode_id, c._capturer_privacy_mode_id)?;
        check_qos(
            &mut encoder,
            &mut quality,
            &mut spf,
            client_record,
            &mut send_counter,
            &mut second_instant,
            &sp.name(),
        )?;
        if sp.is_option_true(OPTION_REFRESH) {
            if vs.source.is_monitor() {
                let _ = try_broadcast_display_changed(&sp, display_idx, &c, true);
            }
            log::info!("switch to refresh");
            bail!("SWITCH");
        }
        let negotiated_codec = Encoder::negotiated_codec();
        if codec_format != negotiated_codec {
            log::info!(
                "diag video service codec switch requested: service={}, source={:?}, display_idx={}, {:?} -> {:?}, usable={:?}, current_cfg={:?}, hardware={}, bitrate={}",
                sp.name(),
                vs.source,
                display_idx,
                codec_format,
                negotiated_codec,
                Encoder::usable_encoding(),
                encoder_cfg,
                encoder.is_hardware(),
                encoder.bitrate()
            );
            bail!("SWITCH");
        }
        #[cfg(windows)]
        if last_portable_service_running != crate::portable_service::client::running() {
            log::info!("switch due to portable service running changed");
            bail!("SWITCH");
        }
        if Encoder::use_i444(&encoder_cfg) != use_i444 {
            log::info!("switch due to i444 changed");
            bail!("SWITCH");
        }
        #[cfg(all(windows, feature = "vram"))]
        if (c.is_gdi() || c.is_cpu_only()) && encoder.input_texture() {
            log::info!(
                "changed to gdi/cpu-only capture when using vram, gdi={}, cpu_only={}",
                c.is_gdi(),
                c.is_cpu_only()
            );
            VRamEncoder::set_fallback_gdi(sp.name(), true);
            bail!("SWITCH");
        }
        if vs.source.is_monitor() {
            check_privacy_mode_changed(&sp, display_idx, &c)?;
        }
        #[cfg(windows)]
        {
            let desktop_state = (
                crate::platform::windows::is_prelogin(),
                crate::platform::windows::is_locked(),
                crate::platform::windows::desktop_changed(),
            );
            let desktop_changed = desktop_state.2;
            let portable_service_running = crate::portable_service::client::running();
            if portable_service_running && desktop_state != last_desktop_capture_state {
                log::info!(
                    "portable capture desktop state changed: prelogin {}->{}, locked {}->{}, desktop_changed {}->{}",
                    last_desktop_capture_state.0,
                    desktop_state.0,
                    last_desktop_capture_state.1,
                    desktop_state.1,
                    last_desktop_capture_state.2,
                    desktop_state.2
                );
                last_desktop_capture_state = desktop_state;
                if c.is_mag() {
                    if should_force_portable_secure_capturer(
                        portable_service_running,
                        desktop_state.0,
                        desktop_state.1,
                        desktop_state.2,
                    ) {
                        log::info!(
                            "portable secure desktop while using magnifier; switch to helper capture"
                        );
                        bail!("SWITCH");
                    }
                    if !desktop_state.0 && !desktop_state.1 && !desktop_state.2 {
                        log::info!(
                            "portable returned to user desktop while using magnifier; switch capture backend"
                        );
                        bail!("SWITCH");
                    }
                    if try_recreate_magnifier_capture(&mut c, "desktop_state_mag_recreate") {
                        log::info!(
                            "portable desktop state changed while using magnifier; recreated magnifier"
                        );
                    } else {
                        log::warn!(
                            "portable desktop state changed while using magnifier; keep magnifier on locked/secure desktop"
                        );
                    }
                } else {
                    if desktop_changed {
                        log::info!(
                            "portable input desktop changed; switch capture backend from current backend"
                        );
                    }
                    log::info!("portable desktop state changed; switch capture backend");
                    bail!("SWITCH");
                }
            }
            if desktop_changed && !portable_service_running {
                bail!("Desktop changed");
            }
        }
        let now = time::Instant::now();
        if vs.source.is_monitor() && last_check_displays.elapsed().as_millis() > 1000 {
            last_check_displays = now;
            // This check may be redundant, but it is better to be safe.
            // The previous check in `sp.is_option_true(OPTION_REFRESH)` block may be enough.
            try_broadcast_display_changed(&sp, display_idx, &c, false)?;
        }

        #[cfg(windows)]
        {
            let current_capture_backend = c.capture_backend();
            if current_capture_backend != capture_backend {
                capture_backend = current_capture_backend;
                log::info!(
                    "diag video service capture backend changed: service={}, source={:?}, display_idx={}, capture_backend={}, encoder_backend={}, encoder_input={}",
                    sp.name(),
                    vs.source,
                    display_idx,
                    capture_backend,
                    encoder_backend,
                    encoder_input
                );
                VIDEO_QOS.lock().unwrap().store_pipeline_status(
                    capture_backend,
                    encoder_backend,
                    encoder_input,
                );
            }
        }

        frame_controller.reset();

        let time = now - start;
        let ms = (time.as_secs() * 1000 + time.subsec_millis() as u64) as i64;
        let res = match c.frame(spf) {
            Ok(frame) => {
                repeat_encode_counter = 0;
                if frame.valid() {
                    #[cfg(windows)]
                    {
                        user_capture_helper_no_frame_since = None;
                        mag_no_frame_count = 0;
                    }
                    host_diag.valid_capture += 1;
                    let capture_frame = capture_frame_label(&frame);
                    let capture_frame_changed = {
                        let mut video_qos = VIDEO_QOS.lock().unwrap();
                        video_qos.store_capture_frame(capture_frame)
                    };
                    if capture_frame_changed {
                        log::info!(
                            "diag video service capture frame: service={}, source={:?}, display_idx={}, capture_backend={}, capture_frame={}, encoder_input={}",
                            sp.name(),
                            vs.source,
                            display_idx,
                            capture_backend,
                            capture_frame,
                            encoder_input
                        );
                    }
                    let screenshot = SCREENSHOTS.lock().unwrap().remove(&display_idx);
                    if let Some(mut screenshot) = screenshot {
                        let restore_vram = screenshot.restore_vram;
                        let (msg, w, h, data) = match &frame {
                            scrap::Frame::PixelBuffer(f) => match get_rgba_from_pixelbuf(f) {
                                Ok(rgba) => ("".to_owned(), f.width(), f.height(), rgba),
                                Err(e) => {
                                    let serr = e.to_string();
                                    log::error!(
                                        "Failed to convert the pix format into rgba, {}",
                                        &serr
                                    );
                                    (format!("Convert pixfmt: {}", serr), 0, 0, vec![])
                                }
                            },
                            scrap::Frame::Texture(_) => {
                                if restore_vram {
                                    // Already set one time, just ignore to break infinite loop.
                                    // Though it's unreachable, this branch is kept to avoid infinite loop.
                                    (
                                        "Please change codec and try again.".to_owned(),
                                        0,
                                        0,
                                        vec![],
                                    )
                                } else {
                                    #[cfg(all(windows, feature = "vram"))]
                                    VRamEncoder::set_not_use(sp.name(), true);
                                    screenshot.restore_vram = true;
                                    SCREENSHOTS.lock().unwrap().insert(display_idx, screenshot);
                                    _raii.try_vram = false;
                                    bail!("SWITCH");
                                }
                            }
                        };
                        std::thread::spawn(move || {
                            handle_screenshot(screenshot, msg, w, h, data);
                        });
                        if restore_vram {
                            bail!("SWITCH");
                        }
                    }

                    let frame = frame.to(encoder.yuvfmt(), &mut yuv, &mut mid_data)?;
                    let send_conn_ids = handle_one_frame(
                        display_idx,
                        &sp,
                        frame,
                        ms,
                        &mut encoder,
                        recorder.clone(),
                        &mut encode_fail_counter,
                        &mut hw_no_valid_frame_since,
                        &mut first_frame,
                        capture_width,
                        capture_height,
                    )?;
                    host_diag.record_send_result(send_conn_ids.len());
                    frame_controller.set_send(now, send_conn_ids);
                    send_counter += 1;
                } else {
                    host_diag.invalid_capture += 1;
                }
                #[cfg(windows)]
                {
                    #[cfg(feature = "vram")]
                    if try_gdi == 1 && !c.is_gdi() {
                        VRamEncoder::set_fallback_gdi(sp.name(), false);
                    }
                    try_gdi = 0;
                }
                Ok(())
            }
            Err(err) => Err(err),
        };

        match res {
            Err(ref e) if e.kind() == WouldBlock => {
                host_diag.would_block += 1;
                #[cfg(windows)]
                if c.is_mag() {
                    mag_no_frame_count = mag_no_frame_count.saturating_add(1);
                    let portable_service_running = crate::portable_service::client::running();
                    let prelogin = crate::platform::windows::is_prelogin();
                    let locked = crate::platform::windows::is_locked();
                    let desktop_changed = crate::platform::windows::desktop_changed();
                    if should_force_portable_secure_capturer(
                        portable_service_running,
                        prelogin,
                        locked,
                        desktop_changed,
                    ) {
                        log::info!(
                            "portable magnifier produced no frames on secure desktop; switch to helper capture, no_frame_count={}",
                            mag_no_frame_count
                        );
                        bail!("SWITCH");
                    }
                    if portable_service_running
                        && (locked || desktop_changed)
                        && (mag_no_frame_count == 10 || mag_no_frame_count % 60 == 0)
                        && try_recreate_magnifier_capture(&mut c, "mag_no_frame_recreate")
                    {
                        log::info!(
                            "portable magnifier produced no frames; recreated magnifier, no_frame_count={}",
                            mag_no_frame_count
                        );
                        mag_no_frame_count = 0;
                        continue;
                    }
                }
                #[cfg(windows)]
                if c.is_user_capture_helper() && first_frame {
                    let first_no_frame = *user_capture_helper_no_frame_since.get_or_insert(now);
                    if first_no_frame.elapsed() >= USER_CAPTURE_HELPER_STARTUP_TIMEOUT {
                        USER_CAPTURE_HELPER_DISABLED.store(true, Ordering::Relaxed);
                        log::warn!(
                            "User capture helper did not produce startup frame after {:?}; switching to direct dxgi|gdi",
                            USER_CAPTURE_HELPER_STARTUP_TIMEOUT
                        );
                        bail!("SWITCH");
                    }
                }
                #[cfg(windows)]
                if try_gdi > 0 && !c.is_gdi() && !c.is_cpu_only() {
                    if try_gdi > 3 {
                        if try_set_magnifier_fallback(&mut c, "no_image_mag") {
                            try_gdi = 0;
                            log::info!("No image, fall back to magnifier capture");
                            continue;
                        }
                        if try_set_gdi_fallback(&mut c, "no_image") {
                            log::info!("No image, fall back to gdi");
                        } else {
                            log::warn!("No image, failed to fall back to gdi");
                        }
                        try_gdi = 0;
                    }
                    try_gdi += 1;
                }
                #[cfg(target_os = "linux")]
                {
                    would_block_count += 1;
                    if !is_x11() {
                        if would_block_count >= 100 {
                            // to-do: Unknown reason for WouldBlock 100 times (seconds = 100 * 1 / fps)
                            // https://github.com/rustdesk/rustdesk/blob/63e6b2f8ab51743e77a151e2b7ff18816f5fa2fb/libs/scrap/src/common/wayland.rs#L81
                            //
                            // Do not reset the capturer for now, as it will cause the prompt to show every few minutes.
                            // https://github.com/rustdesk/rustdesk/issues/4276
                            //
                            // super::wayland::clear();
                            // bail!("Wayland capturer none 100 times, try restart capture");
                        }
                    }
                }
                if !encoder.latency_free() && yuv.len() > 0 {
                    // yun.len() > 0 means the frame is not texture.
                    if repeat_encode_counter < repeat_encode_max {
                        repeat_encode_counter += 1;
                        host_diag.repeat_encode_calls += 1;
                        let send_conn_ids = handle_one_frame(
                            display_idx,
                            &sp,
                            EncodeInput::YUV(&yuv),
                            ms,
                            &mut encoder,
                            recorder.clone(),
                            &mut encode_fail_counter,
                            &mut hw_no_valid_frame_since,
                            &mut first_frame,
                            capture_width,
                            capture_height,
                        )?;
                        host_diag.record_send_result(send_conn_ids.len());
                        frame_controller.set_send(now, send_conn_ids);
                        send_counter += 1;
                    }
                }
            }
            Err(err) => {
                // This check may be redundant, but it is better to be safe.
                // The previous check in `sp.is_option_true(OPTION_REFRESH)` block may be enough.
                if vs.source.is_monitor() {
                    try_broadcast_display_changed(&sp, display_idx, &c, true)?;
                }

                #[cfg(windows)]
                if c.is_user_capture_helper() {
                    USER_CAPTURE_HELPER_DISABLED.store(true, Ordering::Relaxed);
                    log::warn!(
                        "User capture helper returned capture error; switching to direct dxgi|gdi: {:?}",
                        err
                    );
                    bail!("SWITCH");
                }

                #[cfg(windows)]
                if c.is_mag() {
                    let portable_service_running = crate::portable_service::client::running();
                    let prelogin = crate::platform::windows::is_prelogin();
                    let locked = crate::platform::windows::is_locked();
                    let desktop_changed = crate::platform::windows::desktop_changed();
                    if should_force_portable_secure_capturer(
                        portable_service_running,
                        prelogin,
                        locked,
                        desktop_changed,
                    ) {
                        log::info!(
                            "portable magnifier capture error on secure desktop; switch to helper capture: {:?}",
                            err
                        );
                        bail!("SWITCH");
                    }
                    if portable_service_running && (locked || desktop_changed) {
                        if try_recreate_magnifier_capture(&mut c, "mag_error_recreate") {
                            log::info!(
                                "portable magnifier capture error; recreated magnifier: {:?}",
                                err
                            );
                            continue;
                        }
                        log::warn!(
                            "portable magnifier capture error; keep magnifier on secure/changed desktop: {:?}",
                            err
                        );
                        continue;
                    }
                    if try_set_gdi_fallback(&mut c, "mag_error") {
                        log::info!("magnifier capture error, fall back to gdi: {:?}", err);
                        continue;
                    }
                    return Err(err.into());
                }

                #[cfg(windows)]
                if !c.is_gdi() {
                    if try_set_magnifier_fallback(&mut c, "capture_error_mag") {
                        log::info!("capture error, fall back to magnifier: {:?}", err);
                        continue;
                    }
                    if try_set_gdi_fallback(&mut c, "capture_error") {
                        log::info!("dxgi error, fall back to gdi: {:?}", err);
                        continue;
                    }
                    return Err(err.into());
                }
                return Err(err.into());
            }
            _ => {
                #[cfg(target_os = "linux")]
                {
                    would_block_count = 0;
                }
            }
        }

        let mut fetched_conn_ids = HashSet::new();
        let timeout_millis = 3_000u64;
        let wait_begin = Instant::now();
        while wait_begin.elapsed().as_millis() < timeout_millis as _ {
            if vs.source.is_monitor() {
                check_privacy_mode_changed(&sp, display_idx, &c)?;
            }
            frame_controller.try_wait_next(&mut fetched_conn_ids, 300);
            // break if all connections have received current frame
            if fetched_conn_ids.len() >= frame_controller.send_conn_ids.len() {
                break;
            }
        }
        host_diag.record_wait(
            frame_controller.send_conn_ids.len(),
            fetched_conn_ids.len(),
            wait_begin.elapsed(),
        );
        DISPLAY_CONN_IDS.lock().unwrap().remove(&display_idx);

        let elapsed = now.elapsed();
        // may need to enable frame(timeout)
        log::trace!("{:?} {:?}", time::Instant::now(), elapsed);
        if elapsed < spf {
            std::thread::sleep(spf - elapsed);
        }
        #[cfg(windows)]
        let current_gdi = c.is_gdi();
        #[cfg(not(windows))]
        let current_gdi = false;
        let service_name = sp.name();
        host_diag.maybe_log(
            &service_name,
            vs.source,
            display_idx,
            codec_format,
            encoder.is_hardware(),
            encoder.bitrate(),
            quality,
            spf,
            current_gdi,
        );
    }

    Ok(())
}

struct Raii {
    display_idx: usize,
    name: String,
    try_vram: bool,
}

impl Raii {
    fn new(display_idx: usize, name: String) -> Self {
        log::info!("new video service: {}", name);
        VIDEO_QOS.lock().unwrap().new_display(name.clone());
        Raii {
            display_idx,
            name,
            try_vram: true,
        }
    }
}

impl Drop for Raii {
    fn drop(&mut self) {
        log::info!("stop video service: {}", self.name);
        #[cfg(feature = "vram")]
        if self.try_vram {
            VRamEncoder::set_not_use(self.name.clone(), false);
        }
        #[cfg(feature = "vram")]
        Encoder::update(scrap::codec::EncodingUpdate::Check);
        VIDEO_QOS.lock().unwrap().remove_display(&self.name);
        DISPLAY_CONN_IDS.lock().unwrap().remove(&self.display_idx);
    }
}

fn setup_encoder(
    c: &CapturerInfo,
    name: String,
    quality: f32,
    client_record: bool,
    record_incoming: bool,
    last_portable_service_running: bool,
    source: VideoSource,
    display_idx: usize,
) -> ResultType<(
    Encoder,
    EncoderCfg,
    CodecFormat,
    bool,
    Arc<Mutex<Option<Recorder>>>,
)> {
    let encoder_cfg = get_encoder_config(
        &c,
        name.to_string(),
        quality,
        client_record || record_incoming,
        last_portable_service_running,
        source,
    );
    Encoder::set_fallback(&encoder_cfg);
    let codec_format = Encoder::negotiated_codec();
    let recorder = get_recorder(record_incoming, display_idx, source == VideoSource::Camera);
    let use_i444 = Encoder::use_i444(&encoder_cfg);
    log::info!(
        "diag host selected encoder config: service={}, source={:?}, display_idx={}, capture={}x{}, negotiated={:?}, cfg={:?}, use_i444={}, quality={:?}, client_record={}, record_incoming={}, portable_service={}",
        name,
        source,
        display_idx,
        c.width,
        c.height,
        codec_format,
        encoder_cfg,
        use_i444,
        quality,
        client_record,
        record_incoming,
        last_portable_service_running
    );
    let encoder = Encoder::new(encoder_cfg.clone(), use_i444)?;
    Ok((encoder, encoder_cfg, codec_format, use_i444, recorder))
}

fn get_encoder_config(
    c: &CapturerInfo,
    _name: String,
    quality: f32,
    record: bool,
    _portable_service: bool,
    _source: VideoSource,
) -> EncoderCfg {
    #[cfg(all(windows, feature = "vram"))]
    if _portable_service || c.is_gdi() || c.is_cpu_only() || _source == VideoSource::Camera {
        log::info!(
            "gdi:{}, cpu_only:{}, portable:{}",
            c.is_gdi(),
            c.is_cpu_only(),
            _portable_service
        );
        VRamEncoder::set_not_use(_name, true);
    }
    #[cfg(feature = "vram")]
    Encoder::update(scrap::codec::EncodingUpdate::Check);
    // https://www.wowza.com/community/t/the-correct-keyframe-interval-in-obs-studio/95162
    let keyframe_interval = if record { Some(240) } else { None };
    let negotiated_codec = Encoder::negotiated_codec();
    match negotiated_codec {
        CodecFormat::H264 | CodecFormat::H265 => {
            #[cfg(feature = "vram")]
            if let Some(feature) = VRamEncoder::try_get(&c.device(), negotiated_codec) {
                return EncoderCfg::VRAM(VRamEncoderConfig {
                    device: c.device(),
                    width: c.width,
                    height: c.height,
                    quality,
                    feature,
                    keyframe_interval,
                });
            }
            #[cfg(feature = "hwcodec")]
            if let Some(hw) = HwRamEncoder::try_get(negotiated_codec) {
                return EncoderCfg::HWRAM(HwRamEncoderConfig {
                    name: hw.name,
                    mc_name: hw.mc_name,
                    width: c.width,
                    height: c.height,
                    quality,
                    keyframe_interval,
                    profile: Default::default(),
                });
            }
            EncoderCfg::VPX(VpxEncoderConfig {
                width: c.width as _,
                height: c.height as _,
                quality,
                codec: VpxVideoCodecId::VP9,
                keyframe_interval,
            })
        }
        format @ (CodecFormat::VP8 | CodecFormat::VP9) => EncoderCfg::VPX(VpxEncoderConfig {
            width: c.width as _,
            height: c.height as _,
            quality,
            codec: if format == CodecFormat::VP8 {
                VpxVideoCodecId::VP8
            } else {
                VpxVideoCodecId::VP9
            },
            keyframe_interval,
        }),
        CodecFormat::AV1 => {
            #[cfg(feature = "hwcodec")]
            if Encoder::av1_hardware_allowed() {
                if let Some(hw) = HwRamEncoder::try_get(CodecFormat::AV1) {
                    return EncoderCfg::HWRAM(HwRamEncoderConfig {
                        name: hw.name,
                        mc_name: hw.mc_name,
                        width: c.width,
                        height: c.height,
                        quality,
                        keyframe_interval,
                        profile: Default::default(),
                    });
                }
                if Encoder::av1_hardware_required() {
                    log::warn!("AV1 hardware was requested but no hardware encoder is available");
                    return EncoderCfg::VPX(VpxEncoderConfig {
                        width: c.width as _,
                        height: c.height as _,
                        quality,
                        codec: VpxVideoCodecId::VP9,
                        keyframe_interval,
                    });
                }
            }
            EncoderCfg::AOM(AomEncoderConfig {
                width: c.width as _,
                height: c.height as _,
                quality,
                keyframe_interval,
            })
        }
        _ => EncoderCfg::VPX(VpxEncoderConfig {
            width: c.width as _,
            height: c.height as _,
            quality,
            codec: VpxVideoCodecId::VP9,
            keyframe_interval,
        }),
    }
}

fn get_recorder(
    record_incoming: bool,
    display_idx: usize,
    camera: bool,
) -> Arc<Mutex<Option<Recorder>>> {
    #[cfg(windows)]
    let root = crate::platform::is_root();
    #[cfg(not(windows))]
    let root = false;
    let recorder = if record_incoming {
        use crate::hbbs_http::record_upload;

        let tx = if record_upload::is_enable() {
            let (tx, rx) = std::sync::mpsc::channel();
            record_upload::run(rx);
            Some(tx)
        } else {
            None
        };
        Recorder::new(RecorderContext {
            server: true,
            id: Config::get_id(),
            dir: crate::ui_interface::video_save_directory(root),
            display_idx,
            camera,
            tx,
        })
        .map_or(Default::default(), |r| Arc::new(Mutex::new(Some(r))))
    } else {
        Default::default()
    };

    recorder
}

#[cfg(target_os = "android")]
fn check_change_scale(hardware: bool) -> ResultType<()> {
    use hbb_common::config::keys::OPTION_ENABLE_ANDROID_SOFTWARE_ENCODING_HALF_SCALE as SCALE_SOFT;

    // isStart flag is set at the end of startCapture() in Android, wait it to be set.
    let n = 60; // 3s
    for i in 0..n {
        if scrap::is_start() == Some(true) {
            log::info!("start flag is set");
            break;
        }
        log::info!("wait for start, {i}");
        std::thread::sleep(Duration::from_millis(50));
        if i == n - 1 {
            log::error!("wait for start timeout");
        }
    }
    let screen_size = scrap::screen_size();
    let scale_soft = hbb_common::config::option2bool(SCALE_SOFT, &Config::get_option(SCALE_SOFT));
    let half_scale = !hardware && scale_soft;
    log::info!("hardware: {hardware}, scale_soft: {scale_soft}, screen_size: {screen_size:?}",);
    scrap::android::call_main_service_set_by_name(
        "half_scale",
        Some(half_scale.to_string().as_str()),
        None,
    )
    .ok();
    let old_scale = screen_size.2;
    let new_scale = scrap::screen_size().2;
    log::info!("old_scale: {old_scale}, new_scale: {new_scale}");
    if old_scale != new_scale {
        log::info!("switch due to scale changed, {old_scale} -> {new_scale}");
        // switch is not a must, but it is better to do so.
        bail!("SWITCH");
    }
    Ok(())
}

fn check_privacy_mode_changed(
    sp: &GenericService,
    display_idx: usize,
    ci: &CapturerInfo,
) -> ResultType<()> {
    let privacy_mode_id_2 = get_privacy_mode_conn_id().unwrap_or(INVALID_PRIVACY_MODE_CONN_ID);
    if ci.privacy_mode_id != privacy_mode_id_2 {
        if privacy_mode_id_2 != INVALID_PRIVACY_MODE_CONN_ID {
            let msg_out = crate::common::make_privacy_mode_msg(
                back_notification::PrivacyModeState::PrvOnByOther,
                "".to_owned(),
            );
            sp.send_to_others(msg_out, privacy_mode_id_2);
        }
        log::info!("switch due to privacy mode changed");
        try_broadcast_display_changed(&sp, display_idx, ci, true).ok();
        bail!("SWITCH");
    }
    Ok(())
}

#[inline]
fn handle_one_frame(
    display: usize,
    sp: &GenericService,
    frame: EncodeInput,
    ms: i64,
    encoder: &mut Encoder,
    recorder: Arc<Mutex<Option<Recorder>>>,
    encode_fail_counter: &mut usize,
    hw_no_valid_frame_since: &mut Option<Instant>,
    first_frame: &mut bool,
    width: usize,
    height: usize,
) -> ResultType<HashSet<i32>> {
    sp.snapshot(|sps| {
        // so that new sub and old sub share the same encoder after switch
        if sps.has_subscribes() {
            log::info!("switch due to new subscriber");
            bail!("SWITCH");
        }
        Ok(())
    })?;

    let mut send_conn_ids: HashSet<i32> = Default::default();
    let first = *first_frame;
    *first_frame = false;
    match encoder.encode_to_message(frame, ms) {
        Ok(mut vf) => {
            *encode_fail_counter = 0;
            *hw_no_valid_frame_since = None;
            vf.display = display as _;
            let (payload_bytes, frame_count, has_keyframe) =
                scrap::codec::video_frame_payload_stats(&vf).unwrap_or((0, 0, false));
            let mut msg = Message::new();
            msg.set_video_frame(vf);
            recorder
                .lock()
                .unwrap()
                .as_mut()
                .map(|r| r.write_message(&msg, width, height));
            send_conn_ids = sp.send_video_frame(msg);
            if first {
                log::info!(
                    "diag first video frame encoded: service={}, display={}, width={}, height={}, targets={:?}, negotiated={:?}, hardware={}, bitrate={}, payload_bytes={}, frame_count={}, keyframe={}, capture_ms={}",
                    sp.name(),
                    display,
                    width,
                    height,
                    send_conn_ids,
                    Encoder::negotiated_codec(),
                    encoder.is_hardware(),
                    encoder.bitrate(),
                    payload_bytes,
                    frame_count,
                    has_keyframe,
                    ms
                );
            }
        }
        Err(e) => {
            let is_hw_no_valid_frame = encoder.is_hardware()
                && e.chain()
                    .any(|cause| cause.to_string() == ENCODE_NO_VALID_FRAME);
            *encode_fail_counter += 1;
            if is_hw_no_valid_frame {
                let warmup_start = hw_no_valid_frame_since.get_or_insert_with(Instant::now);
                let warmup_elapsed = warmup_start.elapsed();
                if warmup_elapsed < HW_ENCODER_WARMUP_TIMEOUT {
                    if *encode_fail_counter == 1 {
                        log::warn!(
                            "hardware encoder has no packet yet: {e:?}, warmup_timeout_ms={}",
                            HW_ENCODER_WARMUP_TIMEOUT.as_millis()
                        );
                    }
                    return Ok(send_conn_ids);
                }
                *encode_fail_counter = 0;
                *hw_no_valid_frame_since = None;
                Encoder::set_fallback_codec(CodecFormat::VP9);
                log::error!(
                    "switch due to hardware encoder warmup timeout: elapsed_ms={}, error={e:?}",
                    warmup_elapsed.as_millis()
                );
                bail!("SWITCH");
            }
            *hw_no_valid_frame_since = None;
            if first {
                log::warn!(
                    "diag first video frame encode failed: service={}, display={}, negotiated={:?}, hardware={}, capture_ms={}, err={:?}",
                    sp.name(),
                    display,
                    Encoder::negotiated_codec(),
                    encoder.is_hardware(),
                    ms,
                    e
                );
            }
            // Encoding errors are not frequent except on Android
            if !cfg!(target_os = "android") {
                log::error!("encode fail: {e:?}, times: {}", *encode_fail_counter,);
            }
            let max_fail_times = if cfg!(target_os = "android") && encoder.is_hardware() {
                9
            } else {
                3
            };
            let repeat = !encoder.latency_free();
            // repeat encoders can reach max_fail_times on the first frame
            if (first && !repeat) || *encode_fail_counter >= max_fail_times {
                *encode_fail_counter = 0;
                if encoder.is_hardware() {
                    Encoder::set_fallback_codec(CodecFormat::VP9);
                    log::error!(
                        "switch due to hardware encoding fails without disabling hwcodec availability, first frame: {first}, error: {e:?}"
                    );
                    bail!("SWITCH");
                }
            }
            match e.to_string().as_str() {
                scrap::codec::ENCODE_NEED_SWITCH => {
                    Encoder::set_fallback_codec(CodecFormat::VP9);
                    log::error!(
                        "switch due to encoder need switch without disabling hwcodec availability"
                    );
                    bail!("SWITCH");
                }
                _ => {}
            }
        }
    }
    Ok(send_conn_ids)
}

#[inline]
pub fn refresh() {
    #[cfg(target_os = "android")]
    Display::refresh_size();
}

#[cfg(windows)]
fn start_uac_elevation_check() {
    static START: Once = Once::new();
    START.call_once(|| {
        if !crate::platform::is_installed() && !crate::platform::is_root() {
            std::thread::spawn(|| loop {
                std::thread::sleep(std::time::Duration::from_secs(1));
                if let Ok(uac) = is_process_consent_running() {
                    *IS_UAC_RUNNING.lock().unwrap() = uac;
                }
                if !crate::platform::is_elevated(None).unwrap_or(false) {
                    if let Ok(elevated) = crate::platform::is_foreground_window_elevated() {
                        *IS_FOREGROUND_WINDOW_ELEVATED.lock().unwrap() = elevated;
                    }
                }
            });
        }
    });
}

#[inline]
fn try_broadcast_display_changed(
    sp: &GenericService,
    display_idx: usize,
    cap: &CapturerInfo,
    refresh: bool,
) -> ResultType<()> {
    if refresh {
        // Get display information immediately.
        crate::display_service::check_displays_changed().ok();
    }
    if let Some(display) = check_display_changed(
        cap.ndisplay,
        cap.current,
        (cap.origin.0, cap.origin.1, cap.width, cap.height),
    ) {
        log::info!("Display {} changed", display);
        if let Some(msg_out) =
            make_display_changed_msg(display_idx, Some(display), VideoSource::Monitor)
        {
            let msg_out = Arc::new(msg_out);
            sp.send_shared(msg_out.clone());
            // switch display may occur before the first video frame, add snapshot to send to new subscribers
            sp.snapshot(move |sps| {
                sps.send_shared(msg_out.clone());
                Ok(())
            })?;
            bail!("SWITCH");
        }
    }
    Ok(())
}

pub fn make_display_changed_msg(
    display_idx: usize,
    opt_display: Option<DisplayInfo>,
    source: VideoSource,
) -> Option<Message> {
    let display = match opt_display {
        Some(d) => d,
        None => match source {
            VideoSource::Monitor => display_service::get_display_info(display_idx)?,
            VideoSource::Camera => camera::Cameras::get_sync_cameras()
                .get(display_idx)?
                .clone(),
        },
    };
    let mut misc = Misc::new();
    misc.set_switch_display(SwitchDisplay {
        display: display_idx as _,
        x: display.x,
        y: display.y,
        width: display.width,
        height: display.height,
        cursor_embedded: match source {
            VideoSource::Monitor => display_service::capture_cursor_embedded(),
            VideoSource::Camera => false,
        },
        #[cfg(not(target_os = "android"))]
        resolutions: Some(SupportedResolutions {
            resolutions: match source {
                VideoSource::Monitor => {
                    if display.name.is_empty() {
                        vec![]
                    } else {
                        crate::platform::resolutions(&display.name)
                    }
                }
                VideoSource::Camera => camera::Cameras::get_camera_resolution(display_idx)
                    .ok()
                    .into_iter()
                    .collect(),
            },
            ..SupportedResolutions::default()
        })
        .into(),
        original_resolution: display.original_resolution,
        ..Default::default()
    });
    let mut msg_out = Message::new();
    msg_out.set_misc(misc);
    Some(msg_out)
}

fn check_qos(
    encoder: &mut Encoder,
    ratio: &mut f32,
    spf: &mut Duration,
    client_record: bool,
    send_counter: &mut usize,
    second_instant: &mut Instant,
    name: &str,
) -> ResultType<()> {
    let mut video_qos = VIDEO_QOS.lock().unwrap();
    *spf = video_qos.spf();
    if *ratio != video_qos.ratio() {
        *ratio = video_qos.ratio();
        if encoder.support_changing_quality() {
            allow_err!(encoder.set_quality(*ratio));
            video_qos.store_bitrate(encoder.bitrate());
        } else {
            // Now only vaapi doesn't support changing quality
            if !video_qos.in_vbr_state() && !video_qos.latest_quality().is_custom() {
                log::info!("switch to change quality");
                bail!("SWITCH");
            }
        }
    }
    if client_record != video_qos.record() {
        log::info!("switch due to record changed");
        bail!("SWITCH");
    }
    if second_instant.elapsed() > Duration::from_secs(1) {
        *second_instant = Instant::now();
        video_qos.update_display_data(&name, *send_counter);
        *send_counter = 0;
    }
    drop(video_qos);
    Ok(())
}

pub fn set_take_screenshot(display_idx: usize, sid: String, tx: Sender) {
    SCREENSHOTS.lock().unwrap().insert(
        display_idx,
        Screenshot {
            sid,
            tx,
            restore_vram: false,
        },
    );
}

// We need to this function, because the `stride` may be larger than `width * 4`.
fn get_rgba_from_pixelbuf<'a>(pixbuf: &scrap::PixelBuffer<'a>) -> ResultType<Vec<u8>> {
    let w = pixbuf.width();
    let h = pixbuf.height();
    let stride = pixbuf.stride();
    let Some(s) = stride.get(0) else {
        bail!("Invalid pixel buf stride.")
    };

    if *s == w * 4 {
        let mut rgba = vec![];
        scrap::convert(pixbuf, scrap::Pixfmt::RGBA, &mut rgba)?;
        Ok(rgba)
    } else {
        let bgra = pixbuf.data();
        let mut bit_flipped = Vec::with_capacity(w * h * 4);
        for y in 0..h {
            for x in 0..w {
                let i = s * y + 4 * x;
                bit_flipped.extend_from_slice(&[bgra[i + 2], bgra[i + 1], bgra[i], bgra[i + 3]]);
            }
        }
        Ok(bit_flipped)
    }
}

fn handle_screenshot(screenshot: Screenshot, msg: String, w: usize, h: usize, data: Vec<u8>) {
    let mut response = ScreenshotResponse::new();
    response.sid = screenshot.sid;
    if msg.is_empty() {
        if data.is_empty() {
            response.msg = "Failed to take screenshot, please try again later.".to_owned();
        } else {
            fn encode_png(width: usize, height: usize, rgba: Vec<u8>) -> ResultType<Vec<u8>> {
                let mut png = Vec::new();
                let mut encoder =
                    repng::Options::smallest(width as _, height as _).build(&mut png)?;
                encoder.write(&rgba)?;
                encoder.finish()?;
                Ok(png)
            }
            match encode_png(w as _, h as _, data) {
                Ok(png) => {
                    response.data = png.into();
                }
                Err(e) => {
                    response.msg = format!("Error encoding png: {}", e);
                }
            }
        }
    } else {
        response.msg = msg;
    }
    let mut msg_out = Message::new();
    msg_out.set_screenshot_response(response);
    if let Err(e) = screenshot
        .tx
        .send((hbb_common::tokio::time::Instant::now(), Arc::new(msg_out)))
    {
        log::error!("Failed to send screenshot, {}", e);
    }
}
