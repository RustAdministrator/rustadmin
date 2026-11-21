//! The remote cursor on a viewer whose picture is held back by a playout buffer.
//!
//! The host reports its cursor (where it is, which shape it has) in messages of their own,
//! past the video queue, and the viewer applies them at once. Where a presentation clock
//! holds the picture back, in the Movie profile, the cursor is then ahead of the picture by
//! the playout delay: it reaches a button before the picture shows the pointer there, and a
//! window that is dragged trails behind it. Here these messages wait as long as the picture
//! does, in the order they came.
//!
//! This is about what the host reports. The viewer's own mouse pointer is the system's and
//! is not delayed.

use hbb_common::message_proto::{CursorData, CursorPosition};
use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};

/// What the host says about its cursor.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum CursorEvent {
    Data(CursorData),
    Id(String),
    Position(CursorPosition),
}

/// No more events than this wait. A host reports the position at most about as often as it
/// captures, so 50 ms hold a handful; the bound is for a host that sends without measure.
const MAX_WAITING: usize = 256;

#[derive(Debug, Default)]
pub(crate) struct CursorDelay {
    waiting: VecDeque<(Instant, CursorEvent)>,
}

impl CursorDelay {
    /// An event arrived at `now` and is to be applied `delay` later. Returns an event to
    /// apply at once: this one, when there is no delay and nothing waits, or the oldest
    /// waiting one when too many wait. An event never overtakes an earlier one, also when
    /// the delay has just become shorter.
    pub(crate) fn push(
        &mut self,
        event: CursorEvent,
        now: Instant,
        delay: Duration,
    ) -> Option<CursorEvent> {
        let last_due = self.waiting.back().map(|(due, _)| *due);
        if delay.is_zero() && last_due.is_none() {
            return Some(event);
        }
        let due = last_due.map_or(now + delay, |last| last.max(now + delay));
        self.waiting.push_back((due, event));
        if self.waiting.len() > MAX_WAITING {
            return self.waiting.pop_front().map(|(_, event)| event);
        }
        None
    }

    /// The next event that is due at `now`, oldest first.
    pub(crate) fn pop_due(&mut self, now: Instant) -> Option<CursorEvent> {
        if self.waiting.front().is_some_and(|(due, _)| *due <= now) {
            return self.waiting.pop_front().map(|(_, event)| event);
        }
        None
    }

    /// When the oldest waiting event is due.
    pub(crate) fn next_due(&self) -> Option<Instant> {
        self.waiting.front().map(|(due, _)| *due)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn position(x: i32) -> CursorEvent {
        CursorEvent::Position(CursorPosition {
            x,
            y: 0,
            ..Default::default()
        })
    }

    fn ms(value: u64) -> Duration {
        Duration::from_millis(value)
    }

    fn drain(delay: &mut CursorDelay, now: Instant) -> Vec<CursorEvent> {
        std::iter::from_fn(|| delay.pop_due(now)).collect()
    }

    #[test]
    fn without_a_playout_buffer_the_cursor_is_applied_at_once() {
        let now = Instant::now();
        let mut delay = CursorDelay::default();
        assert_eq!(
            delay.push(position(1), now, Duration::ZERO),
            Some(position(1))
        );
        assert_eq!(delay.next_due(), None);
    }

    #[test]
    fn with_a_playout_buffer_the_cursor_waits_as_long_as_the_picture() {
        let start = Instant::now();
        let mut delay = CursorDelay::default();
        assert_eq!(delay.push(position(1), start, ms(50)), None);
        assert_eq!(delay.push(position(2), start + ms(16), ms(50)), None);
        assert_eq!(delay.next_due(), Some(start + ms(50)));
        assert!(drain(&mut delay, start + ms(49)).is_empty());
        assert_eq!(drain(&mut delay, start + ms(50)), vec![position(1)]);
        assert_eq!(delay.next_due(), Some(start + ms(66)));
        assert_eq!(drain(&mut delay, start + ms(66)), vec![position(2)]);
        assert_eq!(delay.next_due(), None);
    }

    #[test]
    fn shape_and_position_keep_the_order_they_came_in() {
        let start = Instant::now();
        let mut delay = CursorDelay::default();
        let events = [
            CursorEvent::Data(CursorData {
                id: 7,
                ..Default::default()
            }),
            CursorEvent::Id("7".to_owned()),
            position(3),
        ];
        for event in events.iter().cloned() {
            assert_eq!(delay.push(event, start, ms(50)), None);
        }
        assert_eq!(drain(&mut delay, start + ms(50)), events.to_vec());
    }

    #[test]
    fn event_never_overtakes_an_earlier_one_when_the_buffer_is_switched_off() {
        let start = Instant::now();
        let mut delay = CursorDelay::default();
        assert_eq!(delay.push(position(1), start, ms(50)), None);
        // Movie ends 10 ms later: the next event has no delay of its own, but one waits.
        assert_eq!(
            delay.push(position(2), start + ms(10), Duration::ZERO),
            None
        );
        assert!(drain(&mut delay, start + ms(49)).is_empty());
        assert_eq!(
            drain(&mut delay, start + ms(50)),
            vec![position(1), position(2)]
        );
        // With nothing waiting it is immediate again.
        assert_eq!(
            delay.push(position(3), start + ms(60), Duration::ZERO),
            Some(position(3))
        );
    }

    #[test]
    fn flood_of_events_is_bounded_and_stays_in_order() {
        let start = Instant::now();
        let mut delay = CursorDelay::default();
        let mut applied = Vec::new();
        for x in 0..(MAX_WAITING as i32 + 10) {
            applied.extend(delay.push(position(x), start, ms(50)));
        }
        // The ten oldest went out early, the rest waits.
        assert_eq!(applied, (0..10).map(position).collect::<Vec<_>>());
        let rest = drain(&mut delay, start + ms(50));
        assert_eq!(rest.len(), MAX_WAITING);
        assert_eq!(rest.first(), Some(&position(10)));
    }
}
