//! Connection-owned encoded-video admission. No OS capture or transport work here.
use hbb_common::tokio::sync::Notify;
use hbb_common::{
    message_proto::{message, video_frame, Message, VideoFrame},
    protobuf::Message as _,
};
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

const DISPLAYS: usize = 64;
const CONTROL_RESERVE: usize = 8;
const TRACK_FRAMES: usize = 4;
const TRACKS: usize = 16;
const CAPACITY: usize = TRACKS * TRACK_FRAMES + CONTROL_RESERVE;
const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;
const MAX_BYTES: usize = 64 * 1024 * 1024;
const QUANTUM: usize = 64 * 1024;
const REFRESH_INTERVAL: Duration = Duration::from_secs(1);
const MAX_REFRESHES: usize = 5;
const STALE_DELTA: Duration = Duration::from_secs(3);

pub(super) type Queued = (hbb_common::tokio::time::Instant, Arc<Message>);

#[derive(Clone, Copy, Default)]
struct Track {
    stream: Option<u64>,
    enabled: bool,
    recovering: bool,
    lost_through: u64,
    refreshes: usize,
    last_refresh: Option<Instant>,
    deficit: usize,
    loss_events: u64,
}

struct Entry {
    item: Queued,
    display: Option<usize>,
    bytes: usize,
    key: bool,
    frame: u64,
}

pub(super) struct Drops {
    pub times: [Option<hbb_common::tokio::time::Instant>; DISPLAYS],
}
impl Default for Drops {
    fn default() -> Self {
        Self {
            times: [None; DISPLAYS],
        }
    }
}
impl Drops {
    fn record(&mut self, entry: &Entry) {
        if let Some(display) = entry.display {
            self.times[display] = Some(entry.item.0);
        }
    }
}

struct State {
    messages: VecDeque<Entry>,
    tracks: [Track; DISPLAYS],
    bytes: usize,
    cursor: usize,
    continuing: bool,
    fatal: bool,
}

impl State {
    fn new() -> Self {
        Self {
            messages: VecDeque::with_capacity(CAPACITY),
            tracks: [Track {
                enabled: true,
                ..Track::default()
            }; DISPLAYS],
            bytes: 0,
            cursor: 0,
            continuing: false,
            fatal: false,
        }
    }

    fn remove(&mut self, index: usize) -> Option<Entry> {
        let entry = self.messages.remove(index)?;
        self.bytes -= entry.bytes;
        Some(entry)
    }

    fn purge(&mut self, display: usize, deltas_only: bool, drops: &mut Drops) {
        let mut i = 0;
        while i < self.messages.len() {
            let entry = &self.messages[i];
            if entry.display == Some(display) && (!deltas_only || !entry.key) {
                if let Some(entry) = self.remove(i) {
                    drops.record(&entry);
                }
            } else {
                i += 1;
            }
        }
    }

    fn loss(&mut self, display: usize, frame: u64, drops: &mut Drops) {
        let frame = self
            .messages
            .iter()
            .filter(|e| e.display == Some(display) && !e.key)
            .fold(frame, |floor, e| floor.max(e.frame));
        let track = &mut self.tracks[display];
        if !track.recovering {
            track.refreshes = 0;
            track.last_refresh = None;
        }
        track.recovering = true;
        track.lost_through = track.lost_through.max(frame);
        track.loss_events = track.loss_events.saturating_add(1);
        // All later queued deltas can depend on the lost reference. Retain a
        // pending keyframe, but only a newer keyframe can complete recovery.
        self.purge(display, true, drops);
    }

    fn push(&mut self, item: Queued) -> Drops {
        let mut drops = Drops::default();
        let bytes = item.1.compute_size() as usize;
        let metadata = match item.1.union.as_ref() {
            Some(message::Union::VideoFrame(frame)) => {
                let Ok(display) = usize::try_from(frame.display) else {
                    return drops;
                };
                if display >= DISPLAYS {
                    return drops;
                }
                Some((
                    display,
                    frame.stream_id,
                    frame.frame_id,
                    leading_keyframe(frame),
                ))
            }
            _ => None,
        };
        let Some((display, stream, frame, key)) = metadata else {
            // Ordering barriers are never silently evicted. A bounded queue of
            // nothing but barriers fails closed instead of lying about order.
            if self.messages.len() == CAPACITY
                || bytes > MAX_FRAME_BYTES
                || self.bytes.saturating_add(bytes) > MAX_BYTES
            {
                self.fatal = true;
            } else {
                self.bytes += bytes;
                self.messages.push_back(Entry {
                    item,
                    display: None,
                    bytes,
                    key: false,
                    frame: 0,
                });
            }
            return drops;
        };
        let entry = Entry {
            item,
            display: Some(display),
            bytes,
            key,
            frame,
        };
        let track = self.tracks[display];
        if !track.enabled || track.stream.is_some_and(|old| stream < old) {
            drops.record(&entry);
            return drops;
        }
        if track.stream != Some(stream) {
            self.purge(display, false, &mut drops);
            self.tracks[display] = Track {
                stream: Some(stream),
                enabled: true,
                recovering: !key,
                ..Track::default()
            };
        }
        if !key && self.tracks[display].recovering {
            self.loss(display, frame, &mut drops);
            drops.record(&entry);
            return drops;
        }
        if key {
            // A complete independent reference supersedes only its own track.
            self.purge(display, false, &mut drops);
        }
        let mut pending = [false; DISPLAYS];
        let mut own_frames = 0;
        let mut own_bytes = 0;
        for e in &self.messages {
            if let Some(d) = e.display {
                pending[d] = true;
                if d == display {
                    own_frames += 1;
                    own_bytes += e.bytes;
                }
            }
        }
        let track_full =
            !pending[display] && pending.iter().filter(|value| **value).count() >= TRACKS;
        if bytes > MAX_FRAME_BYTES
            || self.bytes.saturating_add(bytes) > MAX_BYTES
            || self.messages.len() >= CAPACITY - CONTROL_RESERVE
            || own_bytes.saturating_add(bytes) > MAX_FRAME_BYTES
            || own_frames >= TRACK_FRAMES
            || track_full
        {
            self.loss(display, frame, &mut drops);
            drops.record(&entry);
            return drops;
        }
        if key && (frame == 0 || frame > self.tracks[display].lost_through) {
            self.tracks[display].recovering = false;
            self.tracks[display].refreshes = 0;
        }
        self.bytes += bytes;
        self.messages.push_back(entry);
        drops
    }

    fn pop(&mut self) -> Option<Queued> {
        if self
            .messages
            .front()
            .is_some_and(|entry| entry.display.is_none())
        {
            return self.remove(0).map(|entry| entry.item);
        }
        // Deficit round robin, bounded by 16 MiB / 64 KiB credit rounds.
        // Never overtake a queued ordering barrier or another frame of this track.
        let barrier = self
            .messages
            .iter()
            .position(|e| e.display.is_none())
            .unwrap_or(self.messages.len());
        if barrier == 0 {
            return None;
        }
        for _ in 0..DISPLAYS * (MAX_FRAME_BYTES / QUANTUM + 1) {
            let display = self.cursor;
            self.cursor = (self.cursor + 1) % DISPLAYS;
            let continuing = self.continuing;
            self.continuing = false;
            let Some(index) = self
                .messages
                .iter()
                .take(barrier)
                .position(|e| e.display == Some(display))
            else {
                self.tracks[display].deficit = 0;
                continue;
            };
            let credit = &mut self.tracks[display].deficit;
            if !continuing {
                *credit = credit
                    .saturating_add(QUANTUM)
                    .min(MAX_FRAME_BYTES + QUANTUM);
            }
            let cost = self.messages[index].bytes;
            if *credit >= cost {
                *credit -= cost;
                // Continue this track while its remaining credit can pay the
                // next packet; otherwise rotate to give other tracks a turn.
                self.cursor = display;
                self.continuing = true;
                return self.remove(index).map(|entry| entry.item);
            }
        }
        None
    }
}

fn leading_keyframe(frame: &VideoFrame) -> bool {
    match frame.union.as_ref() {
        Some(
            video_frame::Union::Vp8s(f)
            | video_frame::Union::Vp9s(f)
            | video_frame::Union::Av1s(f)
            | video_frame::Union::H264s(f)
            | video_frame::Union::H265s(f),
        ) => f
            .frames
            .first()
            .is_some_and(|f| f.key && !f.data.is_empty()),
        _ => false,
    }
}

struct Inner {
    state: Mutex<State>,
    notify: Notify,
}
#[derive(Clone)]
pub(crate) struct VideoQueueSender {
    inner: Arc<Inner>,
}
pub(super) struct VideoQueueReceiver {
    inner: Arc<Inner>,
}

pub(super) fn video_queue() -> (VideoQueueSender, VideoQueueReceiver) {
    let inner = Arc::new(Inner {
        state: Mutex::new(State::new()),
        notify: Notify::new(),
    });
    (
        VideoQueueSender {
            inner: inner.clone(),
        },
        VideoQueueReceiver { inner },
    )
}

impl VideoQueueSender {
    pub(super) fn send(&self, item: Queued) -> Drops {
        let drops = self.inner.state.lock().unwrap().push(item);
        self.inner.notify.notify_one();
        drops
    }

    pub(super) fn lose(&self, item: &Queued) -> Drops {
        let mut drops = Drops::default();
        if let Some(message::Union::VideoFrame(frame)) = item.1.union.as_ref() {
            if let Ok(display) = usize::try_from(frame.display) {
                if display < DISPLAYS {
                    let mut state = self.inner.state.lock().unwrap();
                    if state.tracks[display].stream == Some(frame.stream_id) {
                        state.loss(display, frame.frame_id, &mut drops);
                    }
                    drops.times[display] = Some(item.0);
                }
            }
        }
        drops
    }

    pub(super) fn set_displays(&self, displays: &[usize]) -> Drops {
        let mut state = self.inner.state.lock().unwrap();
        let mut drops = Drops::default();
        for display in 0..DISPLAYS {
            let enabled = displays.contains(&display);
            if state.tracks[display].enabled && !enabled {
                state.purge(display, false, &mut drops);
                state.tracks[display].recovering = false;
            }
            if !state.tracks[display].enabled && enabled {
                let track = &mut state.tracks[display];
                track.recovering = true;
                track.refreshes = 0;
                track.last_refresh = None;
            }
            state.tracks[display].enabled = enabled;
        }
        drops
    }

    pub(super) fn recovery_due(&self, now: Instant) -> [Option<(u64, u64)>; DISPLAYS] {
        let mut state = self.inner.state.lock().unwrap();
        std::array::from_fn(|display| {
            let t = &mut state.tracks[display];
            if !t.enabled
                || !t.recovering
                || t.refreshes >= MAX_REFRESHES
                || t.last_refresh
                    .is_some_and(|at| now.saturating_duration_since(at) < REFRESH_INTERVAL)
            {
                return None;
            }
            t.last_refresh = Some(now);
            t.refreshes += 1;
            Some((t.stream.unwrap_or(0), t.loss_events))
        })
    }

    pub(super) fn stale_delta(item: &Queued) -> bool {
        matches!(item.1.union.as_ref(), Some(message::Union::VideoFrame(frame))
            if !leading_keyframe(frame) && item.0.elapsed() >= STALE_DELTA)
    }
}

impl VideoQueueReceiver {
    pub(super) async fn recv(&mut self) -> Result<Queued, &'static str> {
        loop {
            let notified = self.inner.notify.notified();
            {
                let mut state = self.inner.state.lock().unwrap();
                if state.fatal {
                    return Err("video ordering queue capacity exceeded");
                }
                if let Some(item) = state.pop() {
                    return Ok(item);
                }
            }
            notified.await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::{
        bytes::Bytes,
        message_proto::{EncodedVideoFrame, EncodedVideoFrames},
    };

    fn video(display: i32, stream: u64, frame: u64, key: bool, size: usize) -> Queued {
        let mut video = VideoFrame {
            display,
            stream_id: stream,
            frame_id: frame,
            ..Default::default()
        };
        video.set_h264s(EncodedVideoFrames {
            frames: vec![EncodedVideoFrame {
                key,
                data: Bytes::from(vec![1; size]),
                ..Default::default()
            }],
            ..Default::default()
        });
        let mut message = Message::new();
        message.set_video_frame(video);
        (hbb_common::tokio::time::Instant::now(), Arc::new(message))
    }

    fn identity(item: Queued) -> (i32, u64, u64) {
        match item.1.union.as_ref().unwrap() {
            message::Union::VideoFrame(f) => (f.display, f.stream_id, f.frame_id),
            _ => panic!("expected video"),
        }
    }

    #[test]
    fn busy_track_loss_preserves_other_startup_and_purges_dependent_deltas() {
        let mut q = State::new();
        q.push(video(0, 1, 1, true, 100));
        q.push(video(1, 2, 1, true, 100));
        for id in 2..=5 {
            q.push(video(0, 1, id, false, 100));
        }
        assert!(q.tracks[0].recovering);
        assert!(!q.tracks[1].recovering);
        assert_eq!(q.messages.len(), 2);
        assert!(q.messages.iter().all(|e| e.key));
        q.push(video(0, 1, 6, false, 100));
        assert_eq!(q.messages.len(), 2);
        q.push(video(0, 1, 7, true, 100));
        q.push(video(0, 1, 8, false, 100));
        assert!(!q.tracks[0].recovering);
        assert_eq!(q.messages.len(), 3);
    }

    #[test]
    fn transport_loss_advances_floor_past_all_purged_deltas() {
        let (tx, _) = video_queue();
        tx.send(video(0, 1, 1, true, 100));
        tx.inner.state.lock().unwrap().pop();
        for id in 2..=4 {
            tx.send(video(0, 1, id, false, 100));
        }
        let lost = tx.inner.state.lock().unwrap().pop().unwrap();
        tx.lose(&lost);
        let q = tx.inner.state.lock().unwrap();
        assert_eq!(q.tracks[0].lost_through, 4);
        assert_eq!(q.bytes, 0);
        assert!(q.messages.is_empty());
    }

    #[test]
    fn full_per_track_bursts_leave_room_for_the_last_startup() {
        let mut q = State::new();
        for display in 0..15 {
            q.push(video(display, display as u64 + 1, 1, true, 100));
            for frame in 2..=4 {
                q.push(video(display, display as u64 + 1, frame, false, 100));
            }
        }
        q.push(video(15, 16, 1, true, 100));
        assert_eq!(q.messages.len(), 61);
        assert!(q
            .messages
            .iter()
            .any(|entry| entry.display == Some(15) && entry.key));
        assert!(!q.tracks[15].recovering);
    }

    #[test]
    fn sixteen_pending_tracks_are_not_a_lifetime_limit() {
        let mut q = State::new();
        for display in 0..16 {
            q.push(video(display, 1, 1, true, 100));
        }
        assert_eq!(q.messages.len(), 16);
        q.push(video(16, 1, 1, true, 100));
        assert_eq!(q.messages.len(), 16);
        assert!(q.tracks[16].recovering);
        let first = identity(q.pop().unwrap());
        assert_eq!(first.0, 0);
        q.push(video(16, 1, 2, true, 100));
        assert_eq!(q.messages.len(), 16);
        assert!(!q.tracks[16].recovering);
        let mut seen = [false; 17];
        while let Some(item) = q.pop() {
            seen[identity(item).0 as usize] = true;
        }
        assert!(seen[1..].iter().all(|seen| *seen));
        assert_eq!(q.bytes, 0);
        q.push(video(0, 1, 2, true, 100));
        assert_eq!(identity(q.pop().unwrap()), (0, 1, 2));
    }

    #[test]
    fn stream_replacement_retires_only_its_display_and_rejects_late_frames() {
        let mut q = State::new();
        q.push(video(0, 10, 1, true, 100));
        q.push(video(1, 11, 1, true, 100));
        q.push(video(0, 12, 1, true, 100));
        q.push(video(0, 10, 2, true, 100));
        assert_eq!(q.messages.len(), 2);
        assert_eq!(identity(q.pop().unwrap()), (0, 12, 1));
        assert_eq!(identity(q.pop().unwrap()), (1, 11, 1));
    }

    #[test]
    fn subscription_readd_requires_an_independent_reference() {
        let (tx, _) = video_queue();
        tx.send(video(0, 1, 1, true, 100));
        tx.send(video(1, 2, 1, true, 100));
        tx.set_displays(&[1]);
        tx.send(video(0, 1, 2, true, 100));
        assert_eq!(tx.inner.state.lock().unwrap().messages.len(), 1);
        tx.set_displays(&[0, 1]);
        tx.send(video(0, 1, 3, false, 100));
        assert_eq!(tx.inner.state.lock().unwrap().messages.len(), 1);
        tx.send(video(0, 1, 4, true, 100));
        assert_eq!(tx.inner.state.lock().unwrap().messages.len(), 2);
    }

    #[test]
    fn byte_and_control_limits_have_explicit_exhaustion_policy() {
        let mut q = State::new();
        q.push(video(0, 1, 1, true, MAX_FRAME_BYTES)); // protobuf overhead exceeds the limit
        assert!(q.messages.is_empty());
        assert!(q.tracks[0].recovering);
        for display in 0..4 {
            q.push(video(display, 2, 1, true, MAX_FRAME_BYTES - 100));
        }
        assert!(q.bytes <= MAX_BYTES);
        q.push(video(4, 2, 1, true, 1000));
        assert_eq!(q.messages.len(), 4); // all keys: reject incoming, never evict another track
        assert!(q.tracks[4].recovering);
        assert!(!q.fatal);
        let mut controls = State::new();
        for _ in 0..CAPACITY {
            controls.push((
                hbb_common::tokio::time::Instant::now(),
                Arc::new(Message::new()),
            ));
        }
        assert!(!controls.fatal);
        controls.push((
            hbb_common::tokio::time::Instant::now(),
            Arc::new(Message::new()),
        ));
        assert!(controls.fatal);
        assert_eq!(controls.messages.len(), CAPACITY);
    }

    #[test]
    fn ordering_barrier_cannot_be_overtaken_by_a_small_new_frame() {
        let mut q = State::new();
        q.push(video(0, 1, 1, true, 1024 * 1024));
        let barrier = Arc::new(Message::new());
        q.push((hbb_common::tokio::time::Instant::now(), barrier.clone()));
        q.push(video(1, 2, 1, true, 1));
        assert_eq!(identity(q.pop().unwrap()).0, 0);
        assert!(Arc::ptr_eq(&q.pop().unwrap().1, &barrier));
        assert_eq!(identity(q.pop().unwrap()).0, 1);
    }

    #[test]
    fn unequal_frames_make_bounded_byte_fair_progress_under_replenishment() {
        let mut q = State::new();
        q.push(video(0, 1, 1, true, 1024 * 1024));
        q.push(video(1, 2, 1, true, 64 * 1024));
        let mut small = 0;
        for id in 2..=20 {
            let display = identity(q.pop().unwrap()).0;
            if display == 0 {
                break;
            }
            small += 1;
            q.push(video(1, 2, id, false, 64 * 1024));
        }
        assert!(
            (10..=17).contains(&small),
            "small frames before large: {small}"
        );
        assert!(!q.messages.iter().any(|e| e.display == Some(0)));
    }

    #[test]
    fn refreshes_are_scoped_rate_limited_and_bounded() {
        let (tx, _) = video_queue();
        tx.send(video(0, 1, 1, false, 1));
        tx.send(video(1, 2, 1, true, 1));
        let now = Instant::now();
        for attempt in 0..MAX_REFRESHES {
            let due = tx.recovery_due(now + REFRESH_INTERVAL * attempt as u32);
            assert!(due[0].is_some());
            assert!(due[1..].iter().all(Option::is_none));
            assert!(tx
                .recovery_due(now + REFRESH_INTERVAL * attempt as u32)
                .iter()
                .all(Option::is_none));
        }
        assert!(tx
            .recovery_due(now + REFRESH_INTERVAL * 100)
            .iter()
            .all(Option::is_none));
        tx.send(video(0, 1, 2, true, 1));
        tx.lose(&video(0, 1, 3, false, 1));
        assert!(tx.recovery_due(now + REFRESH_INTERVAL * 101)[0].is_some());
    }

    #[test]
    fn stale_keyframes_survive_but_stale_deltas_trigger_loss() {
        let mut key = video(0, 1, 1, true, 1);
        key.0 -= STALE_DELTA;
        assert!(!VideoQueueSender::stale_delta(&key));
        let mut delta = video(0, 1, 2, false, 1);
        delta.0 -= STALE_DELTA;
        assert!(VideoQueueSender::stale_delta(&delta));
    }
}
