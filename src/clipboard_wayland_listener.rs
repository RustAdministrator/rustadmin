use clipboard_master::{CallbackResult, ClipboardHandler};
use hbb_common::log;
use std::{
    io,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{sync_channel, Receiver, RecvTimeoutError, SyncSender},
        Arc, Mutex,
    },
    thread::JoinHandle,
    time::Duration,
};
use wayland_client::{
    backend::WaylandError,
    event_created_child,
    protocol::{wl_registry, wl_seat},
    Connection, Dispatch, EventQueue, Proxy,
};
use wayland_protocols_wlr::data_control::v1::client::{
    zwlr_data_control_device_v1, zwlr_data_control_manager_v1, zwlr_data_control_offer_v1,
    zwlr_data_control_source_v1,
};

pub(crate) struct Shutdown {
    sender: SyncSender<()>,
}

impl Drop for Shutdown {
    fn drop(&mut self) {
        let _ = self.sender.send(());
    }
}

impl Shutdown {
    pub(crate) fn signal(self) {
        drop(self);
    }
}

pub(crate) fn should_use_wayland_listener() -> bool {
    if std::env::var_os("WAYLAND_DISPLAY").is_none() {
        return false;
    }
    match wl_clipboard_rs::utils::is_primary_selection_supported() {
        Ok(supported) => supported,
        Err(error) => {
            log::debug!(
                "Failed to start Wayland clipboard listener: {:?}; falling back to X11",
                error
            );
            false
        }
    }
}

pub(crate) fn start_thread<H, F>(mut handler: H, on_started: F) -> JoinHandle<()>
where
    H: ClipboardHandler + Send + 'static,
    F: FnOnce(Result<Shutdown, String>) + Send + 'static,
{
    std::thread::spawn(move || {
        let (sender, receiver) = sync_channel(0);
        on_started(Ok(Shutdown { sender }));
        log::debug!("Wayland clipboard listener started");
        if let Err(error) = run_wayland(&mut handler, receiver) {
            log::error!("Failed to run Wayland clipboard listener: {}", error);
        } else {
            log::debug!("Wayland clipboard listener stopped");
        }
    })
}

fn run_wayland<H: ClipboardHandler>(handler: &mut H, shutdown_rx: Receiver<()>) -> io::Result<()> {
    let exit_flag = Arc::new(AtomicBool::new(false));
    let exit_flag_clone = exit_flag.clone();
    let (listen_tx, listen_rx) = sync_channel(0);
    let shutdown_thread = std::thread::spawn(move || {
        let timeout = Duration::from_millis(100);
        loop {
            match shutdown_rx.recv_timeout(timeout) {
                Ok(()) | Err(RecvTimeoutError::Disconnected) => break,
                Err(RecvTimeoutError::Timeout) => {}
            }
            match listen_rx.recv_timeout(timeout) {
                Ok(()) | Err(RecvTimeoutError::Disconnected) => break,
                Err(RecvTimeoutError::Timeout) => {}
            }
        }
        exit_flag_clone.store(true, Ordering::Relaxed);
    });

    let result = run_wayland_loop(handler, exit_flag);
    listen_tx.send(()).ok();
    shutdown_thread.join().ok();
    result
}

fn run_wayland_loop<H: ClipboardHandler>(
    handler: &mut H,
    exit_flag: Arc<AtomicBool>,
) -> io::Result<()> {
    let listener = WlClipboardListener::init(exit_flag.clone())?;
    for event in listener {
        if exit_flag.load(Ordering::Relaxed) {
            break;
        }
        if let Err(error) = event {
            match handler.on_clipboard_error(error) {
                CallbackResult::Next => continue,
                CallbackResult::Stop => break,
                CallbackResult::StopWithError(error) => return Err(error),
            }
        }
        match handler.on_clipboard_change() {
            CallbackResult::Next => {}
            CallbackResult::Stop => break,
            CallbackResult::StopWithError(error) => return Err(error),
        }
    }
    Ok(())
}

#[derive(Debug)]
struct ClipboardListenMessage {
    _mime_types: Vec<String>,
}

struct WlClipboardListener {
    seat: Option<wl_seat::WlSeat>,
    seat_name: Option<String>,
    data_manager: Option<zwlr_data_control_manager_v1::ZwlrDataControlManagerV1>,
    data_device: Option<zwlr_data_control_device_v1::ZwlrDataControlDeviceV1>,
    mime_types: Vec<String>,
    queue: Option<Arc<Mutex<EventQueue<Self>>>>,
    exit_flag: Arc<AtomicBool>,
    copied: bool,
}

impl WlClipboardListener {
    fn init(exit_flag: Arc<AtomicBool>) -> io::Result<Self> {
        let conn = Connection::connect_to_env().map_err(|_| {
            io::Error::new(
                io::ErrorKind::Other,
                "Cannot connect to Wayland server, is it running?",
            )
        })?;
        let mut event_queue = conn.new_event_queue();
        let qhandle = event_queue.handle();
        let display = conn.display();

        display.get_registry(&qhandle, ());
        let mut state = WlClipboardListener {
            seat: None,
            seat_name: None,
            data_manager: None,
            data_device: None,
            mime_types: Vec::new(),
            queue: None,
            exit_flag,
            copied: false,
        };
        event_queue.blocking_dispatch(&mut state).map_err(|error| {
            io::Error::new(
                io::ErrorKind::Other,
                format!("Initial Wayland dispatch failed: {error}"),
            )
        })?;
        if !state.device_ready() {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                "Cannot get Wayland seat and data manager",
            ));
        }
        while state.seat_name.is_none() {
            event_queue.roundtrip(&mut state).map_err(|_| {
                io::Error::new(
                    io::ErrorKind::Other,
                    "Cannot roundtrip during Wayland clipboard listener init",
                )
            })?;
        }

        state.set_data_device(&qhandle);
        state.queue = Some(Arc::new(Mutex::new(event_queue)));
        Ok(state)
    }

    fn device_ready(&self) -> bool {
        self.seat.is_some() && self.data_manager.is_some()
    }

    fn set_data_device(&mut self, qh: &wayland_client::QueueHandle<Self>) {
        if let (Some(seat), Some(manager)) = (self.seat.as_ref(), self.data_manager.as_ref()) {
            self.data_device = Some(manager.get_data_device(seat, qh, ()));
        }
    }

    fn get_message(&mut self) -> io::Result<ClipboardListenMessage> {
        let Some(queue) = self.queue.clone() else {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                "Wayland event queue not initialized",
            ));
        };
        let mut queue = queue.lock().map_err(|error| {
            io::Error::new(
                io::ErrorKind::Other,
                format!("Cannot lock Wayland event queue: {error}"),
            )
        })?;
        loop {
            if self.exit_flag.load(Ordering::Relaxed) {
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    "Exit signal received, exiting",
                ));
            }

            queue.flush().map_err(|error| {
                io::Error::new(
                    io::ErrorKind::Other,
                    format!("Wayland flush failed: {error}"),
                )
            })?;
            let read_guard = queue.prepare_read().ok_or_else(|| {
                io::Error::new(io::ErrorKind::Other, "Wayland prepare_read failed")
            })?;
            match read_guard.read() {
                Ok(count) => {
                    if count > 0 {
                        queue.dispatch_pending(self).map_err(|error| {
                            io::Error::new(
                                io::ErrorKind::Other,
                                format!("Wayland dispatch_pending failed: {error}"),
                            )
                        })?;
                        if self.copied {
                            self.copied = false;
                            break;
                        }
                    } else {
                        // winit can make read() return Ok(0); avoid spinning.
                        std::thread::sleep(Duration::from_millis(30));
                    }
                }
                Err(WaylandError::Io(ref error)) if error.kind() == io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(30));
                }
                Err(error) => {
                    return Err(io::Error::new(
                        io::ErrorKind::Other,
                        format!("Wayland read failed: {error}"),
                    ));
                }
            }
        }
        Ok(ClipboardListenMessage {
            _mime_types: self.mime_types.clone(),
        })
    }
}

impl Iterator for WlClipboardListener {
    type Item = io::Result<ClipboardListenMessage>;

    fn next(&mut self) -> Option<Self::Item> {
        let result = self.get_message();
        if result.is_err() && self.exit_flag.load(Ordering::Relaxed) {
            None
        } else {
            Some(result)
        }
    }
}

impl Dispatch<wl_registry::WlRegistry, ()> for WlClipboardListener {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: <wl_registry::WlRegistry as Proxy>::Event,
        _data: &(),
        _conn: &wayland_client::Connection,
        qh: &wayland_client::QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        {
            if interface == wl_seat::WlSeat::interface().name {
                state.seat = Some(registry.bind::<wl_seat::WlSeat, _, _>(name, version, qh, ()));
            } else if interface
                == zwlr_data_control_manager_v1::ZwlrDataControlManagerV1::interface().name
            {
                state.data_manager = Some(
                    registry.bind::<zwlr_data_control_manager_v1::ZwlrDataControlManagerV1, _, _>(
                        name,
                        version,
                        qh,
                        (),
                    ),
                );
            }
        }
    }
}

impl Dispatch<wl_seat::WlSeat, ()> for WlClipboardListener {
    fn event(
        state: &mut Self,
        _proxy: &wl_seat::WlSeat,
        event: <wl_seat::WlSeat as Proxy>::Event,
        _data: &(),
        _conn: &wayland_client::Connection,
        _qhandle: &wayland_client::QueueHandle<Self>,
    ) {
        if let wl_seat::Event::Name { name } = event {
            state.seat_name = Some(name);
        }
    }
}

impl Dispatch<zwlr_data_control_manager_v1::ZwlrDataControlManagerV1, ()> for WlClipboardListener {
    fn event(
        _state: &mut Self,
        _proxy: &zwlr_data_control_manager_v1::ZwlrDataControlManagerV1,
        _event: <zwlr_data_control_manager_v1::ZwlrDataControlManagerV1 as Proxy>::Event,
        _data: &(),
        _conn: &wayland_client::Connection,
        _qhandle: &wayland_client::QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<zwlr_data_control_device_v1::ZwlrDataControlDeviceV1, ()> for WlClipboardListener {
    fn event(
        state: &mut Self,
        _proxy: &zwlr_data_control_device_v1::ZwlrDataControlDeviceV1,
        event: <zwlr_data_control_device_v1::ZwlrDataControlDeviceV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        qh: &wayland_client::QueueHandle<Self>,
    ) {
        match event {
            zwlr_data_control_device_v1::Event::DataOffer { id: _id } => {}
            zwlr_data_control_device_v1::Event::Finished => {
                if let Some(source) = state
                    .data_manager
                    .as_ref()
                    .map(|manager| manager.create_data_source(qh, ()))
                {
                    if let Some(device) = state.data_device.as_ref() {
                        device.set_selection(Some(&source));
                    }
                }
            }
            zwlr_data_control_device_v1::Event::PrimarySelection { id } => {
                if let Some(offer) = id {
                    offer.destroy();
                }
            }
            zwlr_data_control_device_v1::Event::Selection { id } => {
                if id.is_some() {
                    state.copied = true;
                }
            }
            _ => {
                log::debug!("Unhandled Wayland clipboard device event: {:?}", event);
            }
        }
    }

    event_created_child!(WlClipboardListener, zwlr_data_control_device_v1::ZwlrDataControlDeviceV1, [
        zwlr_data_control_device_v1::EVT_DATA_OFFER_OPCODE => (zwlr_data_control_offer_v1::ZwlrDataControlOfferV1, ())
    ]);
}

impl Dispatch<zwlr_data_control_source_v1::ZwlrDataControlSourceV1, ()> for WlClipboardListener {
    fn event(
        _state: &mut Self,
        _proxy: &zwlr_data_control_source_v1::ZwlrDataControlSourceV1,
        event: <zwlr_data_control_source_v1::ZwlrDataControlSourceV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qhandle: &wayland_client::QueueHandle<Self>,
    ) {
        if !matches!(
            event,
            zwlr_data_control_source_v1::Event::Send {
                fd: _,
                mime_type: _
            }
        ) {
            log::debug!("Unhandled Wayland clipboard source event: {:?}", event);
        }
    }
}

impl Dispatch<zwlr_data_control_offer_v1::ZwlrDataControlOfferV1, ()> for WlClipboardListener {
    fn event(
        state: &mut Self,
        _proxy: &zwlr_data_control_offer_v1::ZwlrDataControlOfferV1,
        event: <zwlr_data_control_offer_v1::ZwlrDataControlOfferV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qhandle: &wayland_client::QueueHandle<Self>,
    ) {
        if let zwlr_data_control_offer_v1::Event::Offer { mime_type } = event {
            state.mime_types.push(mime_type);
        }
    }
}
