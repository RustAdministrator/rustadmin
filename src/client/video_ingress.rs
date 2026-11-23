//! The viewer's queue of encoded frames for one display, between the network thread and the
//! decoder thread, and the wait for a keyframe after frames were lost.
//!
//! Keyframes used to travel in the wake-up channel while delta frames waited in a separate
//! queue, and a wake-up token took whatever was at the head of that queue. When the network
//! thread had removed old deltas to make room, tokens were left over; they took deltas that had
//! arrived *after* a keyframe which was still behind them in the channel. Those deltas were
//! thrown away as "waiting for the keyframe", the keyframe then ended the wait, and the next
//! delta was decoded on a keyframe it did not follow: a damaged picture until some later
//! keyframe, with nothing left pending to repair it.
//!
//! Here every frame, keyframe or not, waits in one queue in the order it arrived, and a
//! wake-up only means "look at the queue". A frame that follows a removed one carries a mark,
//! so the decoder thread knows exactly where the chain of references is broken.

use std::{
    collections::VecDeque,
    sync::Mutex,
    time::{Duration, Instant},
};

struct Entry<T> {
    frame: T,
    keyframe: bool,
    after_gap: bool,
    arrived_at: Instant,
}

struct State<T> {
    frames: VecDeque<Entry<T>>,
    /// A frame was removed from the tail end of the queue: the next one to arrive follows a gap.
    gap_pending: bool,
}

/// What the decoder thread takes from the queue.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Popped<T> {
    pub frame: T,
    pub keyframe: bool,
    /// The frame that arrived right before this one was removed from the queue. Unless this
    /// is a keyframe, it and what follows cannot be decoded until the next keyframe.
    pub after_gap: bool,
    /// When the frame was queued.
    pub arrived_at: Instant,
}

/// Frames of one display in arrival order.
pub(crate) struct VideoIngress<T> {
    state: Mutex<State<T>>,
    capacity: usize,
}

impl<T> VideoIngress<T> {
    pub(crate) fn new(capacity: usize) -> Self {
        Self {
            state: Mutex::new(State {
                frames: VecDeque::new(),
                gap_pending: false,
            }),
            capacity: capacity.max(1),
        }
    }

    pub(crate) fn capacity(&self) -> usize {
        self.capacity
    }

    pub(crate) fn len(&self) -> usize {
        self.state.lock().unwrap().frames.len()
    }

    /// Queues `frame` behind everything that is waiting. No more than `limit` frames wait
    /// (and never more than the capacity): to make room, the oldest frame that is not a
    /// keyframe is removed and the frame that followed it is marked. A keyframe is removed
    /// only when nothing else is left to remove — everything behind a lost keyframe is useless.
    /// Returns how many frames were removed.
    pub(crate) fn push(&self, frame: T, keyframe: bool, limit: usize) -> usize {
        let limit = limit.clamp(1, self.capacity);
        let mut state = self.state.lock().unwrap();
        let mut removed = 0;
        while state.frames.len() >= limit {
            let index = state
                .frames
                .iter()
                .position(|entry| !entry.keyframe)
                .unwrap_or(0);
            state.frames.remove(index);
            removed += 1;
            match state.frames.get_mut(index) {
                Some(next) => next.after_gap = true,
                None => state.gap_pending = true,
            }
        }
        let after_gap = std::mem::take(&mut state.gap_pending);
        state.frames.push_back(Entry {
            frame,
            keyframe,
            after_gap,
            arrived_at: Instant::now(),
        });
        removed
    }

    /// The oldest waiting frame.
    pub(crate) fn pop(&self) -> Option<Popped<T>> {
        let entry = self.state.lock().unwrap().frames.pop_front()?;
        Some(Popped {
            frame: entry.frame,
            keyframe: entry.keyframe,
            after_gap: entry.after_gap,
            arrived_at: entry.arrived_at,
        })
    }

    /// Removes everything. What arrives next follows a gap, if anything was removed.
    pub(crate) fn clear(&self) -> usize {
        let mut state = self.state.lock().unwrap();
        let removed = state.frames.len();
        state.frames.clear();
        if removed > 0 {
            state.gap_pending = true;
        }
        removed
    }
}

/// How long the first wait for a keyframe lasts before a full refresh is asked for, in the
/// Movie profile. Movie asks the host for a scoped recovery first; this is the fallback that
/// every host version answers with a keyframe.
pub(crate) const MOVIE_KEYFRAME_FALLBACK_DELAY: Duration = Duration::from_secs(1);
/// The same outside Movie. Longer: there the refresh itself was the request, and on a slow
/// link its keyframe can take more than a second to arrive.
pub(crate) const KEYFRAME_FALLBACK_DELAY: Duration = Duration::from_secs(3);
/// The pause between two fallback requests doubles up to this.
pub(crate) const KEYFRAME_FALLBACK_MAX_INTERVAL: Duration = Duration::from_secs(8);

/// The state "delta frames are discarded until a keyframe arrives".
///
/// It used to be a bare flag that several places set and only a keyframe cleared; in the
/// Movie profile one fallback request followed after a second, elsewhere nothing. A request
/// that got lost on the way left the picture frozen for good. Every wait now has a deadline:
/// while it lasts, a full refresh is asked for again and again, with a growing pause.
#[derive(Debug, Default)]
pub(crate) struct KeyframeWait {
    since: Option<Instant>,
    next_fallback: Option<Instant>,
    interval: Duration,
    fallbacks: u32,
}

impl KeyframeWait {
    /// Starts discarding delta frames. A wait that is already running keeps its deadline:
    /// more lost frames, or one more request, do not postpone the fallback.
    pub(crate) fn begin(&mut self, now: Instant, first_fallback: Duration) {
        if self.since.is_none() {
            self.since = Some(now);
            self.next_fallback = Some(now + first_fallback);
            self.interval = first_fallback;
            self.fallbacks = 0;
        }
    }

    /// Whether delta frames are being discarded.
    pub(crate) fn waiting(&self) -> bool {
        self.since.is_some()
    }

    /// A keyframe of the current stream is about to be decoded: decoding goes on from it.
    pub(crate) fn keyframe_accepted(&mut self) {
        *self = Self::default();
    }

    /// True each time a fallback request is due. The next one is due after twice the pause,
    /// up to [`KEYFRAME_FALLBACK_MAX_INTERVAL`].
    pub(crate) fn fallback_due(&mut self, now: Instant) -> bool {
        match self.next_fallback {
            Some(due) if now >= due => {
                self.interval = (self.interval * 2).min(KEYFRAME_FALLBACK_MAX_INTERVAL);
                self.next_fallback = Some(now + self.interval);
                self.fallbacks = self.fallbacks.saturating_add(1);
                true
            }
            _ => false,
        }
    }

    /// Time until the next fallback request, while waiting.
    pub(crate) fn fallback_wait(&self, now: Instant) -> Option<Duration> {
        self.next_fallback
            .map(|due| due.saturating_duration_since(now))
    }

    /// How many fallback requests this wait has made.
    pub(crate) fn fallbacks(&self) -> u32 {
        self.fallbacks
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    /// A frame of the test stream: `K3` is a keyframe with id 3, `d4` a delta that needs 3.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    struct Frame {
        id: u32,
        keyframe: bool,
    }

    fn key(id: u32) -> Frame {
        Frame { id, keyframe: true }
    }

    fn delta(id: u32) -> Frame {
        Frame {
            id,
            keyframe: false,
        }
    }

    /// What a decoder shows for a sequence of frames handed to it: a delta is shown intact
    /// only when the frame decoded right before it is its predecessor.
    #[derive(Default)]
    struct Decoder {
        last: Option<u32>,
        decoded: Vec<u32>,
        damaged: Vec<u32>,
    }

    impl Decoder {
        fn decode(&mut self, frame: Frame) {
            if !frame.keyframe && self.last != Some(frame.id - 1) {
                self.damaged.push(frame.id);
            }
            self.last = Some(frame.id);
            self.decoded.push(frame.id);
        }
    }

    const MOVIE_LIMIT: usize = 8;

    /// The arrival that showed the defect: the decoder is busy while nine deltas arrive (the
    /// queue holds eight, so one is removed and a keyframe is asked for), then the keyframe
    /// and two deltas that follow it arrive, and only then the decoder comes back.
    fn arrival() -> Vec<Frame> {
        let mut frames: Vec<Frame> = (1..=9).map(delta).collect();
        frames.push(key(10));
        frames.push(delta(11));
        frames.push(delta(12));
        frames
    }

    /// The ingress as it was, reduced to its mechanics: keyframes in the wake-up channel,
    /// deltas in their own queue, one token per queued delta, one flag.
    fn replay_split_ingress(frames: &[Frame], then: &[Frame]) -> Decoder {
        enum Wake {
            Keyframe(Frame),
            Queue,
        }
        let (sender, receiver) = mpsc::channel();
        let mut queue: VecDeque<Frame> = VecDeque::new();
        let mut discard = false;
        let arrive = |frame: Frame, queue: &mut VecDeque<Frame>, discard: &mut bool| {
            if frame.keyframe {
                sender.send(Wake::Keyframe(frame)).unwrap();
                return;
            }
            let mut dropped = 0;
            while queue.len() >= MOVIE_LIMIT {
                queue.pop_front();
                dropped += 1;
            }
            queue.push_back(frame);
            sender.send(Wake::Queue).unwrap();
            if dropped > 0 {
                *discard = true;
            }
        };
        let mut decoder = Decoder::default();
        let drain = |queue: &mut VecDeque<Frame>, discard: &mut bool, decoder: &mut Decoder| {
            while let Ok(wake) = receiver.try_recv() {
                match wake {
                    Wake::Keyframe(frame) => {
                        *discard = false;
                        decoder.decode(frame);
                    }
                    Wake::Queue => {
                        let Some(frame) = queue.pop_front() else {
                            continue;
                        };
                        if !*discard {
                            decoder.decode(frame);
                        }
                    }
                }
            }
        };
        for frame in frames {
            arrive(*frame, &mut queue, &mut discard);
        }
        drain(&mut queue, &mut discard, &mut decoder);
        for frame in then {
            arrive(*frame, &mut queue, &mut discard);
            drain(&mut queue, &mut discard, &mut decoder);
        }
        decoder
    }

    /// The same arrival through [`VideoIngress`] and [`KeyframeWait`], with the decisions the
    /// decoder thread makes.
    fn replay_ordered_ingress(frames: &[Frame], then: &[Frame]) -> Decoder {
        let ingress = VideoIngress::new(120);
        let mut wait = KeyframeWait::default();
        let now = Instant::now();
        let mut decoder = Decoder::default();
        let arrive = |frame: Frame, wait: &mut KeyframeWait| {
            if ingress.push(frame, frame.keyframe, MOVIE_LIMIT) > 0 {
                wait.begin(now, MOVIE_KEYFRAME_FALLBACK_DELAY);
            }
        };
        let drain = |wait: &mut KeyframeWait, decoder: &mut Decoder| {
            while let Some(popped) = ingress.pop() {
                if popped.keyframe {
                    wait.keyframe_accepted();
                } else {
                    if popped.after_gap {
                        wait.begin(now, MOVIE_KEYFRAME_FALLBACK_DELAY);
                    }
                    if wait.waiting() {
                        continue;
                    }
                }
                decoder.decode(popped.frame);
            }
        };
        for frame in frames {
            arrive(*frame, &mut wait);
        }
        drain(&mut wait, &mut decoder);
        for frame in then {
            arrive(*frame, &mut wait);
            drain(&mut wait, &mut decoder);
        }
        decoder
    }

    /// The reference for the defect: what the ingress did before this module existed. It is a
    /// model of the old mechanics, not the old code, which lived inside two long functions.
    #[test]
    fn split_ingress_decodes_a_delta_on_a_keyframe_it_does_not_follow() {
        let decoder = replay_split_ingress(&arrival(), &[delta(13)]);
        // Deltas 11 and 12 were taken by tokens left over from the removed frames and thrown
        // away; 13 was then decoded right after the keyframe.
        assert_eq!(decoder.decoded, vec![10, 13]);
        assert_eq!(decoder.damaged, vec![13]);
    }

    #[test]
    fn frames_are_decoded_in_the_order_they_arrived() {
        let decoder = replay_ordered_ingress(&arrival(), &[delta(13)]);
        assert_eq!(decoder.decoded, vec![10, 11, 12, 13]);
        assert!(decoder.damaged.is_empty(), "{:?}", decoder.damaged);
    }

    #[test]
    fn deltas_before_the_keyframe_are_decoded_up_to_the_gap() {
        // Nothing is lost: everything is decoded, in order.
        let frames: Vec<Frame> = vec![key(1), delta(2), delta(3), key(4), delta(5)];
        let decoder = replay_ordered_ingress(&frames, &[]);
        assert_eq!(decoder.decoded, vec![1, 2, 3, 4, 5]);
        assert!(decoder.damaged.is_empty());
    }

    #[test]
    fn keyframe_waiting_in_the_queue_is_not_removed_to_make_room() {
        let ingress = VideoIngress::new(120);
        ingress.push(key(1), true, 4);
        for id in 2..=4 {
            assert_eq!(ingress.push(delta(id), false, 4), 0);
        }
        // Full. The oldest delta goes, not the keyframe, and the delta after it is marked.
        assert_eq!(ingress.push(delta(5), false, 4), 1);
        let popped: Vec<_> = std::iter::from_fn(|| ingress.pop()).collect();
        let summary: Vec<(u32, bool)> = popped
            .iter()
            .map(|popped| (popped.frame.id, popped.after_gap))
            .collect();
        assert_eq!(summary, vec![(1, false), (3, true), (4, false), (5, false)]);
    }

    #[test]
    fn decoder_stops_at_the_mark_after_an_old_keyframe() {
        // The keyframe was queued before the loss; it must not end the wait for what was lost
        // behind it.
        let ingress = VideoIngress::new(120);
        let mut wait = KeyframeWait::default();
        let now = Instant::now();
        ingress.push(key(1), true, 3);
        ingress.push(delta(2), false, 3);
        ingress.push(delta(3), false, 3);
        assert_eq!(ingress.push(delta(4), false, 3), 1);
        wait.begin(now, MOVIE_KEYFRAME_FALLBACK_DELAY);
        let mut decoder = Decoder::default();
        while let Some(popped) = ingress.pop() {
            if popped.keyframe {
                wait.keyframe_accepted();
            } else {
                if popped.after_gap {
                    wait.begin(now, MOVIE_KEYFRAME_FALLBACK_DELAY);
                }
                if wait.waiting() {
                    continue;
                }
            }
            decoder.decode(popped.frame);
        }
        assert_eq!(decoder.decoded, vec![1], "2 was removed; 3 and 4 need it");
        assert!(decoder.damaged.is_empty());
        assert!(wait.waiting(), "still waiting for a keyframe after the gap");
    }

    #[test]
    fn mark_goes_to_the_next_arrival_when_the_last_frame_was_removed() {
        let ingress = VideoIngress::new(120);
        ingress.push(key(1), true, 1);
        // The limit is one and the only frame is a keyframe: it has to go.
        assert_eq!(ingress.push(delta(2), false, 1), 1);
        let popped = ingress.pop();
        assert!(popped.is_some_and(|popped| {
            popped.frame == delta(2) && !popped.keyframe && popped.after_gap
        }));
        // Clearing a queue that held frames marks what comes next; an empty one does not.
        ingress.push(delta(3), false, 8);
        assert_eq!(ingress.clear(), 1);
        assert_eq!(ingress.clear(), 0);
        ingress.push(delta(4), false, 8);
        assert!(ingress.pop().is_some_and(|popped| popped.after_gap));
        ingress.push(delta(5), false, 8);
        assert!(ingress.pop().is_some_and(|popped| !popped.after_gap));
        assert_eq!(ingress.len(), 0);
        assert_eq!(ingress.capacity(), 120);
    }

    #[test]
    fn capacity_bounds_the_queue_whatever_the_limit() {
        let ingress = VideoIngress::new(3);
        let mut removed = 0;
        for id in 1..=10 {
            removed += ingress.push(delta(id), false, usize::MAX);
        }
        assert_eq!((ingress.len(), removed), (3, 7));
        // A limit of zero still keeps the frame that was just pushed.
        assert_eq!(ingress.push(delta(11), false, 0), 3);
        assert_eq!(ingress.len(), 1);
    }

    #[test]
    fn wait_discards_until_a_keyframe() {
        let now = Instant::now();
        let mut wait = KeyframeWait::default();
        assert!(!wait.waiting());
        assert_eq!(wait.fallback_wait(now), None);
        wait.begin(now, MOVIE_KEYFRAME_FALLBACK_DELAY);
        assert!(wait.waiting(), "deltas are discarded");
        wait.keyframe_accepted();
        assert!(!wait.waiting(), "a keyframe resumes decoding");
        assert!(!wait.fallback_due(now + Duration::from_secs(60)));
    }

    #[test]
    fn fallback_repeats_with_a_growing_pause() {
        let now = Instant::now();
        let second = Duration::from_secs(1);
        let mut wait = KeyframeWait::default();
        wait.begin(now, second);
        assert_eq!(wait.fallback_wait(now), Some(second));
        assert!(!wait.fallback_due(now + Duration::from_millis(999)));
        // More lost frames, or one more request, do not postpone the fallback.
        wait.begin(now + Duration::from_millis(500), second);
        assert!(wait.fallback_due(now + second));
        assert!(!wait.fallback_due(now + second), "once per deadline");
        // 1 s, then 2 s later, 4 s later, 8 s later, and every 8 s after that.
        let mut at = now + second;
        for pause in [2, 4, 8, 8, 8] {
            assert!(!wait.fallback_due(at + Duration::from_secs(pause) - Duration::from_millis(1)));
            at += Duration::from_secs(pause);
            assert!(wait.fallback_due(at), "{} s", pause);
        }
        assert_eq!(wait.fallbacks(), 6);
        assert!(wait.waiting(), "a fallback is a request, not a keyframe");
    }

    #[test]
    fn wait_starts_afresh_after_a_keyframe() {
        let now = Instant::now();
        let mut wait = KeyframeWait::default();
        wait.begin(now, MOVIE_KEYFRAME_FALLBACK_DELAY);
        assert!(wait.fallback_due(now + MOVIE_KEYFRAME_FALLBACK_DELAY));
        wait.keyframe_accepted();
        let later = now + Duration::from_secs(10);
        wait.begin(later, KEYFRAME_FALLBACK_DELAY);
        assert_eq!(wait.fallbacks(), 0);
        assert!(!wait.fallback_due(later + Duration::from_secs(1)));
        assert!(wait.fallback_due(later + KEYFRAME_FALLBACK_DELAY));
    }
}
