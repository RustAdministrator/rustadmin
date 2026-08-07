use crate::{
    ipc::{self, new_listener, Connection, Data, DataPortableService, IPC_TOKEN_LEN},
    platform::{
        set_path_permission, set_path_permission_for_portable_service_shmem_dir,
        set_path_permission_for_portable_service_shmem_file,
        validate_path_for_portable_service_shmem_dir,
    },
};
use core::slice;
use hbb_common::{
    allow_err,
    anyhow::anyhow,
    bail, libc, log,
    message_proto::{KeyEvent, MouseEvent},
    protobuf::Message,
    tokio::{self, sync::mpsc},
    ResultType,
};
#[cfg(feature = "vram")]
use scrap::AdapterDevice;
use scrap::{Capturer, Frame, TraitCapturer, TraitPixelBuffer};
use shared_memory::*;
use std::{
    mem::size_of,
    ops::{Deref, DerefMut},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use winapi::{
    shared::minwindef::{BOOL, FALSE, TRUE},
    um::winuser::{self, CURSORINFO, PCURSORINFO},
};
use windows::Win32::Storage::FileSystem::{FILE_GENERIC_EXECUTE, FILE_GENERIC_READ};

use super::video_qos;

const SIZE_COUNTER: usize = size_of::<i32>() * 2;
const FRAME_ALIGN: usize = 64;

const ADDR_IPC_TOKEN: usize = 0;
const ADDR_CURSOR_PARA: usize = ADDR_IPC_TOKEN + IPC_TOKEN_LEN;
const ADDR_CURSOR_COUNTER: usize = ADDR_CURSOR_PARA + size_of::<CURSORINFO>();

const ADDR_CAPTURER_PARA: usize = ADDR_CURSOR_COUNTER + SIZE_COUNTER;
const ADDR_CAPTURE_FRAME_INFO: usize = ADDR_CAPTURER_PARA + size_of::<CapturerPara>();
const ADDR_CAPTURE_WOULDBLOCK: usize = ADDR_CAPTURE_FRAME_INFO + size_of::<FrameInfo>();
const ADDR_CAPTURE_FRAME_COUNTER: usize = ADDR_CAPTURE_WOULDBLOCK + size_of::<i32>();

const ADDR_CAPTURE_FRAME: usize =
    (ADDR_CAPTURE_FRAME_COUNTER + SIZE_COUNTER + FRAME_ALIGN - 1) / FRAME_ALIGN * FRAME_ALIGN;
const MIN_RUNTIME_SHMEM_LEN: usize = ADDR_CAPTURE_FRAME + FRAME_ALIGN;

const IPC_SUFFIX: &str = "_portable_service";
pub const SHMEM_NAME: &str = "_portable_service";
pub const SHMEM_ARG_PREFIX: &str = "--portable-service-shmem-name=";
const SHMEM_PARENT_DIR: &str = "portable_service_shmem";
const SHMEM_NAME_MAX_LEN: usize = 64;
const MAX_NACK: usize = 3;
const PORTABLE_SERVICE_STARTUP_TIMEOUT: Duration = Duration::from_secs(15);
const PORTABLE_SERVICE_FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_SECURE_CAPTURE_RECOVERY_FAILURES: u64 = 3;
const SECURE_CAPTURE_RECOVERY_BACKOFF: Duration = Duration::from_secs(15);
const MAX_DXGI_FAIL_TIME: usize = 5;

#[inline]
fn is_valid_portable_service_shmem_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= SHMEM_NAME_MAX_LEN
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

#[inline]
pub fn portable_service_shmem_arg(name: &str) -> String {
    format!("{SHMEM_ARG_PREFIX}{name}")
}

#[inline]
fn is_valid_portable_service_ipc_token(token: &str) -> bool {
    token.len() == IPC_TOKEN_LEN
        && token
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

#[inline]
fn read_ipc_token_from_shmem(shmem: &SharedMemory) -> Option<String> {
    if shmem.len() < ADDR_IPC_TOKEN + IPC_TOKEN_LEN {
        log::error!(
            "Portable service shared memory too small: len={}, need>={}",
            shmem.len(),
            ADDR_IPC_TOKEN + IPC_TOKEN_LEN
        );
        return None;
    }
    unsafe {
        let ptr = shmem.as_ptr().add(ADDR_IPC_TOKEN);
        let bytes = slice::from_raw_parts(ptr, IPC_TOKEN_LEN);
        let end = bytes
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(IPC_TOKEN_LEN);
        if end == 0 {
            return None;
        }
        let token = std::str::from_utf8(&bytes[..end]).ok()?.to_owned();
        if is_valid_portable_service_ipc_token(&token) {
            Some(token)
        } else {
            None
        }
    }
}

#[inline]
fn validate_runtime_shmem_layout(shmem: &SharedMemory) -> ResultType<()> {
    if shmem.len() < MIN_RUNTIME_SHMEM_LEN {
        bail!(
            "Portable service shared memory too small for runtime layout: len={}, need>={}",
            shmem.len(),
            MIN_RUNTIME_SHMEM_LEN
        );
    }
    Ok(())
}

#[inline]
fn is_valid_capture_frame_length(shmem_len: usize, frame_len: usize) -> bool {
    let frame_capacity = shmem_len.saturating_sub(ADDR_CAPTURE_FRAME);
    frame_len > 0 && frame_len <= frame_capacity
}

#[inline]
fn shared_memory_flink_path_by_name(name: &str) -> ResultType<PathBuf> {
    let mut dir = crate::platform::user_accessible_folder()?;
    dir = dir.join(hbb_common::config::APP_NAME.read().unwrap().clone());
    dir = dir.join(SHMEM_PARENT_DIR);
    Ok(dir.join(format!("shared_memory{}", name)))
}

#[inline]
fn remove_shared_memory_flink_once(name: &str, log_on_error: bool, log_context: &str) -> bool {
    let flink = match shared_memory_flink_path_by_name(name) {
        Ok(path) => path,
        Err(err) => {
            if log_on_error {
                log::warn!(
                    "{} failed to resolve portable service shared-memory flink path for '{}': {}",
                    log_context,
                    name,
                    err
                );
            }
            return false;
        }
    };
    match std::fs::remove_file(&flink) {
        Ok(()) => {
            log::info!(
                "{} removed portable service shared-memory flink artifact: {:?}",
                log_context,
                flink
            );
            true
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => true,
        Err(err) => {
            if log_on_error {
                log::warn!(
                    "{} failed to remove portable service shared-memory flink artifact {:?}: {}",
                    log_context,
                    flink,
                    err
                );
            }
            false
        }
    }
}

#[inline]
fn write_ipc_token_to_shmem(shmem: &SharedMemory, token: &str) -> ResultType<()> {
    if !is_valid_portable_service_ipc_token(token) {
        bail!("Invalid portable service ipc token");
    }
    shmem.write(ADDR_IPC_TOKEN, token.as_bytes());
    Ok(())
}

#[inline]
fn clear_ipc_token_in_shmem(shmem: &SharedMemory) {
    shmem.write(ADDR_IPC_TOKEN, &[0u8; IPC_TOKEN_LEN]);
}

#[inline]
fn portable_service_arg_value_candidate_from_arg<'a>(
    arg: &'a str,
    prefix: &str,
) -> Option<&'a str> {
    let mut value = arg.strip_prefix(prefix)?;
    value = value.trim_start();
    value = value
        .strip_prefix('"')
        .or_else(|| value.strip_prefix('\''))
        .unwrap_or(value);
    value = value.split_whitespace().next().unwrap_or_default();
    value = value.trim_matches(|c| c == '"' || c == '\'');
    Some(value)
}

#[inline]
pub fn portable_service_shmem_name_from_args() -> Option<String> {
    for arg in std::env::args() {
        if let Some(value) = portable_service_arg_value_candidate_from_arg(&arg, SHMEM_ARG_PREFIX) {
            if is_valid_portable_service_shmem_name(value) {
                return Some(value.to_owned());
            }
            log::error!(
                "Invalid portable service shared memory name argument: '{}'",
                value
            );
            return None;
        }
    }
    None
}

#[inline]
pub fn has_portable_service_shmem_arg() -> bool {
    std::env::args().any(|arg| arg.starts_with(SHMEM_ARG_PREFIX))
}

pub struct SharedMemory {
    inner: Shmem,
}

unsafe impl Send for SharedMemory {}
unsafe impl Sync for SharedMemory {}

impl Deref for SharedMemory {
    type Target = Shmem;

    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}

impl DerefMut for SharedMemory {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.inner
    }
}

impl SharedMemory {
    pub fn create(name: &str, size: usize) -> ResultType<Self> {
        let flink = Self::flink(name.to_string())?;
        let shmem = match ShmemConf::new()
            .size(size)
            .flink(&flink)
            .force_create_flink()
            .create()
        {
            Ok(m) => m,
            Err(ShmemError::LinkExists) => {
                bail!(
                    "Unable to force create shmem flink {}, which should not happen.",
                    flink
                )
            }
            Err(e) => {
                bail!("Unable to create shmem flink {} : {}", flink, e);
            }
        };
        log::info!("Create shared memory, size: {}, flink: {}", size, flink);
        if let Err(err) = set_path_permission_for_portable_service_shmem_file(Path::new(&flink)) {
            // Release shmem handle first so best-effort flink cleanup has a chance to succeed.
            drop(shmem);
            match std::fs::remove_file(&flink) {
                Ok(()) => {
                    log::info!(
                        "Create cleanup removed portable service shared-memory flink artifact: {}",
                        flink
                    );
                }
                Err(remove_err) if remove_err.kind() == std::io::ErrorKind::NotFound => {}
                Err(remove_err) => {
                    log::warn!(
                        "Create cleanup failed to remove portable service shared-memory flink artifact {}: {}",
                        flink,
                        remove_err
                    );
                }
            }
            return Err(err);
        }
        Ok(SharedMemory { inner: shmem })
    }

    pub fn open_existing(name: &str) -> ResultType<Self> {
        let flink = Self::flink(name.to_string())?;
        let shmem = match ShmemConf::new().flink(&flink).allow_raw(true).open() {
            Ok(m) => m,
            Err(e) => {
                bail!("Unable to open existing shmem flink {} : {}", flink, e);
            }
        };
        log::info!("open existing shared memory, flink: {:?}", flink);
        Ok(SharedMemory { inner: shmem })
    }

    pub fn write(&self, addr: usize, data: &[u8]) {
        unsafe {
            debug_assert!(addr + data.len() <= self.inner.len());
            let ptr = self.inner.as_ptr().add(addr);
            let shared_mem_slice = slice::from_raw_parts_mut(ptr, data.len());
            shared_mem_slice.copy_from_slice(data);
        }
    }

    fn flink(name: String) -> ResultType<String> {
        let mut dir = crate::platform::user_accessible_folder()?;
        dir = dir.join(hbb_common::config::APP_NAME.read().unwrap().clone());
        dir = dir.join(SHMEM_PARENT_DIR);
        let parent_created = !dir.exists();
        if parent_created {
            std::fs::create_dir_all(&dir)?;
        }
        if parent_created || crate::platform::is_root() {
            // Harden parent ACL on first provisioning and periodically on SYSTEM path.
            set_path_permission_for_portable_service_shmem_dir(&dir)?;
        } else {
            // Existing parents still need type/reparse validation. Non-SYSTEM callers may lack
            // WRITE_DAC on a valid parent, so avoid rebuilding the ACL here.
            validate_path_for_portable_service_shmem_dir(&dir)?;
        }
        Ok(dir
            .join(format!("shared_memory{}", name))
            .to_string_lossy()
            .to_string())
    }
}

mod utils {
    use core::slice;
    use std::mem::size_of;

    use super::{
        CapturerPara, FrameInfo, SharedMemory, ADDR_CAPTURER_PARA, ADDR_CAPTURE_FRAME_INFO,
    };

    #[inline]
    pub fn i32_to_vec(i: i32) -> Vec<u8> {
        i.to_ne_bytes().to_vec()
    }

    #[inline]
    pub fn ptr_to_i32(ptr: *const u8) -> i32 {
        unsafe {
            let v = slice::from_raw_parts(ptr, size_of::<i32>());
            i32::from_ne_bytes([v[0], v[1], v[2], v[3]])
        }
    }

    #[inline]
    pub fn counter_ready(counter: *const u8) -> bool {
        unsafe {
            let wptr = counter;
            let rptr = counter.add(size_of::<i32>());
            let iw = ptr_to_i32(wptr);
            let ir = ptr_to_i32(rptr);
            if ir != iw {
                std::ptr::copy_nonoverlapping(wptr, rptr as *mut _, size_of::<i32>());
                true
            } else {
                false
            }
        }
    }

    #[inline]
    pub fn counter_equal(counter: *const u8) -> bool {
        unsafe {
            let wptr = counter;
            let rptr = counter.add(size_of::<i32>());
            let iw = ptr_to_i32(wptr);
            let ir = ptr_to_i32(rptr);
            iw == ir
        }
    }

    #[inline]
    pub fn increase_counter(counter: *mut u8) {
        unsafe {
            let wptr = counter;
            let rptr = counter.add(size_of::<i32>());
            let iw = ptr_to_i32(counter);
            let ir = ptr_to_i32(counter);
            let iw_plus1 = if iw == i32::MAX { 0 } else { iw + 1 };
            let v = i32_to_vec(iw_plus1);
            std::ptr::copy_nonoverlapping(v.as_ptr(), wptr, size_of::<i32>());
            if ir == iw_plus1 {
                let v = i32_to_vec(iw);
                std::ptr::copy_nonoverlapping(v.as_ptr(), rptr, size_of::<i32>());
            }
        }
    }

    #[inline]
    pub fn align(v: usize, align: usize) -> usize {
        (v + align - 1) / align * align
    }

    #[inline]
    pub fn set_para(shmem: &SharedMemory, para: CapturerPara) {
        let para_ptr = &para as *const CapturerPara as *const u8;
        let para_data;
        unsafe {
            para_data = slice::from_raw_parts(para_ptr, size_of::<CapturerPara>());
        }
        shmem.write(ADDR_CAPTURER_PARA, para_data);
    }

    #[inline]
    pub fn set_frame_info(shmem: &SharedMemory, info: FrameInfo) {
        let ptr = &info as *const FrameInfo as *const u8;
        let data;
        unsafe {
            data = slice::from_raw_parts(ptr, size_of::<FrameInfo>());
        }
        shmem.write(ADDR_CAPTURE_FRAME_INFO, data);
    }
}

// functions called in separate SYSTEM user process.
pub mod server {
    use hbb_common::message_proto::PointerDeviceEvent;

    use crate::display_service;

    use super::*;

    lazy_static::lazy_static! {
        static ref EXIT: Arc<Mutex<bool>> = Default::default();
        static ref FORCE_EXIT_ARMED: AtomicBool = AtomicBool::new(false);
    }

    pub fn run_portable_service() {
        let shmem_name = match portable_service_shmem_name_from_args() {
            Some(name) => name,
            None => {
                if has_portable_service_shmem_arg() {
                    log::error!(
                        "Invalid portable service shared memory argument, aborting startup"
                    );
                } else {
                    log::error!(
                        "Missing portable service shared memory argument, aborting startup"
                    );
                }
                return;
            }
        };
        let shmem = match SharedMemory::open_existing(&shmem_name) {
            Ok(shmem) => Arc::new(shmem),
            Err(e) => {
                log::error!("Failed to open existing shared memory: {:?}", e);
                return;
            }
        };
        if let Err(e) = validate_runtime_shmem_layout(shmem.as_ref()) {
            log::error!("{}", e);
            return;
        }
        let ipc_token = match read_ipc_token_from_shmem(shmem.as_ref()) {
            Some(token) => token,
            None => {
                log::error!(
                    "Missing portable service ipc token in shared memory, aborting startup"
                );
                return;
            }
        };
        let shmem1 = shmem.clone();
        let shmem2 = shmem.clone();
        let mut threads = vec![];
        threads.push(std::thread::spawn(|| {
            run_get_cursor_info(shmem1);
        }));
        threads.push(std::thread::spawn(|| {
            run_capture(shmem2);
        }));
        threads.push(std::thread::spawn(move || {
            run_ipc_client(ipc_token);
        }));
        // Detached shutdown watchdog:
        // - gives graceful shutdown/cleanup a short window
        // - force-exits the process if workers are still stuck
        std::thread::spawn(|| {
            run_exit_check();
        });
        let record_pos_handle = crate::input_service::try_start_record_cursor_pos();
        // Arm forced-exit watchdog only for worker join phase.
        // Once join phase completes, cleanup should not be interrupted by forced exit.
        FORCE_EXIT_ARMED.store(true, Ordering::SeqCst);
        for th in threads.drain(..) {
            th.join().ok();
            log::info!("thread joined");
        }
        FORCE_EXIT_ARMED.store(false, Ordering::SeqCst);

        crate::input_service::try_stop_record_cursor_pos();
        if let Some(handle) = record_pos_handle {
            match handle.join() {
                Ok(_) => log::info!("record_pos_handle joined"),
                Err(e) => log::error!("record_pos_handle join error {:?}", &e),
            }
        }
        drop(shmem);
        remove_shared_memory_flink_with_retry(&shmem_name);
    }

    fn run_exit_check() {
        const FORCED_EXIT_DELAY: Duration = Duration::from_secs(3);
        loop {
            if EXIT.lock().unwrap().clone() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        // Fallback only: normal shutdown path should complete and process should exit naturally.
        // This forced exit is a last resort when worker threads are stuck and graceful teardown
        // does not finish in time.
        std::thread::sleep(FORCED_EXIT_DELAY);
        if FORCE_EXIT_ARMED.load(Ordering::SeqCst) {
            log::warn!(
                "Portable service shutdown watchdog fallback triggered: forcing process exit after {:?}",
                FORCED_EXIT_DELAY
            );
            std::process::exit(0);
        }
    }

    fn remove_shared_memory_flink_with_retry(name: &str) {
        const MAX_RETRY: usize = 20;
        const RETRY_INTERVAL: Duration = Duration::from_millis(200);
        for attempt in 0..MAX_RETRY {
            let is_last_attempt = attempt + 1 == MAX_RETRY;
            if remove_shared_memory_flink_once(name, is_last_attempt, "SYSTEM cleanup") {
                return;
            }
            if !is_last_attempt {
                std::thread::sleep(RETRY_INTERVAL);
            }
        }
        log::warn!(
            "SYSTEM cleanup failed to remove portable service shared-memory flink artifact '{}' after retry",
            name
        );
    }

    fn run_get_cursor_info(shmem: Arc<SharedMemory>) {
        loop {
            if EXIT.lock().unwrap().clone() {
                break;
            }
            unsafe {
                let para = shmem.as_ptr().add(ADDR_CURSOR_PARA) as *mut CURSORINFO;
                (*para).cbSize = size_of::<CURSORINFO>() as _;
                let result = winuser::GetCursorInfo(para);
                if result == TRUE {
                    utils::increase_counter(shmem.as_ptr().add(ADDR_CURSOR_COUNTER));
                }
            }
            // more frequent in case of `Error of mouse_cursor service`
            std::thread::sleep(Duration::from_millis(15));
        }
    }

    fn capture_desktop_state() -> (bool, bool, bool, bool) {
        (
            crate::platform::windows::is_prelogin(),
            crate::platform::windows::is_locked(),
            crate::platform::windows::desktop_changed(),
            crate::platform::windows::is_logon_ui_for_capture(),
        )
    }

    fn sampled_bgr_sum(data: &[u8]) -> u64 {
        let pixels = data.len() / 4;
        if pixels == 0 {
            return 0;
        }
        let step = (pixels / 1024).max(1);
        let mut sum = 0u64;
        let mut samples = 0usize;
        let mut pixel = 0usize;
        while pixel < pixels && samples < 1024 {
            let i = pixel * 4;
            sum += data[i] as u64 + data[i + 1] as u64 + data[i + 2] as u64;
            samples += 1;
            pixel += step;
        }
        sum
    }

    fn run_capture(shmem: Arc<SharedMemory>) {
        let mut c = None;
        let mut last_current_display = usize::MAX;
        let mut last_timeout_ms: i32 = 33;
        let mut spf = Duration::from_millis(last_timeout_ms as _);
        let mut first_frame_captured = false;
        let mut dxgi_failed_times = 0;
        let mut display_width = 0;
        let mut display_height = 0;
        loop {
            if EXIT.lock().unwrap().clone() {
                break;
            }
            unsafe {
                let para_ptr = shmem.as_ptr().add(ADDR_CAPTURER_PARA);
                let para = para_ptr as *const CapturerPara;
                let recreate = (*para).recreate;
                let current_display = (*para).current_display;
                let timeout_ms = (*para).timeout_ms;
                if c.is_none() {
                    let (prelogin, locked, desktop_changed, logon_ui) = capture_desktop_state();
                    let Ok(mut displays) = display_service::try_get_displays() else {
                        log::error!("Failed to get displays");
                        *EXIT.lock().unwrap() = true;
                        return;
                    };
                    if displays.len() <= current_display {
                        log::error!("Invalid display index:{}", current_display);
                        *EXIT.lock().unwrap() = true;
                        return;
                    }
                    let display = displays.remove(current_display);
                    display_width = display.width();
                    display_height = display.height();
                    match Capturer::new(display) {
                        Ok(mut v) => {
                            let force_gdi = prelogin || locked || desktop_changed || logon_ui;
                            let mut forced_gdi = false;
                            if force_gdi || dxgi_failed_times > MAX_DXGI_FAIL_TIME {
                                dxgi_failed_times = 0;
                                forced_gdi = v.set_gdi();
                            }
                            log::info!(
                                "portable service capture created: display={}, size={}x{}, prelogin={}, locked={}, desktop_changed={}, logon_ui={}, force_gdi={}, forced_gdi={}, backend={}, is_gdi={}",
                                current_display,
                                display_width,
                                display_height,
                                prelogin,
                                locked,
                                desktop_changed,
                                logon_ui,
                                force_gdi,
                                forced_gdi,
                                v.capture_backend(),
                                v.is_gdi()
                            );
                            c = {
                                last_current_display = current_display;
                                first_frame_captured = false;
                                utils::set_para(
                                    &shmem,
                                    CapturerPara {
                                        recreate: false,
                                        current_display: (*para).current_display,
                                        timeout_ms: (*para).timeout_ms,
                                    },
                                );
                                Some(v)
                            }
                        }
                        Err(e) => {
                            log::error!("Failed to create gdi capturer: {:?}", e);
                            std::thread::sleep(std::time::Duration::from_secs(1));
                            continue;
                        }
                    }
                } else {
                    if recreate || current_display != last_current_display {
                        log::info!(
                            "create capturer, display: {} -> {}",
                            last_current_display,
                            current_display,
                        );
                        c = None;
                        continue;
                    }
                    if timeout_ms != last_timeout_ms
                        && timeout_ms >= 1000 / video_qos::MAX_FPS as i32
                        && timeout_ms <= 1000 / video_qos::MIN_FPS as i32
                    {
                        last_timeout_ms = timeout_ms;
                        spf = Duration::from_millis(timeout_ms as _);
                    }
                }
                if first_frame_captured {
                    if !utils::counter_equal(shmem.as_ptr().add(ADDR_CAPTURE_FRAME_COUNTER)) {
                        std::thread::sleep(std::time::Duration::from_millis(1));
                        continue;
                    }
                }
                let capture_backend = c.as_ref().map(|f| f.capture_backend()).unwrap_or("none");
                let capture_is_gdi = c.as_ref().map(|f| f.is_gdi()).unwrap_or(false);
                match c.as_mut().map(|f| f.frame(spf)) {
                    Some(Ok(f)) => match f {
                        Frame::PixelBuffer(f) => {
                            let frame_capacity = shmem.len().saturating_sub(ADDR_CAPTURE_FRAME);
                            if f.data().len() > frame_capacity {
                                log::error!(
                                    "Portable service capture frame exceeds shared memory capacity: frame_len={}, capacity={}, shmem_len={}",
                                    f.data().len(),
                                    frame_capacity,
                                    shmem.len()
                                );
                                *EXIT.lock().unwrap() = true;
                                return;
                            }
                            utils::set_frame_info(
                                &shmem,
                                FrameInfo {
                                    length: f.data().len(),
                                    width: display_width,
                                    height: display_height,
                                },
                            );
                            shmem.write(ADDR_CAPTURE_FRAME, f.data());
                            shmem.write(ADDR_CAPTURE_WOULDBLOCK, &utils::i32_to_vec(TRUE));
                            utils::increase_counter(shmem.as_ptr().add(ADDR_CAPTURE_FRAME_COUNTER));
                            if !first_frame_captured {
                                log::info!(
                                    "portable service capture first frame: backend={}, is_gdi={}, frame_len={}, size={}x{}, sampled_bgr_sum={}",
                                    capture_backend,
                                    capture_is_gdi,
                                    f.data().len(),
                                    display_width,
                                    display_height,
                                    sampled_bgr_sum(f.data())
                                );
                            }
                            first_frame_captured = true;
                            dxgi_failed_times = 0;
                        }
                        Frame::Texture(_) => {
                            // should not happen
                        }
                    },
                    Some(Err(e)) => {
                        if crate::platform::windows::desktop_changed() {
                            let changed = crate::platform::try_change_desktop();
                            log::warn!(
                                "portable service capture desktop changed after frame error; try_change_desktop={}, err={:?}",
                                changed,
                                e
                            );
                            c = None;
                            std::thread::sleep(spf);
                            continue;
                        }
                        if e.kind() != std::io::ErrorKind::WouldBlock {
                            // DXGI_ERROR_INVALID_CALL after each success on Microsoft GPU driver
                            // log::error!("capture frame failed: {:?}", e);
                            if c.as_ref().map(|c| c.is_gdi()) == Some(false) {
                                // nog gdi
                                dxgi_failed_times += 1;
                            }
                            if dxgi_failed_times > MAX_DXGI_FAIL_TIME {
                                c = None;
                                shmem.write(ADDR_CAPTURE_WOULDBLOCK, &utils::i32_to_vec(FALSE));
                                std::thread::sleep(spf);
                            }
                        } else {
                            shmem.write(ADDR_CAPTURE_WOULDBLOCK, &utils::i32_to_vec(TRUE));
                        }
                    }
                    _ => {
                        println!("unreachable!");
                    }
                }
            }
        }
    }

    #[tokio::main(flavor = "current_thread")]
    async fn run_ipc_client(ipc_token: String) {
        use DataPortableService::*;

        let postfix = IPC_SUFFIX;

        match ipc::connect(1000, postfix).await {
            Ok(mut stream) => {
                if let Err(err) =
                    ipc::portable_service_ipc_handshake_as_client(&mut stream, &ipc_token).await
                {
                    log::error!("portable service ipc handshake failed: {}", err);
                    *EXIT.lock().unwrap() = true;
                    return;
                }
                let mut timer =
                    crate::rustdesk_interval(tokio::time::interval(Duration::from_secs(1)));
                let mut nack = 0;
                loop {
                    if *EXIT.lock().unwrap() {
                        log::info!("Portable service EXIT signaled, closing ipc client loop");
                        stream
                            .send(&Data::DataPortableService(WillClose))
                            .await
                            .ok();
                        break;
                    }

                    tokio::select! {
                        res = stream.next() => {
                            match res {
                                Err(err) => {
                                    log::error!(
                                        "ipc{} connection closed: {}",
                                        postfix,
                                        err
                                    );
                                    break;
                                }
                                Ok(Some(Data::DataPortableService(data))) => match data {
                                    Ping => {
                                        allow_err!(
                                            stream
                                                .send(&Data::DataPortableService(Pong))
                                                .await
                                        );
                                    }
                                    Pong => {
                                        nack = 0;
                                    }
                                    ConnCount(Some(n)) => {
                                        if n == 0 {
                                            log::info!("Connection count equals 0, exit");
                                            stream.send(&Data::DataPortableService(WillClose)).await.ok();
                                            break;
                                        }
                                    }
                                    Mouse((v, conn, username, argb, simulate, show_cursor)) => {
                                        if let Ok(evt) = MouseEvent::parse_from_bytes(&v) {
                                            crate::input_service::handle_mouse_(&evt, conn, username, argb, simulate, show_cursor);
                                        }
                                    }
                                    Pointer((v, conn)) => {
                                        if let Ok(evt) = PointerDeviceEvent::parse_from_bytes(&v) {
                                            crate::input_service::handle_pointer_(&evt, conn);
                                        }
                                    }
                                    Key(v) => {
                                        if let Ok(evt) = KeyEvent::parse_from_bytes(&v) {
                                            crate::input_service::handle_key_(&evt);
                                        }
                                    }
                                    _ => {}
                                },
                                _ => {}
                            }
                        }
                        _ = timer.tick() => {
                            nack+=1;
                            if nack > MAX_NACK {
                                log::info!("max ping nack, exit");
                                break;
                            }
                            stream.send(&Data::DataPortableService(Ping)).await.ok();
                            stream.send(&Data::DataPortableService(ConnCount(None))).await.ok();
                        }
                    }
                }
            }
            Err(e) => {
                log::error!("Failed to connect portable service ipc: {:?}", e);
            }
        }

        *EXIT.lock().unwrap() = true;
    }
}

// functions called in main process.
pub mod client {
    use super::*;
    use crate::display_service;
    use hbb_common::{anyhow::Context, message_proto::PointerDeviceEvent};
    use scrap::PixelBuffer;

    lazy_static::lazy_static! {
        static ref LIFECYCLE: Arc<Mutex<PortableServiceLifecycle>> = Default::default();
        static ref NEXT_LIFECYCLE_GENERATION: AtomicU64 = AtomicU64::new(0);
        static ref IPC_RUNTIME_GENERATION: AtomicU64 = AtomicU64::new(0);
        static ref SECURE_CAPTURE_GENERATION: AtomicU64 = AtomicU64::new(0);
        static ref SECURE_DESKTOP_HELPER_GENERATION: AtomicU64 = AtomicU64::new(0);
        static ref FIRST_FRAME_GENERATION: AtomicU64 = AtomicU64::new(0);
        static ref SECURE_CAPTURE_RECOVERY_FAILURES: AtomicU64 = AtomicU64::new(0);
        static ref LAST_SECURE_CAPTURE_RECOVERY_FAILURE: Mutex<Option<std::time::Instant>> =
            Default::default();
        static ref SHMEM: Arc<Mutex<Option<SharedMemory>>> = Default::default();
        static ref SHMEM_RUNTIME_NAME: Arc<Mutex<Option<String>>> = Default::default();
        static ref IPC_RUNTIME_TOKEN: Arc<Mutex<Option<String>>> = Default::default();
        static ref SENDER : Mutex<mpsc::UnboundedSender<PortableServiceCommand>> = Mutex::new(client::start_ipc_server());
        static ref QUICK_SUPPORT: Arc<Mutex<bool>> = Default::default();
        static ref INPUT_VIA_HELPER: AtomicBool = AtomicBool::new(false);
    }

    pub enum StartPara {
        Direct,
        ElevatedDirect,
        SecureDesktop,
        Logon(String, String),
    }

    #[derive(Debug)]
    enum PortableServiceCommand {
        Send(Data),
        ShutdownGeneration(u64),
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum LifecycleState {
        Stopped,
        Starting,
        Ready,
    }

    impl Default for LifecycleState {
        fn default() -> Self {
            Self::Stopped
        }
    }

    #[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
    struct PortableServiceLifecycle {
        state: LifecycleState,
        generation: u64,
    }

    fn mark_generation_ready(generation: u64) -> bool {
        let mut lifecycle = LIFECYCLE.lock().unwrap();
        if generation == 0
            || lifecycle.generation != generation
            || lifecycle.state != LifecycleState::Starting
        {
            return false;
        }
        lifecycle.state = LifecycleState::Ready;
        true
    }

    fn clear_generation_if_current(generation: u64, reason: &str) -> bool {
        let mut lifecycle = LIFECYCLE.lock().unwrap();
        if generation == 0 || lifecycle.generation != generation {
            log::debug!(
                "Ignore stale portable service state clear: generation={}, current_generation={}, reason={}",
                generation,
                lifecycle.generation,
                reason
            );
            return false;
        }
        lifecycle.state = LifecycleState::Stopped;
        drop(lifecycle);
        let secure_capture_generation = SECURE_CAPTURE_GENERATION
            .compare_exchange(generation, 0, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok();
        let secure_owner_generation = SECURE_DESKTOP_HELPER_GENERATION
            .compare_exchange(generation, 0, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok();
        if secure_capture_generation || secure_owner_generation {
            let _ = FIRST_FRAME_GENERATION.compare_exchange(
                generation,
                0,
                Ordering::SeqCst,
                Ordering::SeqCst,
            );
        }
        INPUT_VIA_HELPER.store(false, Ordering::SeqCst);
        log::info!(
            "Portable service generation stopped: generation={}, reason={}",
            generation,
            reason
        );
        true
    }

    fn record_secure_capture_recovery_failure(reason: &str, generation: u64) -> u64 {
        let failures = SECURE_CAPTURE_RECOVERY_FAILURES.fetch_add(1, Ordering::SeqCst) + 1;
        *LAST_SECURE_CAPTURE_RECOVERY_FAILURE.lock().unwrap() = Some(std::time::Instant::now());
        log::warn!(
            "Portable secure capture recovery failure: generation={}, failures={}/{}, reason={}",
            generation,
            failures,
            MAX_SECURE_CAPTURE_RECOVERY_FAILURES,
            reason
        );
        failures
    }

    fn first_frame_timed_out(
        first_frame_received: bool,
        elapsed: Duration,
        timeout: Duration,
    ) -> bool {
        !first_frame_received && elapsed >= timeout
    }

    fn recovery_allowed(failures: u64, backoff_elapsed: bool) -> bool {
        failures < MAX_SECURE_CAPTURE_RECOVERY_FAILURES || backoff_elapsed
    }

    fn has_running_portable_service_process() -> bool {
        let app_exe = format!("{}.exe", crate::get_app_name().to_lowercase());
        !crate::platform::get_pids_of_process_with_first_arg(&app_exe, "--portable-service")
            .is_empty()
    }

    #[inline]
    fn next_portable_service_shmem_name() -> String {
        format!(
            "{}_{}_{:08x}",
            crate::portable_service::SHMEM_NAME,
            std::process::id(),
            hbb_common::rand::random::<u32>()
        )
    }

    #[inline]
    fn set_runtime_ipc_token(token: String) {
        *IPC_RUNTIME_TOKEN.lock().unwrap() = Some(token);
    }

    fn start_para_routes_input_via_helper(para: &StartPara) -> bool {
        matches!(
            para,
            StartPara::ElevatedDirect | StartPara::SecureDesktop | StartPara::Logon(_, _)
        )
    }

    fn should_use_helper_capture_for_desktop_state(
        portable_service_running: bool,
        prelogin: bool,
        locked: bool,
        desktop_changed: bool,
        logon_ui: bool,
    ) -> bool {
        portable_service_running && (prelogin || locked || desktop_changed || logon_ui)
    }

    pub(crate) fn start_para_for_quick_support_process(elevated: bool) -> StartPara {
        if elevated {
            StartPara::ElevatedDirect
        } else {
            StartPara::Direct
        }
    }

    fn routes_input_via_helper() -> bool {
        running() && INPUT_VIA_HELPER.load(Ordering::SeqCst)
    }

    fn start_direct_portable_service_process(portable_service_arg: &str) -> ResultType<()> {
        match crate::platform::run_background(
            &std::env::current_exe()?.to_string_lossy().to_string(),
            portable_service_arg,
        ) {
            Ok(true) => Ok(()),
            Ok(false) => bail!("Failed to run portable service process"),
            Err(e) => bail!("Failed to run portable service process: {}", e),
        }
    }

    #[cfg(windows)]
    fn portable_service_process_arg(shmem_arg: &str) -> String {
        format!("--portable-service {}", shmem_arg)
    }

    #[cfg(windows)]
    fn portable_service_system_process_arg(shmem_arg: &str) -> String {
        format!(
            "--run-as-system {}",
            portable_service_process_arg(shmem_arg)
        )
    }

    #[cfg(windows)]
    fn start_elevated_portable_service_process(shmem_name: &str) -> ResultType<()> {
        let shmem_arg = crate::portable_service::portable_service_shmem_arg(shmem_name);
        if crate::platform::is_root() {
            log::info!("Start portable service directly from SYSTEM process");
            let portable_service_arg = portable_service_process_arg(&shmem_arg);
            return start_direct_portable_service_process(&portable_service_arg);
        }

        if crate::platform::is_elevated(None).unwrap_or(false) {
            log::info!("Start portable service as SYSTEM from elevated process");
            let portable_service_arg = portable_service_system_process_arg(&shmem_arg);
            if let Err(err) = crate::platform::run_as_system(&portable_service_arg) {
                log::warn!(
                    "Failed to start portable service as SYSTEM from elevated process: {}. Falling back to elevated user process",
                    err
                );
                let portable_service_arg = portable_service_process_arg(&shmem_arg);
                return start_direct_portable_service_process(&portable_service_arg);
            }
            return Ok(());
        }

        log::info!("Start portable service through UAC elevation bootstrap");
        crate::platform::elevate(&format!("--elevate {}", shmem_arg))
            .and_then(|started| {
                if started {
                    Ok(())
                } else {
                    bail!("Failed to start elevated portable service process")
                }
            })
            .map_err(|err| anyhow!("Failed to start elevated portable service process: {}", err))
    }

    #[inline]
    fn schedule_remove_runtime_shmem_flink_retry(name: String) {
        std::thread::spawn(move || {
            const MAX_RETRY: usize = 20;
            const RETRY_INTERVAL: Duration = Duration::from_millis(200);
            for _ in 0..MAX_RETRY {
                std::thread::sleep(RETRY_INTERVAL);
                if remove_shared_memory_flink_once(&name, false, "Client cleanup") {
                    return;
                }
            }
            log::warn!(
                "Failed to remove portable service shared-memory flink artifact '{}' after retry",
                name
            );
        });
    }

    #[inline]
    fn clear_runtime_shmem_state() {
        let mut runtime_token = IPC_RUNTIME_TOKEN.lock().unwrap();
        let mut shmem_lock = SHMEM.lock().unwrap();
        if let Some(shmem) = shmem_lock.as_mut() {
            clear_ipc_token_in_shmem(shmem);
        }
        *shmem_lock = None;
        let runtime_name = SHMEM_RUNTIME_NAME.lock().unwrap().take();
        *runtime_token = None;
        IPC_RUNTIME_GENERATION.store(0, Ordering::SeqCst);
        drop(runtime_token);
        drop(shmem_lock);
        if let Some(name) = runtime_name.as_deref() {
            if !remove_shared_memory_flink_once(name, true, "Client cleanup") {
                schedule_remove_runtime_shmem_flink_retry(name.to_owned());
            }
        }
    }

    #[inline]
    fn consume_runtime_ipc_token_if_match(candidate: &str) -> (bool, Option<String>, Option<u64>) {
        let mut token = IPC_RUNTIME_TOKEN.lock().unwrap();
        if !token
            .as_deref()
            .is_some_and(|expected| ipc::constant_time_ipc_token_eq(expected, candidate))
        {
            return (false, None, None);
        }
        let mut shmem_lock = SHMEM.lock().unwrap();
        let matched_shmem_name = SHMEM_RUNTIME_NAME.lock().unwrap().clone();
        let generation = IPC_RUNTIME_GENERATION.load(Ordering::SeqCst);
        *token = None;
        if let Some(shmem) = shmem_lock.as_mut() {
            clear_ipc_token_in_shmem(shmem);
        }
        (
            true,
            matched_shmem_name,
            (generation != 0).then_some(generation),
        )
    }

    #[inline]
    fn restore_runtime_ipc_token_after_failed_handshake(
        token: &str,
        expected_shmem_name: Option<&str>,
    ) {
        let mut runtime_token = IPC_RUNTIME_TOKEN.lock().unwrap();
        if let Some(current) = runtime_token.as_deref() {
            if current != token {
                log::debug!(
                    "Skip restoring portable service ipc token after handshake failure: runtime token has changed to a newer value"
                );
                return;
            }
        }
        let mut shmem_lock = SHMEM.lock().unwrap();
        let current_shmem_name = SHMEM_RUNTIME_NAME.lock().unwrap().clone();
        if current_shmem_name.as_deref() != expected_shmem_name {
            if runtime_token.as_deref() == Some(token) {
                *runtime_token = None;
            }
            log::debug!(
                "Skip restoring portable service ipc token after handshake failure: shared-memory instance has changed"
            );
            return;
        }
        let shmem_write_error = if let Some(shmem) = shmem_lock.as_mut() {
            write_ipc_token_to_shmem(shmem, token)
                .err()
                .map(|err| err.to_string())
        } else {
            Some("shared memory unavailable".to_owned())
        };
        if let Some(err) = shmem_write_error {
            if runtime_token.as_deref() == Some(token) {
                *runtime_token = None;
            }
            log::warn!(
                "Failed to restore portable service ipc token after handshake failure: {}",
                err
            );
            return;
        }
        *runtime_token = Some(token.to_owned());
    }

    #[inline]
    fn schedule_starting_timeout_reset(launch_token: u64) {
        std::thread::spawn(move || {
            std::thread::sleep(PORTABLE_SERVICE_STARTUP_TIMEOUT);
            let should_reset = {
                let mut lifecycle = LIFECYCLE.lock().unwrap();
                if lifecycle.generation == launch_token
                    && lifecycle.state == LifecycleState::Starting
                {
                    lifecycle.state = LifecycleState::Stopped;
                    true
                } else {
                    false
                }
            };
            if should_reset {
                let secure_capture_generation =
                    SECURE_CAPTURE_GENERATION.load(Ordering::SeqCst) == launch_token;
                if secure_capture_generation {
                    let failures = record_secure_capture_recovery_failure(
                        "startup timeout before authenticated IPC readiness",
                        launch_token,
                    );
                    log::warn!(
                        "Portable secure capture helper startup timeout before IPC ready: generation={}, failures={}/{}",
                        launch_token,
                        failures,
                        MAX_SECURE_CAPTURE_RECOVERY_FAILURES
                    );
                } else {
                    log::warn!(
                        "Portable service startup timeout before IPC ready: generation={}",
                        launch_token
                    );
                }
                if secure_capture_generation {
                    let _ = SECURE_CAPTURE_GENERATION.compare_exchange(
                        launch_token,
                        0,
                        Ordering::SeqCst,
                        Ordering::SeqCst,
                    );
                }
                let _ = SECURE_DESKTOP_HELPER_GENERATION.compare_exchange(
                    launch_token,
                    0,
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                );
                INPUT_VIA_HELPER.store(false, Ordering::SeqCst);
            }
        });
    }

    // Launch flow summary:
    // 1) Prepare/reset runtime shared memory + IPC token.
    // 2) Start helper process (direct or logon) with shmem argument.
    // 3) Keep STARTING=true until IPC ping/pong marks RUNNING, or timeout watchdog resets it.
    pub(crate) fn start_portable_service(para: StartPara) -> ResultType<()> {
        log::info!("start portable service");
        let input_via_helper = start_para_routes_input_via_helper(&para);
        let secure_capture_launch = matches!(&para, StartPara::SecureDesktop);
        let launch_token = {
            let mut lifecycle = LIFECYCLE.lock().unwrap();
            if lifecycle.state == LifecycleState::Starting
                && !has_running_portable_service_process()
            {
                log::warn!(
                    "Detected stale portable service STARTING state without running process, reset it"
                );
                lifecycle.state = LifecycleState::Stopped;
            }
            if lifecycle.state != LifecycleState::Stopped {
                bail!("already running");
            }
            let generation = NEXT_LIFECYCLE_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
            *lifecycle = PortableServiceLifecycle {
                state: LifecycleState::Starting,
                generation,
            };
            generation
        };
        let start_result = (|| -> ResultType<()> {
            clear_runtime_shmem_state();
            let mut shmem_lock = SHMEM.lock().unwrap();
            let displays = scrap::Display::all()?;
            if displays.is_empty() {
                bail!("no display available!");
            }
            let mut max_pixel = 0;
            let align = 64;
            for d in displays {
                let resolutions = crate::platform::resolutions(&d.name());
                for r in resolutions {
                    let pixel =
                        utils::align(r.width as _, align) * utils::align(r.height as _, align);
                    if max_pixel < pixel {
                        max_pixel = pixel;
                    }
                }
            }
            let shmem_size =
                utils::align(ADDR_CAPTURE_FRAME + max_pixel * 4, align).max(MIN_RUNTIME_SHMEM_LEN);
            let shmem_name = next_portable_service_shmem_name();
            if !is_valid_portable_service_shmem_name(&shmem_name) {
                bail!("Generated invalid portable service shared memory name");
            }
            let ipc_token = ipc::generate_one_time_ipc_token()?;
            // os error 112, no enough space
            *shmem_lock = Some(crate::portable_service::SharedMemory::create(
                &shmem_name,
                shmem_size,
            )?);
            *SHMEM_RUNTIME_NAME.lock().unwrap() = Some(shmem_name);
            IPC_RUNTIME_GENERATION.store(launch_token, Ordering::SeqCst);
            SECURE_CAPTURE_GENERATION.store(
                if secure_capture_launch {
                    launch_token
                } else {
                    0
                },
                Ordering::SeqCst,
            );
            SECURE_DESKTOP_HELPER_GENERATION.store(
                if secure_capture_launch {
                    launch_token
                } else {
                    0
                },
                Ordering::SeqCst,
            );
            FIRST_FRAME_GENERATION.store(0, Ordering::SeqCst);
            shutdown_hooks::add_shutdown_hook(drop_portable_service_shared_memory);
            let shmem_name = SHMEM_RUNTIME_NAME
                .lock()
                .unwrap()
                .clone()
                .ok_or_else(|| anyhow!("portable service shared memory name is unavailable"))?;
            let init_token_result = if let Some(shmem) = shmem_lock.as_mut() {
                unsafe {
                    libc::memset(shmem.as_ptr() as _, 0, shmem.len() as _);
                }
                write_ipc_token_to_shmem(shmem, &ipc_token)
            } else {
                Ok(())
            };
            if let Err(e) = init_token_result {
                drop(shmem_lock);
                clear_runtime_shmem_state();
                bail!(
                    "Failed to initialize portable service ipc token in shared memory: {}",
                    e
                );
            };
            drop(shmem_lock);
            set_runtime_ipc_token(ipc_token.clone());
            let shmem_arg = crate::portable_service::portable_service_shmem_arg(&shmem_name);
            let portable_service_arg = portable_service_process_arg(&shmem_arg);
            {
                let _sender = SENDER.lock().unwrap();
            }
            match para {
                StartPara::Direct => {
                    if let Err(e) = start_direct_portable_service_process(&portable_service_arg) {
                        clear_runtime_shmem_state();
                        bail!("{}", e);
                    }
                }
                StartPara::ElevatedDirect | StartPara::SecureDesktop => {
                    if let Err(e) = start_elevated_portable_service_process(&shmem_name) {
                        clear_runtime_shmem_state();
                        bail!("{}", e);
                    }
                }
                StartPara::Logon(username, password) => {
                    #[allow(unused_mut)]
                    let mut exe = std::env::current_exe()?.to_string_lossy().to_string();
                    #[cfg(feature = "flutter")]
                    {
                        if let Some(dir) = Path::new(&exe).parent() {
                            if let Err(err) = set_path_permission(
                                Path::new(dir),
                                FILE_GENERIC_READ.0 | FILE_GENERIC_EXECUTE.0,
                            ) {
                                clear_runtime_shmem_state();
                                bail!("Failed to set permission of {:?}: {}", dir, err);
                            }
                        }
                    }
                    #[cfg(not(feature = "flutter"))]
                    if let Some((dir, dst)) =
                        crate::platform::windows::portable_service_logon_helper_paths()
                    {
                        let cleanup_helper_artifacts = || {
                            if Path::new(&exe) != dst {
                                std::fs::remove_file(&dst).ok();
                            }
                            std::fs::remove_dir(&dir).ok();
                        };
                        let mut use_logon_helper_exe = false;
                        if let Err(err) = std::fs::create_dir_all(&dir) {
                            log::warn!(
                                "Failed to create portable service logon helper dir {:?}: {}",
                                dir,
                                err
                            );
                        } else if let Err(err) = std::fs::copy(&exe, &dst) {
                            log::warn!(
                                "Failed to copy portable service logon helper binary from '{}' to {:?}: {}",
                                exe,
                                dst,
                                err
                            );
                            cleanup_helper_artifacts();
                        } else if !dst.exists() {
                            log::warn!(
                                "Portable service logon helper binary missing after copy: {:?}",
                                dst
                            );
                            cleanup_helper_artifacts();
                        } else if let Err(err) =
                            set_path_permission(&dir, FILE_GENERIC_READ.0 | FILE_GENERIC_EXECUTE.0)
                        {
                            log::warn!(
                                "Failed to set portable service logon helper path permission for {:?}: {}",
                                dir,
                                err
                            );
                            cleanup_helper_artifacts();
                        } else {
                            use_logon_helper_exe = true;
                        }
                        if use_logon_helper_exe {
                            exe = dst.to_string_lossy().to_string();
                        }
                    }
                    if let Err(e) = crate::platform::windows::create_process_with_logon(
                        username.as_str(),
                        password.as_str(),
                        &exe,
                        &portable_service_arg,
                    ) {
                        clear_runtime_shmem_state();
                        bail!("Failed to run portable service process: {}", e);
                    }
                }
            }
            log::info!(
                "Portable service process spawned: generation={}, shmem_name={}, input_via_helper={}",
                launch_token,
                shmem_name,
                input_via_helper
            );
            schedule_starting_timeout_reset(launch_token);
            INPUT_VIA_HELPER.store(input_via_helper, Ordering::SeqCst);
            Ok(())
        })();
        if start_result.is_err() {
            clear_generation_if_current(launch_token, "process launch failed");
        }
        start_result
    }

    pub extern "C" fn drop_portable_service_shared_memory() {
        // https://stackoverflow.com/questions/35980148/why-does-an-atexit-handler-panic-when-it-accesses-stdout
        // Please make sure there is no print in the call stack
        clear_runtime_shmem_state();
    }

    pub fn set_quick_support(v: bool) {
        *QUICK_SUPPORT.lock().unwrap() = v;
    }

    pub fn quick_support() -> bool {
        *QUICK_SUPPORT.lock().unwrap()
    }

    pub fn lifecycle() -> LifecycleState {
        LIFECYCLE.lock().unwrap().state
    }

    fn ready_generation() -> Option<u64> {
        let lifecycle = LIFECYCLE.lock().unwrap();
        (lifecycle.state == LifecycleState::Ready).then_some(lifecycle.generation)
    }

    pub fn ready_for_capture() -> bool {
        ready_generation().is_some()
    }

    pub fn secure_capture_recovery_allowed() -> bool {
        let failures = SECURE_CAPTURE_RECOVERY_FAILURES.load(Ordering::SeqCst);
        let backoff_elapsed = LAST_SECURE_CAPTURE_RECOVERY_FAILURE
            .lock()
            .unwrap()
            .is_some_and(|last| last.elapsed() >= SECURE_CAPTURE_RECOVERY_BACKOFF);
        let allowed = recovery_allowed(failures, backoff_elapsed);
        if failures >= MAX_SECURE_CAPTURE_RECOVERY_FAILURES && backoff_elapsed {
            SECURE_CAPTURE_RECOVERY_FAILURES
                .store(MAX_SECURE_CAPTURE_RECOVERY_FAILURES - 1, Ordering::SeqCst);
            log::warn!(
                "Portable secure capture recovery backoff elapsed; allowing one retry after {}s",
                SECURE_CAPTURE_RECOVERY_BACKOFF.as_secs()
            );
        }
        allowed
    }

    pub fn reset_secure_capture_recovery_failures(reason: &str) {
        let previous = SECURE_CAPTURE_RECOVERY_FAILURES.swap(0, Ordering::SeqCst);
        *LAST_SECURE_CAPTURE_RECOVERY_FAILURE.lock().unwrap() = None;
        SECURE_CAPTURE_GENERATION.store(0, Ordering::SeqCst);
        if previous > 0 {
            log::info!(
                "Portable secure capture recovery counter reset: previous_failures={}, reason={}",
                previous,
                reason
            );
        }
    }

    fn mark_secure_capture_first_frame(generation: u64, elapsed: Duration) {
        if ready_generation() != Some(generation) {
            return;
        }
        FIRST_FRAME_GENERATION.store(generation, Ordering::SeqCst);
        reset_secure_capture_recovery_failures("first frame received");
        log::info!(
            "Portable secure capture first frame consumed: generation={}, elapsed_ms={}",
            generation,
            elapsed.as_millis()
        );
    }

    fn send_generation_shutdown(generation: u64, reason: &str) {
        if let Err(err) = SENDER
            .lock()
            .unwrap()
            .send(PortableServiceCommand::ShutdownGeneration(generation))
        {
            log::warn!(
                "Failed to request portable service generation shutdown: generation={}, reason={}, err={}",
                generation,
                reason,
                err
            );
        }
    }

    pub fn stop_secure_capture_helper(reason: &str) -> bool {
        let Some(generation) = ready_generation() else {
            return false;
        };
        let owner_generation = SECURE_DESKTOP_HELPER_GENERATION.load(Ordering::SeqCst);
        if generation == 0 || owner_generation != generation {
            log::debug!(
                "Keep non-owned portable service generation running: generation={}, secure_owner_generation={}, reason={}",
                generation,
                owner_generation,
                reason
            );
            return false;
        }
        if !clear_generation_if_current(generation, reason) {
            return false;
        }
        send_generation_shutdown(generation, reason);
        log::info!(
            "Portable secure capture helper stop requested: generation={}, reason={}",
            generation,
            reason
        );
        true
    }

    fn request_secure_capture_restart(generation: u64, reason: &str) -> bool {
        if !clear_generation_if_current(generation, reason) {
            return false;
        }
        let failures = record_secure_capture_recovery_failure(reason, generation);
        send_generation_shutdown(generation, reason);
        if failures >= MAX_SECURE_CAPTURE_RECOVERY_FAILURES {
            log::error!(
                "Portable secure capture fast recovery exhausted: failures={}, retry_backoff_s={}",
                failures,
                SECURE_CAPTURE_RECOVERY_BACKOFF.as_secs()
            );
        }
        true
    }

    pub struct CapturerPortable {
        width: usize,
        height: usize,
        generation: u64,
        started_at: std::time::Instant,
        first_frame_received: bool,
    }

    impl CapturerPortable {
        pub fn new(current_display: usize) -> ResultType<Self>
        where
            Self: Sized,
        {
            let generation = ready_generation()
                .ok_or_else(|| anyhow!("portable service IPC is not ready for capture"))?;
            let mut option = SHMEM.lock().unwrap();
            let shmem = option
                .as_mut()
                .ok_or_else(|| anyhow!("portable service shared memory is unavailable"))?;
            unsafe {
                libc::memset(
                    shmem.as_ptr().add(ADDR_CURSOR_PARA) as _,
                    0,
                    shmem.len().saturating_sub(ADDR_CURSOR_PARA) as _,
                );
            }
            utils::set_para(
                shmem,
                CapturerPara {
                    recreate: true,
                    current_display,
                    timeout_ms: 33,
                },
            );
            shmem.write(ADDR_CAPTURE_WOULDBLOCK, &utils::i32_to_vec(TRUE));
            let (mut width, mut height) = (0, 0);
            if let Ok(displays) = display_service::try_get_displays() {
                if let Some(display) = displays.get(current_display) {
                    width = display.width();
                    height = display.height();
                }
            }
            if width == 0 || height == 0 {
                bail!(
                    "portable service display geometry is invalid: display={}, size={}x{}",
                    current_display,
                    width,
                    height
                );
            }
            log::info!(
                "Portable secure capture shared-memory capturer armed: generation={}, display={}, size={}x{}, first_frame_timeout_ms={}",
                generation,
                current_display,
                width,
                height,
                PORTABLE_SERVICE_FIRST_FRAME_TIMEOUT.as_millis()
            );
            SECURE_CAPTURE_GENERATION.store(generation, Ordering::SeqCst);
            Ok(CapturerPortable {
                width,
                height,
                generation,
                started_at: std::time::Instant::now(),
                first_frame_received: false,
            })
        }
    }

    impl TraitCapturer for CapturerPortable {
        fn frame<'a>(&'a mut self, timeout: Duration) -> std::io::Result<Frame<'a>> {
            if ready_generation() != Some(self.generation) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "portable service generation is no longer ready".to_string(),
                ));
            }
            let mut lock = SHMEM.lock().unwrap();
            let shmem = lock.as_mut().ok_or(std::io::Error::new(
                std::io::ErrorKind::Other,
                "shmem dropped".to_string(),
            ))?;
            unsafe {
                let base = shmem.as_ptr();
                let para_ptr = base.add(ADDR_CAPTURER_PARA);
                let para = para_ptr as *const CapturerPara;
                if timeout.as_millis() != (*para).timeout_ms as _ {
                    utils::set_para(
                        shmem,
                        CapturerPara {
                            recreate: (*para).recreate,
                            current_display: (*para).current_display,
                            timeout_ms: timeout.as_millis() as _,
                        },
                    );
                }
                if utils::counter_ready(base.add(ADDR_CAPTURE_FRAME_COUNTER)) {
                    let frame_info_ptr = shmem.as_ptr().add(ADDR_CAPTURE_FRAME_INFO);
                    let frame_info = frame_info_ptr as *const FrameInfo;
                    let frame_len = (*frame_info).length;
                    if !is_valid_capture_frame_length(shmem.len(), frame_len) {
                        log::error!(
                            "Portable service frame length exceeds shared memory capacity: frame_len={}, shmem_len={}, frame_addr={}",
                            frame_len,
                            shmem.len(),
                            ADDR_CAPTURE_FRAME
                        );
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "invalid portable service frame length".to_string(),
                        ));
                    }
                    if (*frame_info).width != self.width || (*frame_info).height != self.height {
                        log::info!(
                            "skip frame, ({},{}) != ({},{})",
                            (*frame_info).width,
                            (*frame_info).height,
                            self.width,
                            self.height,
                        );
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::WouldBlock,
                            "wouldblock error".to_string(),
                        ));
                    }
                    let frame_ptr = base.add(ADDR_CAPTURE_FRAME);
                    let data = slice::from_raw_parts(frame_ptr, frame_len);
                    if !self.first_frame_received {
                        self.first_frame_received = true;
                        mark_secure_capture_first_frame(self.generation, self.started_at.elapsed());
                    }
                    Ok(Frame::PixelBuffer(PixelBuffer::with_BGRA(
                        data,
                        self.width,
                        self.height,
                    )))
                } else {
                    if first_frame_timed_out(
                        self.first_frame_received,
                        self.started_at.elapsed(),
                        PORTABLE_SERVICE_FIRST_FRAME_TIMEOUT,
                    ) {
                        drop(lock);
                        request_secure_capture_restart(
                            self.generation,
                            "first frame timeout after IPC readiness",
                        );
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            "portable service first frame timeout".to_string(),
                        ));
                    }
                    let ptr = base.add(ADDR_CAPTURE_WOULDBLOCK);
                    let wouldblock = utils::ptr_to_i32(ptr);
                    if wouldblock == TRUE {
                        Err(std::io::Error::new(
                            std::io::ErrorKind::WouldBlock,
                            "wouldblock error".to_string(),
                        ))
                    } else {
                        Err(std::io::Error::new(
                            std::io::ErrorKind::Other,
                            "other error".to_string(),
                        ))
                    }
                }
            }
        }

        // control by itself
        fn is_gdi(&self) -> bool {
            true
        }

        fn capture_backend(&self) -> &'static str {
            "Portable SYSTEM helper capture"
        }

        fn set_gdi(&mut self) -> bool {
            true
        }

        #[cfg(feature = "vram")]
        fn device(&self) -> AdapterDevice {
            AdapterDevice::default()
        }

        #[cfg(feature = "vram")]
        fn set_output_texture(&mut self, _texture: bool) {}
    }

    fn start_ipc_server() -> mpsc::UnboundedSender<PortableServiceCommand> {
        let (tx, rx) = mpsc::unbounded_channel::<PortableServiceCommand>();
        std::thread::spawn(move || start_ipc_server_async(rx));
        tx
    }

    #[tokio::main(flavor = "current_thread")]
    async fn start_ipc_server_async(rx: mpsc::UnboundedReceiver<PortableServiceCommand>) {
        use DataPortableService::*;
        let rx = Arc::new(tokio::sync::Mutex::new(rx));
        let postfix = IPC_SUFFIX;

        match new_listener(postfix).await {
            Ok(mut incoming) => loop {
                {
                    tokio::select! {
                        Some(result) = incoming.next() => {
                            match result {
                                Ok(stream) => {
                                    let mut stream = Connection::new(stream);
                                    if !ipc::authorize_windows_portable_service_ipc_connection(
                                        &stream, postfix,
                                    ) {
                                        continue;
                                    }
                                    let mut consumed_token: Option<String> = None;
                                    let mut consumed_token_shmem_name: Option<String> = None;
                                    let mut consumed_generation: Option<u64> = None;
                                    let handshake_result =
                                        ipc::portable_service_ipc_handshake_as_server(
                                            &mut stream,
                                            |token| {
                                                let (matched, matched_shmem_name, generation) =
                                                    consume_runtime_ipc_token_if_match(token);
                                                if matched {
                                                    consumed_token = Some(token.to_owned());
                                                    consumed_token_shmem_name = matched_shmem_name;
                                                    consumed_generation = generation;
                                                    true
                                                } else {
                                                    false
                                                }
                                            },
                                        )
                                        .await;
                                    if let Err(err) = handshake_result {
                                        if let Some(token) = consumed_token.as_deref() {
                                            restore_runtime_ipc_token_after_failed_handshake(
                                                token,
                                                consumed_token_shmem_name.as_deref(),
                                            );
                                            if let Some(generation) = consumed_generation {
                                                clear_generation_if_current(
                                                    generation,
                                                    "IPC handshake failed",
                                                );
                                            }
                                        }
                                        log::warn!(
                                            "Rejected portable service ipc connection due to token handshake failure: postfix={}, err={}",
                                            postfix,
                                            err
                                        );
                                        continue;
                                    }
                                    let Some(generation) = consumed_generation else {
                                        log::warn!(
                                            "Rejected portable service IPC connection without a launch generation"
                                        );
                                        continue;
                                    };
                                    log::info!(
                                        "Portable service IPC authenticated: generation={}, shmem_name={}",
                                        generation,
                                        consumed_token_shmem_name.as_deref().unwrap_or("unknown")
                                    );
                                    let rx_clone = rx.clone();
                                    tokio::spawn(async move {
                                        let mut stream = stream;
                                        let postfix = postfix.to_owned();
                                        let mut timer = crate::rustdesk_interval(tokio::time::interval(Duration::from_secs(1)));
                                        let mut nack = 0;
                                        let mut rx = rx_clone.lock().await;
                                        loop {
                                            tokio::select! {
                                                res = stream.next() => {
                                                    match res {
                                                        Err(err) => {
                                                            log::info!(
                                                                "ipc{} connection closed: {}",
                                                                postfix,
                                                                err
                                                            );
                                                            break;
                                                        }
                                                        Ok(Some(Data::DataPortableService(data))) => match data {
                                                            Ping => {
                                                                stream.send(&Data::DataPortableService(Pong)).await.ok();
                                                            }
                                                            Pong => {
                                                                nack = 0;
                                                                if mark_generation_ready(generation) {
                                                                    log::info!(
                                                                        "Portable service IPC ready: generation={}",
                                                                        generation
                                                                    );
                                                                }
                                                            },
                                                            ConnCount(None) => {
                                                                if !quick_support() {
                                                                    let remote_count = crate::server::AUTHED_CONNS
                                                                        .lock()
                                                                        .unwrap()
                                                                        .iter()
                                                                        .filter(|c| c.conn_type == crate::server::AuthConnType::Remote)
                                                                        .count();
                                                                    stream.send(&Data::DataPortableService(ConnCount(Some(remote_count)))).await.ok();
                                                                }
                                                            },
                                                            WillClose => {
                                                                log::info!("portable service will close");
                                                                break;
                                                            }
                                                            _=>{}
                                                        }
                                                        _=>{}
                                                    }
                                                }
                                                _ = timer.tick() => {
                                                    nack+=1;
                                                    if nack > MAX_NACK {
                                                        // In fact, this will not happen, ipc will be closed before max nack.
                                                        log::error!("max ipc nack");
                                                        break;
                                                    }
                                                    stream.send(&Data::DataPortableService(Ping)).await.ok();
                                                }
                                                Some(command) = rx.recv() => {
                                                    match command {
                                                        PortableServiceCommand::Send(data) => {
                                                            allow_err!(stream.send(&data).await);
                                                        }
                                                        PortableServiceCommand::ShutdownGeneration(target_generation) => {
                                                            if target_generation == generation {
                                                                log::warn!(
                                                                    "Request portable service generation shutdown: generation={}",
                                                                    generation
                                                                );
                                                                allow_err!(
                                                                    stream
                                                                        .send(&Data::DataPortableService(ConnCount(Some(0))))
                                                                        .await
                                                                );
                                                            } else {
                                                                log::debug!(
                                                                    "Ignore stale portable service shutdown command: target_generation={}, active_generation={}",
                                                                    target_generation,
                                                                    generation
                                                                );
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        let secure_capture_generation =
                                            SECURE_CAPTURE_GENERATION.load(Ordering::SeqCst)
                                                == generation;
                                        let first_frame_received =
                                            FIRST_FRAME_GENERATION.load(Ordering::SeqCst)
                                                == generation;
                                        let cleared = clear_generation_if_current(
                                            generation,
                                            "IPC connection closed",
                                        );
                                        if cleared
                                            && secure_capture_generation
                                            && !first_frame_received
                                        {
                                            record_secure_capture_recovery_failure(
                                                "IPC connection closed before first frame",
                                                generation,
                                            );
                                        }
                                    });
                                }
                                Err(err) => {
                                    log::error!("Couldn't get portable client: {:?}", err);
                                }
                            }
                        }
                    }
                }
            },
            Err(err) => {
                log::error!("Failed to start portable service ipc server: {}", err);
            }
        }
    }

    fn get_cursor_info_(shmem: &mut SharedMemory, pci: PCURSORINFO) -> BOOL {
        unsafe {
            let shmem_addr_para = shmem.as_ptr().add(ADDR_CURSOR_PARA);
            if utils::counter_ready(shmem.as_ptr().add(ADDR_CURSOR_COUNTER)) {
                std::ptr::copy_nonoverlapping(shmem_addr_para, pci as _, size_of::<CURSORINFO>());
                return TRUE;
            }
            FALSE
        }
    }

    fn ipc_send(data: Data) -> ResultType<()> {
        let sender = SENDER.lock().unwrap();
        sender
            .send(PortableServiceCommand::Send(data))
            .map_err(|e| anyhow!("ipc send error:{:?}", e))
    }

    fn handle_mouse_(
        evt: &MouseEvent,
        conn: i32,
        username: String,
        argb: u32,
        simulate: bool,
        show_cursor: bool,
    ) -> ResultType<()> {
        let mut v = vec![];
        evt.write_to_vec(&mut v)?;
        ipc_send(Data::DataPortableService(DataPortableService::Mouse((
            v,
            conn,
            username,
            argb,
            simulate,
            show_cursor,
        ))))
    }

    fn handle_pointer_(evt: &PointerDeviceEvent, conn: i32) -> ResultType<()> {
        let mut v = vec![];
        evt.write_to_vec(&mut v)?;
        ipc_send(Data::DataPortableService(DataPortableService::Pointer((
            v, conn,
        ))))
    }

    fn handle_key_(evt: &KeyEvent) -> ResultType<()> {
        let mut v = vec![];
        evt.write_to_vec(&mut v)?;
        ipc_send(Data::DataPortableService(DataPortableService::Key(v)))
    }

    pub fn create_capturer(
        current_display: usize,
        display: scrap::Display,
        portable_service_running: bool,
    ) -> ResultType<Box<dyn TraitCapturer>> {
        let helper_ready = ready_for_capture();
        if portable_service_running != helper_ready {
            log::info!(
                "portable service status mismatch: requested_running={}, lifecycle={:?}",
                portable_service_running,
                lifecycle()
            );
        }
        let prelogin = crate::platform::windows::is_prelogin();
        let locked = crate::platform::windows::is_locked();
        let desktop_changed = crate::platform::windows::desktop_changed();
        let logon_ui = crate::platform::windows::is_logon_ui_for_capture();
        if should_use_helper_capture_for_desktop_state(
            portable_service_running,
            prelogin,
            locked,
            desktop_changed,
            logon_ui,
        ) {
            log::info!(
                "Portable secure desktop capture: use SYSTEM helper shared-memory capturer, display={}, prelogin={}, locked={}, desktop_changed={}, logon_ui={}",
                current_display,
                prelogin,
                locked,
                desktop_changed,
                logon_ui
            );
            if !helper_ready {
                bail!("portable service IPC is not ready for secure capture");
            }
            return Ok(Box::new(CapturerPortable::new(current_display)?));
        }
        // WARNING: Be extremely careful changing the portable primary-display path.
        // RustAdmin 2.0.1.81 regressed here after upstream IPC changes restored
        // CapturerPortable for the primary display: non-primary monitors worked, but
        // the primary monitor stayed on "Waiting for an Image". Keep the primary
        // display on dxgi|gdi unless a Windows portable-mode smoke test proves a
        // replacement path works for the primary monitor.
        if portable_service_running && display.is_primary() {
            log::warn!(
                "Portable mode primary display: bypass shared memory capturer, use dxgi|gdi"
            );
        }
        log::debug!("Create capturer dxgi|gdi");
        Ok(Box::new(
            Capturer::new(display).with_context(|| "Failed to create capturer")?,
        ))
    }

    pub fn get_cursor_info(pci: PCURSORINFO) -> BOOL {
        if running() {
            let mut option = SHMEM.lock().unwrap();
            option
                .as_mut()
                .map_or(FALSE, |sheme| get_cursor_info_(sheme, pci))
        } else {
            unsafe { winuser::GetCursorInfo(pci) }
        }
    }

    pub fn handle_mouse(
        evt: &MouseEvent,
        conn: i32,
        username: String,
        argb: u32,
        simulate: bool,
        show_cursor: bool,
    ) {
        if routes_input_via_helper() {
            crate::input_service::update_latest_input_cursor_time(conn);
            if let Err(err) =
                handle_mouse_(evt, conn, username.clone(), argb, simulate, show_cursor)
            {
                log::warn!(
                    "portable service mouse IPC failed, falling back to local input: {}",
                    err
                );
                crate::input_service::handle_mouse_(
                    evt,
                    conn,
                    username,
                    argb,
                    simulate,
                    show_cursor,
                );
            }
        } else {
            crate::input_service::handle_mouse_(evt, conn, username, argb, simulate, show_cursor);
        }
    }

    pub fn handle_pointer(evt: &PointerDeviceEvent, conn: i32) {
        if routes_input_via_helper() {
            crate::input_service::update_latest_input_cursor_time(conn);
            if let Err(err) = handle_pointer_(evt, conn) {
                log::warn!(
                    "portable service pointer IPC failed, falling back to local input: {}",
                    err
                );
                crate::input_service::handle_pointer_(evt, conn);
            }
        } else {
            crate::input_service::handle_pointer_(evt, conn);
        }
    }

    pub fn handle_key(evt: &KeyEvent) {
        if routes_input_via_helper() {
            if let Err(err) = handle_key_(evt) {
                log::warn!(
                    "portable service keyboard IPC failed, falling back to local input: {}",
                    err
                );
                crate::input_service::handle_key_(evt);
            }
        } else {
            crate::input_service::handle_key_(evt);
        }
    }

    pub fn running() -> bool {
        lifecycle() == LifecycleState::Ready
    }

    pub fn active() -> bool {
        lifecycle() != LifecycleState::Stopped
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::sync::Mutex;

        static TEST_STATE_LOCK: Mutex<()> = Mutex::new(());

        struct InputRouteStateGuard {
            lifecycle: PortableServiceLifecycle,
            input_via_helper: bool,
            recovery_failures: u64,
            first_frame_generation: u64,
            secure_capture_generation: u64,
            secure_desktop_helper_generation: u64,
            last_recovery_failure: Option<std::time::Instant>,
        }

        impl InputRouteStateGuard {
            fn set(running: bool, input_via_helper: bool) -> Self {
                let guard = Self {
                    lifecycle: *LIFECYCLE.lock().unwrap(),
                    input_via_helper: INPUT_VIA_HELPER.load(Ordering::SeqCst),
                    recovery_failures: SECURE_CAPTURE_RECOVERY_FAILURES.load(Ordering::SeqCst),
                    first_frame_generation: FIRST_FRAME_GENERATION.load(Ordering::SeqCst),
                    secure_capture_generation: SECURE_CAPTURE_GENERATION.load(Ordering::SeqCst),
                    secure_desktop_helper_generation: SECURE_DESKTOP_HELPER_GENERATION
                        .load(Ordering::SeqCst),
                    last_recovery_failure: *LAST_SECURE_CAPTURE_RECOVERY_FAILURE.lock().unwrap(),
                };
                *LIFECYCLE.lock().unwrap() = PortableServiceLifecycle {
                    state: if running {
                        LifecycleState::Ready
                    } else {
                        LifecycleState::Stopped
                    },
                    generation: u64::from(running),
                };
                INPUT_VIA_HELPER.store(input_via_helper, Ordering::SeqCst);
                guard
            }
        }

        impl Drop for InputRouteStateGuard {
            fn drop(&mut self) {
                *LIFECYCLE.lock().unwrap() = self.lifecycle;
                INPUT_VIA_HELPER.store(self.input_via_helper, Ordering::SeqCst);
                SECURE_CAPTURE_RECOVERY_FAILURES.store(self.recovery_failures, Ordering::SeqCst);
                FIRST_FRAME_GENERATION.store(self.first_frame_generation, Ordering::SeqCst);
                SECURE_CAPTURE_GENERATION.store(self.secure_capture_generation, Ordering::SeqCst);
                SECURE_DESKTOP_HELPER_GENERATION
                    .store(self.secure_desktop_helper_generation, Ordering::SeqCst);
                *LAST_SECURE_CAPTURE_RECOVERY_FAILURE.lock().unwrap() = self.last_recovery_failure;
            }
        }

        #[test]
        fn test_lifecycle_rejects_stale_generation_transitions() {
            let _lock = TEST_STATE_LOCK.lock().unwrap();
            let _guard = InputRouteStateGuard::set(false, false);
            *LIFECYCLE.lock().unwrap() = PortableServiceLifecycle {
                state: LifecycleState::Starting,
                generation: 41,
            };

            assert!(!mark_generation_ready(40));
            assert_eq!(lifecycle(), LifecycleState::Starting);
            assert!(mark_generation_ready(41));
            assert_eq!(lifecycle(), LifecycleState::Ready);

            *LIFECYCLE.lock().unwrap() = PortableServiceLifecycle {
                state: LifecycleState::Starting,
                generation: 42,
            };
            assert!(!clear_generation_if_current(41, "stale test disconnect"));
            assert_eq!(lifecycle(), LifecycleState::Starting);
            assert!(mark_generation_ready(42));
            assert_eq!(lifecycle(), LifecycleState::Ready);
        }

        #[test]
        fn test_first_frame_timeout_and_recovery_limit() {
            assert!(!first_frame_timed_out(
                false,
                Duration::from_millis(4999),
                Duration::from_secs(5)
            ));
            assert!(first_frame_timed_out(
                false,
                Duration::from_secs(5),
                Duration::from_secs(5)
            ));
            assert!(!first_frame_timed_out(
                true,
                Duration::from_secs(10),
                Duration::from_secs(5)
            ));
            assert!(recovery_allowed(
                MAX_SECURE_CAPTURE_RECOVERY_FAILURES - 1,
                false
            ));
            assert!(!recovery_allowed(
                MAX_SECURE_CAPTURE_RECOVERY_FAILURES,
                false
            ));
            assert!(recovery_allowed(MAX_SECURE_CAPTURE_RECOVERY_FAILURES, true));
        }

        #[test]
        fn test_first_frame_reset_preserves_secure_helper_owner_generation() {
            let _lock = TEST_STATE_LOCK.lock().unwrap();
            let _guard = InputRouteStateGuard::set(true, true);
            *LIFECYCLE.lock().unwrap() = PortableServiceLifecycle {
                state: LifecycleState::Ready,
                generation: 71,
            };
            SECURE_CAPTURE_GENERATION.store(71, Ordering::SeqCst);
            SECURE_DESKTOP_HELPER_GENERATION.store(71, Ordering::SeqCst);
            FIRST_FRAME_GENERATION.store(71, Ordering::SeqCst);
            SECURE_CAPTURE_RECOVERY_FAILURES.store(2, Ordering::SeqCst);
            *LAST_SECURE_CAPTURE_RECOVERY_FAILURE.lock().unwrap() = Some(std::time::Instant::now());

            reset_secure_capture_recovery_failures("test first frame");

            assert_eq!(SECURE_CAPTURE_GENERATION.load(Ordering::SeqCst), 0);
            assert_eq!(SECURE_DESKTOP_HELPER_GENERATION.load(Ordering::SeqCst), 71);
            assert_eq!(FIRST_FRAME_GENERATION.load(Ordering::SeqCst), 71);
            assert_eq!(SECURE_CAPTURE_RECOVERY_FAILURES.load(Ordering::SeqCst), 0);
            assert!(LAST_SECURE_CAPTURE_RECOVERY_FAILURE
                .lock()
                .unwrap()
                .is_none());
        }

        #[test]
        fn test_generation_stop_clears_only_matching_secure_capture_marker() {
            let _lock = TEST_STATE_LOCK.lock().unwrap();
            let _guard = InputRouteStateGuard::set(true, true);
            *LIFECYCLE.lock().unwrap() = PortableServiceLifecycle {
                state: LifecycleState::Ready,
                generation: 83,
            };
            SECURE_CAPTURE_GENERATION.store(83, Ordering::SeqCst);
            SECURE_DESKTOP_HELPER_GENERATION.store(82, Ordering::SeqCst);
            FIRST_FRAME_GENERATION.store(83, Ordering::SeqCst);

            assert!(!stop_secure_capture_helper("mismatched secure owner"));
            assert_eq!(lifecycle(), LifecycleState::Ready);
            assert!(!clear_generation_if_current(82, "stale secure stop"));
            assert_eq!(SECURE_CAPTURE_GENERATION.load(Ordering::SeqCst), 83);
            assert_eq!(SECURE_DESKTOP_HELPER_GENERATION.load(Ordering::SeqCst), 82);
            assert_eq!(lifecycle(), LifecycleState::Ready);

            SECURE_DESKTOP_HELPER_GENERATION.store(83, Ordering::SeqCst);
            assert!(clear_generation_if_current(
                83,
                "interactive desktop restored"
            ));
            assert_eq!(SECURE_CAPTURE_GENERATION.load(Ordering::SeqCst), 0);
            assert_eq!(SECURE_DESKTOP_HELPER_GENERATION.load(Ordering::SeqCst), 0);
            assert_eq!(FIRST_FRAME_GENERATION.load(Ordering::SeqCst), 0);
            assert_eq!(lifecycle(), LifecycleState::Stopped);
            assert!(!routes_input_via_helper());
        }

        #[test]
        fn test_start_para_input_routing_policy() {
            let _lock = TEST_STATE_LOCK.lock().unwrap();
            assert!(!start_para_routes_input_via_helper(&StartPara::Direct));
            assert!(start_para_routes_input_via_helper(
                &StartPara::ElevatedDirect
            ));
            assert!(start_para_routes_input_via_helper(
                &StartPara::SecureDesktop
            ));
            assert!(start_para_routes_input_via_helper(&StartPara::Logon(
                "user".to_owned(),
                "password".to_owned()
            )));
        }

        #[test]
        fn test_quick_support_start_policy_routes_elevated_input_through_helper() {
            let direct = start_para_for_quick_support_process(false);
            assert!(matches!(direct, StartPara::Direct));
            assert!(!start_para_routes_input_via_helper(&direct));

            let elevated = start_para_for_quick_support_process(true);
            assert!(matches!(elevated, StartPara::ElevatedDirect));
            assert!(start_para_routes_input_via_helper(&elevated));
        }

        #[test]
        fn test_portable_helper_capture_only_for_secure_or_changed_desktop() {
            assert!(!should_use_helper_capture_for_desktop_state(
                false, true, true, true, true
            ));
            assert!(!should_use_helper_capture_for_desktop_state(
                true, false, false, false, false
            ));
            assert!(should_use_helper_capture_for_desktop_state(
                true, true, false, false, false
            ));
            assert!(should_use_helper_capture_for_desktop_state(
                true, false, true, false, false
            ));
            assert!(should_use_helper_capture_for_desktop_state(
                true, false, false, true, false
            ));
            assert!(should_use_helper_capture_for_desktop_state(
                true, false, false, false, true
            ));
        }

        #[cfg(windows)]
        #[test]
        fn test_elevated_portable_service_uses_system_bootstrap_arg() {
            let shmem_arg = crate::portable_service::portable_service_shmem_arg("test-shmem");

            assert_eq!(
                portable_service_process_arg(&shmem_arg),
                "--portable-service --portable-service-shmem-name=test-shmem"
            );
            assert_eq!(
                portable_service_system_process_arg(&shmem_arg),
                "--run-as-system --portable-service --portable-service-shmem-name=test-shmem"
            );
        }

        #[test]
        fn test_input_helper_routing_requires_running_helper_mode() {
            let _lock = TEST_STATE_LOCK.lock().unwrap();

            let _guard = InputRouteStateGuard::set(false, false);
            assert!(!routes_input_via_helper());

            let _guard = InputRouteStateGuard::set(false, true);
            assert!(!routes_input_via_helper());

            let _guard = InputRouteStateGuard::set(true, false);
            assert!(!routes_input_via_helper());

            let _guard = InputRouteStateGuard::set(true, true);
            assert!(routes_input_via_helper());
        }
    }
}

#[repr(C)]
pub struct CapturerPara {
    recreate: bool,
    current_display: usize,
    timeout_ms: i32,
}

#[repr(C)]
pub struct FrameInfo {
    length: usize,
    width: usize,
    height: usize,
}

#[cfg(test)]
mod tests {
    use super::{is_valid_capture_frame_length, ADDR_CAPTURE_FRAME};

    #[test]
    fn test_is_valid_capture_frame_length_rejects_zero_length() {
        assert!(!is_valid_capture_frame_length(ADDR_CAPTURE_FRAME + 1024, 0));
    }

    #[test]
    fn test_is_valid_capture_frame_length_rejects_out_of_bounds_length() {
        assert!(!is_valid_capture_frame_length(ADDR_CAPTURE_FRAME + 16, 17));
    }

    #[test]
    fn test_is_valid_capture_frame_length_accepts_in_bounds_length() {
        assert!(is_valid_capture_frame_length(ADDR_CAPTURE_FRAME + 16, 16));
    }
}
