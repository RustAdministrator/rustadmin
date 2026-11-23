//! Textures that two processes share on one GPU: how the user capture helper hands a captured
//! frame to the server without a copy through RAM.
//!
//! The server creates the textures on its own device and duplicates their NT handles into the
//! helper process ([`SharedTextureRing`]); the helper opens them on a device of the same adapter
//! ([`OpenedSharedTexture`]). Nothing has a name, so no other process can open them, and the
//! helper, which runs with less rights, never hands a handle to the server.
//!
//! Which side may touch which texture is decided by the slot protocol of the shared memory
//! (`src/server/capture_slots.rs`): a texture is a slot. The keyed mutex of each texture only
//! orders the GPU work of the two devices: both sides take it with [`KEY`] around their use.

use std::{ffi::c_void, io};
use windows::{
    core::{Interface, PCWSTR},
    Win32::{
        Foundation::{
            CloseHandle, DuplicateHandle, DUPLICATE_CLOSE_SOURCE, DUPLICATE_SAME_ACCESS, HANDLE,
            HMODULE, LUID,
        },
        Graphics::{
            Direct3D::{D3D_DRIVER_TYPE_UNKNOWN, D3D_FEATURE_LEVEL_11_0},
            Direct3D11::{
                D3D11CreateDevice, ID3D11Device, ID3D11Device1, ID3D11DeviceContext,
                ID3D11Texture2D, D3D11_BIND_RENDER_TARGET, D3D11_BIND_SHADER_RESOURCE,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_CREATE_DEVICE_FLAG,
                D3D11_CREATE_DEVICE_VIDEO_SUPPORT, D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX,
                D3D11_RESOURCE_MISC_SHARED_NTHANDLE, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC,
                D3D11_USAGE_DEFAULT,
            },
            Dxgi::{
                Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC},
                CreateDXGIFactory1, IDXGIFactory1, IDXGIKeyedMutex, IDXGIResource1,
                DXGI_SHARED_RESOURCE_READ, DXGI_SHARED_RESOURCE_WRITE,
            },
        },
        System::Threading::GetCurrentProcess,
    },
};

/// The key both sides take a texture's keyed mutex with.
pub const KEY: u64 = 0;

/// `IDXGIKeyedMutex::AcquireSync` answers these two as success codes, not as errors.
const HRESULT_WAIT_TIMEOUT: i32 = 0x102;
const HRESULT_WAIT_ABANDONED: i32 = 0x80;

fn error(context: &str, err: windows::core::Error) -> io::Error {
    io::Error::new(io::ErrorKind::Other, format!("{context}: {err}"))
}

/// The LUID of an adapter as one number, as `AdapterDevice::luid` holds it.
pub fn luid_value(luid: LUID) -> i64 {
    ((luid.HighPart as i64) << 32) | luid.LowPart as i64
}

/// A D3D11 device on one adapter, made as the texture encoder makes its own (video and BGRA
/// support, feature level 11.0), so that the encoder can work on it.
pub struct AdapterD3dDevice {
    pub device: ID3D11Device,
    pub context: ID3D11DeviceContext,
    pub vendor_id: u32,
    pub luid: i64,
}

unsafe impl Send for AdapterD3dDevice {}

impl AdapterD3dDevice {
    /// The raw `ID3D11Device*`, as `AdapterDevice::device` holds it.
    pub fn device_ptr(&self) -> *mut c_void {
        self.device.as_raw()
    }
}

/// Makes a device on the adapter with this LUID.
pub fn create_device_on_adapter(luid: i64) -> io::Result<AdapterD3dDevice> {
    create_device(
        luid,
        D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
    )
}

fn create_device(luid: i64, flags: D3D11_CREATE_DEVICE_FLAG) -> io::Result<AdapterD3dDevice> {
    unsafe {
        let factory: IDXGIFactory1 =
            CreateDXGIFactory1().map_err(|err| error("CreateDXGIFactory1", err))?;
        let mut index = 0;
        loop {
            let Ok(adapter) = factory.EnumAdapters1(index) else {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("no adapter with LUID {luid}"),
                ));
            };
            index += 1;
            let desc = adapter
                .GetDesc1()
                .map_err(|err| error("IDXGIAdapter1::GetDesc1", err))?;
            if luid_value(desc.AdapterLuid) != luid {
                continue;
            }
            let mut device = None;
            let mut context = None;
            D3D11CreateDevice(
                &adapter,
                D3D_DRIVER_TYPE_UNKNOWN,
                HMODULE::default(),
                flags,
                Some(&[D3D_FEATURE_LEVEL_11_0]),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )
            .map_err(|err| error("D3D11CreateDevice", err))?;
            let (Some(device), Some(context)) = (device, context) else {
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    "D3D11CreateDevice gave no device",
                ));
            };
            return Ok(AdapterD3dDevice {
                device,
                context,
                vendor_id: desc.VendorId,
                luid,
            });
        }
    }
}

/// Takes a texture's keyed mutex: `Ok(true)` once it is held, `Ok(false)` when `timeout_ms`
/// ran out.
fn acquire_sync(mutex: &IDXGIKeyedMutex, timeout_ms: u32) -> io::Result<bool> {
    // The method wrapper of the `windows` crate takes every HRESULT that is not an error for
    // success, and a timeout is such an HRESULT: call the method itself and read the code.
    let hr = unsafe { (Interface::vtable(mutex).AcquireSync)(mutex.as_raw(), KEY, timeout_ms) };
    match hr.0 {
        0 => Ok(true),
        HRESULT_WAIT_TIMEOUT => Ok(false),
        HRESULT_WAIT_ABANDONED => Err(io::Error::new(
            io::ErrorKind::BrokenPipe,
            "the other process ended while it held the texture",
        )),
        _ => Err(error(
            "IDXGIKeyedMutex::AcquireSync",
            windows::core::Error::from(hr),
        )),
    }
}

fn release_sync(mutex: &IDXGIKeyedMutex) -> io::Result<()> {
    unsafe { mutex.ReleaseSync(KEY) }.map_err(|err| error("IDXGIKeyedMutex::ReleaseSync", err))
}

fn texture_desc(texture: &ID3D11Texture2D) -> D3D11_TEXTURE2D_DESC {
    let mut desc = D3D11_TEXTURE2D_DESC::default();
    unsafe { texture.GetDesc(&mut desc) };
    desc
}

struct SharedTexture {
    texture: ID3D11Texture2D,
    mutex: IDXGIKeyedMutex,
    handle: HANDLE,
}

impl Drop for SharedTexture {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.handle);
        }
    }
}

/// The textures of one hand-over, owned by the reader (the server).
pub struct SharedTextureRing {
    textures: Vec<SharedTexture>,
    width: u32,
    height: u32,
}

// Used by one thread at a time; the keyed mutexes order the GPU work of the two processes.
unsafe impl Send for SharedTextureRing {}

impl SharedTextureRing {
    /// Makes `count` BGRA textures of this size on `device`, each with an NT handle and a
    /// keyed mutex.
    pub fn create(
        device: &ID3D11Device,
        width: u32,
        height: u32,
        count: usize,
    ) -> io::Result<Self> {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: width,
            Height: height,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: (D3D11_BIND_RENDER_TARGET.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
            CPUAccessFlags: 0,
            MiscFlags: (D3D11_RESOURCE_MISC_SHARED_NTHANDLE.0
                | D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX.0) as u32,
        };
        let mut textures = Vec::with_capacity(count);
        for _ in 0..count {
            unsafe {
                let mut texture = None;
                device
                    .CreateTexture2D(&desc, None, Some(&mut texture))
                    .map_err(|err| error("CreateTexture2D", err))?;
                let Some(texture) = texture else {
                    return Err(io::Error::new(
                        io::ErrorKind::Other,
                        "CreateTexture2D gave no texture",
                    ));
                };
                let resource: IDXGIResource1 =
                    texture.cast().map_err(|err| error("IDXGIResource1", err))?;
                let handle = resource
                    .CreateSharedHandle(
                        None,
                        DXGI_SHARED_RESOURCE_READ.0 | DXGI_SHARED_RESOURCE_WRITE.0,
                        PCWSTR::null(),
                    )
                    .map_err(|err| error("IDXGIResource1::CreateSharedHandle", err))?;
                let mutex: IDXGIKeyedMutex = match texture.cast() {
                    Ok(mutex) => mutex,
                    Err(err) => {
                        let _ = CloseHandle(handle);
                        return Err(error("IDXGIKeyedMutex", err));
                    }
                };
                textures.push(SharedTexture {
                    texture,
                    mutex,
                    handle,
                });
            }
        }
        Ok(Self {
            textures,
            width,
            height,
        })
    }

    pub fn len(&self) -> usize {
        self.textures.len()
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    pub fn texture(&self, index: usize) -> &ID3D11Texture2D {
        &self.textures[index].texture
    }

    /// The raw `ID3D11Texture2D*` of a texture, for `Frame::Texture`.
    pub fn texture_ptr(&self, index: usize) -> *mut c_void {
        self.textures[index].texture.as_raw()
    }

    /// Duplicates the handle of every texture into `process` (a raw process handle with the
    /// right to duplicate handles into it) and returns the values the handles have there, in the
    /// order of the textures. On a failure the handles already duplicated are closed in that
    /// process again.
    pub fn duplicate_into(&self, process: *mut c_void) -> io::Result<Vec<u64>> {
        let process = HANDLE(process);
        let mut values = Vec::with_capacity(self.textures.len());
        for shared in &self.textures {
            let mut target = HANDLE::default();
            let duplicated = unsafe {
                DuplicateHandle(
                    GetCurrentProcess(),
                    shared.handle,
                    process,
                    &mut target,
                    0,
                    false,
                    DUPLICATE_SAME_ACCESS,
                )
            };
            if let Err(err) = duplicated {
                for value in values {
                    close_handle_in(process.0, value);
                }
                return Err(error("DuplicateHandle", err));
            }
            values.push(target.0 as usize as u64);
        }
        Ok(values)
    }

    /// Takes the keyed mutex of texture `index` for this process's GPU work on it.
    pub fn acquire(&self, index: usize, timeout_ms: u32) -> io::Result<bool> {
        acquire_sync(&self.textures[index].mutex, timeout_ms)
    }

    pub fn release(&self, index: usize) -> io::Result<()> {
        release_sync(&self.textures[index].mutex)
    }
}

/// Closes a handle that lives in another process (one this process duplicated there).
pub fn close_handle_in(process: *mut c_void, value: u64) {
    unsafe {
        let _ = DuplicateHandle(
            HANDLE(process),
            HANDLE(value as usize as *mut c_void),
            HANDLE::default(),
            std::ptr::null_mut(),
            0,
            false,
            DUPLICATE_CLOSE_SOURCE,
        );
    }
}

/// Closes a handle of this process, given as the value the other side wrote down.
///
/// # Safety
/// `value` must be a handle of this process that nothing else uses or closes.
pub unsafe fn close_handle(value: u64) {
    let _ = CloseHandle(HANDLE(value as usize as *mut c_void));
}

/// A texture of the reader's ring, opened by the writer (the helper) on one of its devices.
pub struct OpenedSharedTexture {
    texture: ID3D11Texture2D,
    mutex: IDXGIKeyedMutex,
    width: u32,
    height: u32,
}

unsafe impl Send for OpenedSharedTexture {}

impl OpenedSharedTexture {
    /// Opens the texture behind `handle`, a handle the reader duplicated into this process, on
    /// `device`. The handle stays open: the same texture can be opened on another device later
    /// (the helper makes a new capturer, and with it a new device); close it with
    /// [`close_handle`] when the ring is given up.
    ///
    /// # Safety
    /// `handle` must be an open handle of this process to a shared texture.
    pub unsafe fn open(device: &ID3D11Device, handle: u64) -> io::Result<Self> {
        let device1: ID3D11Device1 = device.cast().map_err(|err| error("ID3D11Device1", err))?;
        let texture: ID3D11Texture2D = device1
            .OpenSharedResource1(HANDLE(handle as usize as *mut c_void))
            .map_err(|err| error("ID3D11Device1::OpenSharedResource1", err))?;
        let mutex: IDXGIKeyedMutex = texture
            .cast()
            .map_err(|err| error("IDXGIKeyedMutex", err))?;
        let desc = texture_desc(&texture);
        Ok(Self {
            texture,
            mutex,
            width: desc.Width,
            height: desc.Height,
        })
    }

    pub fn texture(&self) -> &ID3D11Texture2D {
        &self.texture
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    pub fn acquire(&self, timeout_ms: u32) -> io::Result<bool> {
        acquire_sync(&self.mutex, timeout_ms)
    }

    fn check_source(&self, source: &ID3D11Texture2D) -> io::Result<()> {
        let desc = texture_desc(source);
        if (desc.Width, desc.Height) != (self.width, self.height)
            || desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "the frame is {}x{} format {}, the shared texture {}x{} BGRA",
                    desc.Width, desc.Height, desc.Format.0, self.width, self.height
                ),
            ));
        }
        Ok(())
    }

    pub fn release(&self) -> io::Result<()> {
        release_sync(&self.mutex)
    }

    /// Copies a captured texture of the same device into this one. `Ok(false)`: the texture was
    /// not free within `timeout_ms`, and nothing was copied.
    ///
    /// # Safety
    /// `source` must be a live `ID3D11Texture2D*` of the device this texture was opened on, and
    /// `context` that device's immediate context.
    pub unsafe fn write_texture(
        &self,
        context: &ID3D11DeviceContext,
        source: *mut c_void,
        timeout_ms: u32,
    ) -> io::Result<bool> {
        let Some(source) = ID3D11Texture2D::from_raw_borrowed(&source) else {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "no texture"));
        };
        self.check_source(source)?;
        if !self.acquire(timeout_ms)? {
            return Ok(false);
        }
        context.CopyResource(&self.texture, source);
        context.Flush();
        self.release()?;
        Ok(true)
    }

    /// Uploads a BGRA frame from memory, rows `stride` bytes apart. `Ok(false)`: the texture was
    /// not free within `timeout_ms`, and nothing was written.
    ///
    /// # Safety
    /// `context` must be the immediate context of the device this texture was opened on.
    pub unsafe fn write_pixels(
        &self,
        context: &ID3D11DeviceContext,
        data: &[u8],
        stride: usize,
        timeout_ms: u32,
    ) -> io::Result<bool> {
        let row = self.width as usize * 4;
        if stride < row || data.len() < stride * (self.height as usize).saturating_sub(1) + row {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "{} bytes with rows {stride} apart do not hold a {}x{} BGRA frame",
                    data.len(),
                    self.width,
                    self.height
                ),
            ));
        }
        if !self.acquire(timeout_ms)? {
            return Ok(false);
        }
        context.UpdateSubresource(
            &self.texture,
            0,
            None,
            data.as_ptr() as *const c_void,
            stride as u32,
            0,
        );
        context.Flush();
        self.release()?;
        Ok(true)
    }
}

/// The helper's side of a ring: its textures opened on one device, in slot order.
pub struct SharedTextureWriter {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    textures: Vec<OpenedSharedTexture>,
}

unsafe impl Send for SharedTextureWriter {}

impl SharedTextureWriter {
    /// Opens the textures behind `handles` on `device`, a raw `ID3D11Device*` of this process,
    /// such as the one a capturer copies its frames on.
    ///
    /// # Safety
    /// `device` must be a live device, and `handles` open handles of this process to shared
    /// textures.
    pub unsafe fn open(device: *mut c_void, handles: &[u64]) -> io::Result<Self> {
        let Some(device) = ID3D11Device::from_raw_borrowed(&device) else {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "no device"));
        };
        Self::open_on(device.clone(), handles)
    }

    /// Opens them on a device of its own on the adapter `luid`: for frames that come from
    /// memory.
    ///
    /// # Safety
    /// `handles` must be open handles of this process to shared textures.
    pub unsafe fn open_on_adapter(luid: i64, handles: &[u64]) -> io::Result<Self> {
        Self::open_on(create_device_on_adapter(luid)?.device, handles)
    }

    unsafe fn open_on(device: ID3D11Device, handles: &[u64]) -> io::Result<Self> {
        let context = device
            .GetImmediateContext()
            .map_err(|err| error("ID3D11Device::GetImmediateContext", err))?;
        let textures = handles
            .iter()
            .map(|handle| OpenedSharedTexture::open(&device, *handle))
            .collect::<io::Result<Vec<_>>>()?;
        Ok(Self {
            device,
            context,
            textures,
        })
    }

    /// The raw `ID3D11Device*` the textures are open on.
    pub fn device_ptr(&self) -> *mut c_void {
        self.device.as_raw()
    }

    /// Whether `source`, a raw `ID3D11Texture2D*`, can be copied into the textures: the same
    /// size, BGRA.
    ///
    /// # Safety
    /// `source` must be a live texture.
    pub unsafe fn check_texture(&self, source: *mut c_void) -> io::Result<()> {
        let Some(first) = self.textures.first() else {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "no textures"));
        };
        let Some(source) = ID3D11Texture2D::from_raw_borrowed(&source) else {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "no texture"));
        };
        first.check_source(source)
    }

    /// Copies `source`, a texture of this writer's device, into the texture of `slot`.
    /// `Ok(false)`: the texture was not free within `timeout_ms`, and nothing was copied.
    ///
    /// # Safety
    /// `source` must be a live `ID3D11Texture2D*` of this writer's device.
    pub unsafe fn write_texture(
        &self,
        slot: usize,
        source: *mut c_void,
        timeout_ms: u32,
    ) -> io::Result<bool> {
        self.textures[slot].write_texture(&self.context, source, timeout_ms)
    }

    /// Uploads a BGRA frame from memory into the texture of `slot`. `Ok(false)`: the texture
    /// was not free within `timeout_ms`, and nothing was written.
    pub fn write_pixels(
        &self,
        slot: usize,
        data: &[u8],
        stride: usize,
        timeout_ms: u32,
    ) -> io::Result<bool> {
        unsafe { self.textures[slot].write_pixels(&self.context, data, stride, timeout_ms) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{BufRead, Write},
        os::windows::io::AsRawHandle,
        process::{Command, Stdio},
    };
    use windows::Win32::Graphics::{
        Direct3D11::{
            D3D11_CPU_ACCESS_READ, D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_READ, D3D11_USAGE_STAGING,
        },
        Dxgi::DXGI_ADAPTER_FLAG_SOFTWARE,
    };

    const CHILD_ENV: &str = "RUSTADMIN_SHARED_TEXTURE_CHILD";
    const CHILD_TEST: &str = "dxgi::shared_texture::tests::shared_texture_child";
    /// Red 0, green 0.25 (64), blue 1, alpha 1: no channel on a rounding edge.
    const COLOR: [f32; 4] = [0.0, 0.25, 1.0, 1.0];
    /// The same colour as BGRA bytes.
    const COLOR_BGRA: [u8; 4] = [255, 64, 0, 255];
    /// What the child uploads from memory.
    const PIXELS_BGRA: [u8; 4] = [10, 20, 30, 255];

    fn first_hardware_adapter_luid() -> Option<i64> {
        unsafe {
            let factory: IDXGIFactory1 = CreateDXGIFactory1().ok()?;
            let mut index = 0;
            while let Ok(adapter) = factory.EnumAdapters1(index) {
                index += 1;
                let desc = adapter.GetDesc1().ok()?;
                if desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 == 0 {
                    return Some(luid_value(desc.AdapterLuid));
                }
            }
            None
        }
    }

    /// Without video support: the sharing does not need it, and a virtual adapter may lack it.
    fn test_device(luid: i64) -> AdapterD3dDevice {
        create_device(luid, D3D11_CREATE_DEVICE_BGRA_SUPPORT).expect("a device on the adapter")
    }

    fn device_or_skip() -> Option<AdapterD3dDevice> {
        let Some(luid) = first_hardware_adapter_luid() else {
            println!("no hardware adapter: skipped");
            return None;
        };
        Some(test_device(luid))
    }

    fn first_pixel(device: &AdapterD3dDevice, texture: &ID3D11Texture2D) -> [u8; 4] {
        unsafe {
            let mut desc = texture_desc(texture);
            desc.Usage = D3D11_USAGE_STAGING;
            desc.BindFlags = 0;
            desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
            desc.MiscFlags = 0;
            let mut staging = None;
            device
                .device
                .CreateTexture2D(&desc, None, Some(&mut staging))
                .unwrap();
            let staging = staging.unwrap();
            device.context.CopyResource(&staging, texture);
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            device
                .context
                .Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))
                .unwrap();
            let pixel = *(mapped.pData as *const [u8; 4]);
            device.context.Unmap(&staging, 0);
            pixel
        }
    }

    /// The writer side of `frames_written_by_another_process_arrive`; does nothing unless that
    /// test started it. Clears texture 1 on the GPU and uploads a frame into texture 2.
    #[test]
    fn shared_texture_child() {
        if std::env::var(CHILD_ENV).is_err() {
            return;
        }
        let mut line = String::new();
        std::io::stdin().lock().read_line(&mut line).unwrap();
        let fields: Vec<&str> = line.split_whitespace().collect();
        let luid: i64 = fields[0].parse().unwrap();
        let handles: Vec<u64> = fields[1..].iter().map(|v| v.parse().unwrap()).collect();
        let device = test_device(luid);
        unsafe {
            let cleared = OpenedSharedTexture::open(&device.device, handles[0]).unwrap();
            assert!(cleared.acquire(5000).unwrap(), "texture 1 never came free");
            let mut view = None;
            device
                .device
                .CreateRenderTargetView(cleared.texture(), None, Some(&mut view))
                .unwrap();
            device
                .context
                .ClearRenderTargetView(view.as_ref().unwrap(), &COLOR);
            device.context.Flush();
            cleared.release().unwrap();
            let uploaded = OpenedSharedTexture::open(&device.device, handles[1]).unwrap();
            let pixels: Vec<u8> = PIXELS_BGRA
                .iter()
                .copied()
                .cycle()
                .take(64 * 4 * 32)
                .collect();
            assert!(uploaded
                .write_pixels(&device.context, &pixels, 64 * 4, 5000)
                .unwrap());
            for handle in handles {
                close_handle(handle);
            }
        }
    }

    #[test]
    fn frames_written_by_another_process_arrive() {
        let Some(device) = device_or_skip() else {
            return;
        };
        let ring = SharedTextureRing::create(&device.device, 64, 32, 3).unwrap();
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([CHILD_TEST, "--exact", "--nocapture", "--test-threads=1"])
            .env(CHILD_ENV, "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let values = ring
            .duplicate_into(child.as_raw_handle() as *mut c_void)
            .unwrap();
        assert_eq!(values.len(), 3);
        writeln!(
            child.stdin.take().unwrap(),
            "{} {} {}",
            device.luid,
            values[1],
            values[2]
        )
        .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "child failed: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        for (index, expected) in [(1, COLOR_BGRA), (2, PIXELS_BGRA)] {
            assert!(
                ring.acquire(index, 5000).unwrap(),
                "texture {index} stayed held"
            );
            let pixel = first_pixel(&device, ring.texture(index));
            ring.release(index).unwrap();
            assert_eq!(pixel, expected, "texture {index}");
        }
    }

    #[test]
    fn a_texture_held_on_one_device_waits_on_another() {
        let Some(device) = device_or_skip() else {
            return;
        };
        let other = test_device(device.luid);
        let ring = SharedTextureRing::create(&device.device, 16, 16, 1).unwrap();
        let values = ring
            .duplicate_into(unsafe { GetCurrentProcess() }.0)
            .unwrap();
        unsafe {
            let opened = OpenedSharedTexture::open(&other.device, values[0]).unwrap();
            assert!(ring.acquire(0, 0).unwrap());
            // A timeout must read as "not yet", not as the texture being held.
            assert!(!opened.acquire(0).unwrap());
            ring.release(0).unwrap();
            assert!(opened.acquire(0).unwrap());
            opened.release().unwrap();
            close_handle(values[0]);
        }
    }

    #[test]
    fn a_frame_of_another_size_is_not_copied() {
        let Some(device) = device_or_skip() else {
            return;
        };
        let ring = SharedTextureRing::create(&device.device, 16, 16, 1).unwrap();
        let values = ring
            .duplicate_into(unsafe { GetCurrentProcess() }.0)
            .unwrap();
        unsafe {
            let opened = OpenedSharedTexture::open(&device.device, values[0]).unwrap();
            let mut desc = texture_desc(ring.texture(0));
            desc.Width = 32;
            desc.MiscFlags = 0;
            let mut other = None;
            device
                .device
                .CreateTexture2D(&desc, None, Some(&mut other))
                .unwrap();
            let other = other.unwrap();
            let err = opened
                .write_texture(&device.context, other.as_raw(), 0)
                .unwrap_err();
            assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
            let err = opened
                .write_pixels(&device.context, &[0; 16 * 4 * 15], 16 * 4, 0)
                .unwrap_err();
            assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
            close_handle(values[0]);
        }
    }
}
