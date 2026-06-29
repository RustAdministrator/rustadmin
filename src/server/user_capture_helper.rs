use hbb_common::{anyhow::Context, bail, libc, log, ResultType};
#[cfg(feature = "vram")]
use scrap::AdapterDevice;
use scrap::{Capturer, Display, Frame, TraitCapturer, TraitPixelBuffer};
use std::{
    mem::size_of,
    path::PathBuf,
    slice,
    sync::atomic::{AtomicU32, Ordering},
    time::{Duration, Instant},
};
use winapi::um::{
    handleapi::CloseHandle,
    minwinbase::STILL_ACTIVE,
    processthreadsapi::{GetCurrentProcessId, GetExitCodeProcess},
    winnt::HANDLE,
};

pub const ARG: &str = "--user-capture-helper";
pub const SHMEM_ARG_PREFIX: &str = "--user-capture-helper-shmem-name=";
const SHMEM_NAME: &str = "_user_capture_helper";
const SHMEM_NAME_MAX_LEN: usize = 64;
const FRAME_ALIGN: usize = 64;
const STATUS_STARTING: u32 = 0;
const STATUS_OK: u32 = 1;
const STATUS_WOULD_BLOCK: u32 = 2;
const STATUS_ERROR: u32 = 3;
const BACKEND_UNKNOWN: u32 = 0;
const BACKEND_WGC_CPU: u32 = 1;
const BACKEND_GDI_CPU: u32 = 2;
const GDI_BOOTSTRAP_AFTER: Duration = Duration::from_millis(500);

const fn align_up(value: usize, align: usize) -> usize {
    (value + align - 1) / align * align
}

const ADDR_COMMAND: usize = 0;
const ADDR_FRAME_INFO: usize = align_up(ADDR_COMMAND + size_of::<CaptureCommand>(), 8);
const ADDR_FRAME: usize = align_up(ADDR_FRAME_INFO + size_of::<CaptureFrameInfo>(), FRAME_ALIGN);
const MIN_SHMEM_LEN: usize = ADDR_FRAME + FRAME_ALIGN;

#[repr(C)]
#[derive(Clone, Copy)]
struct CaptureCommand {
    exit: u32,
    generation: u32,
    current_display: usize,
    timeout_ms: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CaptureFrameInfo {
    counter: u32,
    status: u32,
    length: usize,
    width: usize,
    height: usize,
    backend: u32,
}

#[inline]
fn is_valid_shmem_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= SHMEM_NAME_MAX_LEN
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

#[inline]
fn shmem_arg(name: &str) -> String {
    format!("{SHMEM_ARG_PREFIX}{name}")
}

#[inline]
pub fn user_capture_helper_shmem_name_from_args() -> Option<String> {
    for arg in std::env::args() {
        if let Some(value) = arg.strip_prefix(SHMEM_ARG_PREFIX) {
            let value = value.trim_matches(|c| c == '"' || c == '\'');
            if is_valid_shmem_name(value) {
                return Some(value.to_owned());
            }
            log::error!(
                "Invalid user capture helper shared memory name: '{}'",
                value
            );
            return None;
        }
    }
    None
}

#[inline]
fn next_shmem_name() -> String {
    format!(
        "{}_{}_{:08x}",
        SHMEM_NAME,
        unsafe { GetCurrentProcessId() },
        hbb_common::rand::random::<u32>()
    )
}

#[inline]
fn shmem_flink_path(name: &str) -> ResultType<PathBuf> {
    let mut dir = crate::platform::user_accessible_folder()?;
    dir = dir.join(hbb_common::config::APP_NAME.read().unwrap().clone());
    dir = dir.join("portable_service_shmem");
    Ok(dir.join(format!("shared_memory{}", name)))
}

#[inline]
fn schedule_remove_shmem_flink(name: String) {
    std::thread::spawn(move || {
        let Ok(path) = shmem_flink_path(&name) else {
            return;
        };
        for attempt in 0..20 {
            match std::fs::remove_file(&path) {
                Ok(()) => return,
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => return,
                Err(err) => {
                    if attempt == 19 {
                        log::warn!(
                            "Failed to remove user capture helper shared-memory flink {:?}: {}",
                            path,
                            err
                        );
                    }
                    std::thread::sleep(Duration::from_millis(200));
                }
            }
        }
    });
}

#[inline]
fn read_command(shmem: &crate::portable_service::SharedMemory) -> CaptureCommand {
    unsafe {
        let ptr = shmem.as_ptr().add(ADDR_COMMAND) as *const CaptureCommand;
        std::ptr::read_volatile(ptr)
    }
}

#[inline]
fn write_command(shmem: &crate::portable_service::SharedMemory, command: CaptureCommand) {
    unsafe {
        let ptr = &command as *const CaptureCommand as *const u8;
        let data = slice::from_raw_parts(ptr, size_of::<CaptureCommand>());
        shmem.write(ADDR_COMMAND, data);
    }
}

#[inline]
fn read_frame_info(shmem: &crate::portable_service::SharedMemory) -> CaptureFrameInfo {
    unsafe {
        let ptr = shmem.as_ptr().add(ADDR_FRAME_INFO) as *const CaptureFrameInfo;
        std::ptr::read_volatile(ptr)
    }
}

#[inline]
fn write_frame_info(shmem: &crate::portable_service::SharedMemory, info: CaptureFrameInfo) {
    unsafe {
        let ptr = &info as *const CaptureFrameInfo as *const u8;
        let data = slice::from_raw_parts(ptr, size_of::<CaptureFrameInfo>());
        shmem.write(ADDR_FRAME_INFO, data);
    }
}

#[inline]
fn shmem_size_for_display(width: usize, height: usize) -> usize {
    align_up(
        ADDR_FRAME + width.saturating_mul(height).saturating_mul(4),
        FRAME_ALIGN,
    )
    .max(MIN_SHMEM_LEN)
}

#[inline]
fn validate_frame_length(shmem_len: usize, length: usize) -> bool {
    length > 0 && length <= shmem_len.saturating_sub(ADDR_FRAME)
}

fn create_wgc_capturer(
    current_display: usize,
) -> ResultType<(Box<dyn TraitCapturer>, usize, usize)> {
    let mut displays = Display::all().with_context(|| "Failed to enumerate displays")?;
    if displays.len() <= current_display {
        bail!(
            "Invalid display index {}, display_count={}",
            current_display,
            displays.len()
        );
    }
    let display = displays.remove(current_display);
    let width = display.width();
    let height = display.height();
    if !scrap::CapturerWgc::is_supported() {
        bail!("WGC is not supported");
    }
    let capturer =
        scrap::CapturerWgc::new(display).with_context(|| "Failed to create WGC capturer")?;
    Ok((Box::new(capturer), width, height))
}

fn create_gdi_capturer(
    current_display: usize,
) -> ResultType<(Box<dyn TraitCapturer>, usize, usize)> {
    let mut displays = Display::all().with_context(|| "Failed to enumerate displays")?;
    if displays.len() <= current_display {
        bail!(
            "Invalid display index {}, display_count={}",
            current_display,
            displays.len()
        );
    }
    let display = displays.remove(current_display);
    let width = display.width();
    let height = display.height();
    let mut capturer = Capturer::new(display).with_context(|| "Failed to create GDI capturer")?;
    if !capturer.set_gdi() {
        bail!("Failed to enable GDI capture");
    }
    Ok((Box::new(capturer), width, height))
}

pub mod server {
    use super::*;

    pub fn run_user_capture_helper() {
        let Some(shmem_name) = user_capture_helper_shmem_name_from_args() else {
            log::error!("Missing user capture helper shared memory argument");
            return;
        };
        let shmem = match crate::portable_service::SharedMemory::open_existing(&shmem_name) {
            Ok(shmem) => shmem,
            Err(err) => {
                log::error!("Failed to open user capture helper shared memory: {}", err);
                return;
            }
        };
        if shmem.len() < MIN_SHMEM_LEN {
            log::error!(
                "User capture helper shared memory too small: len={}, need>={}",
                shmem.len(),
                MIN_SHMEM_LEN
            );
            return;
        }
        run_capture_loop(&shmem);
    }

    fn run_capture_loop(shmem: &crate::portable_service::SharedMemory) {
        let mut capturer: Option<Box<dyn TraitCapturer>> = None;
        let mut active_generation = u32::MAX;
        let mut active_display = usize::MAX;
        let mut width = 0usize;
        let mut height = 0usize;
        let mut counter = 0u32;
        let mut would_block_samples = 0u32;
        let mut primary_frames = 0u32;
        let mut primary_no_frame_since: Option<Instant> = None;
        let mut primary_backend = "Windows Graphics Capture";
        let mut primary_is_gdi = false;
        let mut gdi_fallback: Option<Box<dyn TraitCapturer>> = None;
        let mut gdi_fallback_frames = 0u32;
        let mut gdi_bootstrap_attempted = false;
        loop {
            let command = read_command(shmem);
            if command.exit != 0 {
                log::info!("User capture helper exit requested");
                break;
            }
            let recreate = capturer.is_none()
                || active_generation != command.generation
                || active_display != command.current_display;
            if recreate {
                let new_backend = match create_wgc_capturer(command.current_display) {
                    Ok((new_capturer, new_width, new_height)) => (
                        new_capturer,
                        new_width,
                        new_height,
                        "Windows Graphics Capture",
                        false,
                    ),
                    Err(wgc_err) => {
                        log::warn!(
                            "User capture helper failed to create WGC capturer, trying GDI fallback: {}",
                            wgc_err
                        );
                        match create_gdi_capturer(command.current_display) {
                            Ok((new_capturer, new_width, new_height)) => {
                                (new_capturer, new_width, new_height, "Windows GDI", true)
                            }
                            Err(gdi_err) => {
                                log::warn!(
                                    "User capture helper failed to create GDI fallback capturer: {}",
                                    gdi_err
                                );
                                capturer = None;
                                write_frame_info(
                                    shmem,
                                    CaptureFrameInfo {
                                        counter,
                                        status: STATUS_ERROR,
                                        length: 0,
                                        width: 0,
                                        height: 0,
                                        backend: BACKEND_UNKNOWN,
                                    },
                                );
                                std::thread::sleep(Duration::from_millis(500));
                                continue;
                            }
                        }
                    }
                };
                let (new_capturer, new_width, new_height, new_backend_name, new_is_gdi) =
                    new_backend;
                log::info!(
                    "User capture helper created {} capturer for display {}, size={}x{}",
                    new_backend_name,
                    command.current_display,
                    new_width,
                    new_height
                );
                capturer = Some(new_capturer);
                active_generation = command.generation;
                active_display = command.current_display;
                width = new_width;
                height = new_height;
                primary_backend = new_backend_name;
                primary_is_gdi = new_is_gdi;
                would_block_samples = 0;
                primary_frames = 0;
                primary_no_frame_since = None;
                gdi_fallback = None;
                gdi_fallback_frames = 0;
                gdi_bootstrap_attempted = false;
                write_frame_info(
                    shmem,
                    CaptureFrameInfo {
                        counter,
                        status: STATUS_STARTING,
                        length: 0,
                        width,
                        height,
                        backend: if primary_is_gdi {
                            BACKEND_GDI_CPU
                        } else {
                            BACKEND_WGC_CPU
                        },
                    },
                );
            }

            let timeout = Duration::from_millis(command.timeout_ms.max(1) as u64);
            let primary_timeout = if primary_frames == 0 && gdi_fallback.is_some() {
                Duration::from_millis(1)
            } else {
                timeout
            };
            match capturer
                .as_mut()
                .map(|capturer| capturer.frame(primary_timeout))
            {
                Some(Ok(Frame::PixelBuffer(frame))) => {
                    let data = frame.data();
                    if !validate_frame_length(shmem.len(), data.len()) {
                        log::error!(
                            "User capture helper frame exceeds shared memory capacity: frame_len={}, shmem_len={}",
                            data.len(),
                            shmem.len()
                        );
                        write_frame_info(
                            shmem,
                            CaptureFrameInfo {
                                counter,
                                status: STATUS_ERROR,
                                length: 0,
                                width,
                                height,
                                backend: if primary_is_gdi {
                                    BACKEND_GDI_CPU
                                } else {
                                    BACKEND_WGC_CPU
                                },
                            },
                        );
                        std::thread::sleep(timeout);
                        continue;
                    }
                    shmem.write(ADDR_FRAME, data);
                    counter = counter.wrapping_add(1).max(1);
                    primary_frames = primary_frames.saturating_add(1);
                    if primary_frames == 1 {
                        log::info!(
                            "User capture helper received first {} frame, len={}, size={}x{}",
                            primary_backend,
                            data.len(),
                            width,
                            height
                        );
                        if gdi_fallback.is_some() {
                            log::info!(
                                "User capture helper switching from GDI fallback to {}",
                                primary_backend
                            );
                        }
                    }
                    gdi_fallback = None;
                    gdi_fallback_frames = 0;
                    primary_no_frame_since = None;
                    would_block_samples = 0;
                    write_frame_info(
                        shmem,
                        CaptureFrameInfo {
                            counter,
                            status: STATUS_OK,
                            length: data.len(),
                            width,
                            height,
                            backend: if primary_is_gdi {
                                BACKEND_GDI_CPU
                            } else {
                                BACKEND_WGC_CPU
                            },
                        },
                    );
                }
                Some(Ok(Frame::Texture(_))) => {
                    log::warn!(
                        "User capture helper received {} texture frame, recreating capturer",
                        primary_backend
                    );
                    capturer = None;
                    write_frame_info(
                        shmem,
                        CaptureFrameInfo {
                            counter,
                            status: STATUS_ERROR,
                            length: 0,
                            width,
                            height,
                            backend: if primary_is_gdi {
                                BACKEND_GDI_CPU
                            } else {
                                BACKEND_WGC_CPU
                            },
                        },
                    );
                }
                Some(Err(err)) if err.kind() == std::io::ErrorKind::WouldBlock => {
                    would_block_samples = would_block_samples.saturating_add(1);
                    let first_no_frame = *primary_no_frame_since.get_or_insert_with(Instant::now);
                    if would_block_samples == 1 || would_block_samples % 60 == 0 {
                        log::debug!(
                            "User capture helper {} would block, samples={}",
                            primary_backend,
                            would_block_samples,
                        );
                    }
                    if primary_frames == 0
                        && !primary_is_gdi
                        && first_no_frame.elapsed() >= GDI_BOOTSTRAP_AFTER
                    {
                        if gdi_fallback.is_none() && !gdi_bootstrap_attempted {
                            gdi_bootstrap_attempted = true;
                            match create_gdi_capturer(active_display) {
                                Ok((new_gdi_capturer, gdi_width, gdi_height))
                                    if gdi_width == width && gdi_height == height =>
                                {
                                    log::info!(
                                        "User capture helper enabled GDI fallback after {:?}, size={}x{}",
                                        first_no_frame.elapsed(),
                                        width,
                                        height
                                    );
                                    gdi_fallback = Some(new_gdi_capturer);
                                    gdi_fallback_frames = 0;
                                }
                                Ok((_gdi_capturer, gdi_width, gdi_height)) => {
                                    log::warn!(
                                        "User capture helper GDI fallback size mismatch: primary={}x{}, gdi={}x{}",
                                        width,
                                        height,
                                        gdi_width,
                                        gdi_height
                                    );
                                }
                                Err(err) => {
                                    log::warn!(
                                        "User capture helper failed to create GDI fallback capturer: {}",
                                        err
                                    );
                                }
                            }
                        }
                        if let Some(gdi_capturer) = gdi_fallback.as_mut() {
                            match gdi_capturer.frame(timeout) {
                                Ok(Frame::PixelBuffer(frame)) => {
                                    let data = frame.data();
                                    if validate_frame_length(shmem.len(), data.len()) {
                                        shmem.write(ADDR_FRAME, data);
                                        counter = counter.wrapping_add(1).max(1);
                                        gdi_fallback_frames = gdi_fallback_frames.saturating_add(1);
                                        if gdi_fallback_frames == 1 || gdi_fallback_frames % 60 == 0
                                        {
                                            log::info!(
                                                "User capture helper wrote GDI fallback frame #{}, len={}, size={}x{}",
                                                gdi_fallback_frames,
                                                data.len(),
                                                width,
                                                height
                                            );
                                        }
                                        write_frame_info(
                                            shmem,
                                            CaptureFrameInfo {
                                                counter,
                                                status: STATUS_OK,
                                                length: data.len(),
                                                width,
                                                height,
                                                backend: BACKEND_GDI_CPU,
                                            },
                                        );
                                        continue;
                                    }
                                    log::warn!(
                                        "User capture helper GDI fallback frame exceeds shared memory capacity: frame_len={}, shmem_len={}",
                                        data.len(),
                                        shmem.len()
                                    );
                                    gdi_fallback = None;
                                }
                                Ok(Frame::Texture(_)) => {
                                    log::warn!(
                                        "User capture helper GDI fallback returned texture frame"
                                    );
                                    gdi_fallback = None;
                                }
                                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {}
                                Err(err) => {
                                    log::warn!(
                                        "User capture helper GDI fallback frame failed: {}",
                                        err
                                    );
                                    gdi_fallback = None;
                                }
                            }
                        }
                    }
                    if counter == 0 {
                        write_frame_info(
                            shmem,
                            CaptureFrameInfo {
                                counter,
                                status: STATUS_WOULD_BLOCK,
                                length: 0,
                                width,
                                height,
                                backend: if primary_is_gdi {
                                    BACKEND_GDI_CPU
                                } else {
                                    BACKEND_WGC_CPU
                                },
                            },
                        );
                    }
                }
                Some(Err(err)) => {
                    log::warn!(
                        "User capture helper {} frame failed: {}",
                        primary_backend,
                        err
                    );
                    capturer = None;
                    write_frame_info(
                        shmem,
                        CaptureFrameInfo {
                            counter,
                            status: STATUS_ERROR,
                            length: 0,
                            width,
                            height,
                            backend: if primary_is_gdi {
                                BACKEND_GDI_CPU
                            } else {
                                BACKEND_WGC_CPU
                            },
                        },
                    );
                    std::thread::sleep(Duration::from_millis(100));
                }
                None => std::thread::sleep(Duration::from_millis(20)),
            }
        }
    }
}

pub mod client {
    use super::*;
    use scrap::PixelBuffer;

    static NEXT_GENERATION: AtomicU32 = AtomicU32::new(1);

    pub struct UserCaptureHelperCapturer {
        shmem_name: String,
        shmem: crate::portable_service::SharedMemory,
        process: HANDLE,
        current_display: usize,
        generation: u32,
        width: usize,
        height: usize,
        last_counter: u32,
        last_backend: u32,
    }

    unsafe impl Send for UserCaptureHelperCapturer {}

    impl UserCaptureHelperCapturer {
        pub fn new(current_display: usize, width: usize, height: usize) -> ResultType<Self> {
            let shmem_name = next_shmem_name();
            let shmem_size = shmem_size_for_display(width, height);
            let shmem = crate::portable_service::SharedMemory::create(&shmem_name, shmem_size)?;
            if let Ok(flink) = shmem_flink_path(&shmem_name) {
                if let Err(err) =
                    crate::platform::windows::grant_user_capture_helper_shmem_file_access(&flink)
                {
                    log::warn!(
                        "Failed to grant user capture helper shared-memory access for {:?}: {}",
                        flink,
                        err
                    );
                }
            }
            unsafe {
                libc::memset(shmem.as_ptr() as _, 0, shmem.len());
            }
            let generation = NEXT_GENERATION.fetch_add(1, Ordering::SeqCst);
            write_command(
                &shmem,
                CaptureCommand {
                    exit: 0,
                    generation,
                    current_display,
                    timeout_ms: 33,
                },
            );
            write_frame_info(
                &shmem,
                CaptureFrameInfo {
                    counter: 0,
                    status: STATUS_STARTING,
                    length: 0,
                    width,
                    height,
                    backend: BACKEND_UNKNOWN,
                },
            );
            let exe = std::env::current_exe()?.to_string_lossy().to_string();
            let cmd = format!("\"{}\" {} {}", exe, ARG, shmem_arg(&shmem_name));
            let Some(session_id) = crate::platform::windows::get_current_process_session_id()
            else {
                schedule_remove_shmem_flink(shmem_name);
                bail!("current process session id is unavailable");
            };
            let process =
                match crate::platform::windows::launch_user_process_in_session(session_id, &cmd) {
                    Ok(process) => process,
                    Err(err) => {
                        schedule_remove_shmem_flink(shmem_name);
                        return Err(err).with_context(|| "Failed to launch user capture helper");
                    }
                };
            if process.is_null() {
                schedule_remove_shmem_flink(shmem_name);
                bail!("Failed to launch user capture helper");
            }
            log::info!(
                "Launched user capture helper: backend=WGC helper CPU, display={}, session={}, shmem={}, size={}",
                current_display,
                session_id,
                shmem_name,
                shmem_size
            );
            Ok(Self {
                shmem_name,
                shmem,
                process,
                current_display,
                generation,
                width,
                height,
                last_counter: 0,
                last_backend: BACKEND_UNKNOWN,
            })
        }

        fn update_timeout(&self, timeout: Duration) {
            let mut command = read_command(&self.shmem);
            command.timeout_ms = timeout.as_millis().clamp(1, u32::MAX as u128) as u32;
            command.exit = 0;
            command.generation = self.generation;
            command.current_display = self.current_display;
            write_command(&self.shmem, command);
        }

        fn helper_exited(&self) -> bool {
            if self.process.is_null() {
                return true;
            }
            let mut exit_code = 0;
            let ok = unsafe { GetExitCodeProcess(self.process, &mut exit_code) };
            ok == 0 || exit_code != STILL_ACTIVE
        }
    }

    impl Drop for UserCaptureHelperCapturer {
        fn drop(&mut self) {
            let mut command = read_command(&self.shmem);
            command.exit = 1;
            write_command(&self.shmem, command);
            if !self.process.is_null() {
                unsafe {
                    CloseHandle(self.process);
                }
            }
            schedule_remove_shmem_flink(self.shmem_name.clone());
        }
    }

    impl TraitCapturer for UserCaptureHelperCapturer {
        fn frame<'a>(&'a mut self, timeout: Duration) -> std::io::Result<Frame<'a>> {
            self.update_timeout(timeout);
            let info = read_frame_info(&self.shmem);
            if info.backend != BACKEND_UNKNOWN {
                self.last_backend = info.backend;
            }
            if info.status == STATUS_OK && info.counter != self.last_counter {
                if info.width != self.width || info.height != self.height {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::WouldBlock,
                        "user capture helper frame size is changing",
                    ));
                }
                if !validate_frame_length(self.shmem.len(), info.length) {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "invalid user capture helper frame length",
                    ));
                }
                self.last_counter = info.counter;
                unsafe {
                    let data =
                        slice::from_raw_parts(self.shmem.as_ptr().add(ADDR_FRAME), info.length);
                    return Ok(Frame::PixelBuffer(PixelBuffer::with_BGRA(
                        data,
                        self.width,
                        self.height,
                    )));
                }
            }
            match info.status {
                STATUS_ERROR => Err(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    "user capture helper backend error",
                )),
                _ if self.helper_exited() => Err(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    "user capture helper exited",
                )),
                _ => Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "user capture helper would block",
                )),
            }
        }

        fn is_gdi(&self) -> bool {
            false
        }

        fn is_cpu_only(&self) -> bool {
            true
        }

        fn capture_backend(&self) -> &'static str {
            match self.last_backend {
                BACKEND_WGC_CPU => "Windows Graphics Capture Helper (CPU)",
                BACKEND_GDI_CPU => "Windows GDI Helper (CPU)",
                _ => "User Capture Helper (CPU)",
            }
        }

        fn set_gdi(&mut self) -> bool {
            false
        }

        #[cfg(feature = "vram")]
        fn device(&self) -> AdapterDevice {
            AdapterDevice::default()
        }

        #[cfg(feature = "vram")]
        fn set_output_texture(&mut self, _texture: bool) {}
    }

    pub fn create_capturer(
        current_display: usize,
        width: usize,
        height: usize,
    ) -> ResultType<Box<dyn TraitCapturer>> {
        Ok(Box::new(UserCaptureHelperCapturer::new(
            current_display,
            width,
            height,
        )?))
    }
}
