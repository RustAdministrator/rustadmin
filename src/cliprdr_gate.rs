//! The decisions about file clipboard (Cliprdr) messages, in one place.
//!
//! Each of the places that pass these messages on had its own condition. They stopped a
//! *new* exchange when the file clipboard was off and let every other message through "so
//! that a transfer in progress can finish" — which also let a peer send a request out of
//! the blue and have it answered. The rule here: when the file clipboard is off for the
//! session, nothing is processed.

#![cfg_attr(not(target_os = "windows"), allow(dead_code))]

use clipboard::ClipboardFile;
use hbb_common::{config::RolloutMode, log};
use std::sync::atomic::{AtomicU32, Ordering};

/// What to do with a file clipboard message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CliprdrVerdict {
    /// Pass it on.
    Process,
    /// The file clipboard is off and this message would start an exchange: do not pass it
    /// on, and stop the local file clipboard.
    Stop,
    /// The file clipboard is off: do not pass it on.
    Drop,
}

/// The verdict for a message. `starts_exchange` is the caller's notion of a message that
/// opens an exchange (`ClipboardFile::is_beginning_message` for a message from the peer,
/// `is_stopping_allowed` for one from the local clipboard).
pub(crate) fn cliprdr_verdict(file_clipboard_on: bool, starts_exchange: bool) -> CliprdrVerdict {
    match (file_clipboard_on, starts_exchange) {
        (true, _) => CliprdrVerdict::Process,
        (false, true) => CliprdrVerdict::Stop,
        (false, false) => CliprdrVerdict::Drop,
    }
}

/// The most a peer may ask for in one file contents request. The same number is in
/// `wf_cliprdr.c` (`WF_CLIPRDR_MAX_FILE_CONTENTS_REQUEST`), where the buffer is allocated.
/// Not measured against Explorer yet; see [`note_file_contents_request`].
pub(crate) const MAX_FILE_CONTENTS_REQUEST: u32 = 256 * 1024 * 1024;

const FILECONTENTS_SIZE: i32 = 1;
const CB_RESPONSE_FAIL: i32 = 2;

/// The answer to send in place of serving `message`, when it is a request for more file
/// contents than is accepted. Answering, and not just dropping, lets the peer's paste fail
/// at once instead of waiting for a timeout.
pub(crate) fn refusal_for_oversize_request(message: &ClipboardFile) -> Option<ClipboardFile> {
    match message {
        ClipboardFile::FileContentsRequest {
            stream_id,
            dw_flags,
            cb_requested,
            ..
        } if *dw_flags != FILECONTENTS_SIZE
            && (*cb_requested as u32) > MAX_FILE_CONTENTS_REQUEST =>
        {
            Some(ClipboardFile::FileContentsResponse {
                msg_flags: CB_RESPONSE_FAIL,
                stream_id: *stream_id,
                requested_data: Vec::new(),
            })
        }
        _ => None,
    }
}

/// Remembers the largest file contents request seen in this process. Returns the size when
/// `message` is a new maximum of at least 1 MiB, for the caller to log: that is how the
/// largest request of a real paste is measured.
pub(crate) fn note_file_contents_request(message: &ClipboardFile) -> Option<u32> {
    static LARGEST: AtomicU32 = AtomicU32::new(0);
    let ClipboardFile::FileContentsRequest {
        dw_flags,
        cb_requested,
        ..
    } = message
    else {
        return None;
    };
    if *dw_flags == FILECONTENTS_SIZE {
        return None;
    }
    let size = *cb_requested as u32;
    let previous = LARGEST.fetch_max(size, Ordering::Relaxed);
    (size > previous && size >= 1024 * 1024).then_some(size)
}

/// Which way the files of a message go, seen from the side that sends the message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Flow {
    /// The sender offers or delivers its files.
    FromSender,
    /// The sender asks for the receiver's files.
    ToSender,
    Neither,
}

fn flow(message: &ClipboardFile) -> Flow {
    match message {
        ClipboardFile::FormatList { .. }
        | ClipboardFile::FormatDataResponse { .. }
        | ClipboardFile::FileContentsResponse { .. } => Flow::FromSender,
        ClipboardFile::FormatDataRequest { .. } | ClipboardFile::FileContentsRequest { .. } => {
            Flow::ToSender
        }
        _ => Flow::Neither,
    }
}

/// Whether `message` moves files in a direction that the clipboard direction policy of this
/// side does not allow. `outgoing`: this side sends the message; otherwise it came from the
/// peer. "Local" is this side.
pub(crate) fn crosses_direction_policy(
    message: &ClipboardFile,
    outgoing: bool,
    local_to_remote_allowed: bool,
    remote_to_local_allowed: bool,
) -> bool {
    let local_to_remote = match (flow(message), outgoing) {
        (Flow::Neither, _) => return false,
        (Flow::FromSender, true) | (Flow::ToSender, false) => true,
        (Flow::FromSender, false) | (Flow::ToSender, true) => false,
    };
    if local_to_remote {
        !local_to_remote_allowed
    } else {
        !remote_to_local_allowed
    }
}

/// What the rollout mode makes of a message that crosses the direction policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DirectionVerdict {
    Pass,
    /// Let it through and say so in the log.
    WarnAndPass,
    Refuse,
}

pub(crate) fn direction_verdict(mode: RolloutMode, crosses: bool) -> DirectionVerdict {
    match (crosses, mode) {
        (false, _) | (true, RolloutMode::Off) => DirectionVerdict::Pass,
        (true, RolloutMode::Warn) => DirectionVerdict::WarnAndPass,
        (true, RolloutMode::Enforce) => DirectionVerdict::Refuse,
    }
}

/// Applies the direction policy to one message and returns whether it may pass. In warn mode
/// the message passes and a warning is logged, at most once a minute.
pub(crate) fn direction_check_passes(
    message: &ClipboardFile,
    outgoing: bool,
    local_to_remote_allowed: bool,
    remote_to_local_allowed: bool,
    where_: &str,
) -> bool {
    let crosses = crosses_direction_policy(
        message,
        outgoing,
        local_to_remote_allowed,
        remote_to_local_allowed,
    );
    match direction_verdict(
        hbb_common::config::file_clipboard_direction_check_mode(),
        crosses,
    ) {
        DirectionVerdict::Pass => true,
        DirectionVerdict::WarnAndPass => {
            static LAST_WARNING_SECS: AtomicU32 = AtomicU32::new(0);
            let now = hbb_common::get_time() as u64 / 1000;
            let now = now.min(u64::from(u32::MAX)) as u32;
            let last = LAST_WARNING_SECS.load(Ordering::Relaxed);
            if now.saturating_sub(last) >= 60 || last == 0 {
                LAST_WARNING_SECS.store(now.max(1), Ordering::Relaxed);
                log::warn!(
                    "{}: a file clipboard message ({}) crosses against the clipboard direction policy; it is let through because file-clipboard-direction-check is in warn mode",
                    where_,
                    if outgoing { "sent" } else { "received" }
                );
            }
            true
        }
        DirectionVerdict::Refuse => {
            log::warn!(
                "{}: a file clipboard message ({}) crosses against the clipboard direction policy and is refused",
                where_,
                if outgoing { "sent" } else { "received" }
            );
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn contents_request(dw_flags: i32, cb_requested: u32) -> ClipboardFile {
        ClipboardFile::FileContentsRequest {
            stream_id: 5,
            list_index: 0,
            dw_flags,
            n_position_low: 0,
            n_position_high: 0,
            cb_requested: cb_requested as i32,
            have_clip_data_id: false,
            clip_data_id: 0,
        }
    }

    fn every_kind() -> Vec<ClipboardFile> {
        vec![
            ClipboardFile::MonitorReady,
            ClipboardFile::FormatList {
                format_list: vec![],
            },
            ClipboardFile::FormatListResponse { msg_flags: 1 },
            ClipboardFile::FormatDataRequest {
                requested_format_id: 13,
            },
            ClipboardFile::FormatDataResponse {
                msg_flags: 1,
                format_data: vec![],
            },
            contents_request(2, 1024),
            ClipboardFile::FileContentsResponse {
                msg_flags: 1,
                stream_id: 5,
                requested_data: vec![],
            },
            ClipboardFile::TryEmpty,
        ]
    }

    #[test]
    fn nothing_is_processed_while_the_file_clipboard_is_off() {
        for message in every_kind() {
            // From the peer and from the local clipboard, by each caller's own notion of a
            // message that opens an exchange.
            for starts_exchange in [
                message.is_beginning_message(),
                message.is_stopping_allowed(),
            ] {
                assert_eq!(
                    cliprdr_verdict(true, starts_exchange),
                    CliprdrVerdict::Process
                );
                assert_ne!(
                    cliprdr_verdict(false, starts_exchange),
                    CliprdrVerdict::Process,
                    "{:?}",
                    message
                );
            }
        }
        // A request out of the blue, which used to be answered with the file clipboard off.
        let request = ClipboardFile::FormatDataRequest {
            requested_format_id: 13,
        };
        assert_eq!(
            cliprdr_verdict(false, request.is_beginning_message()),
            CliprdrVerdict::Drop
        );
        assert_eq!(cliprdr_verdict(false, true), CliprdrVerdict::Stop);
    }

    #[test]
    fn oversize_contents_request_is_refused_with_an_answer() {
        assert!(
            refusal_for_oversize_request(&contents_request(2, MAX_FILE_CONTENTS_REQUEST)).is_none()
        );
        assert!(refusal_for_oversize_request(&contents_request(2, 64 * 1024)).is_none());
        // The size of a file is asked for with a fixed answer; the field does not matter.
        assert!(refusal_for_oversize_request(&contents_request(1, u32::MAX)).is_none());
        for size in [MAX_FILE_CONTENTS_REQUEST + 1, 0x8000_0000, u32::MAX] {
            match refusal_for_oversize_request(&contents_request(2, size)) {
                Some(ClipboardFile::FileContentsResponse {
                    msg_flags,
                    stream_id,
                    requested_data,
                }) => {
                    assert_eq!((msg_flags, stream_id), (CB_RESPONSE_FAIL, 5));
                    assert!(requested_data.is_empty());
                }
                other => panic!("{}: {:?}", size, other),
            }
        }
        assert!(refusal_for_oversize_request(&ClipboardFile::MonitorReady).is_none());
    }

    #[test]
    fn largest_contents_request_is_reported_once() {
        // The counter is shared by the process; use sizes no other test uses.
        let base = 200 * 1024 * 1024;
        assert_eq!(
            note_file_contents_request(&contents_request(2, base)),
            Some(base)
        );
        assert_eq!(note_file_contents_request(&contents_request(2, base)), None);
        assert_eq!(
            note_file_contents_request(&contents_request(2, base - 1)),
            None
        );
        assert_eq!(
            note_file_contents_request(&contents_request(2, base + 1)),
            Some(base + 1)
        );
        assert_eq!(
            note_file_contents_request(&contents_request(1, u32::MAX)),
            None
        );
        assert_eq!(note_file_contents_request(&ClipboardFile::TryEmpty), None);
    }

    #[test]
    fn direction_of_each_message() {
        let offer = ClipboardFile::FormatList {
            format_list: vec![],
        };
        let data = ClipboardFile::FileContentsResponse {
            msg_flags: 1,
            stream_id: 1,
            requested_data: vec![1],
        };
        let request = contents_request(2, 4096);
        // (message, outgoing, local-to-remote allowed, remote-to-local allowed, crosses)
        let table = [
            // Everything allowed: nothing crosses.
            (&offer, true, true, true, false),
            (&request, false, true, true, false),
            // This side may not give files to the other.
            (&offer, true, false, true, true),
            (&data, true, false, true, true),
            (&request, false, false, true, true),
            (&offer, false, false, true, false),
            (&request, true, false, true, false),
            // This side may not take files from the other.
            (&offer, false, true, false, true),
            (&data, false, true, false, true),
            (&request, true, true, false, true),
            (&offer, true, true, false, false),
            (&request, false, true, false, false),
        ];
        for (index, (message, outgoing, out_allowed, in_allowed, crosses)) in
            table.iter().enumerate()
        {
            assert_eq!(
                crosses_direction_policy(message, *outgoing, *out_allowed, *in_allowed),
                *crosses,
                "row {}",
                index
            );
        }
        // Messages that move no files never cross, whatever the policy.
        for message in [
            ClipboardFile::MonitorReady,
            ClipboardFile::TryEmpty,
            ClipboardFile::FormatListResponse { msg_flags: 1 },
        ] {
            assert!(!crosses_direction_policy(&message, true, false, false));
            assert!(!crosses_direction_policy(&message, false, false, false));
        }
    }

    #[test]
    fn rollout_mode_decides_what_a_crossing_message_gets() {
        use DirectionVerdict::*;
        for mode in [RolloutMode::Off, RolloutMode::Warn, RolloutMode::Enforce] {
            assert_eq!(direction_verdict(mode, false), Pass);
        }
        assert_eq!(direction_verdict(RolloutMode::Off, true), Pass);
        assert_eq!(direction_verdict(RolloutMode::Warn, true), WarnAndPass);
        assert_eq!(direction_verdict(RolloutMode::Enforce, true), Refuse);
        assert_eq!(
            hbb_common::config::FILE_CLIPBOARD_DIRECTION_CHECK_DEFAULT,
            RolloutMode::Warn
        );
    }
}
