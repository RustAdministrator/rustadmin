#[cfg(all(
    target_os = "android",
    feature = "hwcodec",
    not(feature = "mediacodec")
))]
compile_error!("Android hwcodec builds must enable the mediacodec Cargo feature.");
#[cfg(all(
    target_os = "android",
    feature = "mediacodec",
    not(feature = "hwcodec")
))]
compile_error!("Android mediacodec builds must enable the hwcodec Cargo feature.");
#[cfg(all(not(target_os = "android"), feature = "mediacodec"))]
compile_error!("The mediacodec Cargo feature is supported only on Android.");
#[cfg(all(not(target_os = "windows"), feature = "vram"))]
compile_error!("The vram Cargo feature is supported only on Windows.");
#[cfg(all(not(target_os = "linux"), feature = "linux-pkg-config"))]
compile_error!("The linux-pkg-config Cargo feature is supported only on Linux.");
#[cfg(all(not(target_os = "macos"), feature = "screencapturekit"))]
compile_error!("The screencapturekit Cargo feature is supported only on macOS.");

mod keyboard;
/// cbindgen:ignore
pub mod platform;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub use platform::{
    clip_cursor, get_cursor, get_cursor_data, get_cursor_pos, get_focused_display, set_cursor_pos,
    start_os_service,
};
#[cfg(not(any(target_os = "ios")))]
/// cbindgen:ignore
mod server;
#[cfg(not(any(target_os = "ios")))]
pub use self::server::*;
mod client;
mod lan;
#[cfg(not(any(target_os = "ios")))]
mod rendezvous_mediator;
#[cfg(not(any(target_os = "ios")))]
pub use self::rendezvous_mediator::*;
/// cbindgen:ignore
pub mod common;
#[cfg(not(any(target_os = "ios")))]
pub mod ipc;
#[cfg(not(any(
    target_os = "android",
    target_os = "ios",
    feature = "cli",
    feature = "flutter"
)))]
pub mod ui;
mod version;
pub use version::*;
mod video_profile;
#[cfg(any(target_os = "android", target_os = "ios", feature = "flutter"))]
mod bridge_generated;
#[cfg(any(target_os = "android", target_os = "ios", feature = "flutter"))]
pub mod flutter;
#[cfg(any(target_os = "android", target_os = "ios", feature = "flutter"))]
pub mod flutter_ffi;
use common::*;
mod auth_2fa;
#[cfg(feature = "cli")]
pub mod cli;
#[cfg(not(target_os = "ios"))]
mod clipboard;
#[cfg(target_os = "linux")]
mod clipboard_wayland_listener;
#[cfg(not(any(target_os = "android", target_os = "ios", feature = "cli")))]
pub mod core_main;
mod custom_server;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
mod diagnostics;
mod lang;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
mod port_forward;

#[cfg(all(feature = "flutter", feature = "plugin_framework"))]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub mod plugin;

#[cfg(not(any(target_os = "android", target_os = "ios")))]
mod tray;

#[cfg(not(any(target_os = "android", target_os = "ios")))]
mod whiteboard;

#[cfg(not(any(target_os = "android", target_os = "ios")))]
mod updater;

mod ui_cm_interface;
mod ui_interface;
mod ui_session_interface;

mod hbbs_http;

#[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
pub mod clipboard_file;

pub mod privacy_mode;

#[cfg(windows)]
pub mod virtual_display_manager;

mod kcp_stream;

#[cfg(feature = "quic-transport")]
mod quic_transport;
