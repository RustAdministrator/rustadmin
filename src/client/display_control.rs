//! Connection-local admission of the latest desired display set (not a host ack).
use super::DisplayMediaIntent;
use hbb_common::message_proto::{CaptureDisplays, Message, Misc, SwitchDisplay};

pub(super) fn replacement_refresh_required(
    supports_set: bool,
    desktop_viewer: bool,
    display_set_starts_capture: bool,
) -> bool {
    // Updated hosts start new subscriptions and detect resolution changes on
    // their capture loop. Older desktop hosts retain the compatibility refresh.
    supports_set && desktop_viewer && !display_set_starts_capture
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum DisplayControlCommand {
    Set(Vec<i32>),
    Select(i32),
    Replace {
        display: i32,
        width: i32,
        height: i32,
    },
    Refresh(i32),
}

impl DisplayControlCommand {
    pub(super) fn message(&self) -> Message {
        let mut misc = Misc::new();
        match self {
            Self::Set(set) => misc.set_capture_displays(CaptureDisplays {
                set: set.clone(),
                ..Default::default()
            }),
            // Metadata/current-display synchronization only. Never resize or refresh
            // a retained display; explicit replacement keeps its compatibility path.
            Self::Select(display) => misc.set_switch_display(SwitchDisplay {
                display: *display,
                ..Default::default()
            }),
            Self::Replace {
                display,
                width,
                height,
            } => misc.set_switch_display(SwitchDisplay {
                display: *display,
                width: *width,
                height: *height,
                ..Default::default()
            }),
            Self::Refresh(display) => misc.set_refresh_video_display(*display),
        }
        let mut message = Message::new();
        message.set_misc(misc);
        message
    }
}

#[derive(Default)]
pub(super) struct DisplayIntentOutbox {
    round: u32,
    generation: Option<(u64, u64)>,
    desired: Vec<i32>,
    admitted: Option<Vec<i32>>,
    selected: Option<i32>,
    metadata_selection: Option<i32>,
    failures: u64,
    replacement_generation: Option<(u64, u64)>,
    replacement: Option<DisplayControlCommand>,
    refresh_replacement: bool,
}

impl DisplayIntentOutbox {
    pub(super) fn new(round: u32) -> Self {
        Self {
            round,
            ..Self::default()
        }
    }

    pub(super) fn observe(&mut self, round: u32, intent: &DisplayMediaIntent) {
        if round != self.round || intent.aggregate_generation == 0 {
            return;
        }
        let generation = (
            intent.logical_session_generation,
            intent.aggregate_generation,
        );
        if self.generation.is_some_and(|current| generation <= current) {
            return;
        }
        if self
            .generation
            .is_some_and(|current| current.0 != generation.0)
        {
            self.admitted = None;
            self.selected = None;
            self.metadata_selection = None;
        }
        self.generation = Some(generation);
        self.replacement = None;
        self.desired.clear();
        self.desired.extend(
            intent
                .displays
                .iter()
                .filter_map(|entry| i32::try_from(entry.display).ok()),
        );
        self.desired.sort_unstable();
        self.desired.dedup();
    }

    pub(super) fn replace(
        &mut self,
        round: u32,
        intent: &DisplayMediaIntent,
        display: i32,
        size: (i32, i32),
        refresh: bool,
    ) {
        let generation = (
            intent.logical_session_generation,
            intent.aggregate_generation,
        );
        if round != self.round
            || self.generation != Some(generation)
            || self.replacement_generation == Some(generation)
            || self.desired.as_slice() != [display]
        {
            return;
        }
        self.replacement_generation = Some(generation);
        self.replacement = Some(DisplayControlCommand::Replace {
            display,
            width: size.0,
            height: size.1,
        });
        self.refresh_replacement = refresh;
    }

    pub(super) fn pending(&self, round: u32, supports_set: bool) -> Option<DisplayControlCommand> {
        if round != self.round || self.generation.is_none() {
            return None;
        }
        if supports_set && self.admitted.as_ref() != Some(&self.desired) {
            return Some(DisplayControlCommand::Set(self.desired.clone()));
        }
        if let Some(command) = &self.replacement {
            return Some(command.clone());
        }
        if self.desired.len() == 1 && self.selected != Some(self.desired[0]) {
            return Some(DisplayControlCommand::Select(self.desired[0]));
        }
        // Pre-multi-display peers have no aggregate unsubscribe operation. Do not
        // translate an empty set into selecting an arbitrary display.
        None
    }

    pub(super) fn admit(&mut self, round: u32, command: &DisplayControlCommand) {
        if round != self.round {
            return;
        }
        match command {
            DisplayControlCommand::Set(set) if *set == self.desired => {
                self.admitted = Some(set.clone());
                if set.len() != 1 {
                    self.selected = None;
                }
            }
            DisplayControlCommand::Select(display) if self.desired.as_slice() == [*display] => {
                self.selected = Some(*display);
                self.metadata_selection = Some(*display);
            }
            DisplayControlCommand::Replace { display, .. }
                if self.replacement.as_ref() == Some(command) =>
            {
                self.selected = Some(*display);
                self.replacement = self
                    .refresh_replacement
                    .then_some(DisplayControlCommand::Refresh(*display));
            }
            DisplayControlCommand::Refresh(_) if self.replacement.as_ref() == Some(command) => {
                self.replacement = None;
            }
            _ => return,
        }
        self.failures = 0;
    }

    pub(super) fn record_failure(&mut self) -> bool {
        self.failures = self.failures.saturating_add(1);
        self.failures.is_power_of_two()
    }

    pub(super) fn take_metadata_selection(&mut self, display: i32) -> bool {
        if self.metadata_selection == Some(display) {
            self.metadata_selection = None;
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::DisplayActivation;
    use hbb_common::tokio;

    #[test]
    fn replacement_refresh_is_only_an_older_desktop_host_fallback() {
        assert!(replacement_refresh_required(true, true, false));
        assert!(!replacement_refresh_required(true, true, true));
        assert!(!replacement_refresh_required(true, false, false));
        assert!(!replacement_refresh_required(false, true, false));
    }

    fn intent(generation: u64, displays: &[usize]) -> DisplayMediaIntent {
        DisplayMediaIntent {
            logical_session_generation: 1,
            aggregate_generation: generation,
            replacement_display: None,
            displays: displays
                .iter()
                .map(|display| DisplayActivation {
                    display: *display,
                    generation: 1,
                    view_count: 1,
                })
                .collect(),
        }
    }

    fn drain(
        outbox: &mut DisplayIntentOutbox,
        round: u32,
        supports_set: bool,
    ) -> Vec<DisplayControlCommand> {
        let mut commands = Vec::new();
        while let Some(command) = outbox.pending(round, supports_set) {
            outbox.admit(round, &command);
            commands.push(command);
        }
        commands
    }

    #[test]
    fn admission_coalesces_failed_updates_and_retries_empty_set() {
        let mut outbox = DisplayIntentOutbox::new(1);
        outbox.observe(1, &intent(1, &[0, 1]));
        for _ in 0..100 {
            assert_eq!(
                outbox.pending(1, true),
                Some(DisplayControlCommand::Set(vec![0, 1]))
            );
            outbox.record_failure();
        }
        outbox.observe(1, &intent(2, &[1]));
        assert_eq!(
            drain(&mut outbox, 1, true),
            vec![
                DisplayControlCommand::Set(vec![1]),
                DisplayControlCommand::Select(1)
            ]
        );
        outbox.observe(1, &intent(3, &[]));
        assert_eq!(
            drain(&mut outbox, 1, true),
            vec![DisplayControlCommand::Set(vec![])]
        );
    }

    #[test]
    fn stale_events_and_old_connection_admission_cannot_clear_latest_work() {
        let mut outbox = DisplayIntentOutbox::new(2);
        outbox.observe(2, &intent(2, &[1]));
        outbox.observe(2, &intent(1, &[0]));
        outbox.observe(1, &intent(3, &[2]));
        assert!(outbox.pending(1, true).is_none());
        outbox.admit(1, &DisplayControlCommand::Set(vec![1]));
        assert_eq!(
            outbox.pending(2, true),
            Some(DisplayControlCommand::Set(vec![1]))
        );
        outbox.admit(2, &DisplayControlCommand::Set(vec![0]));
        assert_eq!(
            outbox.pending(2, true),
            Some(DisplayControlCommand::Set(vec![1]))
        );
    }

    #[test]
    fn shared_view_changes_do_not_resend_an_admitted_set() {
        let mut outbox = DisplayIntentOutbox::new(1);
        outbox.observe(1, &intent(1, &[1]));
        drain(&mut outbox, 1, true);
        let mut shared = intent(2, &[1]);
        shared.displays[0].view_count = 2;
        outbox.observe(1, &shared);
        assert!(outbox.pending(1, true).is_none());
        outbox.observe(1, &intent(3, &[1]));
        assert!(outbox.pending(1, true).is_none());
    }

    #[test]
    fn reconnect_replays_even_an_unchanged_set() {
        let mut first = DisplayIntentOutbox::new(1);
        first.observe(1, &intent(5, &[0, 1]));
        drain(&mut first, 1, true);
        let mut second = DisplayIntentOutbox::new(2);
        second.observe(2, &intent(5, &[0, 1]));
        assert_eq!(
            second.pending(2, true),
            Some(DisplayControlCommand::Set(vec![0, 1]))
        );
    }

    #[test]
    fn legacy_peer_only_selects_a_single_display() {
        let mut outbox = DisplayIntentOutbox::new(1);
        outbox.observe(1, &intent(1, &[1]));
        assert_eq!(
            drain(&mut outbox, 1, false),
            vec![DisplayControlCommand::Select(1)]
        );
        outbox.observe(1, &intent(2, &[]));
        assert!(outbox.pending(1, false).is_none());
    }

    #[test]
    fn select_retry_does_not_resend_set_or_survive_a_new_multi_display_intent() {
        let mut outbox = DisplayIntentOutbox::new(1);
        outbox.observe(1, &intent(1, &[1]));
        outbox.admit(1, &DisplayControlCommand::Set(vec![1]));
        assert_eq!(
            outbox.pending(1, true),
            Some(DisplayControlCommand::Select(1))
        );
        outbox.observe(1, &intent(2, &[0, 1]));
        assert_eq!(
            drain(&mut outbox, 1, true),
            vec![DisplayControlCommand::Set(vec![0, 1])]
        );
    }

    #[test]
    fn replacement_is_generation_fenced_and_its_control_steps_are_retried() {
        let mut outbox = DisplayIntentOutbox::new(1);
        let current = intent(2, &[1]);
        outbox.observe(1, &current);
        outbox.replace(1, &current, 1, (1920, 1080), true);
        let commands = drain(&mut outbox, 1, true);
        assert_eq!(
            commands,
            vec![
                DisplayControlCommand::Set(vec![1]),
                DisplayControlCommand::Replace {
                    display: 1,
                    width: 1920,
                    height: 1080
                },
                DisplayControlCommand::Refresh(1)
            ]
        );
        outbox.replace(1, &current, 1, (1920, 1080), true);
        assert!(outbox.pending(1, true).is_none());
        outbox.observe(1, &intent(3, &[0, 1]));
        outbox.replace(1, &current, 1, (1920, 1080), true);
        assert_eq!(
            drain(&mut outbox, 1, true),
            vec![DisplayControlCommand::Set(vec![0, 1])]
        );
    }

    #[hbb_common::tokio::test]
    async fn saturated_tcp_writer_eventually_receives_latest_set() {
        use hbb_common::{protobuf::Message as _, tcp::FramedStream, Stream};
        let (left, right) = tokio::io::duplex(64);
        let addr = "127.0.0.1:0".parse().unwrap();
        let mut writer = Stream::Tcp(FramedStream::from(left, addr)).into_duplex(1);
        let mut reader = FramedStream::from(right, addr);
        let filler = Message::new();
        // No yield: fill the actual bounded admission queue before its worker runs.
        writer.send(&filler).await.unwrap();
        let mut outbox = DisplayIntentOutbox::new(1);
        outbox.observe(1, &intent(1, &[0]));
        let command = outbox.pending(1, true).unwrap();
        let error = writer.send(&command.message()).await.unwrap_err();
        assert!(super::super::io_loop::is_would_block_error(&error));
        outbox.record_failure();
        outbox.observe(1, &intent(2, &[1, 2]));
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            reader.next().await.unwrap().unwrap();
            loop {
                let command = outbox.pending(1, true).unwrap();
                if writer.send(&command.message()).await.is_ok() {
                    outbox.admit(1, &command);
                    break;
                }
                tokio::task::yield_now().await;
            }
            let received =
                Message::parse_from_bytes(&reader.next().await.unwrap().unwrap()).unwrap();
            assert_eq!(received.misc().capture_displays().set, vec![1, 2]);
            assert!(received.misc().capture_displays().add.is_empty());
            assert!(received.misc().capture_displays().sub.is_empty());
        })
        .await
        .unwrap();
        assert!(outbox.pending(1, true).is_none());
    }
}
