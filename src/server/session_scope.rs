//! What each kind of authorized session may send.
//!
//! A file-transfer, terminal, tunnel or camera session is authorized for that
//! one thing. The message handlers were written for remote desktop and accept
//! whatever arrives, so a peer could use a session it was granted for one
//! purpose to reach another (input injection through a file-transfer session,
//! display control through a terminal, and so on). This module classifies the
//! messages the host actually acts on and says which session types may send
//! them; everything not listed is housekeeping that every type may send.
//!
//! The decision is pure; the connection applies it, drops what is refused and
//! logs each violating family once.

use super::connection::AuthConnType;
use hbb_common::message_proto::{message, misc, Message, OptionMessage};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ScopeClass {
    /// Heartbeat, chat, debug, permission requests, video feedback broadcast
    /// that every session may send, and anything the host does not act on.
    Housekeeping,
    /// Mouse, key, pointer and keyboard-v2 input.
    RemoteInput,
    /// Text clipboard data (`Clipboard`, `MultiClipboards`).
    Clipboard,
    /// File clipboard protocol (`Cliprdr`).
    FileClipboard,
    /// `FileAction`, `FileResponse`.
    FileTransfer,
    /// `TerminalAction`.
    Terminal,
    /// Choosing, adding or querying displays and screenshots.
    Display,
    /// Video refresh and feedback that the viewer broadcasts to every session.
    VideoBroadcast,
    /// Audio data and voice calls.
    Audio,
    /// Elevation, privacy mode, virtual displays, resolution, restart,
    /// switching sides, plugins.
    PlatformControl,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ScopeDecision {
    Permit,
    /// Not allowed for this session type but legitimately broadcast by older
    /// viewers: dropped without a log line.
    Ignore,
    /// Not allowed and not something a shipped viewer sends: dropped and
    /// reported once per family.
    Violation(&'static str),
}

pub(crate) fn classify(msg: &Message) -> ScopeClass {
    use ScopeClass::*;
    match &msg.union {
        Some(message::Union::MouseEvent(_))
        | Some(message::Union::PointerDeviceEvent(_))
        | Some(message::Union::KeyEvent(_))
        | Some(message::Union::KeyboardInput(_)) => RemoteInput,
        Some(message::Union::Clipboard(_)) | Some(message::Union::MultiClipboards(_)) => Clipboard,
        Some(message::Union::Cliprdr(_)) => FileClipboard,
        Some(message::Union::FileAction(_)) | Some(message::Union::FileResponse(_)) => FileTransfer,
        Some(message::Union::TerminalAction(_)) => Terminal,
        Some(message::Union::ScreenshotRequest(_)) => Display,
        Some(message::Union::AudioFrame(_))
        | Some(message::Union::VoiceCallRequest(_))
        | Some(message::Union::VoiceCallResponse(_)) => Audio,
        Some(message::Union::Misc(m)) => match &m.union {
            Some(misc::Union::SwitchDisplay(_))
            | Some(misc::Union::CaptureDisplays(_))
            | Some(misc::Union::MessageQuery(_))
            | Some(misc::Union::FollowCurrentDisplay(_))
            | Some(misc::Union::SelectedSid(_)) => Display,
            Some(misc::Union::RefreshVideo(_))
            | Some(misc::Union::RefreshVideoDisplay(_))
            | Some(misc::Union::VideoReceived(_))
            | Some(misc::Union::VideoFeedback(_))
            | Some(misc::Union::VideoReferenceRefresh(_))
            | Some(misc::Union::AutoAdjustFps(_))
            | Some(misc::Union::FullSpeedFps(_))
            | Some(misc::Union::ClientRecordStatus(_)) => VideoBroadcast,
            Some(misc::Union::AudioFormat(_)) => Audio,
            Some(misc::Union::ElevationRequest(_))
            | Some(misc::Union::ToggleVirtualDisplay(_))
            | Some(misc::Union::TogglePrivacyMode(_))
            | Some(misc::Union::ChangeResolution(_))
            | Some(misc::Union::ChangeDisplayResolution(_))
            | Some(misc::Union::RestartRemoteDevice(_))
            | Some(misc::Union::SwitchSidesRequest(_))
            | Some(misc::Union::PluginRequest(_)) => PlatformControl,
            _ => Housekeeping,
        },
        _ => Housekeeping,
    }
}

pub(crate) fn scope_permits(conn_type: AuthConnType, class: ScopeClass) -> ScopeDecision {
    use AuthConnType as T;
    use ScopeClass as C;
    use ScopeDecision::*;
    match (class, conn_type) {
        (C::Housekeeping, _) => Permit,
        // Remote desktop is what the handlers were written for.
        (_, T::Remote) => Permit,

        (C::RemoteInput, T::ViewCamera) => Ignore,
        (C::RemoteInput, _) => Violation("input"),

        (C::Clipboard, _) => Ignore,
        (C::FileClipboard, _) => Violation("file clipboard"),

        (C::FileTransfer, T::FileTransfer) => Permit,
        (C::FileTransfer, _) => Violation("file transfer"),

        (C::Terminal, T::Terminal) => Permit,
        (C::Terminal, _) => Violation("terminal"),

        (C::Display, T::ViewCamera) => Permit,
        (C::Display, _) => Violation("display"),

        (C::VideoBroadcast, T::ViewCamera) => Permit,
        (C::VideoBroadcast, _) => Ignore,

        (C::Audio, T::ViewCamera) => Permit,
        (C::Audio, _) => Ignore,

        (C::PlatformControl, T::ViewCamera) => Ignore,
        (C::PlatformControl, _) => Violation("platform control"),
    }
}

/// Decision for one authorized message of a session of this type.
pub(crate) fn decide(conn_type: AuthConnType, msg: &Message) -> ScopeDecision {
    // `SelectedSid` is how a Windows file-transfer viewer picks the session
    // whose directory it lists.
    if conn_type == AuthConnType::FileTransfer {
        if let Some(message::Union::Misc(m)) = &msg.union {
            if matches!(&m.union, Some(misc::Union::SelectedSid(_))) {
                return ScopeDecision::Permit;
            }
        }
    }
    scope_permits(conn_type, classify(msg))
}

/// The part of an option message a session of this type may apply. Remote
/// desktop gets all of it. Other types get only the options that make sense
/// for them, so that for instance a terminal session cannot change the
/// capture backend or lock the screen.
pub(crate) fn scoped_option(conn_type: AuthConnType, o: &OptionMessage) -> OptionMessage {
    match conn_type {
        AuthConnType::Remote => o.clone(),
        AuthConnType::Terminal => OptionMessage {
            terminal_persistent: o.terminal_persistent,
            ..Default::default()
        },
        AuthConnType::ViewCamera => OptionMessage {
            image_quality: o.image_quality,
            custom_image_quality: o.custom_image_quality,
            custom_fps: o.custom_fps,
            supported_decoding: o.supported_decoding.clone(),
            disable_audio: o.disable_audio,
            video_profile: o.video_profile,
            ..Default::default()
        },
        // The decoder preference is broadcast to every session; nothing else.
        AuthConnType::FileTransfer | AuthConnType::PortForward => OptionMessage {
            supported_decoding: o.supported_decoding.clone(),
            ..Default::default()
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::message_proto::{
        option_message::{BoolOption, CaptureBackend, VideoProfile},
        CaptureDisplays, ChatMessage, Clipboard, ElevationRequest, FileAction, KeyEvent, Misc,
        MouseEvent, SwitchDisplay, TerminalAction, TestDelay,
    };

    const ALL: [AuthConnType; 5] = [
        AuthConnType::Remote,
        AuthConnType::FileTransfer,
        AuthConnType::PortForward,
        AuthConnType::ViewCamera,
        AuthConnType::Terminal,
    ];

    fn msg(union: message::Union) -> Message {
        Message {
            union: Some(union),
            ..Default::default()
        }
    }

    fn misc_msg(union: misc::Union) -> Message {
        msg(message::Union::Misc(Misc {
            union: Some(union),
            ..Default::default()
        }))
    }

    #[test]
    fn housekeeping_is_open_to_every_session_type() {
        let heartbeat = msg(message::Union::TestDelay(TestDelay::new()));
        let chat = misc_msg(misc::Union::ChatMessage(ChatMessage::new()));
        let close = misc_msg(misc::Union::CloseReason("bye".to_owned()));
        for conn_type in ALL {
            for message in [&heartbeat, &chat, &close] {
                assert_eq!(
                    decide(conn_type, message),
                    ScopeDecision::Permit,
                    "{conn_type:?}"
                );
            }
        }
    }

    #[test]
    fn remote_desktop_is_not_filtered() {
        let all = [
            msg(message::Union::MouseEvent(MouseEvent::new())),
            msg(message::Union::KeyEvent(KeyEvent::new())),
            msg(message::Union::TerminalAction(TerminalAction::new())),
            msg(message::Union::FileAction(FileAction::new())),
            misc_msg(misc::Union::ElevationRequest(ElevationRequest::new())),
            misc_msg(misc::Union::CaptureDisplays(CaptureDisplays::new())),
        ];
        for message in &all {
            assert_eq!(decide(AuthConnType::Remote, message), ScopeDecision::Permit);
        }
    }

    #[test]
    fn a_file_transfer_session_cannot_inject_input_or_control_displays() {
        let mouse = msg(message::Union::MouseEvent(MouseEvent::new()));
        let key = msg(message::Union::KeyEvent(KeyEvent::new()));
        let capture = misc_msg(misc::Union::CaptureDisplays(CaptureDisplays::new()));
        let switch = misc_msg(misc::Union::SwitchDisplay(SwitchDisplay::new()));
        for conn_type in [
            AuthConnType::FileTransfer,
            AuthConnType::PortForward,
            AuthConnType::Terminal,
        ] {
            for message in [&mouse, &key] {
                assert_eq!(
                    decide(conn_type, message),
                    ScopeDecision::Violation("input")
                );
            }
            for message in [&capture, &switch] {
                assert_eq!(
                    decide(conn_type, message),
                    ScopeDecision::Violation("display")
                );
            }
        }
        // Its own protocol is fine.
        let file = msg(message::Union::FileAction(FileAction::new()));
        assert_eq!(
            decide(AuthConnType::FileTransfer, &file),
            ScopeDecision::Permit
        );
        for other in [
            AuthConnType::PortForward,
            AuthConnType::ViewCamera,
            AuthConnType::Terminal,
        ] {
            assert_eq!(
                decide(other, &file),
                ScopeDecision::Violation("file transfer")
            );
        }
    }

    #[test]
    fn terminal_actions_belong_to_terminal_sessions_only() {
        let action = msg(message::Union::TerminalAction(TerminalAction::new()));
        assert_eq!(
            decide(AuthConnType::Terminal, &action),
            ScopeDecision::Permit
        );
        assert_eq!(decide(AuthConnType::Remote, &action), ScopeDecision::Permit);
        for conn_type in [
            AuthConnType::FileTransfer,
            AuthConnType::PortForward,
            AuthConnType::ViewCamera,
        ] {
            assert_eq!(
                decide(conn_type, &action),
                ScopeDecision::Violation("terminal")
            );
        }
    }

    #[test]
    fn camera_sessions_keep_display_control_and_drop_legacy_input_quietly() {
        let capture = misc_msg(misc::Union::CaptureDisplays(CaptureDisplays::new()));
        assert_eq!(
            decide(AuthConnType::ViewCamera, &capture),
            ScopeDecision::Permit
        );
        let mouse = msg(message::Union::MouseEvent(MouseEvent::new()));
        assert_eq!(
            decide(AuthConnType::ViewCamera, &mouse),
            ScopeDecision::Ignore
        );
        let elevate = misc_msg(misc::Union::ElevationRequest(ElevationRequest::new()));
        assert_eq!(
            decide(AuthConnType::ViewCamera, &elevate),
            ScopeDecision::Ignore
        );
        let clipboard = msg(message::Union::Clipboard(Clipboard::new()));
        assert_eq!(
            decide(AuthConnType::ViewCamera, &clipboard),
            ScopeDecision::Ignore
        );
    }

    #[test]
    fn broadcasts_are_tolerated_without_a_violation() {
        for union in [
            misc::Union::RefreshVideo(true),
            misc::Union::RefreshVideoDisplay(0),
            misc::Union::VideoReceived(true),
        ] {
            let message = misc_msg(union);
            for conn_type in [
                AuthConnType::FileTransfer,
                AuthConnType::PortForward,
                AuthConnType::Terminal,
            ] {
                assert_eq!(decide(conn_type, &message), ScopeDecision::Ignore);
            }
            assert_eq!(
                decide(AuthConnType::ViewCamera, &message),
                ScopeDecision::Permit
            );
        }
    }

    #[test]
    fn a_file_transfer_viewer_may_select_the_session() {
        let selected = misc_msg(misc::Union::SelectedSid(1));
        assert_eq!(
            decide(AuthConnType::FileTransfer, &selected),
            ScopeDecision::Permit
        );
        assert_eq!(
            decide(AuthConnType::Terminal, &selected),
            ScopeDecision::Violation("display")
        );
    }

    #[test]
    fn options_are_cut_down_per_session_type() {
        let all = OptionMessage {
            custom_image_quality: 50,
            custom_fps: 30,
            disable_audio: BoolOption::Yes.into(),
            terminal_persistent: BoolOption::Yes.into(),
            lock_after_session_end: BoolOption::Yes.into(),
            privacy_mode: BoolOption::Yes.into(),
            block_input: BoolOption::Yes.into(),
            disable_keyboard: BoolOption::Yes.into(),
            capture_backend: CaptureBackend::CaptureBackendGdi.into(),
            video_profile: VideoProfile::VideoProfileMovie.into(),
            ..Default::default()
        };
        assert_eq!(scoped_option(AuthConnType::Remote, &all), all);

        let terminal = scoped_option(AuthConnType::Terminal, &all);
        assert_eq!(terminal.terminal_persistent, all.terminal_persistent);
        assert_eq!(
            terminal.capture_backend,
            OptionMessage::default().capture_backend
        );
        assert_eq!(
            terminal.lock_after_session_end,
            OptionMessage::default().lock_after_session_end
        );
        assert_eq!(terminal.custom_fps, 0);

        let camera = scoped_option(AuthConnType::ViewCamera, &all);
        assert_eq!(camera.custom_fps, 30);
        assert_eq!(camera.custom_image_quality, 50);
        assert_eq!(camera.disable_audio, all.disable_audio);
        assert_eq!(camera.video_profile, all.video_profile);
        // Host-wide effects stay out of a camera session.
        assert_eq!(
            camera.capture_backend,
            OptionMessage::default().capture_backend
        );
        assert_eq!(camera.privacy_mode, OptionMessage::default().privacy_mode);
        assert_eq!(camera.block_input, OptionMessage::default().block_input);
        assert_eq!(
            camera.lock_after_session_end,
            OptionMessage::default().lock_after_session_end
        );

        for conn_type in [AuthConnType::FileTransfer, AuthConnType::PortForward] {
            let scoped = scoped_option(conn_type, &all);
            assert_eq!(scoped.custom_fps, 0);
            assert_eq!(scoped.disable_audio, OptionMessage::default().disable_audio);
            assert_eq!(
                scoped.terminal_persistent,
                OptionMessage::default().terminal_persistent
            );
        }
    }
}
