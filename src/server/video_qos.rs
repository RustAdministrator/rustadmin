use super::*;
use crate::video_profile::{VideoProfile, MOVIE_DEFAULT_TARGET_FPS};
use scrap::codec::{Quality, BR_BALANCED, BR_BEST, BR_SPEED};
use std::{
    collections::{BTreeMap, HashSet, VecDeque},
    time::{Duration, Instant},
};

/*
FPS adjust is scoped to one video service and its current subscribers:
a. new service with no rendered viewer => use the startup-safe profile
b. TestDelay receive => update that user's fps according to network delay
    When network delay < DELAY_THRESHOLD_150MS, set minimum fps according to image quality, and increase fps;
    When network delay >= DELAY_THRESHOLD_150MS, set minimum fps according to image quality, and decrease fps;
c. second timeout / TestDelay receive => keep the shared encoder usable for the
   healthiest subscriber; per-viewer queues discard obsolete frames independently

ratio adjust is also scoped to one video service:
a. user set image quality => update to the latest quality for that service
b. 3 seconds timeout => update ratio according to network delay
    When network delay < DELAY_THRESHOLD_150MS, increase ratio, max 150kbps;
    When network delay >= DELAY_THRESHOLD_150MS, decrease ratio;

adjust between FPS and ratio:
    When network delay < DELAY_THRESHOLD_150MS, fps is always higher than the minimum fps, and ratio is increasing;
    When network delay >= DELAY_THRESHOLD_150MS, fps is always lower than the minimum fps, and ratio is decreasing;

delay:
    use delay minus RTT as the actual network delay
*/

// Constants
pub const FPS: u32 = 30;
pub const MIN_FPS: u32 = 1;
pub const MAX_FPS: u32 = 120;
pub const INIT_FPS: u32 = 15;
const STARTUP_SAFE_WINDOW: Duration = Duration::from_secs(8);
const STARTUP_SAFE_FPS: u32 = 5;
const STARTUP_SAFE_RATIO: f32 = 0.25;

// Bitrate ratio constants for different quality levels
const BR_MAX: f32 = 40.0; // 2000 * 2 / 100
const BR_MIN: f32 = 0.2;
const BR_MIN_HIGH_RESOLUTION: f32 = 0.1; // For high resolution, BR_MIN is still too high, so we set a lower limit
const MAX_BR_MULTIPLE: f32 = 1.0;

const HISTORY_DELAY_LEN: usize = 2;
const ADJUST_RATIO_INTERVAL: usize = 3; // Adjust quality ratio every 3 seconds
const DYNAMIC_SCREEN_THRESHOLD: usize = 2; // Allow increase quality ratio if encode more than 2 times in one second
const DELAY_THRESHOLD_150MS: u32 = 150; // 150ms is the threshold for good network condition
const TRANSPORT_LOSS_WINDOW: Duration = Duration::from_secs(10);
const TRANSPORT_LOSS_BACKOFF_COOLDOWN: Duration = Duration::from_secs(5);
const TRANSPORT_LOSS_BURST_DROPS: u64 = 3;
const TRANSPORT_LOSS_MIN_RATE_DROPS: u64 = 3;
const TRANSPORT_LOSS_MIN_OBSERVED_FRAMES: u64 = 30;
const TRANSPORT_LOSS_RATE_PERCENT: u64 = 3;
const TRANSPORT_LOSS_BACKOFF_NUMERATOR: u32 = 7;
const TRANSPORT_LOSS_BACKOFF_DENOMINATOR: u32 = 8;
const MAX_TRANSPORT_LOSS_WINDOWS: usize = 16;
const DATAGRAM_ADMISSION_SAMPLE_FRESHNESS: Duration = Duration::from_millis(1_500);
const DATAGRAM_ADMISSION_PRESSURE_DURATION: Duration = Duration::from_secs(1);
const DATAGRAM_ADMISSION_ACTION_COOLDOWN: Duration = Duration::from_secs(2);
const DATAGRAM_ADMISSION_UPSHIFT_FREEZE: Duration = Duration::from_secs(6);
const DATAGRAM_ADMISSION_CLEAN_RESET: Duration = Duration::from_secs(5);
const DATAGRAM_ADMISSION_MAX_RATIO_REDUCTIONS: u8 = 4;
const DATAGRAM_ADMISSION_CADENCE_EVENTS: u8 = 3;
const DATAGRAM_ADMISSION_MIN_REJECT_PERMILLE: u64 = 20;
const DATAGRAM_ADMISSION_PREEMPTIVE_QUEUE_PERMILLE: u64 = 850;
const DATAGRAM_ADMISSION_EVENT_INTERVAL: Duration = Duration::from_millis(500);
const MAX_DATAGRAM_ADMISSION_SERVICES: usize = 16;
const CUSTOM_CONGESTION_EPISODE_CLEAN_RESET: Duration = Duration::from_secs(15);
const CUSTOM_CONGESTION_EPISODE_FLOOR_MULTIPLIER: f32 = 0.5;
const CUSTOM_CONGESTION_MAX_TRANSPORT_REDUCTIONS: u8 = 3;
const NVENC_RATIO_UPSHIFT_INTERVAL: Duration = Duration::from_secs(10);
const NVENC_RATIO_UPSHIFT_KBPS: u32 = 500;
pub(crate) const MOVIE_BOOTSTRAP_FPS: u32 = STARTUP_SAFE_FPS;
pub(crate) const MOVIE_BOOTSTRAP_TIMEOUT: Duration = STARTUP_SAFE_WINDOW;
const MOVIE_FEEDBACK_FRESHNESS: Duration = Duration::from_secs(2);
const MOVIE_PROBATION_HEALTHY: Duration = Duration::from_secs(2);
const MOVIE_PRESSURE_DURATION: Duration = Duration::from_secs(2);
const MOVIE_UPSHIFT_HEALTHY: Duration = Duration::from_secs(20);
const MOVIE_MINIMUM_DWELL: Duration = Duration::from_secs(10);
const MAX_MOVIE_FEEDBACK_DISPLAYS: usize = 16;

#[derive(Default, Debug, Clone)]
struct UserDelay {
    response_delayed: bool,
    delay_history: VecDeque<u32>,
    fps: Option<u32>,
    rtt_calculator: RttCalculator,
    quick_increase_fps_count: usize,
    increase_fps_count: usize,
}

#[derive(Default, Debug, Clone)]
struct MovieViewerFeedback {
    queue_depth_frames: u32,
    decode_time_us: u32,
    render_submit_time_us: u32,
    dropped_frames: u64,
    display_refresh_millihz: u32,
    presentation_late_frames: u64,
    presentation_dropped_frames: u64,
    presentation_jitter_p95_us: u32,
    updated_at: Option<Instant>,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct TransportLossKey {
    display: i32,
    stream_id: u64,
}

#[derive(Clone, Debug)]
struct TransportLossWindow {
    first_frame_id: u64,
    highest_frame_id: u64,
    dropped_frames: u64,
    started_at: Instant,
    updated_at: Instant,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct VideoTransportLossSample {
    pub(crate) display: i32,
    pub(crate) stream_id: u64,
    pub(crate) received_frame_id: u64,
    pub(crate) dropped_frames: u64,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct VideoDatagramAdmissionSample {
    pub(crate) rejected_active: u64,
    pub(crate) frames_sent: u64,
    pub(crate) queue_delay_us: u64,
    pub(crate) queue_budget_bytes: u64,
    pub(crate) queued_bytes: u64,
    pub(crate) datagram_bytes_p99: u64,
    pub(crate) required_bytes_p99: u64,
}

#[derive(Clone, Copy, Debug, Default)]
struct DatagramAdmissionState {
    rejected_active: u64,
    frames_sent: u64,
    pressured: bool,
    updated_at: Option<Instant>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TransportLossBackoffReason {
    Burst,
    Rate,
}

impl TransportLossBackoffReason {
    fn as_str(self) -> &'static str {
        match self {
            Self::Burst => "burst",
            Self::Rate => "rate",
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct TransportLossObservation {
    key: TransportLossKey,
    observed_frames: u64,
    dropped_frames: u64,
    loss_permille: u64,
    reason: Option<TransportLossBackoffReason>,
    stale: bool,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct MovieViewerMetrics {
    pub(crate) available: bool,
    pub(crate) all_rendered: bool,
    pub(crate) max_queue_depth_frames: u32,
    pub(crate) max_decode_time_us: u32,
    pub(crate) max_render_submit_time_us: u32,
    pub(crate) dropped_frames: u64,
    pub(crate) display_refresh_millihz: u32,
    pub(crate) presentation_late_frames: u64,
    pub(crate) presentation_dropped_frames: u64,
    pub(crate) presentation_jitter_p95_us: u32,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct MovieCadenceSample {
    pub(crate) now: Instant,
    pub(crate) target_fps: u32,
    pub(crate) host_pipeline_p95_us: u64,
    pub(crate) host_iterations: u64,
    pub(crate) host_missed_slots: u64,
    pub(crate) viewer: MovieViewerMetrics,
    pub(crate) local_admission_pressure: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum MovieCadenceReason {
    ProbationComplete,
    HostCapacity,
    ViewerCapacity,
    DeliveryPressure,
    HealthyUpshift,
    TargetChanged,
}

impl MovieCadenceReason {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::ProbationComplete => "probation-complete",
            Self::HostCapacity => "host-capacity",
            Self::ViewerCapacity => "viewer-capacity",
            Self::DeliveryPressure => "delivery-pressure",
            Self::HealthyUpshift => "healthy-upshift",
            Self::TargetChanged => "target-changed",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct MovieCadenceDecision {
    pub(crate) previous_fps: u32,
    pub(crate) current_fps: u32,
    pub(crate) reason: MovieCadenceReason,
}

#[derive(Debug)]
pub(crate) struct MovieCadenceController {
    target_fps: u32,
    tiers: Vec<u32>,
    current_tier: u32,
    last_change: Instant,
    pressure_since: Option<Instant>,
    healthy_since: Option<Instant>,
    probation_complete: bool,
    refresh_millihz: u32,
    last_viewer_counters: Option<(u64, u64, u64)>,
}

impl MovieCadenceController {
    pub(crate) fn new(target_fps: u32, refresh_millihz: u32, now: Instant) -> Self {
        let target_fps = target_fps.clamp(MIN_FPS, MAX_FPS);
        let tiers = movie_cadence_tiers(target_fps, refresh_millihz);
        let current_tier = tiers
            .iter()
            .copied()
            .find(|fps| *fps <= FPS)
            .unwrap_or_else(|| tiers.last().copied().unwrap_or(target_fps));
        Self {
            target_fps,
            tiers,
            current_tier,
            last_change: now,
            pressure_since: None,
            healthy_since: None,
            probation_complete: current_tier == target_fps,
            refresh_millihz,
            last_viewer_counters: None,
        }
    }

    pub(crate) fn target_fps(&self) -> u32 {
        self.target_fps
    }

    pub(crate) fn current_tier(&self) -> u32 {
        self.current_tier
    }

    pub(crate) fn reject_change(&mut self, previous_fps: u32, rejected_fps: u32, now: Instant) {
        self.current_tier = previous_fps;
        if rejected_fps > previous_fps {
            self.tiers.retain(|fps| *fps <= previous_fps);
            self.probation_complete = true;
        }
        self.last_change = now;
        self.pressure_since = None;
        self.healthy_since = None;
    }

    pub(crate) fn evaluate(&mut self, sample: MovieCadenceSample) -> Option<MovieCadenceDecision> {
        if let Some(decision) = self.update_target(
            sample.target_fps,
            sample.viewer.display_refresh_millihz,
            sample.now,
        ) {
            return Some(decision);
        }
        self.update_probation_tiers(sample.viewer.display_refresh_millihz);
        let frame_period_us = 1_000_000u64 / u64::from(self.current_tier.max(1));
        let missed_ratio = if sample.host_iterations == 0 {
            0.0
        } else {
            sample.host_missed_slots as f64 / sample.host_iterations as f64
        };
        let (dropped_delta, late_delta, presentation_dropped_delta) =
            self.viewer_counter_deltas(sample.viewer);
        let at_or_below_baseline = self.target_fps >= FPS && self.current_tier <= FPS;
        let host_pressure = if at_or_below_baseline {
            sample.host_pipeline_p95_us > frame_period_us * 95 / 100 || missed_ratio > 0.20
        } else {
            sample.host_pipeline_p95_us > frame_period_us || missed_ratio > 0.10
        };
        let viewer_pressure = sample.viewer.available
            && (sample.viewer.max_queue_depth_frames > 3
                || u64::from(sample.viewer.max_decode_time_us) > frame_period_us * 95 / 100
                || u64::from(sample.viewer.max_render_submit_time_us) > frame_period_us * 95 / 100
                || u64::from(sample.viewer.presentation_jitter_p95_us) > frame_period_us / 2);
        let delivery_pressure = dropped_delta > 0
            || late_delta > 0
            || presentation_dropped_delta > 0
            || sample.local_admission_pressure;
        let pressured = host_pressure || viewer_pressure || delivery_pressure;

        if pressured {
            self.healthy_since = None;
            let pressure_since = *self.pressure_since.get_or_insert(sample.now);
            if sample.now.saturating_duration_since(pressure_since) >= MOVIE_PRESSURE_DURATION {
                let reason = if host_pressure {
                    MovieCadenceReason::HostCapacity
                } else if viewer_pressure {
                    MovieCadenceReason::ViewerCapacity
                } else {
                    MovieCadenceReason::DeliveryPressure
                };
                if let Some(next) = self.next_lower_tier() {
                    return self.change_tier(next, reason, sample.now);
                }
            }
            return None;
        }

        self.pressure_since = None;
        let Some(next) = self.next_higher_tier() else {
            self.probation_complete = true;
            self.healthy_since = None;
            return None;
        };
        let next_period_us = 1_000_000u64 / u64::from(next.max(1));
        let (host_headroom_percent, viewer_headroom_percent) = if self.probation_complete {
            (65, 65)
        } else {
            (95, 90)
        };
        let healthy = sample.viewer.available
            && sample.viewer.all_rendered
            && sample.host_pipeline_p95_us > 0
            && sample.host_pipeline_p95_us <= next_period_us * host_headroom_percent / 100
            && sample.host_missed_slots == 0
            && sample.viewer.max_queue_depth_frames <= 1
            && u64::from(sample.viewer.max_decode_time_us)
                <= next_period_us * viewer_headroom_percent / 100
            && u64::from(sample.viewer.max_render_submit_time_us)
                <= next_period_us * viewer_headroom_percent / 100;
        if !healthy {
            self.healthy_since = None;
            return None;
        }

        let healthy_since = *self.healthy_since.get_or_insert(sample.now);
        let healthy_required = if self.probation_complete {
            MOVIE_UPSHIFT_HEALTHY
        } else {
            MOVIE_PROBATION_HEALTHY
        };
        if sample.now.saturating_duration_since(healthy_since) < healthy_required {
            return None;
        }
        if self.probation_complete
            && sample.now.saturating_duration_since(self.last_change) < MOVIE_MINIMUM_DWELL
        {
            return None;
        }
        let reason = if self.probation_complete {
            MovieCadenceReason::HealthyUpshift
        } else {
            MovieCadenceReason::ProbationComplete
        };
        self.change_tier(next, reason, sample.now)
    }

    fn update_probation_tiers(&mut self, refresh_millihz: u32) {
        if self.probation_complete
            || refresh_millihz == 0
            || refresh_millihz == self.refresh_millihz
        {
            return;
        }
        let tiers = movie_cadence_tiers(self.target_fps, refresh_millihz);
        if tiers.contains(&self.current_tier) {
            self.tiers = tiers;
            self.refresh_millihz = refresh_millihz;
        }
    }

    fn update_target(
        &mut self,
        target_fps: u32,
        refresh_millihz: u32,
        now: Instant,
    ) -> Option<MovieCadenceDecision> {
        let target_fps = target_fps.clamp(MIN_FPS, MAX_FPS);
        if target_fps == self.target_fps {
            return None;
        }

        let previous_target = self.target_fps;
        self.target_fps = target_fps;
        let mut tiers = movie_cadence_tiers(target_fps, refresh_millihz);
        if target_fps > previous_target
            && self.current_tier < target_fps
            && !tiers.contains(&self.current_tier)
        {
            tiers.push(self.current_tier);
            tiers.sort_unstable_by(|left, right| right.cmp(left));
        }
        self.tiers = tiers;
        self.refresh_millihz = refresh_millihz;
        self.pressure_since = None;
        self.healthy_since = None;

        if !self.tiers.contains(&self.current_tier) {
            let next = self.tiers.first().copied().unwrap_or(target_fps);
            return self.change_tier(next, MovieCadenceReason::TargetChanged, now);
        }
        self.probation_complete = self.current_tier >= target_fps;
        None
    }

    fn viewer_counter_deltas(&mut self, viewer: MovieViewerMetrics) -> (u64, u64, u64) {
        let current = (
            viewer.dropped_frames,
            viewer.presentation_late_frames,
            viewer.presentation_dropped_frames,
        );
        let Some(previous) = self.last_viewer_counters.replace(current) else {
            return (0, 0, 0);
        };
        (
            monotonic_counter_delta(current.0, previous.0),
            monotonic_counter_delta(current.1, previous.1),
            monotonic_counter_delta(current.2, previous.2),
        )
    }

    fn next_lower_tier(&self) -> Option<u32> {
        let current = self
            .tiers
            .iter()
            .position(|fps| *fps == self.current_tier)?;
        self.tiers.get(current + 1).copied()
    }

    fn next_higher_tier(&self) -> Option<u32> {
        let current = self
            .tiers
            .iter()
            .position(|fps| *fps == self.current_tier)?;
        current
            .checked_sub(1)
            .and_then(|index| self.tiers.get(index).copied())
    }

    fn change_tier(
        &mut self,
        next: u32,
        reason: MovieCadenceReason,
        now: Instant,
    ) -> Option<MovieCadenceDecision> {
        if next == self.current_tier {
            return None;
        }
        let previous_fps = self.current_tier;
        self.current_tier = next;
        self.last_change = now;
        self.pressure_since = None;
        self.healthy_since = None;
        self.probation_complete = true;
        Some(MovieCadenceDecision {
            previous_fps,
            current_fps: next,
            reason,
        })
    }
}

fn monotonic_counter_delta(current: u64, previous: u64) -> u64 {
    if current >= previous {
        current - previous
    } else {
        0
    }
}

fn movie_cadence_tiers(target_fps: u32, refresh_millihz: u32) -> Vec<u32> {
    const COMMON_TIERS: [u32; 8] = [60, 50, 48, 45, 40, 30, 25, 24];
    let target_fps = target_fps.clamp(MIN_FPS, MAX_FPS);
    let mut tiers: Vec<u32> = if refresh_millihz == 0 {
        COMMON_TIERS
            .into_iter()
            .filter(|fps| *fps <= target_fps)
            .take(1)
            .collect()
    } else {
        COMMON_TIERS
            .into_iter()
            .filter(|fps| {
                if *fps > target_fps {
                    return false;
                }
                if *fps == FPS && target_fps >= FPS {
                    return true;
                }
                let periods = refresh_millihz as f64 / (*fps as f64 * 1_000.0);
                (periods - periods.round()).abs() <= 0.02
            })
            .collect()
    };
    if target_fps >= FPS && !tiers.contains(&FPS) {
        tiers.push(FPS);
    }
    if tiers.is_empty() {
        tiers.push(target_fps);
    }
    tiers.sort_unstable_by(|left, right| right.cmp(left));
    tiers.dedup();
    tiers
}

impl UserDelay {
    fn add_delay(&mut self, delay: u32) {
        self.rtt_calculator.update(delay);
        if self.delay_history.len() > HISTORY_DELAY_LEN {
            self.delay_history.pop_front();
        }
        self.delay_history.push_back(delay);
    }

    // Average delay minus RTT
    fn avg_delay(&self) -> u32 {
        let len = self.delay_history.len();
        if len > 0 {
            let avg_delay = self.delay_history.iter().sum::<u32>() / len as u32;

            // If RTT is available, subtract it from average delay to get actual network latency
            if let Some(rtt) = self.rtt_calculator.get_rtt() {
                if avg_delay > rtt {
                    avg_delay - rtt
                } else {
                    avg_delay
                }
            } else {
                avg_delay
            }
        } else {
            DELAY_THRESHOLD_150MS
        }
    }
}

fn observe_transport_loss(
    windows: &mut HashMap<TransportLossKey, TransportLossWindow>,
    sample: VideoTransportLossSample,
    now: Instant,
) -> TransportLossObservation {
    let key = TransportLossKey {
        display: sample.display,
        stream_id: sample.stream_id,
    };
    windows.retain(|existing, _| {
        existing.display != sample.display || existing.stream_id == sample.stream_id
    });

    if windows
        .get(&key)
        .is_some_and(|window| sample.received_frame_id <= window.highest_frame_id)
    {
        return TransportLossObservation {
            key,
            observed_frames: 0,
            dropped_frames: 0,
            loss_permille: 0,
            reason: None,
            stale: true,
        };
    }

    if !windows.contains_key(&key) && windows.len() >= MAX_TRANSPORT_LOSS_WINDOWS {
        if let Some(oldest) = windows
            .iter()
            .min_by_key(|(_, window)| window.updated_at)
            .map(|(key, _)| *key)
        {
            windows.remove(&oldest);
        }
    }

    let window = windows.entry(key).or_insert(TransportLossWindow {
        first_frame_id: sample.received_frame_id,
        highest_frame_id: sample.received_frame_id,
        dropped_frames: 0,
        started_at: now,
        updated_at: now,
    });
    if now.saturating_duration_since(window.started_at) >= TRANSPORT_LOSS_WINDOW {
        *window = TransportLossWindow {
            first_frame_id: sample.received_frame_id,
            highest_frame_id: sample.received_frame_id,
            dropped_frames: 0,
            started_at: now,
            updated_at: now,
        };
    }
    window.highest_frame_id = sample.received_frame_id;
    window.dropped_frames = window.dropped_frames.saturating_add(sample.dropped_frames);
    window.updated_at = now;

    let observed_frames = window
        .highest_frame_id
        .saturating_sub(window.first_frame_id)
        .saturating_add(1)
        .max(window.dropped_frames)
        .max(1);
    let loss_permille = window.dropped_frames.saturating_mul(1_000) / observed_frames;
    let reason = if sample.dropped_frames >= TRANSPORT_LOSS_BURST_DROPS {
        Some(TransportLossBackoffReason::Burst)
    } else if window.dropped_frames >= TRANSPORT_LOSS_MIN_RATE_DROPS
        && observed_frames >= TRANSPORT_LOSS_MIN_OBSERVED_FRAMES
        && window.dropped_frames.saturating_mul(100)
            >= observed_frames.saturating_mul(TRANSPORT_LOSS_RATE_PERCENT)
    {
        Some(TransportLossBackoffReason::Rate)
    } else {
        None
    };

    TransportLossObservation {
        key,
        observed_frames,
        dropped_frames: window.dropped_frames,
        loss_permille,
        reason,
        stale: false,
    }
}

fn minimum_ratio_for_quality(
    target_quality: Quality,
    current_ratio: f32,
    current_bitrate: u32,
) -> f32 {
    let ratio_1mbps = (current_bitrate > 0)
        .then(|| (current_ratio * 1000.0 / current_bitrate as f32).max(BR_MIN_HIGH_RESOLUTION));
    match target_quality {
        Quality::Best => {
            let mut min = BR_BEST / 2.5;
            if let Some(ratio_1mbps) = ratio_1mbps {
                min = min.min(ratio_1mbps);
            }
            min.max(BR_MIN)
        }
        Quality::Balanced => {
            let mut min = (BR_BALANCED / 2.0).min(0.4);
            if let Some(ratio_1mbps) = ratio_1mbps {
                min = min.min(ratio_1mbps);
            }
            min.max(BR_MIN_HIGH_RESOLUTION)
        }
        Quality::Low | Quality::Custom(_) => BR_MIN_HIGH_RESOLUTION,
    }
}

// User session data structure
#[derive(Debug, Clone)]
struct ViewerStartupState {
    stream_id: Option<u64>,
    render_started: bool,
    started_at: Instant,
}

impl ViewerStartupState {
    fn new(now: Instant) -> Self {
        Self {
            stream_id: None,
            render_started: false,
            started_at: now,
        }
    }

    fn begin_stream(&mut self, stream_id: u64, now: Instant) -> bool {
        if self.stream_id == Some(stream_id) {
            return true;
        }
        if self.stream_id.is_some_and(|current| stream_id < current) {
            return false;
        }
        self.stream_id = Some(stream_id);
        self.render_started = false;
        self.started_at = now;
        true
    }

    fn reset(&mut self, now: Instant) {
        self.stream_id = None;
        self.render_started = false;
        self.started_at = now;
    }
}

#[derive(Default, Debug, Clone)]
struct UserData {
    auto_adjust_fps: Option<u32>, // reserve for compatibility
    custom_fps: Option<u32>,
    fixed_fps: Option<u32>,
    quality: Option<(i64, Quality)>, // (time, quality)
    delay: UserDelay,
    record: bool,
    video_feedback_capable: bool,
    video_startup_by_service: BTreeMap<String, ViewerStartupState>,
    last_transport_loss_at: Option<Instant>,
    transport_loss_windows: HashMap<TransportLossKey, TransportLossWindow>,
    video_profile: VideoProfile,
    movie_transport_capable: bool,
    movie_feedback_by_display: HashMap<i32, MovieViewerFeedback>,
    datagram_admission_by_service: HashMap<String, DatagramAdmissionState>,
    transport_loss_upshift_frozen_until: HashMap<String, Instant>,
}

#[derive(Debug, Clone)]
struct DisplayData {
    send_counter: usize, // Number of times encode during period
    support_changing_quality: bool,
    subscribers: HashSet<i32>,
    fps: u32,
    ratio: f32,
    bitrate_store: u32,
    capture_backend: Option<String>,
    capture_frame: Option<String>,
    encoder_backend: Option<String>,
    encoder_input: Option<String>,
    adjust_ratio_instant: Instant,
    movie_target_fps: u32,
    movie_pacing_fps: u32,
    movie_host_pipeline_p95_us: u32,
    admission_pressure_since: Option<Instant>,
    admission_clean_since: Option<Instant>,
    admission_events: u8,
    admission_ratio_reductions: u8,
    movie_admission_pressure: bool,
    admission_latched_at: Option<Instant>,
    last_admission_event_at: Option<Instant>,
    upshift_frozen_until: Option<Instant>,
    last_congestion_reduction_at: Option<Instant>,
    congestion_episode_floor_ratio: Option<f32>,
    congestion_episode_last_pressure_at: Option<Instant>,
    congestion_episode_transport_reductions: u8,
    last_nvenc_ratio_upshift_at: Option<Instant>,
}

impl Default for DisplayData {
    fn default() -> Self {
        Self {
            send_counter: 0,
            support_changing_quality: false,
            subscribers: HashSet::new(),
            fps: FPS,
            ratio: BR_BALANCED,
            bitrate_store: 0,
            capture_backend: None,
            capture_frame: None,
            encoder_backend: None,
            encoder_input: None,
            adjust_ratio_instant: Instant::now(),
            movie_target_fps: 0,
            movie_pacing_fps: 0,
            movie_host_pipeline_p95_us: 0,
            admission_pressure_since: None,
            admission_clean_since: None,
            admission_events: 0,
            admission_ratio_reductions: 0,
            movie_admission_pressure: false,
            admission_latched_at: None,
            last_admission_event_at: None,
            upshift_frozen_until: None,
            last_congestion_reduction_at: None,
            congestion_episode_floor_ratio: None,
            congestion_episode_last_pressure_at: None,
            congestion_episode_transport_reductions: 0,
            last_nvenc_ratio_upshift_at: None,
        }
    }
}

impl DisplayData {
    fn uses_nvenc(&self) -> bool {
        self.encoder_backend
            .as_deref()
            .is_some_and(|backend| backend.contains("NVENC"))
    }

    fn clear_custom_congestion_episode(&mut self) {
        self.congestion_episode_floor_ratio = None;
        self.congestion_episode_last_pressure_at = None;
        self.congestion_episode_transport_reductions = 0;
    }

    fn expire_custom_congestion_episode(&mut self, now: Instant) -> bool {
        if self
            .congestion_episode_last_pressure_at
            .is_some_and(|last| {
                now.saturating_duration_since(last) >= CUSTOM_CONGESTION_EPISODE_CLEAN_RESET
            })
        {
            self.clear_custom_congestion_episode();
            return true;
        }
        false
    }

    fn touch_custom_congestion_episode(
        &mut self,
        target_quality: Quality,
        now: Instant,
    ) -> Option<f32> {
        if !target_quality.is_custom() {
            self.clear_custom_congestion_episode();
            return None;
        }
        self.expire_custom_congestion_episode(now);
        if self.congestion_episode_floor_ratio.is_none() {
            let quality_minimum =
                minimum_ratio_for_quality(target_quality, self.ratio, self.bitrate_store);
            self.congestion_episode_floor_ratio = Some(
                (self.ratio * CUSTOM_CONGESTION_EPISODE_FLOOR_MULTIPLIER).max(quality_minimum),
            );
        }
        let floor = self.congestion_episode_floor_ratio.unwrap_or_default();
        self.congestion_episode_last_pressure_at = Some(now);
        Some(floor)
    }
}

// Main QoS controller structure
pub struct VideoQoS {
    users: HashMap<i32, UserData>,
    displays: HashMap<String, DisplayData>,
    abr_config: bool,
}

impl Default for VideoQoS {
    fn default() -> Self {
        VideoQoS {
            users: Default::default(),
            displays: Default::default(),
            abr_config: true,
        }
    }
}

// Basic functionality
impl VideoQoS {
    // Calculate seconds per frame based on current FPS
    pub fn spf(&self, video_service_name: &str) -> Duration {
        Duration::from_secs_f32(1. / (self.fps(video_service_name) as f32))
    }

    // Get current FPS within valid range
    pub fn fps(&self, video_service_name: &str) -> u32 {
        let fps = self
            .displays
            .get(video_service_name)
            .map(|display| display.fps)
            .unwrap_or(FPS);
        if fps >= MIN_FPS && fps <= MAX_FPS {
            fps
        } else {
            FPS
        }
    }

    // Store bitrate for later use
    pub fn store_bitrate(&mut self, video_service_name: &str, bitrate: u32) {
        if let Some(display) = self.displays.get_mut(video_service_name) {
            display.bitrate_store = bitrate;
        }
    }

    // Get stored bitrate
    pub fn bitrate(&self, video_service_name: &str) -> u32 {
        self.displays
            .get(video_service_name)
            .map(|display| display.bitrate_store)
            .unwrap_or_default()
    }

    pub fn store_pipeline_status(
        &mut self,
        video_service_name: &str,
        capture_backend: &str,
        encoder_backend: &str,
        encoder_input: &str,
    ) {
        if let Some(display) = self.displays.get_mut(video_service_name) {
            display.capture_backend = Some(capture_backend.to_owned());
            display.encoder_backend = Some(encoder_backend.to_owned());
            display.encoder_input = Some(encoder_input.to_owned());
        }
    }

    pub fn store_capture_frame(&mut self, video_service_name: &str, capture_frame: &str) -> bool {
        let Some(display) = self.displays.get_mut(video_service_name) else {
            return false;
        };
        if display.capture_frame.as_deref() == Some(capture_frame) {
            return false;
        }
        display.capture_frame = Some(capture_frame.to_owned());
        true
    }

    pub fn pipeline_status(
        &self,
        video_service_name: &str,
    ) -> (
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
    ) {
        self.displays
            .get(video_service_name)
            .map(|display| {
                (
                    display.capture_backend.clone(),
                    display.capture_frame.clone(),
                    display.encoder_backend.clone(),
                    display.encoder_input.clone(),
                )
            })
            .unwrap_or_default()
    }

    pub(crate) fn store_movie_runtime_status(
        &mut self,
        video_service_name: &str,
        target_fps: u32,
        pacing_fps: u32,
        host_pipeline_p95_us: u64,
    ) {
        if let Some(display) = self.displays.get_mut(video_service_name) {
            display.movie_target_fps = target_fps;
            display.movie_pacing_fps = pacing_fps;
            if target_fps > 0 && pacing_fps > 0 {
                display.fps = pacing_fps.clamp(MIN_FPS, MAX_FPS);
            }
            display.movie_host_pipeline_p95_us =
                host_pipeline_p95_us.min(u64::from(u32::MAX)) as u32;
        }
    }

    pub(crate) fn movie_runtime_status(&self, video_service_name: &str) -> (u32, u32, u32) {
        self.displays
            .get(video_service_name)
            .map(|display| {
                (
                    display.movie_target_fps,
                    display.movie_pacing_fps,
                    display.movie_host_pipeline_p95_us,
                )
            })
            .unwrap_or_default()
    }

    pub(crate) fn movie_admission_pressure_at(
        &mut self,
        video_service_name: &str,
        now: Instant,
    ) -> bool {
        let Some(display) = self.displays.get_mut(video_service_name) else {
            return false;
        };
        if display.admission_latched_at.is_some_and(|latched| {
            now.saturating_duration_since(latched) >= DATAGRAM_ADMISSION_CLEAN_RESET * 2
        }) {
            display.admission_pressure_since = None;
            display.admission_clean_since = None;
            display.admission_events = 0;
            display.admission_ratio_reductions = 0;
            display.movie_admission_pressure = false;
            display.admission_latched_at = None;
            display.last_admission_event_at = None;
            display.upshift_frozen_until = None;
        }
        for user in self.users.values_mut() {
            user.datagram_admission_by_service
                .remove(video_service_name);
        }
        display.movie_admission_pressure
    }

    // Get current bitrate ratio with bounds checking
    pub fn ratio(&mut self, video_service_name: &str) -> f32 {
        let startup_safe = self.startup_safe_mode(video_service_name);
        let Some(display) = self.displays.get_mut(video_service_name) else {
            return BR_BALANCED;
        };
        if display.ratio < BR_MIN_HIGH_RESOLUTION || display.ratio > BR_MAX {
            display.ratio = BR_BALANCED;
        }
        if startup_safe {
            return display.ratio.min(STARTUP_SAFE_RATIO);
        }
        display.ratio
    }

    pub fn startup_safe_mode(&self, video_service_name: &str) -> bool {
        let Some(display) = self.displays.get(video_service_name) else {
            return false;
        };
        if self.locked_fps(video_service_name).is_some() {
            return false;
        }
        let mut has_established_viewer = false;
        let mut has_starting_viewer = false;
        for user in display
            .subscribers
            .iter()
            .filter_map(|id| self.users.get(id))
        {
            let Some(startup) = user.video_startup_by_service.get(video_service_name) else {
                continue;
            };
            has_established_viewer |= startup.render_started;
            has_starting_viewer |=
                !startup.render_started && startup.started_at.elapsed() < STARTUP_SAFE_WINDOW;
        }
        !has_established_viewer && has_starting_viewer
    }

    // Check if any user is in recording mode
    pub fn record(&self, video_service_name: &str) -> bool {
        self.displays
            .get(video_service_name)
            .is_some_and(|display| {
                display
                    .subscribers
                    .iter()
                    .filter_map(|id| self.users.get(id))
                    .any(|user| user.record)
            })
    }

    pub fn set_support_changing_quality(&mut self, video_service_name: &str, support: bool) {
        if let Some(display) = self.displays.get_mut(video_service_name) {
            display.support_changing_quality = support;
        }
    }

    // Check if variable bitrate encoding is supported and enabled
    pub fn in_vbr_state(&self, video_service_name: &str) -> bool {
        self.abr_config
            && self
                .displays
                .get(video_service_name)
                .is_some_and(|display| display.support_changing_quality)
    }

    fn clear_datagram_admission_for_display(&mut self, video_service_name: &str) {
        if let Some(display) = self.displays.get_mut(video_service_name) {
            display.admission_pressure_since = None;
            display.admission_clean_since = None;
            display.admission_events = 0;
            display.admission_ratio_reductions = 0;
            display.movie_admission_pressure = false;
            display.admission_latched_at = None;
            display.last_admission_event_at = None;
            display.upshift_frozen_until = None;
        }
    }

    pub(crate) fn clear_user_datagram_admission(&mut self, id: i32) {
        if let Some(user) = self.users.get_mut(&id) {
            user.datagram_admission_by_service.clear();
        }
        for display_name in self.display_names_for_user(id) {
            if !self.full_movie_mode(&display_name) {
                self.clear_datagram_admission_for_display(&display_name);
            }
        }
    }

    fn custom_adaptive_display_names_for_user(&self, id: i32) -> Vec<String> {
        let custom_quality = self
            .users
            .get(&id)
            .is_some_and(|user| user.quality.is_some_and(|(_, quality)| quality.is_custom()));
        if !custom_quality {
            return Vec::new();
        }
        self.display_names_for_user(id)
            .into_iter()
            .filter(|display_name| self.in_vbr_state(display_name))
            .collect()
    }

    fn transport_loss_upshift_frozen_for_display(
        &self,
        video_service_name: &str,
        now: Instant,
    ) -> bool {
        let mut subscribers = self.subscribed_users(video_service_name).peekable();
        subscribers.peek().is_some()
            && subscribers.all(|user| {
                user.quality.is_some_and(|(_, quality)| quality.is_custom())
                    && user
                        .transport_loss_upshift_frozen_until
                        .get(video_service_name)
                        .is_some_and(|until| now < *until)
            })
    }

    fn reduce_ratio_for_congestion(
        &mut self,
        video_service_name: &str,
        now: Instant,
        source: &'static str,
        freeze_upshift: bool,
    ) -> bool {
        if !self.in_vbr_state(video_service_name) {
            return false;
        }
        let target_quality = self.latest_quality(video_service_name);
        let Some(display) = self.displays.get_mut(video_service_name) else {
            return false;
        };
        let episode_expired = display.expire_custom_congestion_episode(now);
        let transport_recurrence = source == "transport-loss-recurrence";
        if transport_recurrence
            && target_quality.is_custom()
            && display.congestion_episode_transport_reductions
                >= CUSTOM_CONGESTION_MAX_TRANSPORT_REDUCTIONS
        {
            log::debug!(
                "diag video qos congestion ratio reduction suppressed: service={}, source={}, reason=episode-limit, reductions={}, floor={:.3}",
                video_service_name,
                source,
                display.congestion_episode_transport_reductions,
                display.congestion_episode_floor_ratio.unwrap_or_default(),
            );
            return false;
        }
        let minimum =
            minimum_ratio_for_quality(target_quality, display.ratio, display.bitrate_store);
        let previous = display.ratio;
        let unconstrained_next = (display.ratio * 0.90).max(minimum).min(display.ratio);
        if unconstrained_next >= previous {
            return false;
        }
        if freeze_upshift {
            if let Some(until) = now.checked_add(DATAGRAM_ADMISSION_UPSHIFT_FREEZE) {
                if display
                    .upshift_frozen_until
                    .map_or(true, |current| current < until)
                {
                    display.upshift_frozen_until = Some(until);
                }
            }
        }
        if display.last_congestion_reduction_at.is_some_and(|last| {
            now.saturating_duration_since(last) < DATAGRAM_ADMISSION_ACTION_COOLDOWN
        }) {
            return false;
        }
        let episode_floor = display
            .touch_custom_congestion_episode(target_quality, now)
            .unwrap_or(minimum);
        let next = (display.ratio * 0.90)
            .max(minimum)
            .max(episode_floor)
            .min(display.ratio);
        if next >= previous {
            return false;
        }
        display.ratio = next;
        display.last_congestion_reduction_at = Some(now);
        if transport_recurrence && target_quality.is_custom() {
            display.congestion_episode_transport_reductions = display
                .congestion_episode_transport_reductions
                .saturating_add(1);
        }
        log::warn!(
            "diag video qos congestion ratio reduction: service={}, source={}, previous={:.3}, current={:.3}, bitrate={}, freeze_ms={}, episode_floor={:.3}, episode_transport_reductions={}, episode_expired={}",
            video_service_name,
            source,
            previous,
            display.ratio,
            display.bitrate_store,
            if freeze_upshift {
                DATAGRAM_ADMISSION_UPSHIFT_FREEZE.as_millis()
            } else {
                0
            },
            display.congestion_episode_floor_ratio.unwrap_or(minimum),
            display.congestion_episode_transport_reductions,
            episode_expired,
        );
        true
    }

    pub(crate) fn user_datagram_admission_for_user_at(
        &mut self,
        id: i32,
        sample: VideoDatagramAdmissionSample,
        now: Instant,
    ) -> usize {
        self.display_names_for_user(id)
            .into_iter()
            .filter(|video_service_name| {
                self.user_datagram_admission_at(id, video_service_name, sample, now)
            })
            .count()
    }

    pub(crate) fn user_datagram_admission_at(
        &mut self,
        id: i32,
        video_service_name: &str,
        sample: VideoDatagramAdmissionSample,
        now: Instant,
    ) -> bool {
        if !self.full_movie_mode(video_service_name) {
            self.clear_datagram_admission_for_display(video_service_name);
            return false;
        }
        let (rejected_delta, sent_delta) = {
            let Some(user) = self.users.get_mut(&id) else {
                return false;
            };
            if !user
                .datagram_admission_by_service
                .contains_key(video_service_name)
                && user.datagram_admission_by_service.len() >= MAX_DATAGRAM_ADMISSION_SERVICES
            {
                if let Some(oldest) = user
                    .datagram_admission_by_service
                    .iter()
                    .min_by_key(|(_, state)| state.updated_at)
                    .map(|(name, _)| name.clone())
                {
                    user.datagram_admission_by_service.remove(&oldest);
                }
            }
            let state = user
                .datagram_admission_by_service
                .entry(video_service_name.to_owned())
                .or_default();
            let initialized = state.updated_at.is_some();
            let rejected_delta = initialized
                .then(|| monotonic_counter_delta(sample.rejected_active, state.rejected_active))
                .unwrap_or_default();
            let sent_delta = initialized
                .then(|| monotonic_counter_delta(sample.frames_sent, state.frames_sent))
                .unwrap_or_default();
            let observed = rejected_delta.saturating_add(sent_delta).max(1);
            state.rejected_active = sample.rejected_active;
            state.frames_sent = sample.frames_sent;
            let preemptive_queue_pressure = sample.queue_budget_bytes > 0
                && sample.queued_bytes.saturating_mul(1_000)
                    >= sample
                        .queue_budget_bytes
                        .saturating_mul(DATAGRAM_ADMISSION_PREEMPTIVE_QUEUE_PERMILLE);
            state.pressured = preemptive_queue_pressure
                || (rejected_delta > 0
                    && rejected_delta.saturating_mul(1_000)
                        >= observed.saturating_mul(DATAGRAM_ADMISSION_MIN_REJECT_PERMILLE));
            state.updated_at = Some(now);
            (rejected_delta, sent_delta)
        };

        if rejected_delta > 0 {
            let observed = rejected_delta.saturating_add(sent_delta).max(1);
            log::warn!(
                "diag QUIC video sender admission pressure: user_id={}, service={}, rejected_delta={}, sent_delta={}, reject_permille={}, queue_delay_us={}, queued_bytes={}, queue_budget_bytes={}, datagram_p99={}, required_p99={}",
                id,
                video_service_name,
                rejected_delta,
                sent_delta,
                rejected_delta.saturating_mul(1_000) / observed,
                sample.queue_delay_us,
                sample.queued_bytes,
                sample.queue_budget_bytes,
                sample.datagram_bytes_p99,
                sample.required_bytes_p99,
            );
        }

        let Some(subscribers) = self
            .displays
            .get(video_service_name)
            .map(|display| display.subscribers.iter().copied().collect::<Vec<_>>())
        else {
            return false;
        };
        let statuses = subscribers.iter().filter_map(|subscriber| {
            self.users
                .get(subscriber)?
                .datagram_admission_by_service
                .get(video_service_name)
                .copied()
        });
        let statuses = statuses.collect::<Vec<_>>();
        let all_fresh = !subscribers.is_empty()
            && statuses.len() == subscribers.len()
            && statuses.iter().all(|state| {
                state.updated_at.is_some_and(|updated| {
                    now.saturating_duration_since(updated) <= DATAGRAM_ADMISSION_SAMPLE_FRESHNESS
                })
            });
        let all_pressured = all_fresh && statuses.iter().all(|state| state.pressured);
        let all_clean = all_fresh && statuses.iter().all(|state| !state.pressured);

        let mut should_reduce = false;
        if let Some(display) = self.displays.get_mut(video_service_name) {
            if all_pressured {
                display.admission_clean_since = None;
                if display.movie_admission_pressure {
                    display.admission_latched_at = Some(now);
                }
                let pressure_since = *display.admission_pressure_since.get_or_insert(now);
                if now.saturating_duration_since(pressure_since)
                    >= DATAGRAM_ADMISSION_PRESSURE_DURATION
                {
                    if display.last_admission_event_at.map_or(true, |last| {
                        now.saturating_duration_since(last) >= DATAGRAM_ADMISSION_EVENT_INTERVAL
                    }) {
                        display.last_admission_event_at = Some(now);
                        display.admission_events = display.admission_events.saturating_add(1);
                        if display.admission_events >= DATAGRAM_ADMISSION_CADENCE_EVENTS
                            && !display.movie_admission_pressure
                        {
                            display.movie_admission_pressure = true;
                            display.admission_latched_at = Some(now);
                        }
                    }
                    should_reduce = display.admission_ratio_reductions
                        < DATAGRAM_ADMISSION_MAX_RATIO_REDUCTIONS;
                }
            } else {
                display.admission_pressure_since = None;
                if all_clean {
                    let clean_since = *display.admission_clean_since.get_or_insert(now);
                    if now.saturating_duration_since(clean_since) >= DATAGRAM_ADMISSION_CLEAN_RESET
                    {
                        display.admission_events = 0;
                        display.admission_ratio_reductions = 0;
                        display.movie_admission_pressure = false;
                        display.admission_latched_at = None;
                        display.last_admission_event_at = None;
                        display.upshift_frozen_until = None;
                    }
                } else {
                    display.admission_clean_since = None;
                }
            }
        }

        if !should_reduce
            || !self.reduce_ratio_for_congestion(video_service_name, now, "sender-admission", true)
        {
            return false;
        }
        if let Some(display) = self.displays.get_mut(video_service_name) {
            display.admission_ratio_reductions =
                display.admission_ratio_reductions.saturating_add(1);
        }
        true
    }
}

// User session management
impl VideoQoS {
    // Initialize new user session
    pub fn on_connection_open(&mut self, id: i32) {
        self.users.insert(id, UserData::default());
        self.abr_config = Config::get_option("enable-abr") != "N";
    }

    // Clean up user session
    pub fn on_connection_close(&mut self, id: i32) {
        let affected_displays = self.display_names_for_user(id);
        self.users.remove(&id);
        for display_name in &affected_displays {
            if let Some(display) = self.displays.get_mut(display_name) {
                display.subscribers.remove(&id);
            }
            if !self.full_movie_mode(display_name) {
                self.clear_datagram_admission_for_display(display_name);
            }
            self.adjust_fps(display_name);
        }
    }

    pub fn user_custom_fps(&mut self, id: i32, fps: u32) {
        if fps < MIN_FPS || fps > MAX_FPS {
            log::warn!("custom_fps adaptive ignored: user_id={id}, invalid_fps={fps}");
            return;
        }
        if let Some(user) = self.users.get_mut(&id) {
            user.custom_fps = Some(fps);
            user.fixed_fps = None;
        } else {
            log::warn!("custom_fps adaptive ignored: unknown_user_id={id}, fps={fps}");
            return;
        }
        self.adjust_displays_for_user(id);
        log::info!("custom_fps adaptive applied: user_id={id}, fps={fps}");
    }

    pub fn user_fixed_fps(&mut self, id: i32, fps: u32) {
        if fps < MIN_FPS || fps > MAX_FPS {
            log::warn!("custom_fps fixed ignored: user_id={id}, invalid_fps={fps}");
            return;
        }
        if let Some(user) = self.users.get_mut(&id) {
            user.custom_fps = Some(fps);
            user.fixed_fps = Some(fps);
        } else {
            log::warn!("custom_fps fixed ignored: unknown_user_id={id}, fps={fps}");
            return;
        }
        self.adjust_displays_for_user(id);
        log::info!("custom_fps fixed applied: user_id={id}, fps={fps}");
    }

    pub(crate) fn user_video_profile(&mut self, id: i32, profile: VideoProfile) {
        let Some(user) = self.users.get_mut(&id) else {
            log::warn!(
                "video profile ignored: unknown_user_id={id}, requested={}",
                profile.config_value()
            );
            return;
        };
        let changed = user.video_profile != profile;
        if changed {
            user.delay = UserDelay::default();
            user.auto_adjust_fps = None;
            user.last_transport_loss_at = None;
            user.transport_loss_windows.clear();
            user.movie_feedback_by_display.clear();
            let now = Instant::now();
            for startup in user.video_startup_by_service.values_mut() {
                startup.reset(now);
            }
        }
        user.video_profile = profile;
        if changed {
            self.clear_user_datagram_admission(id);
            self.adjust_displays_for_user(id);
        }
        log::info!(
            "video profile applied: user_id={id}, requested={}, adaptive_state_reset={changed}",
            profile.config_value(),
        );
    }

    pub(crate) fn user_movie_transport_capability(&mut self, id: i32, capable: bool) {
        if let Some(user) = self.users.get_mut(&id) {
            user.movie_transport_capable = capable;
        }
        if !capable {
            self.clear_user_datagram_admission(id);
        }
    }

    pub(crate) fn user_video_feedback(
        &mut self,
        id: i32,
        video_service_name: &str,
        feedback: &VideoFeedback,
    ) {
        let Some(user) = self.users.get_mut(&id) else {
            return;
        };
        let Some(startup) = user.video_startup_by_service.get_mut(video_service_name) else {
            return;
        };
        if !startup.begin_stream(feedback.stream_id, Instant::now()) {
            return;
        }
        if user.video_profile != VideoProfile::Movie {
            return;
        }
        if !user
            .movie_feedback_by_display
            .contains_key(&feedback.display)
            && user.movie_feedback_by_display.len() >= MAX_MOVIE_FEEDBACK_DISPLAYS
        {
            return;
        }
        user.movie_feedback_by_display.insert(
            feedback.display,
            MovieViewerFeedback {
                queue_depth_frames: feedback.queue_depth_frames,
                decode_time_us: feedback.decode_time_us,
                render_submit_time_us: feedback.render_submit_time_us,
                dropped_frames: feedback.dropped_frames,
                display_refresh_millihz: feedback.display_refresh_millihz,
                presentation_late_frames: feedback.presentation_late_frames,
                presentation_dropped_frames: feedback.presentation_dropped_frames,
                presentation_jitter_p95_us: feedback.presentation_jitter_p95_us,
                updated_at: Some(Instant::now()),
            },
        );
    }

    pub fn user_auto_adjust_fps(&mut self, id: i32, fps: u32) {
        if fps < MIN_FPS || fps > MAX_FPS {
            return;
        }
        if let Some(user) = self.users.get_mut(&id) {
            user.auto_adjust_fps = Some(fps);
        }
        self.adjust_displays_for_user(id);
    }

    pub fn user_image_quality(&mut self, id: i32, image_quality: i32) {
        let convert_quality = |q: i32| -> Quality {
            if q == ImageQuality::Balanced.value() {
                Quality::Balanced
            } else if q == ImageQuality::Low.value() {
                Quality::Low
            } else if q == ImageQuality::Best.value() {
                Quality::Best
            } else {
                let b = ((q >> 8 & 0xFFF) * 2) as f32 / 100.0;
                Quality::Custom(b.clamp(BR_MIN, BR_MAX))
            }
        };

        let converted_quality = convert_quality(image_quality);
        let quality = Some((hbb_common::get_time(), converted_quality));
        let mut quality_changed = false;
        if let Some(user) = self.users.get_mut(&id) {
            if user.quality.map(|(_, current)| current) != Some(converted_quality) {
                user.transport_loss_upshift_frozen_until.clear();
                quality_changed = true;
            }
            user.quality = quality;
        } else {
            return;
        }
        for display_name in self.display_names_for_user(id) {
            let ratio = self.latest_quality(&display_name).ratio();
            if let Some(display) = self.displays.get_mut(&display_name) {
                display.ratio = ratio;
                if quality_changed {
                    display.clear_custom_congestion_episode();
                }
            }
        }
    }

    pub fn user_preset_image_quality(&mut self, id: i32, image_quality: i32) {
        if let Some(user) = self.users.get_mut(&id) {
            user.custom_fps = None;
            user.fixed_fps = None;
            user.auto_adjust_fps = None;
        } else {
            return;
        }
        self.user_image_quality(id, image_quality);
        self.adjust_displays_for_user(id);
    }

    pub fn user_record(&mut self, id: i32, v: bool) {
        if let Some(user) = self.users.get_mut(&id) {
            user.record = v;
        }
    }

    pub fn user_video_feedback_capability(&mut self, id: i32, capable: bool) {
        if let Some(user) = self.users.get_mut(&id) {
            user.video_feedback_capable = capable;
            if !capable {
                let now = Instant::now();
                for startup in user.video_startup_by_service.values_mut() {
                    startup.reset(now);
                }
            }
        }
        if !capable {
            self.clear_user_datagram_admission(id);
        }
        self.adjust_displays_for_user(id);
    }

    pub fn user_video_frame_rendered_for_service(
        &mut self,
        id: i32,
        video_service_name: &str,
        stream_id: u64,
    ) -> bool {
        let highest_fps = self.user_requested_fps(id);
        let first_render = self.users.get_mut(&id).is_some_and(|user| {
            let Some(startup) = user.video_startup_by_service.get_mut(video_service_name) else {
                return false;
            };
            if !user.video_feedback_capable
                || startup.stream_id != Some(stream_id)
                || startup.render_started
            {
                return false;
            }
            startup.render_started = true;
            // One end-to-end rendered frame is enough to leave the conservative
            // bootstrap profile. A measured delay sample still takes priority.
            if user.delay.fps.is_none() && !user.delay.response_delayed {
                user.delay.fps = Some(highest_fps);
            }
            true
        });
        if first_render {
            self.adjust_fps(video_service_name);
        }
        first_render
    }

    #[cfg(test)]
    fn user_video_frame_rendered(&mut self, id: i32) -> bool {
        let Some(video_service_name) = self.display_names_for_user(id).into_iter().min() else {
            return false;
        };
        let stream_id = self
            .users
            .get_mut(&id)
            .and_then(|user| user.video_startup_by_service.get_mut(&video_service_name))
            .map(|startup| {
                let stream_id = startup.stream_id.unwrap_or(1);
                startup.begin_stream(stream_id, Instant::now());
                stream_id
            })
            .unwrap_or(1);
        self.user_video_frame_rendered_for_service(id, &video_service_name, stream_id)
    }

    pub(crate) fn user_transport_loss(
        &mut self,
        id: i32,
        sample: VideoTransportLossSample,
    ) -> bool {
        self.user_transport_loss_at(id, sample, Instant::now())
    }

    fn user_transport_loss_at(
        &mut self,
        id: i32,
        sample: VideoTransportLossSample,
        now: Instant,
    ) -> bool {
        if sample.dropped_frames == 0 {
            return false;
        }
        let observation = {
            let Some(user) = self.users.get_mut(&id) else {
                return false;
            };
            let observation = observe_transport_loss(&mut user.transport_loss_windows, sample, now);
            if observation.stale {
                log::debug!(
                    "diag video qos transport loss ignored: user_id={}, display={}, stream_id={}, received_frame_id={}, dropped_frames={}, reason=stale-or-duplicate",
                    id,
                    sample.display,
                    sample.stream_id,
                    sample.received_frame_id,
                    sample.dropped_frames,
                );
                return false;
            }
            observation
        };

        let custom_displays = self.custom_adaptive_display_names_for_user(id);
        if !custom_displays.is_empty() {
            let Some(until) = now.checked_add(DATAGRAM_ADMISSION_UPSHIFT_FREEZE) else {
                return false;
            };
            let previously_frozen = {
                let Some(user) = self.users.get_mut(&id) else {
                    return false;
                };
                let mut previously_frozen = Vec::new();
                for display_name in &custom_displays {
                    if user
                        .transport_loss_upshift_frozen_until
                        .get(display_name)
                        .is_some_and(|current| now < *current)
                    {
                        previously_frozen.push(display_name.clone());
                    }
                    user.transport_loss_upshift_frozen_until
                        .insert(display_name.clone(), until);
                }
                previously_frozen
            };
            let mut reduced_displays = Vec::new();
            for display_name in custom_displays
                .iter()
                .filter(|display_name| !previously_frozen.contains(display_name))
            {
                let target_quality = self.latest_quality(display_name);
                if let Some(display) = self.displays.get_mut(display_name) {
                    display.touch_custom_congestion_episode(target_quality, now);
                }
            }
            for display_name in &previously_frozen {
                if self.transport_loss_upshift_frozen_for_display(display_name, now)
                    && self.reduce_ratio_for_congestion(
                        display_name,
                        now,
                        "transport-loss-recurrence",
                        false,
                    )
                {
                    reduced_displays.push(display_name.clone());
                }
            }
            log::debug!(
                "diag video qos custom transport loss: user_id={}, display={}, stream_id={}, received_frame_id={}, event_dropped={}, window_dropped={}, observed_frames={}, loss_permille={}, reason={}, action={}, transport_upshift_freeze_ms={}, frozen_displays={:?}, reduced_displays={:?}",
                id,
                sample.display,
                sample.stream_id,
                sample.received_frame_id,
                sample.dropped_frames,
                observation.dropped_frames,
                observation.observed_frames,
                observation.loss_permille,
                observation.reason.map(TransportLossBackoffReason::as_str).unwrap_or("none"),
                if reduced_displays.is_empty() {
                    if previously_frozen.is_empty() {
                        "freeze"
                    } else {
                        "recurrence-cooldown"
                    }
                } else {
                    "ratio-reduction"
                },
                DATAGRAM_ADMISSION_UPSHIFT_FREEZE.as_millis(),
                custom_displays,
                reduced_displays,
            );
            return !reduced_displays.is_empty();
        }

        let highest_fps = self.user_requested_fps(id);
        let Some(reason) = observation.reason else {
            log::debug!(
                "diag video qos transport loss observed: user_id={}, display={}, stream_id={}, received_frame_id={}, event_dropped={}, window_dropped={}, observed_frames={}, loss_permille={}, action=tolerated",
                id,
                sample.display,
                sample.stream_id,
                sample.received_frame_id,
                sample.dropped_frames,
                observation.dropped_frames,
                observation.observed_frames,
                observation.loss_permille,
            );
            return false;
        };
        let (previous_fps, next_fps) = {
            let Some(user) = self.users.get_mut(&id) else {
                return false;
            };
            user.transport_loss_windows.remove(&observation.key);
            if user.last_transport_loss_at.is_some_and(|last| {
                now.saturating_duration_since(last) < TRANSPORT_LOSS_BACKOFF_COOLDOWN
            }) {
                log::debug!(
                    "diag video qos transport loss observed: user_id={}, display={}, stream_id={}, received_frame_id={}, event_dropped={}, window_dropped={}, observed_frames={}, loss_permille={}, action=cooldown",
                    id,
                    sample.display,
                    sample.stream_id,
                    sample.received_frame_id,
                    sample.dropped_frames,
                    observation.dropped_frames,
                    observation.observed_frames,
                    observation.loss_permille,
                );
                return false;
            }
            user.last_transport_loss_at = Some(now);
            user.delay.quick_increase_fps_count = 0;
            user.delay.increase_fps_count = 0;
            let previous_fps = user.delay.fps.unwrap_or(highest_fps);
            let next_fps = previous_fps
                .saturating_mul(TRANSPORT_LOSS_BACKOFF_NUMERATOR)
                .saturating_div(TRANSPORT_LOSS_BACKOFF_DENOMINATOR)
                .clamp(MIN_FPS, highest_fps);
            user.delay.fps = Some(next_fps);
            (previous_fps, next_fps)
        };

        let affected_displays = self.display_names_for_user(id);
        for display_name in &affected_displays {
            self.adjust_fps(display_name);
            self.reduce_ratio_for_congestion(display_name, now, "transport-loss", false);
        }
        log::warn!(
            "diag video qos transport loss backoff: user_id={}, display={}, stream_id={}, received_frame_id={}, event_dropped={}, window_dropped={}, observed_frames={}, loss_permille={}, reason={}, fps_previous={}, fps_current={}, displays={:?}",
            id,
            sample.display,
            sample.stream_id,
            sample.received_frame_id,
            sample.dropped_frames,
            observation.dropped_frames,
            observation.observed_frames,
            observation.loss_permille,
            reason.as_str(),
            previous_fps,
            next_fps,
            affected_displays,
        );
        true
    }

    pub fn user_network_delay(&mut self, id: i32, delay: u32) {
        let highest_fps = self.user_requested_fps(id);
        let target_ratio = self
            .users
            .get(&id)
            .and_then(|user| user.quality)
            .map(|(_, quality)| quality.ratio())
            .unwrap_or(BR_BALANCED);

        // For bad network, small fps means quick reaction and high quality
        let (min_fps, normal_fps) = if target_ratio >= BR_BEST {
            (8, 16)
        } else if target_ratio >= BR_BALANCED {
            (10, 20)
        } else {
            (12, 24)
        };

        // Calculate minimum acceptable delay-fps product
        let dividend_ms = DELAY_THRESHOLD_150MS * min_fps;

        let mut adjust_ratio = false;
        if let Some(user) = self.users.get_mut(&id) {
            let delay = delay.max(10);
            let old_avg_delay = user.delay.avg_delay();
            user.delay.add_delay(delay);
            let mut avg_delay = user.delay.avg_delay();
            avg_delay = avg_delay.max(10);
            let mut fps = user.delay.fps.unwrap_or(INIT_FPS);

            // Adaptive FPS adjustment based on network delay:
            if avg_delay < 50 {
                user.delay.quick_increase_fps_count += 1;
                let mut step = if fps < normal_fps { 1 } else { 0 };
                if user.delay.quick_increase_fps_count >= 3 {
                    // After 3 consecutive good samples, increase more aggressively
                    user.delay.quick_increase_fps_count = 0;
                    step = 5;
                }
                fps = min_fps.max(fps + step);
            } else if avg_delay < 100 {
                let step = if avg_delay < old_avg_delay {
                    if fps < normal_fps {
                        1
                    } else {
                        0
                    }
                } else {
                    0
                };
                fps = min_fps.max(fps + step);
            } else if avg_delay < DELAY_THRESHOLD_150MS {
                fps = min_fps.max(fps);
            } else {
                let devide_fps = ((fps as f32) / (avg_delay as f32 / DELAY_THRESHOLD_150MS as f32))
                    .ceil() as u32;
                if avg_delay < 200 {
                    fps = min_fps.max(devide_fps);
                } else if avg_delay < 300 {
                    fps = min_fps.min(devide_fps);
                } else if avg_delay < 600 {
                    fps = dividend_ms / avg_delay;
                } else {
                    fps = (dividend_ms / avg_delay).min(devide_fps);
                }
            }

            if avg_delay < DELAY_THRESHOLD_150MS {
                user.delay.increase_fps_count += 1;
            } else {
                user.delay.increase_fps_count = 0;
            }
            if user.delay.increase_fps_count >= 3 {
                // After 3 stable samples, try increasing FPS
                user.delay.increase_fps_count = 0;
                fps += 1;
            }

            // Reset quick increase counter if network condition worsens
            if avg_delay > 50 {
                user.delay.quick_increase_fps_count = 0;
            }

            fps = fps.clamp(MIN_FPS, highest_fps);
            // first network delay message
            adjust_ratio = user.delay.fps.is_none();
            user.delay.fps = Some(fps);
        }
        let affected_displays = self.display_names_for_user(id);
        for display_name in &affected_displays {
            self.adjust_fps(display_name);
        }
        if adjust_ratio && !cfg!(target_os = "linux") {
            //Reduce the possibility of vaapi being created twice
            for display_name in &affected_displays {
                self.adjust_ratio(display_name, false);
            }
        }
    }

    pub fn user_delay_response_elapsed(&mut self, id: i32, elapsed: u128) {
        if let Some(user) = self.users.get_mut(&id) {
            user.delay.response_delayed = elapsed > 2000;
            if user.delay.response_delayed {
                user.delay.add_delay(elapsed as u32);
            }
        }
        self.adjust_displays_for_user(id);
    }
}

// Common adjust functions
impl VideoQoS {
    pub fn new_display(&mut self, video_service_name: String) {
        self.displays
            .insert(video_service_name, DisplayData::default());
    }

    pub fn sync_subscribers(&mut self, video_service_name: &str, subscribers: HashSet<i32>) {
        let previous_subscribers = self
            .displays
            .get(video_service_name)
            .map(|display| display.subscribers.clone())
            .unwrap_or_default();
        let changed = previous_subscribers != subscribers;
        if let Some(display) = self.displays.get_mut(video_service_name) {
            display.subscribers = subscribers.clone();
        }
        if changed {
            let now = Instant::now();
            for id in previous_subscribers.difference(&subscribers) {
                if let Some(user) = self.users.get_mut(id) {
                    user.video_startup_by_service.remove(video_service_name);
                }
            }
            for id in subscribers.difference(&previous_subscribers) {
                if let Some(user) = self.users.get_mut(id) {
                    user.video_startup_by_service
                        .entry(video_service_name.to_owned())
                        .or_insert_with(|| ViewerStartupState::new(now));
                }
            }
            if !self.full_movie_mode(video_service_name) {
                self.clear_datagram_admission_for_display(video_service_name);
            }
            self.adjust_fps(video_service_name);
            let mut subscriber_ids: Vec<i32> = self
                .displays
                .get(video_service_name)
                .map(|display| display.subscribers.iter().copied().collect())
                .unwrap_or_default();
            subscriber_ids.sort_unstable();
            log::info!(
                "diag video qos subscribers: service={}, count={}, conn_ids={:?}, active_fps={}",
                video_service_name,
                subscriber_ids.len(),
                subscriber_ids,
                self.fps(video_service_name)
            );
        }
    }

    pub fn all_subscribers_request_movie(&self, video_service_name: &str) -> bool {
        let mut subscribers = self.subscribed_users(video_service_name).peekable();
        subscribers.peek().is_some()
            && subscribers.all(|user| user.video_profile == VideoProfile::Movie)
    }

    pub fn full_movie_mode(&self, video_service_name: &str) -> bool {
        let mut subscribers = self.subscribed_users(video_service_name).peekable();
        subscribers.peek().is_some()
            && subscribers.all(|user| {
                user.video_profile == VideoProfile::Movie
                    && user.video_feedback_capable
                    && user.movie_transport_capable
            })
    }

    pub(crate) fn movie_target_fps(&self, video_service_name: &str) -> u32 {
        self.subscribed_users(video_service_name)
            .map(|user| {
                user.custom_fps
                    .unwrap_or(MOVIE_DEFAULT_TARGET_FPS)
                    .clamp(MIN_FPS, MAX_FPS)
            })
            .min()
            .unwrap_or(MOVIE_DEFAULT_TARGET_FPS)
            .clamp(MIN_FPS, MAX_FPS)
    }

    pub(crate) fn custom_encoder_fps(&self, video_service_name: &str) -> Option<u32> {
        self.subscribed_users(video_service_name)
            .filter_map(|user| user.custom_fps)
            .max()
            .map(|fps| fps.clamp(MIN_FPS, MAX_FPS))
    }

    pub(crate) fn movie_viewer_metrics(&self, video_service_name: &str) -> MovieViewerMetrics {
        let Some(display_idx) = video_service_display_index(video_service_name) else {
            return MovieViewerMetrics::default();
        };
        let subscribers: Vec<&UserData> = self.subscribed_users(video_service_name).collect();
        if subscribers.is_empty() {
            return MovieViewerMetrics::default();
        }

        let mut metrics = MovieViewerMetrics {
            available: true,
            all_rendered: subscribers.iter().all(|user| {
                user.video_startup_by_service
                    .get(video_service_name)
                    .is_some_and(|startup| startup.render_started)
            }),
            ..Default::default()
        };
        for user in subscribers {
            let Some(feedback) = user.movie_feedback_by_display.get(&display_idx) else {
                metrics.available = false;
                continue;
            };
            if !feedback
                .updated_at
                .is_some_and(|updated| updated.elapsed() <= MOVIE_FEEDBACK_FRESHNESS)
            {
                metrics.available = false;
                continue;
            }
            metrics.max_queue_depth_frames = metrics
                .max_queue_depth_frames
                .max(feedback.queue_depth_frames);
            metrics.max_decode_time_us = metrics.max_decode_time_us.max(feedback.decode_time_us);
            metrics.max_render_submit_time_us = metrics
                .max_render_submit_time_us
                .max(feedback.render_submit_time_us);
            metrics.dropped_frames = metrics
                .dropped_frames
                .saturating_add(feedback.dropped_frames);
            if feedback.display_refresh_millihz > 0 {
                metrics.display_refresh_millihz = if metrics.display_refresh_millihz == 0 {
                    feedback.display_refresh_millihz
                } else {
                    metrics
                        .display_refresh_millihz
                        .min(feedback.display_refresh_millihz)
                };
            }
            metrics.presentation_late_frames = metrics
                .presentation_late_frames
                .saturating_add(feedback.presentation_late_frames);
            metrics.presentation_dropped_frames = metrics
                .presentation_dropped_frames
                .saturating_add(feedback.presentation_dropped_frames);
            metrics.presentation_jitter_p95_us = metrics
                .presentation_jitter_p95_us
                .max(feedback.presentation_jitter_p95_us);
        }
        metrics
    }

    pub fn remove_display(&mut self, video_service_name: &str) {
        self.displays.remove(video_service_name);
    }

    pub fn update_display_data(&mut self, video_service_name: &str, send_counter: usize) {
        self.adjust_fps(video_service_name);
        let abr_enabled = self.in_vbr_state(video_service_name);
        if abr_enabled {
            let dynamic_screen = self
                .displays
                .get_mut(video_service_name)
                .and_then(|display| {
                    display.send_counter += send_counter;
                    if display.adjust_ratio_instant.elapsed().as_secs()
                        < ADJUST_RATIO_INTERVAL as u64
                    {
                        return None;
                    }
                    let dynamic =
                        display.send_counter >= ADJUST_RATIO_INTERVAL * DYNAMIC_SCREEN_THRESHOLD;
                    display.send_counter = 0;
                    Some(dynamic)
                });
            if let Some(dynamic_screen) = dynamic_screen {
                self.adjust_ratio(video_service_name, dynamic_screen);
            }
        } else {
            let ratio = self.latest_quality(video_service_name).ratio();
            if let Some(display) = self.displays.get_mut(video_service_name) {
                display.ratio = ratio;
            }
        }
    }

    #[inline]
    fn locked_fps(&self, video_service_name: &str) -> Option<u32> {
        self.subscribed_users(video_service_name)
            .filter_map(|user| user.fixed_fps)
            .max()
            .map(|fps| fps.clamp(MIN_FPS, MAX_FPS))
    }

    #[inline]
    fn highest_fps(&self, video_service_name: &str) -> u32 {
        if let Some(fps) = self.locked_fps(video_service_name) {
            return fps;
        }

        self.subscribed_users(video_service_name)
            .map(Self::requested_fps)
            .max()
            .unwrap_or(FPS)
    }

    // Get latest quality settings from all users
    pub fn latest_quality(&self, video_service_name: &str) -> Quality {
        self.subscribed_users(video_service_name)
            .filter_map(|user| user.quality)
            .max_by_key(|(time, _)| *time)
            .unwrap_or((0, Quality::Balanced))
            .1
    }

    // Adjust quality ratio based on network delay and screen changes
    fn adjust_ratio(&mut self, video_service_name: &str, dynamic_screen: bool) {
        self.adjust_ratio_at(video_service_name, dynamic_screen, Instant::now());
    }

    fn adjust_ratio_at(&mut self, video_service_name: &str, dynamic_screen: bool, now: Instant) {
        if !self.in_vbr_state(video_service_name) {
            return;
        }
        // The encoder is shared by the service. Use the best active path here;
        // slow viewers are isolated by their bounded delivery queues.
        let best_delay = self
            .subscribed_users(video_service_name)
            .map(|user| user.delay.avg_delay())
            .min();
        let Some(best_delay) = best_delay else {
            return;
        };

        let target_quality = self.latest_quality(video_service_name);
        let target_ratio = target_quality.ratio();
        let transport_loss_upshift_frozen =
            self.transport_loss_upshift_frozen_for_display(video_service_name, now);
        let Some(display) = self.displays.get(video_service_name) else {
            return;
        };
        let current_ratio = display.ratio;
        let current_bitrate = display.bitrate_store;
        let uses_nvenc = display.uses_nvenc();
        let nvenc_upshift_allowed = !uses_nvenc
            || display.last_nvenc_ratio_upshift_at.map_or(true, |last| {
                now.saturating_duration_since(last) >= NVENC_RATIO_UPSHIFT_INTERVAL
            });
        let upshift_frozen = display
            .upshift_frozen_until
            .is_some_and(|until| now < until)
            || transport_loss_upshift_frozen;

        // NVENC forces an IDR on each dynamic bitrate reconfigure. Coalesce
        // healthy upshifts while preserving roughly the legacy recovery rate.
        let ratio_upshift_kbps = if uses_nvenc {
            NVENC_RATIO_UPSHIFT_KBPS
        } else {
            150
        };
        let ratio_add_bitrate_step = if current_bitrate > 0 {
            Some(
                current_bitrate.saturating_add(ratio_upshift_kbps) as f32 * current_ratio
                    / current_bitrate as f32,
            )
        } else {
            None
        };

        let min = minimum_ratio_for_quality(target_quality, current_ratio, current_bitrate);
        let max = target_ratio * MAX_BR_MULTIPLE;

        let mut v = current_ratio;

        // Adjust ratio based on network delay thresholds
        if best_delay < 50 {
            if dynamic_screen {
                v = current_ratio * 1.15;
            }
        } else if best_delay < 100 {
            if dynamic_screen {
                v = current_ratio * 1.1;
            }
        } else if best_delay < DELAY_THRESHOLD_150MS {
            if dynamic_screen {
                v = current_ratio * 1.05;
            }
        } else if best_delay < 200 {
            v = current_ratio * 0.95;
        } else if best_delay < 300 {
            v = current_ratio * 0.9;
        } else if best_delay < 500 {
            v = current_ratio * 0.85;
        } else {
            v = current_ratio * 0.8;
        }

        // Limit quality increase rate for better stability
        if let Some(ratio_add_bitrate_step) = ratio_add_bitrate_step {
            if v > ratio_add_bitrate_step
                && ratio_add_bitrate_step > current_ratio
                && current_ratio >= BR_SPEED
            {
                v = ratio_add_bitrate_step;
            }
        }
        if uses_nvenc && v > current_ratio && !nvenc_upshift_allowed {
            log::debug!(
                "diag video qos NVENC ratio upshift coalesced: service={}, ratio={:.3}, bitrate={}, remaining_ms={}",
                video_service_name,
                current_ratio,
                current_bitrate,
                display
                    .last_nvenc_ratio_upshift_at
                    .map(|last| {
                        NVENC_RATIO_UPSHIFT_INTERVAL
                            .saturating_sub(now.saturating_duration_since(last))
                            .as_millis()
                    })
                    .unwrap_or_default(),
            );
            v = current_ratio;
        }

        let episode_floor = if let Some(display) = self.displays.get_mut(video_service_name) {
            let expired = display.expire_custom_congestion_episode(now);
            if expired {
                log::info!(
                    "diag video qos congestion episode reset after clean interval: service={}",
                    video_service_name,
                );
            }
            if v < current_ratio {
                display.touch_custom_congestion_episode(target_quality, now)
            } else {
                None
            }
        } else {
            None
        };

        if let Some(display) = self.displays.get_mut(video_service_name) {
            let effective_min = min.max(episode_floor.unwrap_or(min)).min(max);
            let mut next_ratio = v.clamp(effective_min, max);
            if upshift_frozen && next_ratio > current_ratio {
                next_ratio = current_ratio;
            }
            if display.ratio != next_ratio {
                log::info!(
                    "diag video qos ratio: service={}, previous={:.3}, current={:.3}, best_delay_ms={}, dynamic_screen={}, bitrate={}, episode_floor={:.3}, nvenc_upshift_pacing={}, upshift_step_kbps={}",
                    video_service_name,
                    display.ratio,
                    next_ratio,
                    best_delay,
                    dynamic_screen,
                    current_bitrate,
                    episode_floor.unwrap_or(min),
                    uses_nvenc,
                    ratio_upshift_kbps,
                );
            }
            if uses_nvenc && next_ratio > current_ratio {
                display.last_nvenc_ratio_upshift_at = Some(now);
            }
            display.ratio = next_ratio;
            display.adjust_ratio_instant = now;
        }
    }

    // Adjust fps based on network delay and user response time
    fn adjust_fps(&mut self, video_service_name: &str) {
        self.adjust_fps_at(video_service_name, Instant::now());
    }

    fn adjust_fps_at(&mut self, video_service_name: &str, now: Instant) {
        if let Some(fps) = self.locked_fps(video_service_name) {
            let movie_pacing = self
                .full_movie_mode(video_service_name)
                .then(|| {
                    self.displays
                        .get(video_service_name)
                        .map(|display| display.movie_pacing_fps)
                        .unwrap_or_default()
                })
                .unwrap_or_default();
            if let Some(display) = self.displays.get_mut(video_service_name) {
                display.fps = if movie_pacing > 0 {
                    fps.min(movie_pacing)
                } else {
                    fps
                };
            }
            return;
        }

        let highest_fps = self.highest_fps(video_service_name);
        // A slow subscriber must not throttle the shared encoder for healthy
        // subscribers. Per-viewer queues discard stale video independently.
        let mut fps = self
            .subscribed_users(video_service_name)
            .map(|user| user.delay.fps.unwrap_or(INIT_FPS))
            .max()
            .unwrap_or(INIT_FPS);

        let all_subscribers_delayed = {
            let mut subscribers = self.subscribed_users(video_service_name).peekable();
            subscribers.peek().is_some() && subscribers.all(|user| user.delay.response_delayed)
        };
        if all_subscribers_delayed {
            if fps > MIN_FPS + 1 {
                fps = MIN_FPS + 1;
            }
        }

        if self.startup_safe_mode(video_service_name) && fps > STARTUP_SAFE_FPS {
            fps = STARTUP_SAFE_FPS;
        }

        let mut next_fps = fps.clamp(MIN_FPS, highest_fps);
        let startup_safe = self.startup_safe_mode(video_service_name);
        let full_movie_mode = self.full_movie_mode(video_service_name);
        if let Some(display) = self.displays.get_mut(video_service_name) {
            if full_movie_mode && display.movie_pacing_fps > 0 {
                next_fps = next_fps.min(display.movie_pacing_fps);
            }
            if full_movie_mode
                && display
                    .upshift_frozen_until
                    .is_some_and(|until| now < until)
                && next_fps > display.fps
            {
                next_fps = display.fps;
            }
            if display.fps != next_fps {
                log::info!(
                    "diag video qos fps: service={}, previous={}, current={}, subscribers={}, all_delayed={}, startup_safe={}",
                    video_service_name,
                    display.fps,
                    next_fps,
                    display.subscribers.len(),
                    all_subscribers_delayed,
                    startup_safe
                );
            }
            display.fps = next_fps;
        }
    }

    fn requested_fps(user: &UserData) -> u32 {
        let mut fps = user.custom_fps.unwrap_or(FPS);
        if let Some(auto_adjust_fps) = user.auto_adjust_fps {
            if fps == 0 || auto_adjust_fps < fps {
                fps = auto_adjust_fps;
            }
        }
        fps.clamp(MIN_FPS, MAX_FPS)
    }

    fn user_requested_fps(&self, id: i32) -> u32 {
        self.users.get(&id).map(Self::requested_fps).unwrap_or(FPS)
    }

    fn subscribed_users<'a>(
        &'a self,
        video_service_name: &str,
    ) -> impl Iterator<Item = &'a UserData> + 'a {
        self.displays
            .get(video_service_name)
            .into_iter()
            .flat_map(|display| display.subscribers.iter())
            .filter_map(|id| self.users.get(id))
    }

    fn display_names_for_user(&self, id: i32) -> Vec<String> {
        self.displays
            .iter()
            .filter(|(_, display)| display.subscribers.contains(&id))
            .map(|(name, _)| name.clone())
            .collect()
    }

    fn adjust_displays_for_user(&mut self, id: i32) {
        for display_name in self.display_names_for_user(id) {
            self.adjust_fps(&display_name);
        }
    }
}

fn video_service_display_index(video_service_name: &str) -> Option<i32> {
    video_service_name
        .strip_prefix("monitor")
        .or_else(|| video_service_name.strip_prefix("camera"))?
        .trim_start_matches('-')
        .parse()
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    const MONITOR_SERVICE: &str = "monitor-0";
    const CAMERA_SERVICE: &str = "camera-0";

    fn qos_with_viewers(video_service_name: &str, viewer_ids: &[i32]) -> VideoQoS {
        let mut qos = VideoQoS::default();
        qos.new_display(video_service_name.to_owned());
        for id in viewer_ids {
            qos.on_connection_open(*id);
        }
        qos.sync_subscribers(video_service_name, viewer_ids.iter().copied().collect());
        qos
    }

    fn establish_viewer(qos: &mut VideoQoS, id: i32, video_service_name: &str) {
        let startup = qos
            .users
            .get_mut(&id)
            .and_then(|user| user.video_startup_by_service.get_mut(video_service_name))
            .unwrap();
        startup.stream_id = Some(1);
        startup.render_started = true;
    }

    fn expire_viewer_startup(qos: &mut VideoQoS, id: i32, video_service_name: &str) {
        qos.users
            .get_mut(&id)
            .and_then(|user| user.video_startup_by_service.get_mut(video_service_name))
            .unwrap()
            .started_at = Instant::now() - STARTUP_SAFE_WINDOW - Duration::from_secs(1);
    }

    fn transport_loss_sample(
        display: i32,
        stream_id: u64,
        received_frame_id: u64,
        dropped_frames: u64,
    ) -> VideoTransportLossSample {
        VideoTransportLossSample {
            display,
            stream_id,
            received_frame_id,
            dropped_frames,
        }
    }

    fn datagram_admission_sample(
        rejected_active: u64,
        frames_sent: u64,
    ) -> VideoDatagramAdmissionSample {
        VideoDatagramAdmissionSample {
            rejected_active,
            frames_sent,
            queue_delay_us: 20_000,
            queue_budget_bytes: 65_536,
            queued_bytes: 32_768,
            datagram_bytes_p99: 16_000,
            required_bytes_p99: 48_768,
        }
    }

    fn preemptive_datagram_pressure_sample(frames_sent: u64) -> VideoDatagramAdmissionSample {
        VideoDatagramAdmissionSample {
            rejected_active: 0,
            frames_sent,
            queue_delay_us: 35_000,
            queue_budget_bytes: 65_536,
            queued_bytes: 56_000,
            datagram_bytes_p99: 16_000,
            required_bytes_p99: 60_000,
        }
    }

    fn movie_qos_with_viewers(viewer_ids: &[i32]) -> VideoQoS {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, viewer_ids);
        qos.set_support_changing_quality(MONITOR_SERVICE, true);
        qos.store_bitrate(MONITOR_SERVICE, 4_000);
        for id in viewer_ids {
            qos.user_video_profile(*id, VideoProfile::Movie);
            qos.user_video_feedback_capability(*id, true);
            qos.user_movie_transport_capability(*id, true);
            establish_viewer(&mut qos, *id, MONITOR_SERVICE);
            qos.users.get_mut(id).unwrap().delay.fps = Some(60);
        }
        qos.store_movie_runtime_status(MONITOR_SERVICE, 60, 60, 5_000);
        qos
    }

    #[test]
    fn startup_safe_mode_caps_default_quality_ratio() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);

        assert!(qos.startup_safe_mode(MONITOR_SERVICE));
        assert_eq!(qos.ratio(MONITOR_SERVICE), STARTUP_SAFE_RATIO);
    }

    #[test]
    fn movie_profile_requires_every_active_subscriber() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1, 2]);
        assert!(!qos.all_subscribers_request_movie(MONITOR_SERVICE));

        qos.user_video_profile(1, VideoProfile::Movie);
        assert!(!qos.all_subscribers_request_movie(MONITOR_SERVICE));

        qos.user_video_profile(2, VideoProfile::Movie);
        assert!(qos.all_subscribers_request_movie(MONITOR_SERVICE));
        assert!(!qos.full_movie_mode(MONITOR_SERVICE));

        for id in [1, 2] {
            qos.user_video_feedback_capability(id, true);
            qos.user_movie_transport_capability(id, true);
        }
        assert!(qos.full_movie_mode(MONITOR_SERVICE));
        assert_eq!(qos.movie_target_fps(MONITOR_SERVICE), 60);

        qos.user_custom_fps(1, 50);
        assert_eq!(qos.movie_target_fps(MONITOR_SERVICE), 50);

        qos.user_video_profile(1, VideoProfile::Standard);
        assert!(!qos.all_subscribers_request_movie(MONITOR_SERVICE));
        assert!(!qos.full_movie_mode(MONITOR_SERVICE));
    }

    #[test]
    fn profile_switch_resets_movie_transport_penalty_before_standard() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.user_custom_fps(1, 85);
        qos.user_video_profile(1, VideoProfile::Movie);
        assert!(qos.user_transport_loss_at(1, transport_loss_sample(0, 7, 30, 3), Instant::now(),));
        qos.users.get_mut(&1).unwrap().auto_adjust_fps = Some(40);
        assert_eq!(qos.users.get(&1).unwrap().delay.fps, Some(74));

        qos.user_video_profile(1, VideoProfile::Standard);
        let user = qos.users.get(&1).unwrap();
        assert!(user.delay.fps.is_none());
        assert!(user.delay.delay_history.is_empty());
        assert!(user.auto_adjust_fps.is_none());
        assert!(user.last_transport_loss_at.is_none());
        assert!(user.transport_loss_windows.is_empty());
    }

    fn healthy_movie_sample(now: Instant, pipeline_us: u64) -> MovieCadenceSample {
        MovieCadenceSample {
            now,
            target_fps: 60,
            host_pipeline_p95_us: pipeline_us,
            host_iterations: 30,
            host_missed_slots: 0,
            local_admission_pressure: false,
            viewer: MovieViewerMetrics {
                available: true,
                all_rendered: true,
                max_queue_depth_frames: 0,
                max_decode_time_us: 2_000,
                max_render_submit_time_us: 100,
                ..Default::default()
            },
        }
    }

    #[test]
    fn movie_cadence_starts_at_thirty_and_promotes_after_probation() {
        let start = Instant::now();
        let mut controller = MovieCadenceController::new(60, 0, start);
        assert_eq!(controller.current_tier(), 30);

        assert_eq!(
            controller.evaluate(healthy_movie_sample(start, 5_000)),
            None
        );
        let decision = controller
            .evaluate(healthy_movie_sample(start + MOVIE_PROBATION_HEALTHY, 5_000))
            .unwrap();
        assert_eq!(decision.previous_fps, 30);
        assert_eq!(decision.current_fps, 60);
        assert_eq!(decision.reason, MovieCadenceReason::ProbationComplete);
    }

    #[test]
    fn movie_cadence_downshifts_only_after_sustained_pressure() {
        let start = Instant::now();
        let mut controller = MovieCadenceController::new(60, 0, start);
        controller.evaluate(healthy_movie_sample(start, 5_000));
        controller.evaluate(healthy_movie_sample(start + MOVIE_PROBATION_HEALTHY, 5_000));
        assert_eq!(controller.current_tier(), 60);

        let mut pressure = healthy_movie_sample(start + Duration::from_secs(3), 16_000);
        pressure.host_missed_slots = 4;
        assert_eq!(controller.evaluate(pressure), None);
        pressure.now += MOVIE_PRESSURE_DURATION;
        let decision = controller.evaluate(pressure).unwrap();
        assert_eq!(decision.previous_fps, 60);
        assert_eq!(decision.current_fps, 30);
        assert_eq!(decision.reason, MovieCadenceReason::HostCapacity);
    }

    #[test]
    fn movie_cadence_uses_existing_delivery_path_for_local_admission_pressure() {
        let start = Instant::now();
        let mut controller = MovieCadenceController::new(60, 0, start);
        controller.evaluate(healthy_movie_sample(start, 5_000));
        controller.evaluate(healthy_movie_sample(start + MOVIE_PROBATION_HEALTHY, 5_000));
        assert_eq!(controller.current_tier(), 60);

        let mut pressure = healthy_movie_sample(start + Duration::from_secs(3), 5_000);
        pressure.local_admission_pressure = true;
        assert_eq!(controller.evaluate(pressure), None);
        pressure.now += MOVIE_PRESSURE_DURATION;
        let decision = controller.evaluate(pressure).unwrap();
        assert_eq!(decision.previous_fps, 60);
        assert_eq!(decision.current_fps, 30);
        assert_eq!(decision.reason, MovieCadenceReason::DeliveryPressure);
    }

    #[test]
    fn movie_cadence_keeps_thirty_for_bounded_startup_jitter() {
        let start = Instant::now();
        let mut controller = MovieCadenceController::new(85, 120_000, start);
        assert_eq!(controller.current_tier(), 30);

        let mut sample = healthy_movie_sample(start, 22_779);
        sample.target_fps = 85;
        sample.host_iterations = 14;
        sample.host_missed_slots = 2;
        sample.viewer.display_refresh_millihz = 120_000;
        assert_eq!(controller.evaluate(sample), None);

        sample.now += MOVIE_PRESSURE_DURATION;
        assert_eq!(controller.evaluate(sample), None);
        assert_eq!(controller.current_tier(), 30);
    }

    #[test]
    fn movie_cadence_probation_trials_forty_and_rolls_back_on_real_pressure() {
        let start = Instant::now();
        let mut controller = MovieCadenceController::new(85, 120_000, start);
        let mut sample = healthy_movie_sample(start, 23_000);
        sample.target_fps = 85;
        sample.viewer.display_refresh_millihz = 120_000;
        assert_eq!(controller.evaluate(sample), None);

        sample.now += MOVIE_PROBATION_HEALTHY;
        let promoted = controller.evaluate(sample).unwrap();
        assert_eq!(promoted.previous_fps, 30);
        assert_eq!(promoted.current_fps, 40);
        assert_eq!(promoted.reason, MovieCadenceReason::ProbationComplete);

        let mut pressure = sample;
        pressure.now += Duration::from_secs(1);
        pressure.host_pipeline_p95_us = 26_000;
        assert_eq!(controller.evaluate(pressure), None);
        pressure.now += MOVIE_PRESSURE_DURATION;
        let rolled_back = controller.evaluate(pressure).unwrap();
        assert_eq!(rolled_back.previous_fps, 40);
        assert_eq!(rolled_back.current_fps, 30);
        assert_eq!(rolled_back.reason, MovieCadenceReason::HostCapacity);
    }

    #[test]
    fn movie_cadence_requires_long_health_window_after_downshift() {
        let start = Instant::now();
        let mut controller = MovieCadenceController::new(60, 0, start);
        controller.evaluate(healthy_movie_sample(start, 5_000));
        controller.evaluate(healthy_movie_sample(start + MOVIE_PROBATION_HEALTHY, 5_000));

        let pressure_started = start + Duration::from_secs(3);
        let mut pressure = healthy_movie_sample(pressure_started, 16_000);
        pressure.host_missed_slots = 4;
        controller.evaluate(pressure);
        pressure.now += MOVIE_PRESSURE_DURATION;
        controller.evaluate(pressure);
        assert_eq!(controller.current_tier(), 30);

        let healthy_started = pressure.now + Duration::from_secs(1);
        assert_eq!(
            controller.evaluate(healthy_movie_sample(healthy_started, 5_000)),
            None
        );
        assert_eq!(
            controller.evaluate(healthy_movie_sample(
                healthy_started + MOVIE_UPSHIFT_HEALTHY - Duration::from_millis(1),
                5_000,
            )),
            None
        );
        let decision = controller
            .evaluate(healthy_movie_sample(
                healthy_started + MOVIE_UPSHIFT_HEALTHY,
                5_000,
            ))
            .unwrap();
        assert_eq!(decision.current_fps, 60);
        assert_eq!(decision.reason, MovieCadenceReason::HealthyUpshift);
    }

    #[test]
    fn rejected_movie_upshift_is_not_retried() {
        let start = Instant::now();
        let mut controller = MovieCadenceController::new(60, 0, start);
        controller.evaluate(healthy_movie_sample(start, 5_000));
        let decision = controller
            .evaluate(healthy_movie_sample(start + MOVIE_PROBATION_HEALTHY, 5_000))
            .unwrap();
        controller.reject_change(
            decision.previous_fps,
            decision.current_fps,
            start + MOVIE_PROBATION_HEALTHY,
        );

        assert_eq!(controller.current_tier(), 30);
        assert_eq!(
            controller.evaluate(healthy_movie_sample(
                start + MOVIE_PROBATION_HEALTHY + MOVIE_UPSHIFT_HEALTHY,
                5_000,
            )),
            None
        );
    }

    #[test]
    fn movie_cadence_applies_runtime_target_changes() {
        let start = Instant::now();
        let mut controller = MovieCadenceController::new(60, 0, start);
        controller.evaluate(healthy_movie_sample(start, 5_000));
        controller.evaluate(healthy_movie_sample(start + MOVIE_PROBATION_HEALTHY, 5_000));
        assert_eq!(controller.current_tier(), 60);

        let mut lower_target = healthy_movie_sample(start + Duration::from_secs(3), 5_000);
        lower_target.target_fps = 30;
        let decision = controller.evaluate(lower_target).unwrap();
        assert_eq!(decision.current_fps, 30);
        assert_eq!(decision.reason, MovieCadenceReason::TargetChanged);

        let mut higher_target = healthy_movie_sample(start + Duration::from_secs(4), 5_000);
        higher_target.target_fps = 60;
        assert_eq!(controller.evaluate(higher_target), None);
        higher_target.now += MOVIE_PROBATION_HEALTHY;
        let decision = controller.evaluate(higher_target).unwrap();
        assert_eq!(decision.current_fps, 60);
        assert_eq!(decision.reason, MovieCadenceReason::ProbationComplete);
    }

    #[test]
    fn reset_viewer_counter_does_not_report_historical_drops() {
        assert_eq!(monotonic_counter_delta(4, 10), 0);
        assert_eq!(monotonic_counter_delta(11, 10), 1);
    }

    #[test]
    fn movie_cadence_capacity_near_forty_five_does_not_oscillate() {
        let start = Instant::now();
        let mut controller = MovieCadenceController::new(60, 0, start);
        for second in 0..30 {
            let pipeline_us = if second % 2 == 0 { 20_000 } else { 23_000 };
            assert_eq!(
                controller.evaluate(healthy_movie_sample(
                    start + Duration::from_secs(second),
                    pipeline_us,
                )),
                None
            );
        }
        assert_eq!(controller.current_tier(), 30);
    }

    #[test]
    fn movie_cadence_uses_refresh_compatible_tier() {
        let start = Instant::now();
        let mut controller = MovieCadenceController::new(60, 90_000, start);
        assert_eq!(controller.current_tier(), 30);
        controller.evaluate(healthy_movie_sample(start, 8_000));
        let decision = controller
            .evaluate(healthy_movie_sample(start + MOVIE_PROBATION_HEALTHY, 8_000))
            .unwrap();
        assert_eq!(decision.current_fps, 45);
    }

    #[test]
    fn movie_viewer_metrics_are_scoped_to_the_video_display() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.user_video_profile(1, VideoProfile::Movie);
        qos.user_video_feedback_capability(1, true);
        qos.user_video_frame_rendered(1);
        qos.user_video_feedback(
            1,
            MONITOR_SERVICE,
            &VideoFeedback {
                display: 0,
                stream_id: 1,
                queue_depth_frames: 2,
                decode_time_us: 3_000,
                render_submit_time_us: 200,
                display_refresh_millihz: 120_000,
                ..Default::default()
            },
        );

        let metrics = qos.movie_viewer_metrics(MONITOR_SERVICE);
        assert!(metrics.available);
        assert!(metrics.all_rendered);
        assert_eq!(metrics.max_queue_depth_frames, 2);
        assert_eq!(metrics.max_decode_time_us, 3_000);
        assert_eq!(metrics.display_refresh_millihz, 120_000);
        assert!(!qos.movie_viewer_metrics(CAMERA_SERVICE).available);
    }

    #[test]
    fn movie_runtime_status_is_scoped_to_the_video_service() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.new_display(CAMERA_SERVICE.to_owned());
        qos.store_movie_runtime_status(MONITOR_SERVICE, 60, 30, 8_500);

        assert_eq!(qos.movie_runtime_status(MONITOR_SERVICE), (60, 30, 8_500));
        assert_eq!(qos.movie_runtime_status(CAMERA_SERVICE), (0, 0, 0));
    }

    #[test]
    fn startup_safe_mode_expires() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        expire_viewer_startup(&mut qos, 1, MONITOR_SERVICE);

        assert!(!qos.startup_safe_mode(MONITOR_SERVICE));
        assert_eq!(qos.ratio(MONITOR_SERVICE), BR_BALANCED);
    }

    #[test]
    fn legacy_viewer_keeps_time_based_startup_fallback() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.user_video_feedback_capability(1, false);

        assert!(!qos.user_video_frame_rendered(1));
        assert!(qos.startup_safe_mode(MONITOR_SERVICE));
        expire_viewer_startup(&mut qos, 1, MONITOR_SERVICE);
        assert!(!qos.startup_safe_mode(MONITOR_SERVICE));
    }

    #[test]
    fn startup_safe_mode_respects_fixed_fps() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.user_fixed_fps(1, 30);

        assert!(!qos.startup_safe_mode(MONITOR_SERVICE));
        assert_eq!(qos.ratio(MONITOR_SERVICE), BR_BALANCED);
        assert_eq!(qos.fps(MONITOR_SERVICE), 30);
    }

    #[test]
    fn preset_quality_clears_custom_fps_state() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.user_fixed_fps(1, 60);
        qos.user_auto_adjust_fps(1, 20);

        qos.user_preset_image_quality(1, ImageQuality::Balanced.value());

        let user = qos.users.get(&1).unwrap();
        assert_eq!(user.custom_fps, None);
        assert_eq!(user.fixed_fps, None);
        assert_eq!(user.auto_adjust_fps, None);
        assert_eq!(
            user.quality.map(|(_, quality)| quality),
            Some(Quality::Balanced)
        );
    }

    #[test]
    fn custom_quality_keeps_custom_fps_state() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.user_fixed_fps(1, 60);

        qos.user_image_quality(1, 75 << 8);

        let user = qos.users.get(&1).unwrap();
        assert_eq!(user.custom_fps, Some(60));
        assert_eq!(user.fixed_fps, Some(60));
    }

    #[test]
    fn encoder_fps_changes_only_for_custom_quality() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        assert_eq!(qos.custom_encoder_fps(MONITOR_SERVICE), None);

        qos.user_fixed_fps(1, 85);
        assert_eq!(qos.custom_encoder_fps(MONITOR_SERVICE), Some(85));

        qos.user_preset_image_quality(1, ImageQuality::Balanced.value());
        assert_eq!(qos.custom_encoder_fps(MONITOR_SERVICE), None);
    }

    #[test]
    fn first_render_feedback_releases_startup_safe_mode() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.user_video_feedback_capability(1, true);

        assert!(qos.startup_safe_mode(MONITOR_SERVICE));
        assert!(qos.user_video_frame_rendered(1));
        assert!(!qos.user_video_frame_rendered(1));
        assert!(!qos.startup_safe_mode(MONITOR_SERVICE));
        assert_eq!(qos.ratio(MONITOR_SERVICE), BR_BALANCED);
        assert_eq!(qos.fps(MONITOR_SERVICE), FPS);
    }

    #[test]
    fn render_feedback_releases_only_the_matching_video_service() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.new_display(CAMERA_SERVICE.to_owned());
        qos.sync_subscribers(CAMERA_SERVICE, HashSet::from([1]));
        qos.user_video_feedback_capability(1, true);
        qos.user_video_feedback(
            1,
            MONITOR_SERVICE,
            &VideoFeedback {
                display: 0,
                stream_id: 11,
                ..Default::default()
            },
        );
        qos.user_video_feedback(
            1,
            CAMERA_SERVICE,
            &VideoFeedback {
                display: 0,
                stream_id: 22,
                ..Default::default()
            },
        );

        assert!(qos.startup_safe_mode(MONITOR_SERVICE));
        assert!(qos.startup_safe_mode(CAMERA_SERVICE));
        assert!(qos.user_video_frame_rendered_for_service(1, MONITOR_SERVICE, 11));
        assert!(!qos.startup_safe_mode(MONITOR_SERVICE));
        assert!(qos.startup_safe_mode(CAMERA_SERVICE));
    }

    #[test]
    fn stale_stream_render_feedback_cannot_release_replacement_stream() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.user_video_feedback_capability(1, true);
        for stream_id in [31, 32] {
            qos.user_video_feedback(
                1,
                MONITOR_SERVICE,
                &VideoFeedback {
                    display: 0,
                    stream_id,
                    ..Default::default()
                },
            );
        }
        qos.user_video_feedback(
            1,
            MONITOR_SERVICE,
            &VideoFeedback {
                display: 0,
                stream_id: 31,
                ..Default::default()
            },
        );

        assert!(!qos.user_video_frame_rendered_for_service(1, MONITOR_SERVICE, 31));
        assert!(qos.startup_safe_mode(MONITOR_SERVICE));
        assert!(qos.user_video_frame_rendered_for_service(1, MONITOR_SERVICE, 32));
        assert!(!qos.startup_safe_mode(MONITOR_SERVICE));
    }

    #[test]
    fn expired_existing_viewer_does_not_extend_new_viewer_startup() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        expire_viewer_startup(&mut qos, 1, MONITOR_SERVICE);
        qos.on_connection_open(2);
        qos.user_video_feedback_capability(2, true);
        qos.sync_subscribers(MONITOR_SERVICE, HashSet::from([1, 2]));

        assert!(qos.startup_safe_mode(MONITOR_SERVICE));
        assert!(qos.user_video_frame_rendered(2));
        assert!(!qos.startup_safe_mode(MONITOR_SERVICE));
    }

    #[test]
    fn first_render_does_not_override_delayed_response_cap() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.user_video_feedback_capability(1, true);
        qos.user_delay_response_elapsed(1, 2_500);

        assert!(qos.user_video_frame_rendered(1));
        assert_eq!(qos.fps(MONITOR_SERVICE), MIN_FPS + 1);
    }

    #[test]
    fn isolated_transport_loss_does_not_back_off_adaptive_fps() {
        let now = Instant::now();
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.set_support_changing_quality(MONITOR_SERVICE, true);
        qos.store_bitrate(MONITOR_SERVICE, 4_000);
        qos.user_video_feedback_capability(1, true);
        qos.user_custom_fps(1, 60);
        assert!(qos.user_video_frame_rendered(1));
        assert_eq!(qos.fps(MONITOR_SERVICE), 60);
        let initial_ratio = qos.displays.get(MONITOR_SERVICE).unwrap().ratio;

        assert!(!qos.user_transport_loss_at(1, transport_loss_sample(0, 7, 40, 1), now,));
        assert_eq!(qos.fps(MONITOR_SERVICE), 60);
        assert_eq!(
            qos.displays.get(MONITOR_SERVICE).unwrap().ratio,
            initial_ratio
        );
        assert!(qos.displays[MONITOR_SERVICE].upshift_frozen_until.is_none());
        assert!(qos.users.get(&1).unwrap().delay.delay_history.is_empty());
    }

    #[test]
    fn isolated_custom_transport_loss_freezes_bitrate_upshift_without_fps_backoff() {
        let now = Instant::now();
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.set_support_changing_quality(MONITOR_SERVICE, true);
        qos.store_bitrate(MONITOR_SERVICE, 4_000);
        qos.user_image_quality(1, 100 << 8);
        qos.user_custom_fps(1, 60);
        qos.user_video_feedback_capability(1, true);
        assert!(qos.user_video_frame_rendered(1));
        qos.users.get_mut(&1).unwrap().delay.add_delay(20);
        qos.displays.get_mut(MONITOR_SERVICE).unwrap().ratio = 0.5;

        assert!(!qos.user_transport_loss_at(1, transport_loss_sample(0, 7, 40, 1), now,));
        assert_eq!(qos.fps(MONITOR_SERVICE), 60);
        assert_eq!(qos.displays[MONITOR_SERVICE].ratio, 0.5);
        assert_eq!(
            qos.users[&1].transport_loss_upshift_frozen_until[MONITOR_SERVICE],
            now.checked_add(DATAGRAM_ADMISSION_UPSHIFT_FREEZE).unwrap()
        );
        assert!(qos.displays[MONITOR_SERVICE].upshift_frozen_until.is_none());

        qos.adjust_ratio_at(
            MONITOR_SERVICE,
            true,
            now + DATAGRAM_ADMISSION_UPSHIFT_FREEZE - Duration::from_millis(1),
        );
        assert_eq!(qos.displays[MONITOR_SERVICE].ratio, 0.5);

        qos.adjust_ratio_at(
            MONITOR_SERVICE,
            true,
            now + DATAGRAM_ADMISSION_UPSHIFT_FREEZE + Duration::from_millis(1),
        );
        assert!(qos.displays[MONITOR_SERVICE].ratio > 0.5);
    }

    #[test]
    fn repeated_custom_transport_loss_reduces_ratio_without_reducing_fps() {
        let now = Instant::now();
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.set_support_changing_quality(MONITOR_SERVICE, true);
        qos.store_bitrate(MONITOR_SERVICE, 7_200);
        qos.user_image_quality(1, 100 << 8);
        qos.user_custom_fps(1, 60);
        qos.user_video_feedback_capability(1, true);
        assert!(qos.user_video_frame_rendered(1));
        qos.displays.get_mut(MONITOR_SERVICE).unwrap().ratio = 2.0;

        assert!(!qos.user_transport_loss_at(1, transport_loss_sample(0, 7, 100, 1), now,));
        assert!(qos.user_transport_loss_at(
            1,
            transport_loss_sample(0, 7, 140, 1),
            now + Duration::from_secs(1),
        ));

        assert!(qos.displays[MONITOR_SERVICE].ratio < 2.0);
        assert_eq!(qos.fps(MONITOR_SERVICE), 60);
        assert!(qos.users[&1].last_transport_loss_at.is_none());
    }

    #[test]
    fn custom_congestion_episode_bounds_combined_loss_and_delay_reductions() {
        let now = Instant::now();
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.set_support_changing_quality(MONITOR_SERVICE, true);
        qos.store_bitrate(MONITOR_SERVICE, 7_200);
        qos.user_image_quality(1, 100 << 8);
        qos.user_custom_fps(1, 60);
        qos.user_video_feedback_capability(1, true);
        assert!(qos.user_video_frame_rendered(1));
        qos.displays.get_mut(MONITOR_SERVICE).unwrap().ratio = 2.0;

        assert!(!qos.user_transport_loss_at(1, transport_loss_sample(0, 7, 100, 1), now,));
        for (offset_secs, frame_id) in [(2, 140), (4, 180), (6, 220)] {
            assert!(qos.user_transport_loss_at(
                1,
                transport_loss_sample(0, 7, frame_id, 1),
                now + Duration::from_secs(offset_secs),
            ));
        }
        assert!(!qos.user_transport_loss_at(
            1,
            transport_loss_sample(0, 7, 260, 1),
            now + Duration::from_secs(8),
        ));

        qos.users.get_mut(&1).unwrap().delay.delay_history.clear();
        qos.users.get_mut(&1).unwrap().delay.add_delay(600);
        qos.adjust_ratio_at(MONITOR_SERVICE, true, now + Duration::from_secs(9));
        qos.adjust_ratio_at(MONITOR_SERVICE, true, now + Duration::from_secs(12));

        let display = &qos.displays[MONITOR_SERVICE];
        assert!(display.ratio >= 1.0);
        assert_eq!(display.congestion_episode_floor_ratio, Some(1.0));
        assert_eq!(display.congestion_episode_transport_reductions, 3);
        assert_eq!(qos.fps(MONITOR_SERVICE), 60);
    }

    #[test]
    fn custom_congestion_episode_resets_after_clean_interval() {
        let now = Instant::now();
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.set_support_changing_quality(MONITOR_SERVICE, true);
        qos.store_bitrate(MONITOR_SERVICE, 7_200);
        qos.user_image_quality(1, 100 << 8);
        qos.displays.get_mut(MONITOR_SERVICE).unwrap().ratio = 2.0;
        assert!(!qos.user_transport_loss_at(1, transport_loss_sample(0, 7, 100, 1), now,));
        assert_eq!(
            qos.displays[MONITOR_SERVICE].congestion_episode_floor_ratio,
            Some(1.0)
        );

        qos.users.get_mut(&1).unwrap().delay.add_delay(20);
        qos.adjust_ratio_at(
            MONITOR_SERVICE,
            true,
            now + CUSTOM_CONGESTION_EPISODE_CLEAN_RESET + Duration::from_millis(1),
        );
        assert!(qos.displays[MONITOR_SERVICE]
            .congestion_episode_floor_ratio
            .is_none());
    }

    #[test]
    fn nvenc_upshifts_are_coalesced_without_delaying_downshifts() {
        let now = Instant::now();
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.set_support_changing_quality(MONITOR_SERVICE, true);
        qos.user_image_quality(1, 100 << 8);
        qos.users.get_mut(&1).unwrap().delay.add_delay(20);
        qos.store_bitrate(MONITOR_SERVICE, 4_000);
        qos.store_pipeline_status(
            MONITOR_SERVICE,
            "Windows Graphics Capture Helper (CPU)",
            "Hardware NVIDIA NVENC via FFmpeg",
            "CPU YUV frame",
        );
        qos.displays.get_mut(MONITOR_SERVICE).unwrap().ratio = 1.0;

        qos.adjust_ratio_at(MONITOR_SERVICE, true, now);
        let first_upshift = qos.displays[MONITOR_SERVICE].ratio;
        assert!((first_upshift - 1.125).abs() < f32::EPSILON);

        qos.adjust_ratio_at(MONITOR_SERVICE, true, now + Duration::from_secs(9));
        assert_eq!(qos.displays[MONITOR_SERVICE].ratio, first_upshift);

        qos.adjust_ratio_at(MONITOR_SERVICE, true, now + Duration::from_secs(10));
        assert!(qos.displays[MONITOR_SERVICE].ratio > first_upshift);

        qos.users.get_mut(&1).unwrap().delay.delay_history.clear();
        qos.users.get_mut(&1).unwrap().delay.add_delay(600);
        let before_downshift = qos.displays[MONITOR_SERVICE].ratio;
        qos.adjust_ratio_at(MONITOR_SERVICE, true, now + Duration::from_secs(11));
        assert!(qos.displays[MONITOR_SERVICE].ratio < before_downshift);
    }

    #[test]
    fn admission_clean_reset_does_not_clear_transport_loss_freeze() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        qos.user_image_quality(1, 100 << 8);
        qos.users.get_mut(&1).unwrap().delay.add_delay(20);
        qos.displays.get_mut(MONITOR_SERVICE).unwrap().ratio = 0.5;
        qos.user_datagram_admission_at(1, MONITOR_SERVICE, datagram_admission_sample(0, 0), start);

        let loss_at = start + DATAGRAM_ADMISSION_CLEAN_RESET + Duration::from_secs(1);
        assert!(!qos.user_transport_loss_at(1, transport_loss_sample(0, 7, 100, 1), loss_at,));
        assert!(!qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(0, 30),
            loss_at + Duration::from_millis(100),
        ));
        assert!(
            qos.users[&1].transport_loss_upshift_frozen_until[MONITOR_SERVICE]
                > loss_at + Duration::from_millis(100)
        );

        qos.adjust_ratio_at(MONITOR_SERVICE, true, loss_at + Duration::from_secs(1));
        assert_eq!(qos.displays[MONITOR_SERVICE].ratio, 0.5);
    }

    #[test]
    fn custom_transport_freeze_survives_movie_to_standard_stream_reset() {
        let now = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        qos.user_image_quality(1, 100 << 8);
        qos.users.get_mut(&1).unwrap().delay.add_delay(20);
        qos.displays.get_mut(MONITOR_SERVICE).unwrap().ratio = 0.5;

        assert!(!qos.user_transport_loss_at(1, transport_loss_sample(0, 7, 100, 1), now,));
        qos.user_video_profile(1, VideoProfile::Standard);
        assert!(qos.users[&1]
            .transport_loss_upshift_frozen_until
            .contains_key(MONITOR_SERVICE));

        qos.adjust_ratio_at(MONITOR_SERVICE, true, now + Duration::from_secs(1));
        assert!(qos.displays[MONITOR_SERVICE].ratio <= 0.5);
    }

    #[test]
    fn one_custom_viewer_loss_does_not_freeze_healthy_shared_viewer() {
        let now = Instant::now();
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1, 2]);
        qos.set_support_changing_quality(MONITOR_SERVICE, true);
        qos.store_bitrate(MONITOR_SERVICE, 4_000);
        for id in [1, 2] {
            qos.user_image_quality(id, 100 << 8);
            qos.user_custom_fps(id, 60);
            qos.user_video_feedback_capability(id, true);
            assert!(qos.user_video_frame_rendered(id));
            qos.users.get_mut(&id).unwrap().delay.add_delay(20);
        }
        qos.displays.get_mut(MONITOR_SERVICE).unwrap().ratio = 0.5;

        assert!(!qos.user_transport_loss_at(1, transport_loss_sample(0, 7, 100, 1), now,));
        qos.adjust_ratio_at(MONITOR_SERVICE, true, now + Duration::from_millis(500));
        assert!(qos.displays[MONITOR_SERVICE].ratio > 0.5);

        assert!(!qos.user_transport_loss_at(
            2,
            transport_loss_sample(0, 7, 100, 1),
            now + Duration::from_secs(1),
        ));
        let frozen_ratio = qos.displays[MONITOR_SERVICE].ratio;
        qos.adjust_ratio_at(MONITOR_SERVICE, true, now + Duration::from_secs(2));
        assert_eq!(qos.displays[MONITOR_SERVICE].ratio, frozen_ratio);

        assert!(qos.user_transport_loss_at(
            1,
            transport_loss_sample(0, 8, 1, 1),
            now + Duration::from_secs(2),
        ));
        assert!(qos.displays[MONITOR_SERVICE].ratio < frozen_ratio);
        assert_eq!(qos.fps(MONITOR_SERVICE), 60);
    }

    #[test]
    fn image_quality_change_clears_custom_transport_freeze() {
        let now = Instant::now();
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.set_support_changing_quality(MONITOR_SERVICE, true);
        qos.user_image_quality(1, 100 << 8);
        assert!(!qos.user_transport_loss_at(1, transport_loss_sample(0, 7, 100, 1), now,));
        assert!(!qos.users[&1].transport_loss_upshift_frozen_until.is_empty());

        qos.user_preset_image_quality(1, ImageQuality::Balanced.value());
        assert!(qos.users[&1].transport_loss_upshift_frozen_until.is_empty());
        assert!(qos.displays[MONITOR_SERVICE]
            .congestion_episode_floor_ratio
            .is_none());
        assert_eq!(
            qos.displays[MONITOR_SERVICE].congestion_episode_transport_reductions,
            0
        );
    }

    #[test]
    fn sparse_transport_losses_match_field_session_without_fps_collapse() {
        let now = Instant::now();
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.user_custom_fps(1, 104);
        qos.user_video_feedback_capability(1, true);
        assert!(qos.user_video_frame_rendered(1));

        let samples = [(40, 2), (178, 10), (224, 13), (288, 18), (364, 24)];
        for (frame_id, elapsed_secs) in samples {
            assert!(!qos.user_transport_loss_at(
                1,
                transport_loss_sample(0, 6, frame_id, 1),
                now + Duration::from_secs(elapsed_secs),
            ));
        }

        assert_eq!(qos.fps(MONITOR_SERVICE), 104);
        assert!(qos.users.get(&1).unwrap().last_transport_loss_at.is_none());
    }

    #[test]
    fn transport_loss_burst_reduces_ratio_on_low_delay_path() {
        let now = Instant::now();
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.set_support_changing_quality(MONITOR_SERVICE, true);
        qos.store_bitrate(MONITOR_SERVICE, 4_000);
        qos.user_video_feedback_capability(1, true);
        qos.user_custom_fps(1, 60);
        assert!(qos.user_video_frame_rendered(1));
        qos.users.get_mut(&1).unwrap().delay.add_delay(20);
        let initial_ratio = qos.displays.get(MONITOR_SERVICE).unwrap().ratio;

        assert!(qos.user_transport_loss_at(1, transport_loss_sample(0, 7, 40, 3), now,));
        assert_eq!(qos.fps(MONITOR_SERVICE), 52);
        assert!(qos.displays.get(MONITOR_SERVICE).unwrap().ratio < initial_ratio);
        assert!(qos.displays[MONITOR_SERVICE].upshift_frozen_until.is_none());
        assert_eq!(qos.users.get(&1).unwrap().delay.avg_delay(), 20);

        assert!(!qos.user_transport_loss_at(
            1,
            transport_loss_sample(0, 7, 80, 3),
            now + Duration::from_secs(1),
        ));
        assert_eq!(qos.fps(MONITOR_SERVICE), 52);

        assert!(!qos.user_transport_loss_at(
            1,
            transport_loss_sample(0, 7, 120, 1),
            now + TRANSPORT_LOSS_BACKOFF_COOLDOWN + Duration::from_millis(1),
        ));
        assert_eq!(qos.fps(MONITOR_SERVICE), 52);
    }

    #[test]
    fn transport_loss_rate_backoff_ignores_stale_requests_and_resets_on_new_stream() {
        let now = Instant::now();
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.user_custom_fps(1, 60);
        qos.user_video_feedback_capability(1, true);
        assert!(qos.user_video_frame_rendered(1));

        assert!(!qos.user_transport_loss_at(1, transport_loss_sample(0, 7, 100, 1), now,));
        assert!(!qos.user_transport_loss_at(
            1,
            transport_loss_sample(0, 7, 98, 1),
            now + Duration::from_millis(10),
        ));
        assert!(!qos.user_transport_loss_at(
            1,
            transport_loss_sample(0, 7, 115, 1),
            now + Duration::from_secs(1),
        ));
        assert!(qos.user_transport_loss_at(
            1,
            transport_loss_sample(0, 7, 130, 1),
            now + Duration::from_secs(2),
        ));
        assert_eq!(qos.fps(MONITOR_SERVICE), 52);

        assert!(!qos.user_transport_loss_at(
            1,
            transport_loss_sample(0, 8, 1, 1),
            now + TRANSPORT_LOSS_BACKOFF_COOLDOWN + Duration::from_secs(1),
        ));
        assert_eq!(qos.fps(MONITOR_SERVICE), 52);
        let user = qos.users.get(&1).unwrap();
        assert_eq!(user.transport_loss_windows.len(), 1);
        assert!(user.transport_loss_windows.contains_key(&TransportLossKey {
            display: 0,
            stream_id: 8,
        }));
    }

    #[test]
    fn sustained_datagram_admission_pressure_reduces_ratio_before_cadence() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        let initial_ratio = qos.displays[MONITOR_SERVICE].ratio;

        qos.user_datagram_admission_at(1, MONITOR_SERVICE, datagram_admission_sample(0, 0), start);
        assert!(!qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(1, 29),
            start + Duration::from_millis(500),
        ));
        assert!(qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(2, 58),
            start + Duration::from_millis(500) + DATAGRAM_ADMISSION_PRESSURE_DURATION,
        ));

        let display = &qos.displays[MONITOR_SERVICE];
        assert!(display.ratio < initial_ratio);
        assert_eq!(display.admission_events, 1);
        assert!(!display.movie_admission_pressure);
        assert_eq!(qos.users[&1].delay.fps, Some(60));
        assert!(qos.users[&1].delay.delay_history.is_empty());
    }

    #[test]
    fn sustained_queue_pressure_reduces_ratio_before_the_first_rejection() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        let initial_ratio = qos.displays[MONITOR_SERVICE].ratio;

        qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            preemptive_datagram_pressure_sample(0),
            start,
        );
        assert!(!qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            preemptive_datagram_pressure_sample(30),
            start + Duration::from_millis(500),
        ));
        assert!(qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            preemptive_datagram_pressure_sample(60),
            start + Duration::from_millis(500) + DATAGRAM_ADMISSION_PRESSURE_DURATION,
        ));
        assert!(qos.displays[MONITOR_SERVICE].ratio < initial_ratio);
    }

    #[test]
    fn datagram_admission_upshift_freeze_blocks_only_increases() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        qos.users.get_mut(&1).unwrap().delay.add_delay(20);
        qos.user_datagram_admission_at(1, MONITOR_SERVICE, datagram_admission_sample(0, 0), start);
        qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(1, 29),
            start + Duration::from_millis(500),
        );
        assert!(qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(2, 58),
            start + Duration::from_millis(500) + DATAGRAM_ADMISSION_PRESSURE_DURATION,
        ));
        let reduced = qos.displays[MONITOR_SERVICE].ratio;

        qos.adjust_ratio_at(MONITOR_SERVICE, true, start + Duration::from_secs(2));
        assert_eq!(qos.displays[MONITOR_SERVICE].ratio, reduced);
        qos.adjust_ratio_at(MONITOR_SERVICE, true, start + Duration::from_secs(8));
        assert!(qos.displays[MONITOR_SERVICE].ratio > reduced);
    }

    #[test]
    fn repeated_admission_actions_escalate_and_sustained_clean_samples_reset() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        qos.user_datagram_admission_at(1, MONITOR_SERVICE, datagram_admission_sample(0, 0), start);
        let mut rejected = 0u64;
        let mut sent = 0u64;
        for (expected_action, elapsed_ms) in
            [(false, 500), (true, 1_500), (false, 2_000), (false, 2_500)]
        {
            rejected += 1;
            sent += 29;
            let acted = qos.user_datagram_admission_at(
                1,
                MONITOR_SERVICE,
                datagram_admission_sample(rejected, sent),
                start + Duration::from_millis(elapsed_ms),
            );
            assert_eq!(acted, expected_action);
        }
        assert!(
            qos.movie_admission_pressure_at(MONITOR_SERVICE, start + Duration::from_millis(2_500))
        );

        assert!(!qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(rejected, sent + 30),
            start + Duration::from_secs(3),
        ));
        assert!(qos.movie_admission_pressure_at(MONITOR_SERVICE, start + Duration::from_secs(3)));
        assert!(!qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(rejected, sent + 60),
            start + Duration::from_secs(3) + DATAGRAM_ADMISSION_CLEAN_RESET,
        ));
        assert!(!qos.movie_admission_pressure_at(
            MONITOR_SERVICE,
            start + Duration::from_secs(3) + DATAGRAM_ADMISSION_CLEAN_RESET
        ));
    }

    #[test]
    fn one_pressured_movie_viewer_does_not_throttle_shared_encoder() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1, 2]);
        let initial_ratio = qos.displays[MONITOR_SERVICE].ratio;

        for id in [1, 2] {
            qos.user_datagram_admission_at(
                id,
                MONITOR_SERVICE,
                datagram_admission_sample(0, 0),
                start,
            );
        }
        for elapsed_ms in [500, 1_500] {
            let sequence = if elapsed_ms == 500 { 1 } else { 2 };
            assert!(!qos.user_datagram_admission_at(
                1,
                MONITOR_SERVICE,
                datagram_admission_sample(sequence, 29 * sequence),
                start + Duration::from_millis(elapsed_ms),
            ));
            assert!(!qos.user_datagram_admission_at(
                2,
                MONITOR_SERVICE,
                datagram_admission_sample(0, 30 * sequence),
                start + Duration::from_millis(elapsed_ms),
            ));
        }
        assert_eq!(qos.displays[MONITOR_SERVICE].ratio, initial_ratio);
        assert!(
            !qos.movie_admission_pressure_at(MONITOR_SERVICE, start + Duration::from_millis(1_500))
        );
    }

    #[test]
    fn all_pressured_viewers_apply_one_shared_ratio_reduction() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1, 2]);
        for id in [1, 2] {
            qos.user_datagram_admission_at(
                id,
                MONITOR_SERVICE,
                datagram_admission_sample(0, 0),
                start,
            );
        }
        for id in [1, 2] {
            qos.user_datagram_admission_at(
                id,
                MONITOR_SERVICE,
                datagram_admission_sample(1, 29),
                start + Duration::from_millis(500),
            );
        }
        let first = qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(2, 58),
            start + Duration::from_millis(1_500),
        );
        let second = qos.user_datagram_admission_at(
            2,
            MONITOR_SERVICE,
            datagram_admission_sample(2, 58),
            start + Duration::from_millis(1_500),
        );
        assert!(first);
        assert!(!second);
        assert_eq!(qos.displays[MONITOR_SERVICE].admission_ratio_reductions, 1);
        assert_eq!(qos.displays[MONITOR_SERVICE].admission_events, 1);
    }

    #[test]
    fn admission_cadence_pressure_still_works_without_vbr() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        qos.set_support_changing_quality(MONITOR_SERVICE, false);
        qos.user_datagram_admission_at(1, MONITOR_SERVICE, datagram_admission_sample(0, 0), start);
        for (sequence, elapsed_ms) in [(1, 500), (2, 1_500), (3, 2_000), (4, 2_500)] {
            assert!(!qos.user_datagram_admission_at(
                1,
                MONITOR_SERVICE,
                datagram_admission_sample(sequence, sequence * 29),
                start + Duration::from_millis(elapsed_ms),
            ));
        }
        assert!(
            qos.movie_admission_pressure_at(MONITOR_SERVICE, start + Duration::from_millis(2_500))
        );
        assert_eq!(qos.displays[MONITOR_SERVICE].admission_ratio_reductions, 0);
    }

    #[test]
    fn admission_pressure_latch_expires_without_fresh_samples() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        let display = qos.displays.get_mut(MONITOR_SERVICE).unwrap();
        display.movie_admission_pressure = true;
        display.admission_latched_at = Some(start);
        display.admission_events = DATAGRAM_ADMISSION_CADENCE_EVENTS;

        assert!(qos.movie_admission_pressure_at(
            MONITOR_SERVICE,
            start + DATAGRAM_ADMISSION_CLEAN_RESET * 2 - Duration::from_millis(1)
        ));
        assert!(!qos.movie_admission_pressure_at(
            MONITOR_SERVICE,
            start + DATAGRAM_ADMISSION_CLEAN_RESET * 2
        ));
        assert_eq!(qos.displays[MONITOR_SERVICE].admission_events, 0);
    }

    #[test]
    fn congestion_ratio_noop_does_not_arm_cooldown_or_freeze() {
        let now = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        let display = qos.displays.get_mut(MONITOR_SERVICE).unwrap();
        display.ratio = BR_MIN_HIGH_RESOLUTION;
        display.bitrate_store = 1_000;

        assert!(!qos.reduce_ratio_for_congestion(MONITOR_SERVICE, now, "test", true));
        let display = &qos.displays[MONITOR_SERVICE];
        assert!(display.last_congestion_reduction_at.is_none());
        assert!(display.upshift_frozen_until.is_none());
    }

    #[test]
    fn admission_counter_reset_is_not_treated_as_new_pressure() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        qos.user_datagram_admission_at(1, MONITOR_SERVICE, datagram_admission_sample(0, 0), start);
        qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(1, 29),
            start + Duration::from_millis(500),
        );
        assert!(qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(2, 58),
            start + Duration::from_millis(1_500),
        ));
        let reductions = qos.displays[MONITOR_SERVICE].admission_ratio_reductions;
        assert!(!qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(0, 0),
            start + Duration::from_secs(2),
        ));
        assert_eq!(
            qos.displays[MONITOR_SERVICE].admission_ratio_reductions,
            reductions
        );
        assert!(!qos.users[&1].datagram_admission_by_service[MONITOR_SERVICE].pressured);
    }

    #[test]
    fn transport_loss_does_not_double_reduce_recent_admission_action() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        qos.user_custom_fps(1, 60);
        qos.user_datagram_admission_at(1, MONITOR_SERVICE, datagram_admission_sample(0, 0), start);
        qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(1, 29),
            start + Duration::from_millis(500),
        );
        assert!(qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(2, 58),
            start + Duration::from_millis(500) + DATAGRAM_ADMISSION_PRESSURE_DURATION,
        ));
        let reduced = qos.displays[MONITOR_SERVICE].ratio;

        assert!(qos.user_transport_loss_at(
            1,
            transport_loss_sample(0, 7, 40, 3),
            start
                + Duration::from_millis(500)
                + DATAGRAM_ADMISSION_PRESSURE_DURATION
                + Duration::from_millis(100),
        ));
        assert_eq!(qos.displays[MONITOR_SERVICE].ratio, reduced);
        assert_eq!(qos.users[&1].delay.fps, Some(52));
    }

    #[test]
    fn admission_freeze_is_armed_when_transport_loss_reduced_ratio_first() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        qos.user_custom_fps(1, 60);
        qos.user_datagram_admission_at(1, MONITOR_SERVICE, datagram_admission_sample(0, 0), start);
        qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(1, 29),
            start + Duration::from_millis(500),
        );
        assert!(qos.user_transport_loss_at(
            1,
            transport_loss_sample(0, 7, 40, 3),
            start + Duration::from_millis(1_400),
        ));
        let reduced = qos.displays[MONITOR_SERVICE].ratio;

        assert!(!qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(2, 58),
            start + Duration::from_millis(1_500),
        ));
        let display = &qos.displays[MONITOR_SERVICE];
        assert_eq!(display.ratio, reduced);
        assert!(display.upshift_frozen_until.is_some_and(|until| {
            until >= start + Duration::from_millis(1_500) + DATAGRAM_ADMISSION_UPSHIFT_FREEZE
        }));
    }

    #[test]
    fn movie_pacing_clamps_legacy_fps_without_changing_target() {
        let mut qos = movie_qos_with_viewers(&[1]);
        qos.user_custom_fps(1, 120);
        qos.users.get_mut(&1).unwrap().delay.fps = Some(120);
        qos.store_movie_runtime_status(MONITOR_SERVICE, 120, 30, 16_000);
        qos.adjust_fps(MONITOR_SERVICE);

        assert_eq!(qos.fps(MONITOR_SERVICE), 30);
        assert_eq!(qos.movie_target_fps(MONITOR_SERVICE), 120);
        assert_eq!(qos.movie_runtime_status(MONITOR_SERVICE).0, 120);
    }

    #[test]
    fn standard_profile_ignores_and_clears_admission_pressure() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        qos.user_datagram_admission_at(1, MONITOR_SERVICE, datagram_admission_sample(0, 0), start);
        qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(1, 29),
            start + Duration::from_millis(500),
        );
        assert!(qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(2, 58),
            start + Duration::from_millis(1_500),
        ));
        assert!(qos.displays[MONITOR_SERVICE].upshift_frozen_until.is_some());
        qos.user_video_profile(1, VideoProfile::Standard);
        assert!(!qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(2, 58),
            start + Duration::from_secs(1),
        ));
        let display = &qos.displays[MONITOR_SERVICE];
        assert_eq!(display.admission_events, 0);
        assert!(!display.movie_admission_pressure);
        assert!(display.upshift_frozen_until.is_none());
        assert!(display.last_congestion_reduction_at.is_some());

        qos.user_video_profile(1, VideoProfile::Movie);
        qos.user_video_feedback_capability(1, true);
        qos.user_movie_transport_capability(1, true);
        assert!(!qos.user_datagram_admission_at(
            1,
            MONITOR_SERVICE,
            datagram_admission_sample(100, 1_000),
            start + Duration::from_secs(3_600),
        ));
        assert!(!qos.users[&1].datagram_admission_by_service[MONITOR_SERVICE].pressured);
    }

    #[test]
    fn connection_admission_sample_baselines_every_subscribed_service() {
        let start = Instant::now();
        let mut qos = movie_qos_with_viewers(&[1]);
        qos.new_display(CAMERA_SERVICE.to_owned());
        qos.sync_subscribers(CAMERA_SERVICE, HashSet::from([1]));
        assert_eq!(
            qos.user_datagram_admission_for_user_at(1, datagram_admission_sample(10, 100), start,),
            0
        );
        let user = &qos.users[&1];
        assert!(user
            .datagram_admission_by_service
            .contains_key(MONITOR_SERVICE));
        assert!(user
            .datagram_admission_by_service
            .contains_key(CAMERA_SERVICE));
        assert!(!user.datagram_admission_by_service[MONITOR_SERVICE].pressured);
        assert!(!user.datagram_admission_by_service[CAMERA_SERVICE].pressured);
    }

    #[test]
    fn established_viewer_is_not_restarted_by_new_viewer() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.user_video_feedback_capability(1, true);
        assert!(qos.user_video_frame_rendered(1));

        qos.on_connection_open(2);
        qos.user_video_feedback_capability(2, true);
        qos.sync_subscribers(MONITOR_SERVICE, HashSet::from([1, 2]));

        assert!(!qos.startup_safe_mode(MONITOR_SERVICE));
        assert_eq!(qos.fps(MONITOR_SERVICE), FPS);
    }

    #[test]
    fn bad_camera_viewer_does_not_throttle_monitor_service() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.new_display(CAMERA_SERVICE.to_owned());
        qos.on_connection_open(2);
        qos.sync_subscribers(CAMERA_SERVICE, HashSet::from([2]));
        qos.user_custom_fps(1, 60);
        qos.users.get_mut(&1).unwrap().delay.fps = Some(60);
        establish_viewer(&mut qos, 1, MONITOR_SERVICE);
        qos.users.get_mut(&2).unwrap().delay.fps = Some(2);
        qos.users.get_mut(&2).unwrap().delay.response_delayed = true;
        establish_viewer(&mut qos, 2, CAMERA_SERVICE);

        qos.adjust_fps(MONITOR_SERVICE);
        qos.adjust_fps(CAMERA_SERVICE);

        assert_eq!(qos.fps(MONITOR_SERVICE), 60);
        assert_eq!(qos.fps(CAMERA_SERVICE), 2);
    }

    #[test]
    fn slow_viewer_does_not_throttle_healthy_viewer_on_shared_service() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1, 2]);
        qos.user_custom_fps(1, 60);
        qos.users.get_mut(&1).unwrap().delay.fps = Some(60);
        establish_viewer(&mut qos, 1, MONITOR_SERVICE);
        qos.users.get_mut(&2).unwrap().delay.fps = Some(2);
        qos.users.get_mut(&2).unwrap().delay.response_delayed = true;
        establish_viewer(&mut qos, 2, MONITOR_SERVICE);

        qos.adjust_fps(MONITOR_SERVICE);

        assert_eq!(qos.fps(MONITOR_SERVICE), 60);
    }

    #[test]
    fn bitrate_and_pipeline_status_are_service_local() {
        let mut qos = VideoQoS::default();
        qos.new_display(MONITOR_SERVICE.to_owned());
        qos.new_display(CAMERA_SERVICE.to_owned());
        qos.store_bitrate(MONITOR_SERVICE, 12_000);
        qos.store_bitrate(CAMERA_SERVICE, 800);
        qos.store_pipeline_status(MONITOR_SERVICE, "WGC", "NVENC", "D3D11");
        qos.store_pipeline_status(CAMERA_SERVICE, "Camera", "Software", "YUV");

        assert_eq!(qos.bitrate(MONITOR_SERVICE), 12_000);
        assert_eq!(qos.bitrate(CAMERA_SERVICE), 800);
        assert_eq!(
            qos.pipeline_status(MONITOR_SERVICE),
            (
                Some("WGC".to_owned()),
                None,
                Some("NVENC".to_owned()),
                Some("D3D11".to_owned())
            )
        );
        assert_eq!(
            qos.pipeline_status(CAMERA_SERVICE),
            (
                Some("Camera".to_owned()),
                None,
                Some("Software".to_owned()),
                Some("YUV".to_owned())
            )
        );
    }
}

#[derive(Default, Debug, Clone)]
struct RttCalculator {
    min_rtt: Option<u32>,        // Historical minimum RTT ever observed
    window_min_rtt: Option<u32>, // Minimum RTT within last 60 samples
    smoothed_rtt: Option<u32>,   // Smoothed RTT estimation
    samples: VecDeque<u32>,      // Last 60 RTT samples
}

impl RttCalculator {
    const WINDOW_SAMPLES: usize = 60; // Keep last 60 samples
    const MIN_SAMPLES: usize = 10; // Require at least 10 samples
    const ALPHA: f32 = 0.5; // Smoothing factor for weighted average

    /// Update RTT estimates with a new sample
    pub fn update(&mut self, delay: u32) {
        // 1. Update historical minimum RTT
        match self.min_rtt {
            Some(min_rtt) if delay < min_rtt => self.min_rtt = Some(delay),
            None => self.min_rtt = Some(delay),
            _ => {}
        }

        // 2. Update sample window
        if self.samples.len() >= Self::WINDOW_SAMPLES {
            self.samples.pop_front();
        }
        self.samples.push_back(delay);

        // 3. Calculate minimum RTT within the window
        self.window_min_rtt = self.samples.iter().min().copied();

        // 4. Calculate smoothed RTT
        // Use weighted average if we have enough samples
        if self.samples.len() >= Self::WINDOW_SAMPLES {
            if let (Some(min), Some(window_min)) = (self.min_rtt, self.window_min_rtt) {
                // Weighted average of historical minimum and window minimum
                let new_srtt =
                    ((1.0 - Self::ALPHA) * min as f32 + Self::ALPHA * window_min as f32) as u32;
                self.smoothed_rtt = Some(new_srtt);
            }
        }
    }

    /// Get current RTT estimate
    /// Returns None if no valid estimation is available
    pub fn get_rtt(&self) -> Option<u32> {
        if let Some(rtt) = self.smoothed_rtt {
            return Some(rtt);
        }
        if self.samples.len() >= Self::MIN_SAMPLES {
            if let Some(rtt) = self.min_rtt {
                return Some(rtt);
            }
        }
        None
    }
}
