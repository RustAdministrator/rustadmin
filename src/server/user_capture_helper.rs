use super::capture_slots::{
    wall_clock_micros, SlotControl, SlotCounters, SlotReader, SlotWriter, Take, TakenFrame,
    SLOT_COUNT,
};
#[cfg(feature = "vram")]
use super::capture_textures::{
    helper_step, FrameUse, HelperStep, ServiceTextures, TextureControl, TextureFailure,
    TextureOffer,
};
use hbb_common::{anyhow::Context, bail, libc, log, ResultType};
#[cfg(feature = "vram")]
use scrap::{
    dxgi::shared_texture::{self, AdapterD3dDevice, SharedTextureRing, SharedTextureWriter},
    AdapterDevice,
};
use scrap::{Capturer, Display, Frame, TraitCapturer, TraitPixelBuffer};
#[cfg(feature = "vram")]
use std::ffi::c_void;
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
const BACKEND_DXGI_CPU: u32 = 3;
const GDI_BOOTSTRAP_AFTER: Duration = Duration::from_millis(500);
const WOULD_BLOCK_LOG_INTERVAL: Duration = Duration::from_secs(10);

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum UserCaptureBackend {
    Dxgi = 1,
    Wgc = 2,
}

impl UserCaptureBackend {
    fn from_raw(value: u32) -> Option<Self> {
        match value {
            // The helper was WGC-only before the backend selector was added.
            0 => Some(Self::Wgc),
            value if value == Self::Dxgi as u32 => Some(Self::Dxgi),
            value if value == Self::Wgc as u32 => Some(Self::Wgc),
            _ => None,
        }
    }

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Dxgi => "DXGI",
            Self::Wgc => "WGC",
        }
    }

    fn capture_backend(self) -> u32 {
        match self {
            Self::Dxgi => BACKEND_DXGI_CPU,
            Self::Wgc => BACKEND_WGC_CPU,
        }
    }

    fn capture_backend_name(self) -> &'static str {
        match self {
            Self::Dxgi => "DXGI Desktop Duplication",
            Self::Wgc => "Windows Graphics Capture",
        }
    }
}

const fn align_up(value: usize, align: usize) -> usize {
    (value + align - 1) / align * align
}

const ADDR_COMMAND: usize = 0;
const ADDR_STATUS: usize = align_up(ADDR_COMMAND + size_of::<CaptureCommand>(), 8);
// The frames go through two slots (`capture_slots`): their control block, the one of texture
// mode (`capture_textures`, builds with `vram`), then the slots.
const ADDR_SLOT_CONTROL: usize = align_up(ADDR_STATUS + size_of::<CaptureStatus>(), 8);
const ADDR_TEXTURE_CONTROL: usize = align_up(ADDR_SLOT_CONTROL + size_of::<SlotControl>(), 8);
#[cfg(feature = "vram")]
const TEXTURE_CONTROL_LEN: usize = size_of::<TextureControl>();
#[cfg(not(feature = "vram"))]
const TEXTURE_CONTROL_LEN: usize = 0;
const ADDR_FRAME: usize = align_up(ADDR_TEXTURE_CONTROL + TEXTURE_CONTROL_LEN, FRAME_ALIGN);
const MIN_SHMEM_LEN: usize = ADDR_FRAME + SLOT_COUNT * FRAME_ALIGN;
/// How long the service waits for a frame the helper is writing at that moment.
const BEING_WRITTEN_WAIT: Duration = Duration::from_millis(8);
const SLOT_COUNTERS_LOG_INTERVAL: Duration = Duration::from_secs(60);
/// How long either side waits for a shared texture the other side holds. By the slot protocol
/// they never want the same one at the same time; the wait covers the GPU work still queued.
#[cfg(feature = "vram")]
const TEXTURE_WAIT_MS: u32 = 100;

#[repr(C)]
#[derive(Clone, Copy)]
struct CaptureCommand {
    exit: u32,
    generation: u32,
    backend: u32,
    process_priority: u32,
    current_display: usize,
    timeout_ms: u32,
}

/// What the helper reports besides the frames themselves: whether its capture works, and
/// with which backend. The frames and their sizes go through the slots.
#[repr(C)]
#[derive(Clone, Copy)]
struct CaptureStatus {
    status: u32,
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
fn read_status(shmem: &crate::portable_service::SharedMemory) -> CaptureStatus {
    unsafe {
        let ptr = shmem.as_ptr().add(ADDR_STATUS) as *const CaptureStatus;
        std::ptr::read_volatile(ptr)
    }
}

#[inline]
fn write_status(shmem: &crate::portable_service::SharedMemory, status: u32, backend: u32) {
    let status = CaptureStatus { status, backend };
    unsafe {
        let ptr = &status as *const CaptureStatus as *const u8;
        let data = slice::from_raw_parts(ptr, size_of::<CaptureStatus>());
        shmem.write(ADDR_STATUS, data);
    }
}

/// How many bytes one slot holds for a display of this size.
#[inline]
fn slot_capacity_for_display(width: usize, height: usize) -> usize {
    align_up(width.saturating_mul(height).saturating_mul(4), FRAME_ALIGN).max(FRAME_ALIGN)
}

#[inline]
fn shmem_size_for_slot_capacity(slot_capacity: usize) -> usize {
    ADDR_FRAME.saturating_add(SLOT_COUNT.saturating_mul(slot_capacity))
}

#[inline]
fn slot_control(shmem: &crate::portable_service::SharedMemory) -> &SlotControl {
    // The mapping starts on a page boundary and the offset is a multiple of eight; both
    // sides check that the mapping is at least `MIN_SHMEM_LEN` long before they get here.
    unsafe { SlotControl::at(shmem.as_ptr().add(ADDR_SLOT_CONTROL)) }
}

#[cfg(feature = "vram")]
#[inline]
fn texture_control(shmem: &crate::portable_service::SharedMemory) -> &TextureControl {
    // Like the slots' control block: aligned to eight, inside `MIN_SHMEM_LEN`.
    unsafe { TextureControl::at(shmem.as_ptr().add(ADDR_TEXTURE_CONTROL)) }
}

/// The slot size the service recorded, if both slots of that size fit into the mapping.
#[inline]
fn recorded_slot_capacity(shmem: &crate::portable_service::SharedMemory) -> Option<usize> {
    let capacity = slot_control(shmem).slot_capacity();
    (capacity >= FRAME_ALIGN && shmem_size_for_slot_capacity(capacity) <= shmem.len())
        .then_some(capacity)
}

#[inline]
fn slot_addr(slot: usize, slot_capacity: usize) -> usize {
    ADDR_FRAME + slot * slot_capacity
}

#[inline]
fn validate_frame_length(slot_capacity: usize, length: usize) -> bool {
    length > 0 && length <= slot_capacity
}

fn create_backend_capturer(
    backend: UserCaptureBackend,
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
    match backend {
        UserCaptureBackend::Dxgi => {
            let capturer =
                Capturer::new(display).with_context(|| "Failed to create DXGI capturer")?;
            #[cfg(feature = "vram")]
            let capturer = {
                let mut capturer = capturer;
                capturer.set_output_texture(false);
                capturer
            };
            Ok((Box::new(capturer), width, height))
        }
        UserCaptureBackend::Wgc => {
            if !scrap::CapturerWgc::is_supported() {
                bail!("WGC is not supported");
            }
            let capturer = scrap::CapturerWgc::new(display)
                .with_context(|| "Failed to create WGC capturer")?;
            Ok((Box::new(capturer), width, height))
        }
    }
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

    /// Texture mode on the helper's side: the offer it follows, and the textures opened on the
    /// capturer's device and, for frames from memory, on a device of its own.
    #[cfg(feature = "vram")]
    #[derive(Default)]
    struct HelperTextures {
        offer: Option<TextureOffer>,
        capture: Option<SharedTextureWriter>,
        upload: Option<SharedTextureWriter>,
    }

    #[cfg(feature = "vram")]
    impl HelperTextures {
        fn generation(&self) -> u32 {
            self.offer.map_or(0, |offer| offer.generation)
        }

        /// Gives up the textures and closes the handles the service duplicated in.
        fn close(&mut self) {
            self.capture = None;
            self.upload = None;
            if let Some(offer) = self.offer.take() {
                for handle in offer.handles {
                    unsafe { shared_texture::close_handle(handle) };
                }
            }
        }

        /// Follows the service's offer: opens a new one, gives up a withdrawn one.
        fn follow(&mut self, control: &TextureControl) {
            match helper_step(control.offer_now(), control.opened(), control.failed()) {
                HelperStep::Keep => {}
                HelperStep::Open(offer) => {
                    self.close();
                    log::info!(
                        "User capture helper writes frames into shared textures: generation={}, size={}x{}, adapter={}",
                        offer.generation,
                        offer.width,
                        offer.height,
                        offer.luid
                    );
                    self.offer = Some(offer);
                    control.report_opened(offer.generation);
                }
                HelperStep::Close => {
                    log::info!(
                        "User capture helper writes frames as bytes again: generation={}",
                        self.generation()
                    );
                    self.close();
                    control.report_opened(0);
                }
            }
        }

        /// Texture mode cannot go on: back to bytes, and the service is told why.
        fn fail(&mut self, control: &TextureControl, failure: TextureFailure, detail: &str) {
            let generation = self.generation();
            log::warn!(
                "User capture helper cannot use the shared textures of generation {}: {}: {}",
                generation,
                failure.describe(),
                detail
            );
            self.close();
            control.report_failure(generation, failure);
        }

        /// Copies a captured texture into the texture of the slot the writer chooses, and
        /// publishes it. `false`: texture mode failed (and was reported).
        #[allow(clippy::too_many_arguments)]
        fn write_texture_frame(
            &mut self,
            control: &TextureControl,
            slots: &SlotControl,
            writer: &mut SlotWriter,
            device: AdapterDevice,
            texture: *mut c_void,
            rotation: usize,
            (width, height, tag): (usize, usize, u32),
        ) -> bool {
            let Some(offer) = self.offer else {
                return false;
            };
            if device.luid != offer.luid {
                let detail = format!("capture on {}, textures on {}", device.luid, offer.luid);
                self.fail(control, TextureFailure::OtherAdapter, &detail);
                return false;
            }
            if rotation != 0 {
                let detail = format!("the frame is turned by {rotation}");
                self.fail(control, TextureFailure::SizeOrFormat, &detail);
                return false;
            }
            if self.capture.as_ref().map(|target| target.device_ptr()) != Some(device.device) {
                self.capture = None;
                match unsafe { SharedTextureWriter::open(device.device, &offer.handles) } {
                    Ok(target) => self.capture = Some(target),
                    Err(err) => {
                        self.fail(control, TextureFailure::Open, &err.to_string());
                        return false;
                    }
                }
            }
            let checked = match self.capture.as_ref() {
                Some(target) => unsafe { target.check_texture(texture) },
                None => return false,
            };
            if let Err(err) = checked {
                self.fail(control, TextureFailure::SizeOrFormat, &err.to_string());
                return false;
            }
            // `None`: the service took that slot this moment; this capture is dropped.
            let Some(ticket) = writer.begin(slots, wall_clock_micros()) else {
                return true;
            };
            let written = match self.capture.as_ref() {
                Some(target) => unsafe {
                    target.write_texture(ticket.slot(), texture, TEXTURE_WAIT_MS)
                },
                None => Ok(false),
            };
            self.finish(
                control,
                slots,
                writer,
                ticket,
                written,
                (width, height, tag),
            )
        }

        /// The same for a frame from memory (GDI): uploaded on the helper's own device.
        fn write_pixel_frame(
            &mut self,
            control: &TextureControl,
            slots: &SlotControl,
            writer: &mut SlotWriter,
            data: &[u8],
            stride: usize,
            (width, height, tag): (usize, usize, u32),
        ) -> bool {
            let Some(offer) = self.offer else {
                return false;
            };
            if self.upload.is_none() {
                match unsafe { SharedTextureWriter::open_on_adapter(offer.luid, &offer.handles) } {
                    Ok(target) => self.upload = Some(target),
                    Err(err) => {
                        self.fail(control, TextureFailure::Open, &err.to_string());
                        return false;
                    }
                }
            }
            let Some(ticket) = writer.begin(slots, wall_clock_micros()) else {
                return true;
            };
            let written = match self.upload.as_ref() {
                Some(target) => target.write_pixels(ticket.slot(), data, stride, TEXTURE_WAIT_MS),
                None => Ok(false),
            };
            self.finish(
                control,
                slots,
                writer,
                ticket,
                written,
                (width, height, tag),
            )
        }

        fn finish(
            &mut self,
            control: &TextureControl,
            slots: &SlotControl,
            writer: &mut SlotWriter,
            ticket: super::super::capture_slots::WriteTicket,
            written: std::io::Result<bool>,
            (width, height, tag): (usize, usize, u32),
        ) -> bool {
            match written {
                Ok(true) => {
                    writer.publish_texture(slots, ticket, width, height, tag, self.generation());
                    true
                }
                // Still held after the wait: this capture is dropped.
                Ok(false) => {
                    writer.abandon(slots, ticket);
                    true
                }
                Err(err) => {
                    writer.abandon(slots, ticket);
                    let failure = if err.kind() == std::io::ErrorKind::InvalidInput {
                        TextureFailure::SizeOrFormat
                    } else {
                        TextureFailure::Copy
                    };
                    self.fail(control, failure, &err.to_string());
                    false
                }
            }
        }
    }

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
        let Some(slot_capacity) = recorded_slot_capacity(shmem) else {
            log::error!(
                "User capture helper shared memory has no usable slot size: recorded={}, len={}",
                slot_control(shmem).slot_capacity(),
                shmem.len()
            );
            return;
        };
        let control = slot_control(shmem);
        let mut writer = SlotWriter::default();
        let mut capturer: Option<Box<dyn TraitCapturer>> = None;
        let mut active_generation = u32::MAX;
        let mut active_backend: Option<UserCaptureBackend> = None;
        let mut active_process_priority = u32::MAX;
        let mut active_display = usize::MAX;
        let mut width = 0usize;
        let mut height = 0usize;
        let mut counter = 0u32;
        let mut would_block_samples_since_log = 0u32;
        let mut last_would_block_log: Option<Instant> = None;
        let mut primary_frames = 0u32;
        let mut primary_no_frame_since: Option<Instant> = None;
        let mut primary_backend = "Windows Graphics Capture";
        let mut primary_backend_id = BACKEND_UNKNOWN;
        let mut primary_is_gdi = false;
        let mut gdi_fallback: Option<Box<dyn TraitCapturer>> = None;
        let mut gdi_fallback_frames = 0u32;
        let mut gdi_bootstrap_attempted = false;
        #[cfg(feature = "vram")]
        let textures_control = texture_control(shmem);
        #[cfg(feature = "vram")]
        let mut textures = HelperTextures::default();
        // Whether the capturer was told to give textures.
        #[cfg(feature = "vram")]
        let mut texture_output = false;
        loop {
            let command = read_command(shmem);
            if command.exit != 0 {
                log::info!("User capture helper exit requested");
                #[cfg(feature = "vram")]
                textures.close();
                break;
            }
            #[cfg(feature = "vram")]
            {
                textures.follow(textures_control);
                let wanted = textures.offer.is_some() && !primary_is_gdi;
                if wanted != texture_output {
                    if let Some(capturer) = capturer.as_mut() {
                        capturer.set_output_texture(wanted);
                    }
                    texture_output = wanted;
                }
            }
            let Some(requested_backend) = UserCaptureBackend::from_raw(command.backend) else {
                write_status(shmem, STATUS_ERROR, BACKEND_UNKNOWN);
                std::thread::sleep(Duration::from_millis(20));
                continue;
            };
            if active_process_priority != command.process_priority {
                let priority =
                    crate::platform::windows::ProcessPriority::from_raw(command.process_priority);
                crate::platform::windows::apply_current_process_priority(
                    priority,
                    "user-capture-helper",
                );
                active_process_priority = command.process_priority;
            }
            let recreate = capturer.is_none()
                || active_generation != command.generation
                || active_backend != Some(requested_backend)
                || active_display != command.current_display;
            if recreate {
                let new_backend = match create_backend_capturer(
                    requested_backend,
                    command.current_display,
                ) {
                    Ok((new_capturer, new_width, new_height)) => (
                        new_capturer,
                        new_width,
                        new_height,
                        requested_backend.capture_backend_name(),
                        false,
                    ),
                    Err(primary_err) => {
                        log::warn!(
                            "User capture helper failed to create {} capturer, trying GDI fallback: {}",
                            requested_backend.as_str(),
                            primary_err
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
                                write_status(shmem, STATUS_ERROR, BACKEND_UNKNOWN);
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
                #[cfg(feature = "vram")]
                let new_capturer = {
                    let mut new_capturer = new_capturer;
                    // A new capturer has a new device: the textures are opened on it again.
                    textures.capture = None;
                    texture_output = textures.offer.is_some() && !new_is_gdi;
                    if texture_output {
                        new_capturer.set_output_texture(true);
                    }
                    new_capturer
                };
                capturer = Some(new_capturer);
                active_generation = command.generation;
                active_backend = Some(requested_backend);
                active_display = command.current_display;
                width = new_width;
                height = new_height;
                primary_backend = new_backend_name;
                primary_is_gdi = new_is_gdi;
                primary_backend_id = if primary_is_gdi {
                    BACKEND_GDI_CPU
                } else {
                    requested_backend.capture_backend()
                };
                would_block_samples_since_log = 0;
                last_would_block_log = None;
                primary_frames = 0;
                primary_no_frame_since = None;
                gdi_fallback = None;
                gdi_fallback_frames = 0;
                gdi_bootstrap_attempted = false;
                write_status(shmem, STATUS_STARTING, primary_backend_id);
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
                    if !validate_frame_length(slot_capacity, data.len()) {
                        log::error!(
                            "User capture helper frame exceeds shared memory capacity: frame_len={}, slot_capacity={}",
                            data.len(),
                            slot_capacity
                        );
                        write_status(shmem, STATUS_ERROR, primary_backend_id);
                        std::thread::sleep(timeout);
                        continue;
                    }
                    #[cfg(feature = "vram")]
                    let into_texture = textures.offer.is_some();
                    #[cfg(not(feature = "vram"))]
                    let into_texture = false;
                    if into_texture {
                        #[cfg(feature = "vram")]
                        {
                            let stride = frame.stride().first().copied().unwrap_or(width * 4);
                            textures.write_pixel_frame(
                                textures_control,
                                control,
                                &mut writer,
                                data,
                                stride,
                                (width, height, primary_backend_id),
                            );
                        }
                    }
                    // Into the slot the service does not hold; it sees the frame when it is
                    // complete. `None`: the service took that slot this moment, and this
                    // capture is dropped.
                    else if let Some(ticket) = writer.begin(control, wall_clock_micros()) {
                        shmem.write(slot_addr(ticket.slot(), slot_capacity), data);
                        writer.publish(
                            control,
                            ticket,
                            data.len(),
                            width,
                            height,
                            primary_backend_id,
                        );
                    }
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
                    write_status(shmem, STATUS_OK, primary_backend_id);
                }
                #[cfg(feature = "vram")]
                Some(Ok(Frame::Texture((texture, rotation)))) if textures.offer.is_some() => {
                    let device = capturer
                        .as_ref()
                        .map(|capturer| capturer.device())
                        .unwrap_or_default();
                    if !textures.write_texture_frame(
                        textures_control,
                        control,
                        &mut writer,
                        device,
                        texture,
                        rotation,
                        (width, height, primary_backend_id),
                    ) {
                        // Bytes from the next capture on.
                        if let Some(capturer) = capturer.as_mut() {
                            capturer.set_output_texture(false);
                        }
                        texture_output = false;
                        continue;
                    }
                    counter = counter.wrapping_add(1).max(1);
                    primary_frames = primary_frames.saturating_add(1);
                    if primary_frames == 1 {
                        log::info!(
                            "User capture helper received first {} frame, as a texture, size={}x{}",
                            primary_backend,
                            width,
                            height
                        );
                    }
                    gdi_fallback = None;
                    gdi_fallback_frames = 0;
                    primary_no_frame_since = None;
                    write_status(shmem, STATUS_OK, primary_backend_id);
                }
                Some(Ok(Frame::Texture(_))) => {
                    log::warn!(
                        "User capture helper received {} texture frame, recreating capturer",
                        primary_backend
                    );
                    capturer = None;
                    write_status(shmem, STATUS_ERROR, primary_backend_id);
                }
                Some(Err(err)) if err.kind() == std::io::ErrorKind::WouldBlock => {
                    would_block_samples_since_log = would_block_samples_since_log.saturating_add(1);
                    let first_no_frame = *primary_no_frame_since.get_or_insert_with(Instant::now);
                    let now = Instant::now();
                    if last_would_block_log
                        .map(|last| now.saturating_duration_since(last) >= WOULD_BLOCK_LOG_INTERVAL)
                        .unwrap_or(true)
                    {
                        log::debug!(
                            "User capture helper {} would block: samples_since_log={}",
                            primary_backend,
                            would_block_samples_since_log,
                        );
                        would_block_samples_since_log = 0;
                        last_would_block_log = Some(now);
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
                                    if validate_frame_length(slot_capacity, data.len()) {
                                        #[cfg(feature = "vram")]
                                        let into_texture = textures.offer.is_some();
                                        #[cfg(not(feature = "vram"))]
                                        let into_texture = false;
                                        if into_texture {
                                            #[cfg(feature = "vram")]
                                            {
                                                let stride = frame
                                                    .stride()
                                                    .first()
                                                    .copied()
                                                    .unwrap_or(width * 4);
                                                textures.write_pixel_frame(
                                                    textures_control,
                                                    control,
                                                    &mut writer,
                                                    data,
                                                    stride,
                                                    (width, height, BACKEND_GDI_CPU),
                                                );
                                            }
                                        } else if let Some(ticket) =
                                            writer.begin(control, wall_clock_micros())
                                        {
                                            shmem.write(
                                                slot_addr(ticket.slot(), slot_capacity),
                                                data,
                                            );
                                            writer.publish(
                                                control,
                                                ticket,
                                                data.len(),
                                                width,
                                                height,
                                                BACKEND_GDI_CPU,
                                            );
                                        }
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
                                        write_status(shmem, STATUS_OK, BACKEND_GDI_CPU);
                                        continue;
                                    }
                                    log::warn!(
                                        "User capture helper GDI fallback frame exceeds shared memory capacity: frame_len={}, slot_capacity={}",
                                        data.len(),
                                        slot_capacity
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
                        write_status(shmem, STATUS_WOULD_BLOCK, primary_backend_id);
                    }
                }
                Some(Err(err)) => {
                    log::warn!(
                        "User capture helper {} frame failed: {}",
                        primary_backend,
                        err
                    );
                    capturer = None;
                    write_status(shmem, STATUS_ERROR, primary_backend_id);
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
    #[cfg(feature = "vram")]
    static NEXT_TEXTURE_GENERATION: AtomicU32 = AtomicU32::new(1);

    /// The service's textures for one helper: a device on the captured display's adapter, the
    /// one the encoder will work on, and the textures on it.
    #[cfg(feature = "vram")]
    struct ServiceRing {
        device: AdapterD3dDevice,
        ring: SharedTextureRing,
    }

    pub struct UserCaptureHelperCapturer {
        attempt: Option<super::super::helper_retry::HelperAttemptLease>,
        shmem_name: String,
        shmem: crate::portable_service::SharedMemory,
        process: HANDLE,
        requested_backend: UserCaptureBackend,
        current_display: usize,
        generation: u32,
        width: usize,
        height: usize,
        last_backend: u32,
        slot_capacity: usize,
        reader: SlotReader,
        slot_counters_logged: (Instant, SlotCounters),
        #[cfg(feature = "vram")]
        textures: Option<ServiceRing>,
        #[cfg(feature = "vram")]
        texture_state: ServiceTextures,
        /// The slot whose texture the last frame handed out is; given back on the next call.
        #[cfg(feature = "vram")]
        held_texture: Option<usize>,
        /// Why no textures were offered, when they were wanted.
        #[cfg(feature = "vram")]
        texture_offer_failed: Option<String>,
    }

    unsafe impl Send for UserCaptureHelperCapturer {}

    impl UserCaptureHelperCapturer {
        fn new(
            requested_backend: UserCaptureBackend,
            current_display: usize,
            width: usize,
            height: usize,
            textures: bool,
        ) -> ResultType<Self> {
            let shmem_name = next_shmem_name();
            let slot_capacity = slot_capacity_for_display(width, height);
            let shmem_size = shmem_size_for_slot_capacity(slot_capacity).max(MIN_SHMEM_LEN);
            let shmem = crate::portable_service::SharedMemory::create(&shmem_name, shmem_size)?;
            let flink = shmem_flink_path(&shmem_name)?;
            if let Err(err) =
                crate::platform::windows::grant_user_capture_helper_shmem_file_access(&flink)
            {
                // The link is closed to everyone but the service until the
                // session user is granted; do not widen it, do not start the helper.
                log::warn!(
                    "Failed to grant user capture helper shared-memory access for {:?}: {}",
                    flink,
                    err
                );
                drop(shmem);
                let _ = std::fs::remove_file(&flink);
                bail!("user capture helper shared-memory access was not granted: {err}");
            }
            unsafe {
                libc::memset(shmem.as_ptr() as _, 0, shmem.len());
            }
            // `capture-frame-slots = N`: one buffer, as before (the way back, and the
            // comparison for the counters that are logged below).
            let single_slot = hbb_common::config::Config::get_option(
                hbb_common::config::keys::OPTION_CAPTURE_FRAME_SLOTS,
            ) == "N";
            slot_control(&shmem).init(slot_capacity, single_slot);
            let generation = NEXT_GENERATION.fetch_add(1, Ordering::SeqCst);
            write_command(
                &shmem,
                CaptureCommand {
                    exit: 0,
                    generation,
                    backend: requested_backend as u32,
                    process_priority: crate::platform::windows::configured_process_priority()
                        .as_raw(),
                    current_display,
                    timeout_ms: 33,
                },
            );
            write_status(&shmem, STATUS_STARTING, BACKEND_UNKNOWN);
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
                        return Err(err).context(super::super::helper_retry::HelperLaunchFailure);
                    }
                };
            if process.is_null() {
                schedule_remove_shmem_flink(shmem_name);
                return Err(super::super::helper_retry::HelperLaunchFailure.into());
            }
            log::info!(
                "Launched user capture helper: requested_backend={} helper CPU, display={}, session={}, shmem={}, size={}, frame_slots={}",
                requested_backend.as_str(),
                current_display,
                session_id,
                shmem_name,
                shmem_size,
                if single_slot { 1 } else { SLOT_COUNT }
            );
            #[cfg(not(feature = "vram"))]
            let _ = textures;
            #[allow(unused_mut)]
            let mut capturer = Self {
                attempt: None,
                shmem_name,
                shmem,
                process,
                requested_backend,
                current_display,
                generation,
                width,
                height,
                last_backend: requested_backend.capture_backend(),
                slot_capacity,
                reader: SlotReader::default(),
                slot_counters_logged: (Instant::now(), SlotCounters::default()),
                #[cfg(feature = "vram")]
                textures: None,
                #[cfg(feature = "vram")]
                texture_state: ServiceTextures::none(Instant::now()),
                #[cfg(feature = "vram")]
                held_texture: None,
                #[cfg(feature = "vram")]
                texture_offer_failed: None,
            };
            #[cfg(feature = "vram")]
            if textures {
                capturer.offer_textures();
            }
            Ok(capturer)
        }

        /// Makes the textures on the captured display's adapter and offers them to the helper.
        #[cfg(feature = "vram")]
        fn offer_textures(&mut self) {
            match self.make_texture_offer() {
                Ok((textures, offer)) => {
                    texture_control(&self.shmem).offer(&offer);
                    log::info!(
                        "User capture helper offered shared textures: generation={}, display={}, size={}x{}, adapter={}, vendor=0x{:04x}",
                        offer.generation,
                        self.current_display,
                        offer.width,
                        offer.height,
                        offer.luid,
                        textures.device.vendor_id
                    );
                    self.textures = Some(textures);
                    self.texture_state = ServiceTextures::offered(offer.generation, Instant::now());
                }
                Err(err) => {
                    log::warn!(
                        "User capture helper hands frames over in RAM: no shared textures for display {}: {}",
                        self.current_display,
                        err
                    );
                    self.texture_offer_failed = Some(format!("no shared textures: {err}"));
                }
            }
        }

        #[cfg(feature = "vram")]
        fn make_texture_offer(&self) -> ResultType<(ServiceRing, TextureOffer)> {
            let luid = Display::all()?
                .get(self.current_display)
                .and_then(|display| display.adapter_luid())
                .context("the display's adapter is not known")?;
            let device = shared_texture::create_device_on_adapter(luid)?;
            let ring = SharedTextureRing::create(
                &device.device,
                self.width as u32,
                self.height as u32,
                SLOT_COUNT,
            )?;
            let handles = ring.duplicate_into(self.process as *mut c_void)?;
            let offer = TextureOffer {
                generation: NEXT_TEXTURE_GENERATION.fetch_add(1, Ordering::SeqCst),
                width: self.width as u32,
                height: self.height as u32,
                luid,
                handles: std::array::from_fn(|slot| handles[slot]),
            };
            Ok((ServiceRing { device, ring }, offer))
        }

        /// Gives the texture of the frame handed out last back to the helper's side. Before
        /// its slot is released: the slot protocol gives the helper the slot only then.
        #[cfg(feature = "vram")]
        fn release_held_texture(&mut self) {
            let Some(slot) = self.held_texture.take() else {
                return;
            };
            if let Some(textures) = self.textures.as_ref() {
                if let Err(err) = textures.ring.release(slot) {
                    log::warn!("User capture helper shared texture {slot} not released: {err}");
                }
            }
        }

        /// Texture mode ended (the reason is in `texture_state`): the helper is told to go back
        /// to bytes.
        #[cfg(feature = "vram")]
        fn give_up_textures(&mut self) {
            self.release_held_texture();
            texture_control(&self.shmem).withdraw();
            self.textures = None;
            log::warn!(
                "User capture helper hands frames over in RAM from now on: display={}, {}",
                self.current_display,
                self.texture_state
                    .off_reason()
                    .unwrap_or("texture mode ended")
            );
        }

        /// A frame in a shared texture: held for the encoder until the next call.
        #[cfg(feature = "vram")]
        fn take_texture_frame<'a>(&mut self, slot: usize) -> std::io::Result<Frame<'a>> {
            let taken = self
                .textures
                .as_ref()
                .map(|textures| textures.ring.acquire(slot, TEXTURE_WAIT_MS));
            if let (Some(Ok(true)), Some(textures)) = (&taken, self.textures.as_ref()) {
                let texture = textures.ring.texture_ptr(slot);
                self.held_texture = Some(slot);
                return Ok(Frame::Texture((texture, 0)));
            }
            let reason = match taken {
                Some(Err(err)) => format!("the service could not take a shared texture: {err}"),
                _ => "the service could not take a shared texture in time".to_owned(),
            };
            self.texture_state.turn_off(&reason);
            self.give_up_textures();
            Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "user capture helper shared texture not taken",
            ))
        }

        /// The newest frame the helper has published, if the service has not had it yet.
        /// A frame that is being written at this moment is waited for, briefly.
        fn take_frame(&mut self, timeout: Duration) -> Option<TakenFrame> {
            let control = slot_control(&self.shmem);
            // The frame handed out by the previous call is no longer in use.
            self.reader.release(control);
            let give_up_at = Instant::now() + timeout.min(BEING_WRITTEN_WAIT);
            loop {
                match self.reader.take(control, wall_clock_micros()) {
                    Take::Frame(frame) => return Some(frame),
                    Take::Nothing => return None,
                    Take::BeingWritten => {
                        if Instant::now() >= give_up_at {
                            return None;
                        }
                        std::thread::sleep(Duration::from_micros(300));
                    }
                }
            }
        }

        /// Once a minute: what the helper has counted about its writes. The writes that
        /// began within a few milliseconds of the service taking a frame are the ones that
        /// landed in the picture being converted when there was one buffer.
        fn log_slot_counters(&mut self) {
            let now = Instant::now();
            if now.saturating_duration_since(self.slot_counters_logged.0)
                < SLOT_COUNTERS_LOG_INTERVAL
            {
                return;
            }
            let control = slot_control(&self.shmem);
            let counters = control.counters();
            log::info!(
                "user capture helper hand-off: display={}, frame_slots={}, {}",
                self.current_display,
                if control.single_slot() { 1 } else { SLOT_COUNT },
                counters.since(&self.slot_counters_logged.1)
            );
            self.slot_counters_logged = (now, counters);
        }

        fn update_timeout(&self, timeout: Duration) {
            let mut command = read_command(&self.shmem);
            command.timeout_ms = timeout.as_millis().clamp(1, u32::MAX as u128) as u32;
            command.exit = 0;
            command.generation = self.generation;
            command.backend = self.requested_backend as u32;
            command.process_priority =
                crate::platform::windows::configured_process_priority().as_raw();
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
            #[cfg(feature = "vram")]
            {
                self.release_held_texture();
                texture_control(&self.shmem).withdraw();
            }
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
            let info = read_status(&self.shmem);
            if info.backend != BACKEND_UNKNOWN {
                self.last_backend = info.backend;
            }
            self.log_slot_counters();
            #[cfg(feature = "vram")]
            self.release_held_texture();
            if let Some(frame) = self.take_frame(timeout) {
                if frame.tag != BACKEND_UNKNOWN {
                    self.last_backend = frame.tag;
                }
                if frame.width != self.width || frame.height != self.height {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::WouldBlock,
                        "user capture helper frame size is changing",
                    ));
                }
                #[cfg(feature = "vram")]
                {
                    let failure =
                        texture_control(&self.shmem).failure_of(self.texture_state.generation());
                    let was_on = self.texture_state.texture_mode();
                    let frame_use =
                        self.texture_state
                            .frame_use(frame.texture, failure, Instant::now());
                    if was_on && !self.texture_state.texture_mode() {
                        self.give_up_textures();
                    }
                    match frame_use {
                        FrameUse::Bytes => {}
                        FrameUse::Skip => {
                            return Err(std::io::Error::new(
                                std::io::ErrorKind::WouldBlock,
                                "user capture helper frame is not in the shared textures",
                            ));
                        }
                        FrameUse::Texture => {
                            if self
                                .attempt
                                .as_mut()
                                .is_some_and(|attempt| !attempt.success())
                            {
                                return Err(std::io::Error::new(
                                    std::io::ErrorKind::Interrupted,
                                    "retired user capture helper attempt",
                                ));
                            }
                            return self.take_texture_frame(frame.slot);
                        }
                    }
                }
                // Builds without `vram` offer no textures; such a frame cannot be read here.
                #[cfg(not(feature = "vram"))]
                if frame.texture != 0 {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::WouldBlock,
                        "user capture helper frame is in a texture",
                    ));
                }
                if !validate_frame_length(self.slot_capacity, frame.length) {
                    if let Some(attempt) = self.attempt.as_mut() {
                        attempt.failure(false);
                    }
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "invalid user capture helper frame length",
                    ));
                }
                if self
                    .attempt
                    .as_mut()
                    .is_some_and(|attempt| !attempt.success())
                {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::Interrupted,
                        "retired user capture helper attempt",
                    ));
                }
                // The slot stays pinned, and so unwritten, until the next call.
                unsafe {
                    let data = slice::from_raw_parts(
                        self.shmem
                            .as_ptr()
                            .add(slot_addr(frame.slot, self.slot_capacity)),
                        frame.length,
                    );
                    return Ok(Frame::PixelBuffer(PixelBuffer::with_BGRA(
                        data,
                        self.width,
                        self.height,
                    )));
                }
            }
            #[cfg(feature = "vram")]
            if self.texture_state.texture_mode() {
                let failure =
                    texture_control(&self.shmem).failure_of(self.texture_state.generation());
                self.texture_state.check_failure(failure);
                if !self.texture_state.texture_mode() {
                    self.give_up_textures();
                }
            }
            // A valid frame already in shared memory wins over the polling
            // deadline; encoder initialization may delay our first frame call.
            if let Some(attempt) = self.attempt.as_mut() {
                if attempt.startup_timed_out() {
                    attempt.failure(false);
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "user capture helper startup timed out",
                    ));
                }
            }
            let result = match info.status {
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
            };
            if result
                .as_ref()
                .err()
                .is_some_and(|err| err.kind() != std::io::ErrorKind::WouldBlock)
            {
                if let Some(attempt) = self.attempt.as_mut() {
                    attempt.failure(false);
                }
            }
            result
        }

        fn is_gdi(&self) -> bool {
            false
        }

        fn is_user_capture_helper(&self) -> bool {
            true
        }

        fn is_cpu_only(&self) -> bool {
            #[cfg(feature = "vram")]
            return !self.texture_state.texture_mode();
            #[cfg(not(feature = "vram"))]
            true
        }

        fn capture_backend(&self) -> &'static str {
            #[cfg(feature = "vram")]
            if self.texture_state.texture_mode() {
                return match self.last_backend {
                    BACKEND_WGC_CPU => "Windows Graphics Capture Helper (GPU)",
                    BACKEND_GDI_CPU => "Windows GDI Helper (GPU upload)",
                    BACKEND_DXGI_CPU => "DXGI Desktop Duplication Helper (GPU)",
                    _ => "User Capture Helper (GPU)",
                };
            }
            match self.last_backend {
                BACKEND_WGC_CPU => "Windows Graphics Capture Helper (CPU)",
                BACKEND_GDI_CPU => "Windows GDI Helper (CPU)",
                BACKEND_DXGI_CPU => "DXGI Desktop Duplication Helper (CPU)",
                _ => "User Capture Helper (CPU)",
            }
        }

        fn set_gdi(&mut self) -> bool {
            false
        }

        /// The device of the shared textures while frames come in them: the encoder works on it.
        #[cfg(feature = "vram")]
        fn device(&self) -> AdapterDevice {
            match self.textures.as_ref() {
                Some(textures) if self.texture_state.texture_mode() => AdapterDevice {
                    device: textures.device.device_ptr(),
                    vendor_id: textures.device.vendor_id,
                    luid: textures.device.luid,
                },
                _ => AdapterDevice::default(),
            }
        }

        /// `false`: the encoder takes frames from RAM, so the helper goes back to bytes.
        #[cfg(feature = "vram")]
        fn set_output_texture(&mut self, texture: bool) {
            if texture || !self.texture_state.texture_mode() {
                return;
            }
            self.release_held_texture();
            texture_control(&self.shmem).withdraw();
            self.textures = None;
            self.texture_state = ServiceTextures::none(Instant::now());
            log::info!(
                "User capture helper hands frames over in RAM: the encoder of display {} takes them from there",
                self.current_display
            );
        }

        #[cfg(feature = "vram")]
        fn texture_off_reason(&self) -> Option<String> {
            self.texture_state
                .off_reason()
                .map(str::to_owned)
                .or_else(|| self.texture_offer_failed.clone())
        }
    }

    /// `textures`: offer the helper shared textures, so that the frames reach a texture
    /// encoder without a copy through RAM (builds with `vram`).
    pub(crate) fn create_capturer(
        backend: UserCaptureBackend,
        current_display: usize,
        width: usize,
        height: usize,
        textures: bool,
        mut attempt: super::super::helper_retry::HelperAttemptLease,
    ) -> ResultType<Box<dyn TraitCapturer>> {
        match UserCaptureHelperCapturer::new(backend, current_display, width, height, textures) {
            Ok(mut capturer) => {
                capturer.attempt = Some(attempt);
                Ok(Box::new(capturer))
            }
            Err(err) => {
                attempt.failure(
                    err.downcast_ref::<super::super::helper_retry::HelperLaunchFailure>()
                        .is_some(),
                );
                Err(err)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_memory_holds_two_whole_frames_behind_an_aligned_control_block() {
        assert_eq!(ADDR_SLOT_CONTROL % 8, 0);
        assert_eq!(ADDR_TEXTURE_CONTROL % 8, 0);
        assert_eq!(ADDR_FRAME % FRAME_ALIGN, 0);
        assert!(ADDR_SLOT_CONTROL + size_of::<SlotControl>() <= ADDR_TEXTURE_CONTROL);
        assert!(ADDR_TEXTURE_CONTROL + TEXTURE_CONTROL_LEN <= ADDR_FRAME);
        // 1920x1080, and a size whose byte count is not a multiple of the alignment.
        for (width, height) in [(1920usize, 1080usize), (1366, 767)] {
            let frame_bytes = width * height * 4;
            let capacity = slot_capacity_for_display(width, height);
            assert!(capacity >= frame_bytes);
            assert_eq!(capacity % FRAME_ALIGN, 0);
            assert!(validate_frame_length(capacity, frame_bytes));
            assert!(!validate_frame_length(capacity, capacity + 1));
            assert!(!validate_frame_length(capacity, 0));
            let len = shmem_size_for_slot_capacity(capacity);
            assert_eq!(slot_addr(0, capacity), ADDR_FRAME);
            assert_eq!(slot_addr(SLOT_COUNT - 1, capacity) + capacity, len);
        }
        // A display with no size still gets the fixed part and two smallest slots.
        assert_eq!(
            shmem_size_for_slot_capacity(slot_capacity_for_display(0, 0)),
            MIN_SHMEM_LEN
        );
    }

    #[test]
    fn capture_backend_command_values_round_trip() {
        for backend in [UserCaptureBackend::Dxgi, UserCaptureBackend::Wgc] {
            assert_eq!(UserCaptureBackend::from_raw(backend as u32), Some(backend));
        }
        assert_eq!(
            UserCaptureBackend::from_raw(0),
            Some(UserCaptureBackend::Wgc)
        );
        assert_eq!(UserCaptureBackend::from_raw(u32::MAX), None);
    }

    /// Diagnostic, run by hand on Windows (`-- --ignored --nocapture`, ideally as
    /// SYSTEM): creates a helper shared-memory flink the way the server does,
    /// applies the grant and prints who can do what with the flink, its
    /// directory and the backing file. Used to answer "can another account
    /// reach the helper's frames?" without a full capture setup.
    #[cfg(windows)]
    #[test]
    #[ignore = "diagnostic: prints ACLs, run by hand"]
    fn probe_helper_shared_memory_acls() {
        let name = next_shmem_name();
        let shmem = crate::portable_service::SharedMemory::create(&name, 4096)
            .expect("create shared memory");
        let flink = shmem_flink_path(&name).expect("flink path");
        let granted = crate::platform::windows::grant_user_capture_helper_shmem_file_access(&flink);
        println!("PROBE flink={} grant={:?}", flink.display(), granted);
        let mut targets = vec![
            ("flink", flink.clone()),
            ("flink-dir", flink.parent().unwrap().to_path_buf()),
        ];
        // The backing file the shared_memory crate creates for the mapping.
        if let Ok(id) = std::fs::read_to_string(&flink) {
            let id = id.trim().trim_start_matches('/').to_owned();
            let backing = std::env::temp_dir().join("shared_memory-rs").join(&id);
            println!("PROBE mapping id={id} backing={}", backing.display());
            targets.push(("backing", backing));
        }
        for (title, path) in targets {
            let out = std::process::Command::new("icacls")
                .arg(&path)
                .output()
                .expect("icacls");
            println!(
                "PROBE --- {title}: {}\n{}",
                path.display(),
                String::from_utf8_lossy(&out.stdout)
            );
        }
        if let Some(secs) = std::env::var("RUSTADMIN_ACL_PROBE_HOLD_SECS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
        {
            println!("PROBE holding for {secs}s");
            std::thread::sleep(Duration::from_secs(secs));
        }
        drop(shmem);
    }

    #[test]
    fn capture_backend_telemetry_values_are_distinct() {
        assert_ne!(UserCaptureBackend::Dxgi.capture_backend(), BACKEND_GDI_CPU);
        assert_ne!(UserCaptureBackend::Wgc.capture_backend(), BACKEND_GDI_CPU);
        assert_ne!(
            UserCaptureBackend::Dxgi.capture_backend(),
            UserCaptureBackend::Wgc.capture_backend()
        );
    }
}
