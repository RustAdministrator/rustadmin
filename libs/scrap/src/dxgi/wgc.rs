use std::{
    ffi::c_void,
    io,
    io::ErrorKind::WouldBlock,
    ptr, thread,
    time::{Duration, Instant},
};

use crate::AdapterDevice;
use windows::{
    core::{factory, Interface},
    Foundation::TimeSpan,
    Graphics::{
        Capture::{
            Direct3D11CaptureFrame, Direct3D11CaptureFramePool, GraphicsCaptureItem,
            GraphicsCaptureSession,
        },
        DirectX::{Direct3D11::IDirect3DDevice, DirectXPixelFormat},
        SizeInt32,
    },
    Win32::{
        Foundation::HMODULE,
        Graphics::{
            Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_UNKNOWN},
            Direct3D11::{
                D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Resource,
                ID3D11Texture2D, D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_FLAG_DO_NOT_WAIT, D3D11_MAP_READ,
                D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
            },
            Dxgi::{
                Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC},
                IDXGIAdapter, IDXGIAdapter1, IDXGIDevice, DXGI_ERROR_WAIT_TIMEOUT,
                DXGI_ERROR_WAS_STILL_DRAWING,
            },
            Gdi::HMONITOR,
        },
        System::WinRT::{
            Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess},
            Graphics::Capture::IGraphicsCaptureItemInterop,
            RoInitialize, RO_INIT_MULTITHREADED,
        },
    },
};

const WGC_STAGING_TEXTURES: usize = 3;

fn to_io_error(error: windows::core::Error) -> io::Error {
    io::Error::new(io::ErrorKind::Other, error.to_string())
}

fn wgc_item_from_monitor(hmonitor: HMONITOR) -> io::Result<GraphicsCaptureItem> {
    let interop =
        factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>().map_err(to_io_error)?;
    // Safety: hmonitor comes from the enumerated Windows display descriptor.
    unsafe { interop.CreateForMonitor(hmonitor).map_err(to_io_error) }
}

pub struct CapturerWgc {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    direct3d_device: IDirect3DDevice,
    frame_pool: Direct3D11CaptureFramePool,
    session: GraphicsCaptureSession,
    staging: Vec<ID3D11Texture2D>,
    texture: Option<ID3D11Texture2D>,
    next_staging: usize,
    pending_staging: Option<usize>,
    output_texture: bool,
    width: usize,
    height: usize,
    vendor_id: u32,
    luid: i64,
}

impl CapturerWgc {
    pub fn is_supported() -> bool {
        // Safety: RoInitialize is process/thread initialization and accepts this constant flag.
        let _ = unsafe { RoInitialize(RO_INIT_MULTITHREADED) };
        GraphicsCaptureSession::IsSupported().unwrap_or(false)
    }

    pub fn new(display: super::Display) -> io::Result<Self> {
        // Safety: RoInitialize is process/thread initialization and accepts this constant flag.
        let _ = unsafe { RoInitialize(RO_INIT_MULTITHREADED) };
        if !Self::is_supported() {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "windows graphics capture is not supported",
            ));
        }

        let width = display.width() as usize;
        let height = display.height() as usize;
        let hmonitor = display.hmonitor();
        let raw_adapter = display.adapter.0 as *mut c_void;
        let adapter = unsafe {
            // Safety: raw_adapter comes from the enumerated DXGI display and remains owned by display
            // for the duration of this constructor call. from_raw_borrowed does not take ownership.
            IDXGIAdapter::from_raw_borrowed(&raw_adapter)
        };
        let adapter1 = unsafe {
            // Safety: raw_adapter is the same valid DXGI adapter pointer as above.
            IDXGIAdapter1::from_raw_borrowed(&raw_adapter)
        };
        let adapter_desc = match adapter1 {
            Some(adapter) => Some(unsafe {
                // Safety: adapter is a valid borrowed IDXGIAdapter1.
                adapter.GetDesc1().map_err(to_io_error)?
            }),
            None => None,
        };

        let mut device = None;
        let mut context = None;
        match adapter {
            Some(adapter) => unsafe {
                // Safety: adapter is borrowed from the selected display adapter. D3D requires
                // D3D_DRIVER_TYPE_UNKNOWN when a non-null adapter is supplied.
                D3D11CreateDevice(
                    adapter,
                    D3D_DRIVER_TYPE_UNKNOWN,
                    HMODULE::default(),
                    D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                    None,
                    D3D11_SDK_VERSION,
                    Some(&mut device),
                    None,
                    Some(&mut context),
                )
                .map_err(to_io_error)?;
            },
            None => unsafe {
                // Safety: output pointers are initialized by D3D11CreateDevice on success and
                // checked below. This fallback preserves WGC behavior when no adapter is available.
                D3D11CreateDevice(
                    None::<&IDXGIAdapter>,
                    D3D_DRIVER_TYPE_HARDWARE,
                    HMODULE::default(),
                    D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                    None,
                    D3D11_SDK_VERSION,
                    Some(&mut device),
                    None,
                    Some(&mut context),
                )
                .map_err(to_io_error)?;
            },
        }
        let device = device.ok_or_else(|| {
            io::Error::new(io::ErrorKind::Other, "D3D11CreateDevice returned no device")
        })?;
        let context = context.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::Other,
                "D3D11CreateDevice returned no context",
            )
        })?;
        let dxgi_device: IDXGIDevice = device.cast().map_err(to_io_error)?;
        let actual_adapter = unsafe {
            // Safety: dxgi_device is a valid IDXGIDevice from the created D3D11 device.
            dxgi_device.GetAdapter().map_err(to_io_error)?
        };
        let actual_desc = unsafe {
            // Safety: actual_adapter is a valid IDXGIAdapter returned by the D3D device.
            actual_adapter.GetDesc().map_err(to_io_error)?
        };
        let vendor_id = adapter_desc
            .as_ref()
            .map(|desc| desc.VendorId)
            .unwrap_or(actual_desc.VendorId);
        let luid = adapter_desc
            .as_ref()
            .map(|desc| {
                ((desc.AdapterLuid.HighPart as i64) << 32) | desc.AdapterLuid.LowPart as i64
            })
            .unwrap_or_else(|| {
                ((actual_desc.AdapterLuid.HighPart as i64) << 32)
                    | actual_desc.AdapterLuid.LowPart as i64
            });
        let direct3d_device: IDirect3DDevice = unsafe {
            // Safety: dxgi_device is a valid IDXGIDevice from the created D3D11 device.
            CreateDirect3D11DeviceFromDXGIDevice(&dxgi_device)
                .map_err(to_io_error)?
                .cast()
                .map_err(to_io_error)?
        };
        let item = wgc_item_from_monitor(HMONITOR(hmonitor as _))?;
        let size = SizeInt32 {
            Width: width as i32,
            Height: height as i32,
        };
        let frame_pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            &direct3d_device,
            DirectXPixelFormat::B8G8R8A8UIntNormalized,
            2,
            size,
        )
        .map_err(to_io_error)?;
        let session = frame_pool
            .CreateCaptureSession(&item)
            .map_err(to_io_error)?;
        let _ = session.SetIsBorderRequired(false);
        let _ = session.SetIsCursorCaptureEnabled(true);
        let _ = session.SetMinUpdateInterval(TimeSpan { Duration: 0 });
        session.StartCapture().map_err(to_io_error)?;

        let mut capturer = CapturerWgc {
            device,
            context,
            direct3d_device,
            frame_pool,
            session,
            staging: Vec::new(),
            texture: None,
            next_staging: 0,
            pending_staging: None,
            output_texture: false,
            width,
            height,
            vendor_id,
            luid,
        };
        capturer.ensure_staging(width, height)?;
        Ok(capturer)
    }

    pub fn width(&self) -> usize {
        self.width
    }

    pub fn height(&self) -> usize {
        self.height
    }

    pub fn output_texture(&self) -> bool {
        self.output_texture
    }

    pub fn set_output_texture(&mut self, texture: bool) {
        self.output_texture = texture;
        self.pending_staging = None;
        if !texture {
            self.texture = None;
        }
    }

    pub fn device(&self) -> AdapterDevice {
        AdapterDevice {
            device: self.device.as_raw(),
            vendor_id: self.vendor_id,
            luid: self.luid,
        }
    }

    pub fn frame(&mut self, data: &mut Vec<u8>, timeout: Duration) -> io::Result<()> {
        let started = Instant::now();
        loop {
            match self.try_capture_latest(data) {
                Ok(()) => return Ok(()),
                Err(err) if err.kind() == WouldBlock && started.elapsed() < timeout => {
                    thread::sleep(Duration::from_millis(1));
                }
                Err(err) => return Err(err),
            }
        }
    }

    pub fn frame_texture(&mut self, timeout: Duration) -> io::Result<(*mut c_void, usize)> {
        let started = Instant::now();
        loop {
            match self.try_capture_latest_texture() {
                Ok(()) => {
                    let texture = self.texture.as_ref().ok_or_else(|| {
                        io::Error::new(io::ErrorKind::Other, "missing WGC texture")
                    })?;
                    return Ok((texture.as_raw(), 0));
                }
                Err(err) if err.kind() == WouldBlock && started.elapsed() < timeout => {
                    thread::sleep(Duration::from_millis(1));
                }
                Err(err) => return Err(err),
            }
        }
    }

    fn try_capture_latest(&mut self, data: &mut Vec<u8>) -> io::Result<()> {
        let pending_before = self.pending_staging;
        let mut copied_staging = None;
        if let Ok(mut frame) = self.frame_pool.TryGetNextFrame() {
            while let Ok(next) = self.frame_pool.TryGetNextFrame() {
                frame = next;
            }
            copied_staging = Some(self.queue_frame_copy(&frame)?);
        }

        if let Some(pending_staging) = pending_before {
            match self.copy_staging_to_buffer(pending_staging, data) {
                Ok(()) => {
                    self.pending_staging = copied_staging;
                    return Ok(());
                }
                Err(err) if err.kind() == WouldBlock => {
                    self.pending_staging = Some(pending_staging);
                    return Err(err);
                }
                Err(err) => return Err(err),
            }
        }

        if let Some(staging) = copied_staging {
            self.pending_staging = Some(staging);
        }
        Err(io::Error::from(WouldBlock))
    }

    fn try_capture_latest_texture(&mut self) -> io::Result<()> {
        let Ok(mut frame) = self.frame_pool.TryGetNextFrame() else {
            return Err(io::Error::from(WouldBlock));
        };
        while let Ok(next) = self.frame_pool.TryGetNextFrame() {
            frame = next;
        }
        self.update_frame_size(&frame)?;
        self.texture = Some(Self::texture_from_frame(&frame)?);
        Ok(())
    }

    fn ensure_staging(&mut self, width: usize, height: usize) -> io::Result<()> {
        if self.width == width && self.height == height && self.staging.len() >= 2 {
            return Ok(());
        }

        self.width = width;
        self.height = height;
        let desc = D3D11_TEXTURE2D_DESC {
            Width: width as u32,
            Height: height as u32,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Usage: D3D11_USAGE_STAGING,
            BindFlags: 0,
            CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
            MiscFlags: 0,
        };

        let mut staging_textures = Vec::with_capacity(WGC_STAGING_TEXTURES);
        for _ in 0..WGC_STAGING_TEXTURES {
            let mut staging = None;
            unsafe {
                self.device
                    .CreateTexture2D(&desc, None, Some(&mut staging))
                    .map_err(to_io_error)?;
            }
            staging_textures.push(staging.ok_or_else(|| {
                io::Error::new(io::ErrorKind::Other, "CreateTexture2D returned no texture")
            })?);
        }
        self.staging = staging_textures;
        self.next_staging = 0;
        self.pending_staging = None;
        Ok(())
    }

    fn update_frame_size(&mut self, frame: &Direct3D11CaptureFrame) -> io::Result<()> {
        let size = frame.ContentSize().map_err(to_io_error)?;
        if size.Width <= 0 || size.Height <= 0 {
            return Err(io::Error::from(WouldBlock));
        }
        let width = size.Width as usize;
        let height = size.Height as usize;
        if width != self.width || height != self.height {
            self.frame_pool
                .Recreate(
                    &self.direct3d_device,
                    DirectXPixelFormat::B8G8R8A8UIntNormalized,
                    2,
                    size,
                )
                .map_err(to_io_error)?;
            self.width = width;
            self.height = height;
            self.staging.clear();
            self.pending_staging = None;
            if !self.output_texture {
                self.ensure_staging(width, height)?;
            }
        }
        Ok(())
    }

    fn texture_from_frame(frame: &Direct3D11CaptureFrame) -> io::Result<ID3D11Texture2D> {
        let surface = frame.Surface().map_err(to_io_error)?;
        let access: IDirect3DDxgiInterfaceAccess = surface.cast().map_err(to_io_error)?;
        unsafe {
            // Safety: WGC frame surfaces expose an underlying IDXGI texture interface.
            access.GetInterface().map_err(to_io_error)
        }
    }

    fn queue_frame_copy(&mut self, frame: &Direct3D11CaptureFrame) -> io::Result<usize> {
        self.update_frame_size(frame)?;
        if self.staging.is_empty() {
            self.ensure_staging(self.width, self.height)?;
        }

        let source = Self::texture_from_frame(frame)?;
        let staging_index = self.next_copy_staging_index();
        let staging = self
            .staging
            .get(staging_index)
            .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "missing WGC staging texture"))?;
        let source_resource: ID3D11Resource = source.cast().map_err(to_io_error)?;
        let staging_resource: ID3D11Resource = staging.cast().map_err(to_io_error)?;

        // Safety: both resources are D3D11 textures created on the same device.
        unsafe {
            self.context
                .CopyResource(&staging_resource, &source_resource);
        }
        Ok(staging_index)
    }

    fn next_copy_staging_index(&mut self) -> usize {
        let pending = self.pending_staging;
        for _ in 0..self.staging.len() {
            let index = self.next_staging;
            self.next_staging = (self.next_staging + 1) % self.staging.len();
            if Some(index) != pending {
                return index;
            }
        }
        0
    }

    fn copy_staging_to_buffer(
        &mut self,
        staging_index: usize,
        data: &mut Vec<u8>,
    ) -> io::Result<()> {
        let staging = self
            .staging
            .get(staging_index)
            .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "missing WGC staging texture"))?;
        let staging_resource: ID3D11Resource = staging.cast().map_err(to_io_error)?;

        // Safety: the staging texture was created with CPU read access and is unmapped before return.
        unsafe {
            let mut mapped = D3D11_MAPPED_SUBRESOURCE {
                pData: ptr::null_mut(),
                RowPitch: 0,
                DepthPitch: 0,
            };
            match self.context.Map(
                &staging_resource,
                0,
                D3D11_MAP_READ,
                D3D11_MAP_FLAG_DO_NOT_WAIT.0 as u32,
                Some(&mut mapped),
            ) {
                Ok(()) => {}
                Err(err)
                    if err.code() == DXGI_ERROR_WAS_STILL_DRAWING
                        || err.code() == DXGI_ERROR_WAIT_TIMEOUT =>
                {
                    return Err(io::Error::from(WouldBlock));
                }
                Err(err) => return Err(to_io_error(err)),
            }

            let row_bytes = self.width * 4;
            data.resize(row_bytes * self.height, 0);
            for y in 0..self.height {
                let src = (mapped.pData as *const u8).add(y * mapped.RowPitch as usize);
                let dst = data.as_mut_ptr().add(y * row_bytes);
                ptr::copy_nonoverlapping(src, dst, row_bytes);
            }
            self.context.Unmap(&staging_resource, 0);
        }

        Ok(())
    }
}

impl Drop for CapturerWgc {
    fn drop(&mut self) {
        let _ = self.session.Close();
        let _ = self.frame_pool.Close();
    }
}
