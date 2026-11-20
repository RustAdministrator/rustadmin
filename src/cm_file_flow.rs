//! Flow control for files that the connection manager process reads for a peer.
//!
//! On an installed Windows host the connection manager (the process in the user's session)
//! reads the file and hands every block to the service over IPC, and the service puts it on the
//! network stream. Neither hop used to wait: the manager read on a timer into an unbounded
//! channel, and the service dropped a block when the stream's queue was full. A transfer
//! faster than the link lost blocks in the middle of a file and still reported success.
//!
//! Two small pieces fix that. [`CmFileRelay`] keeps what the manager produced, in order, until
//! the stream takes it. [`ReadAheadWindow`] lets the manager read only a bounded number of
//! blocks ahead of what the service has passed on; the service returns the credit with
//! `ipc::Data::FileBlockAck`.

use hbb_common::message_proto::Message;
use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};

/// Blocks the connection manager may have read but not yet seen acknowledged.
/// 32 blocks of 128 KiB are 4 MiB: enough to keep a fast link busy between acknowledgements.
pub(crate) const CM_READ_AHEAD_BLOCKS: usize = 32;

/// What the relay holds for the stream.
#[derive(Debug)]
pub(crate) enum Relayed {
    Message(Message),
    /// Already serialized bytes from the connection manager.
    Raw(Vec<u8>),
}

#[derive(Debug)]
struct Entry {
    payload: Relayed,
    /// File blocks are the unit the manager's read-ahead window counts.
    is_block: bool,
}

/// Ordered queue between the IPC from the connection manager and the network stream.
#[derive(Debug, Default)]
pub(crate) struct CmFileRelay {
    pending: VecDeque<Entry>,
}

impl CmFileRelay {
    pub(crate) fn push_block(&mut self, message: Message) {
        self.pending.push_back(Entry {
            payload: Relayed::Message(message),
            is_block: true,
        });
    }

    pub(crate) fn push_message(&mut self, message: Message) {
        self.pending.push_back(Entry {
            payload: Relayed::Message(message),
            is_block: false,
        });
    }

    pub(crate) fn push_raw(&mut self, bytes: Vec<u8>) {
        self.pending.push_back(Entry {
            payload: Relayed::Raw(bytes),
            is_block: false,
        });
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    /// The next thing to put on the stream, if any.
    pub(crate) fn front(&self) -> Option<&Relayed> {
        self.pending.front().map(|entry| &entry.payload)
    }

    /// The front entry was accepted by the stream. Returns whether it was a file block.
    pub(crate) fn pop_sent(&mut self) -> bool {
        self.pending
            .pop_front()
            .map(|entry| entry.is_block)
            .unwrap_or(false)
    }

    /// The stream is gone: forget everything and report how many blocks were waiting, so that
    /// the manager's window is not left counting blocks that will never be acknowledged.
    pub(crate) fn clear(&mut self) -> usize {
        let blocks = self.pending.iter().filter(|entry| entry.is_block).count();
        self.pending.clear();
        blocks
    }
}

/// The connection manager's side: how many blocks are on their way to the service.
#[derive(Debug, Default)]
pub(crate) struct ReadAheadWindow {
    in_flight: usize,
}

impl ReadAheadWindow {
    pub(crate) fn can_read(&self) -> bool {
        self.in_flight < CM_READ_AHEAD_BLOCKS
    }

    pub(crate) fn sent(&mut self) {
        self.in_flight = self.in_flight.saturating_add(1);
    }

    pub(crate) fn acknowledged(&mut self, blocks: usize) {
        self.in_flight = self.in_flight.saturating_sub(blocks);
    }

    #[cfg(test)]
    fn in_flight(&self) -> usize {
        self.in_flight
    }
}

/// How often the list of running transfers goes to the user interface while nothing else
/// about it changes.
pub(crate) const TRANSFER_LOG_INTERVAL: Duration = Duration::from_millis(250);

/// Decides when the list of running transfers is reported.
///
/// It used to be serialized and sent on every timer tick and for every block, up to a
/// thousand times a second, and each time became an event for the user interface, which shows
/// progress a few times a second.
#[derive(Debug, Default)]
pub(crate) struct TransferLogThrottle {
    last_report: Option<(Instant, usize)>,
}

impl TransferLogThrottle {
    /// Whether to report now: the number of jobs changed (one started or ended), or the
    /// interval has passed since the last report.
    pub(crate) fn due(&mut self, now: Instant, jobs: usize) -> bool {
        let due = match self.last_report {
            None => true,
            Some((at, reported_jobs)) => {
                reported_jobs != jobs || now.saturating_duration_since(at) >= TRANSFER_LOG_INTERVAL
            }
        };
        if due {
            self.last_report = Some((now, jobs));
        }
        due
    }
}

/// How many blocks the connection manager reads in one of its 5 ms ticks. One per tick held
/// a download from an installed Windows host to about 25 MiB/s.
pub(crate) const CM_READ_STEPS_PER_TICK: usize = 8;

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::message_proto::{FileResponse, FileTransferBlock, FileTransferDone};

    fn block(id: i32, byte: u8) -> Message {
        let mut response = FileResponse::new();
        response.set_block(FileTransferBlock {
            id,
            data: vec![byte; 4].into(),
            ..Default::default()
        });
        let mut message = Message::new();
        message.set_file_response(response);
        message
    }

    fn done(id: i32) -> Message {
        let mut response = FileResponse::new();
        response.set_done(FileTransferDone {
            id,
            ..Default::default()
        });
        let mut message = Message::new();
        message.set_file_response(response);
        message
    }

    /// Drains the relay into `sink` the way the connection does: stop when the stream reports no
    /// room. Returns the blocks released.
    fn drain(relay: &mut CmFileRelay, sink: &mut Vec<String>, mut room: usize) -> usize {
        let mut released = 0;
        while room > 0 {
            let Some(front) = relay.front() else { break };
            sink.push(match front {
                Relayed::Message(message) => format!("{message:?}"),
                Relayed::Raw(bytes) => format!("raw{bytes:?}"),
            });
            room -= 1;
            if relay.pop_sent() {
                released += 1;
            }
        }
        released
    }

    #[test]
    fn nothing_is_lost_or_reordered_when_the_stream_has_no_room() {
        let mut relay = CmFileRelay::default();
        relay.push_message(done(0));
        for byte in 0..5u8 {
            relay.push_block(block(1, byte));
        }
        relay.push_raw(vec![7, 7]);
        relay.push_message(done(1));

        let mut sent = Vec::new();
        // The stream takes two entries, then is full for a while, then takes the rest.
        assert_eq!(drain(&mut relay, &mut sent, 2), 1);
        assert_eq!(drain(&mut relay, &mut sent, 0), 0);
        assert!(!relay.is_empty());
        assert_eq!(drain(&mut relay, &mut sent, 100), 4);
        assert!(relay.is_empty());

        let mut expected = vec![format!("{:?}", done(0))];
        expected.extend((0..5u8).map(|byte| format!("{:?}", block(1, byte))));
        expected.push("raw[7, 7]".to_owned());
        expected.push(format!("{:?}", done(1)));
        assert_eq!(sent, expected);
    }

    #[test]
    fn clearing_reports_the_blocks_that_were_waiting() {
        let mut relay = CmFileRelay::default();
        relay.push_block(block(1, 0));
        relay.push_message(done(1));
        relay.push_block(block(2, 0));
        assert_eq!(relay.clear(), 2);
        assert!(relay.is_empty());
        assert!(relay.front().is_none());
        assert!(!relay.pop_sent());
    }

    #[test]
    fn manager_reads_at_most_the_window_ahead() {
        let mut window = ReadAheadWindow::default();
        let mut read = 0;
        while window.can_read() {
            window.sent();
            read += 1;
        }
        assert_eq!(read, CM_READ_AHEAD_BLOCKS);
        assert!(
            !window.can_read(),
            "no further disk read until an acknowledgement"
        );

        window.acknowledged(1);
        assert!(window.can_read());
        window.sent();
        assert!(!window.can_read());

        // An acknowledgement for more than is in flight (a stale one after a restart) is harmless.
        window.acknowledged(CM_READ_AHEAD_BLOCKS * 2);
        assert_eq!(window.in_flight(), 0);
        assert!(window.can_read());
    }

    #[test]
    fn transfer_list_is_reported_on_a_change_and_a_few_times_a_second() {
        let mut throttle = TransferLogThrottle::default();
        let start = Instant::now();
        let ms = Duration::from_millis;
        assert!(throttle.due(start, 1), "the first report");
        // A thousand ticks in the next quarter of a second: nothing.
        for tick in 1..250 {
            assert!(!throttle.due(start + ms(tick), 1), "tick {}", tick);
        }
        assert!(throttle.due(start + ms(250), 1));
        assert!(!throttle.due(start + ms(251), 1));
        // A job started or ended: at once.
        assert!(throttle.due(start + ms(252), 2));
        assert!(!throttle.due(start + ms(253), 2));
        assert!(throttle.due(start + ms(254), 0));
        assert!(!throttle.due(start + ms(255), 0));
    }
}
