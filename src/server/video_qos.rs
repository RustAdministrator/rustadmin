use super::*;
use crate::video_profile::VideoProfile;
use scrap::codec::{Quality, BR_BALANCED, BR_BEST, BR_SPEED};
use std::{
    collections::{HashSet, VecDeque},
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
pub(crate) const MOVIE_DEFAULT_TARGET_FPS: u32 = 60;
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
const TRANSPORT_LOSS_ADAPTATION_COOLDOWN: Duration = Duration::from_secs(1);
const TRANSPORT_LOSS_SYNTHETIC_DELAY_MS: u32 = 500;
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
        let host_pressure =
            sample.host_pipeline_p95_us > frame_period_us * 85 / 100 || missed_ratio > 0.05;
        let viewer_pressure = sample.viewer.available
            && (sample.viewer.max_queue_depth_frames > 3
                || u64::from(sample.viewer.max_decode_time_us) > frame_period_us * 80 / 100
                || u64::from(sample.viewer.max_render_submit_time_us) > frame_period_us * 80 / 100
                || u64::from(sample.viewer.presentation_jitter_p95_us) > frame_period_us / 2);
        let delivery_pressure =
            dropped_delta > 0 || late_delta > 0 || presentation_dropped_delta > 0;
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
        let healthy = sample.viewer.available
            && sample.viewer.all_rendered
            && sample.host_pipeline_p95_us > 0
            && sample.host_pipeline_p95_us <= next_period_us * 65 / 100
            && sample.host_missed_slots == 0
            && sample.viewer.max_queue_depth_frames <= 1
            && u64::from(sample.viewer.max_decode_time_us) <= next_period_us * 65 / 100
            && u64::from(sample.viewer.max_render_submit_time_us) <= next_period_us * 65 / 100;
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

// User session data structure
#[derive(Default, Debug, Clone)]
struct UserData {
    auto_adjust_fps: Option<u32>, // reserve for compatibility
    custom_fps: Option<u32>,
    fixed_fps: Option<u32>,
    quality: Option<(i64, Quality)>, // (time, quality)
    delay: UserDelay,
    record: bool,
    video_feedback_capable: bool,
    video_render_started: bool,
    video_startup_instant: Option<Instant>,
    last_transport_loss_at: Option<Instant>,
    video_profile: VideoProfile,
    movie_transport_capable: bool,
    movie_feedback_by_display: HashMap<i32, MovieViewerFeedback>,
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
        }
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
            has_established_viewer |= user.video_render_started;
            has_starting_viewer |= !user.video_render_started
                && user
                    .video_startup_instant
                    .is_some_and(|started| started.elapsed() < STARTUP_SAFE_WINDOW);
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
}

// User session management
impl VideoQoS {
    // Initialize new user session
    pub fn on_connection_open(&mut self, id: i32) {
        self.users.insert(
            id,
            UserData {
                video_startup_instant: Some(Instant::now()),
                ..Default::default()
            },
        );
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
        user.video_profile = profile;
        log::info!(
            "video profile applied: user_id={id}, requested={}",
            profile.config_value()
        );
    }

    pub(crate) fn user_movie_transport_capability(&mut self, id: i32, capable: bool) {
        if let Some(user) = self.users.get_mut(&id) {
            user.movie_transport_capable = capable;
        }
    }

    pub(crate) fn user_video_feedback(&mut self, id: i32, feedback: &VideoFeedback) {
        let Some(user) = self.users.get_mut(&id) else {
            return;
        };
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

        let quality = Some((hbb_common::get_time(), convert_quality(image_quality)));
        if let Some(user) = self.users.get_mut(&id) {
            user.quality = quality;
        } else {
            return;
        }
        for display_name in self.display_names_for_user(id) {
            let ratio = self.latest_quality(&display_name).ratio();
            if let Some(display) = self.displays.get_mut(&display_name) {
                display.ratio = ratio;
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
                user.video_render_started = false;
            }
        }
        self.adjust_displays_for_user(id);
    }

    pub fn user_video_frame_rendered(&mut self, id: i32) -> bool {
        let highest_fps = self.user_requested_fps(id);
        let first_render = self.users.get_mut(&id).is_some_and(|user| {
            if !user.video_feedback_capable || user.video_render_started {
                return false;
            }
            user.video_render_started = true;
            // One end-to-end rendered frame is enough to leave the conservative
            // bootstrap profile. A measured delay sample still takes priority.
            if user.delay.fps.is_none() && !user.delay.response_delayed {
                user.delay.fps = Some(highest_fps);
            }
            true
        });
        if first_render {
            self.adjust_displays_for_user(id);
        }
        first_render
    }

    pub fn user_transport_loss(&mut self, id: i32, dropped_frames: u64) -> bool {
        self.user_transport_loss_at(id, dropped_frames, Instant::now())
    }

    fn user_transport_loss_at(&mut self, id: i32, dropped_frames: u64, now: Instant) -> bool {
        if dropped_frames == 0 {
            return false;
        }
        let highest_fps = self.user_requested_fps(id);
        let (previous_fps, next_fps) = {
            let Some(user) = self.users.get_mut(&id) else {
                return false;
            };
            if user.last_transport_loss_at.is_some_and(|last| {
                now.saturating_duration_since(last) < TRANSPORT_LOSS_ADAPTATION_COOLDOWN
            }) {
                return false;
            }
            user.last_transport_loss_at = Some(now);
            user.delay.quick_increase_fps_count = 0;
            user.delay.increase_fps_count = 0;
            user.delay.add_delay(TRANSPORT_LOSS_SYNTHETIC_DELAY_MS);
            let previous_fps = user.delay.fps.unwrap_or(highest_fps);
            let next_fps = previous_fps
                .saturating_mul(3)
                .saturating_div(4)
                .clamp(MIN_FPS, highest_fps);
            user.delay.fps = Some(next_fps);
            (previous_fps, next_fps)
        };

        let affected_displays = self.display_names_for_user(id);
        for display_name in &affected_displays {
            self.adjust_fps(display_name);
            self.adjust_ratio(display_name, true);
        }
        log::warn!(
            "diag video qos transport loss: user_id={}, dropped_frames={}, fps_previous={}, fps_current={}, synthetic_delay_ms={}, displays={:?}",
            id,
            dropped_frames,
            previous_fps,
            next_fps,
            TRANSPORT_LOSS_SYNTHETIC_DELAY_MS,
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
        let changed = self
            .displays
            .get(video_service_name)
            .is_some_and(|display| display.subscribers != subscribers);
        if let Some(display) = self.displays.get_mut(video_service_name) {
            display.subscribers = subscribers;
        }
        if changed {
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
            all_rendered: subscribers.iter().all(|user| user.video_render_started),
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
        let Some(display) = self.displays.get(video_service_name) else {
            return;
        };
        let current_ratio = display.ratio;
        let current_bitrate = display.bitrate_store;

        // Calculate minimum ratio for high resolution (1Mbps baseline)
        let ratio_1mbps = if current_bitrate > 0 {
            Some((current_ratio * 1000.0 / current_bitrate as f32).max(BR_MIN_HIGH_RESOLUTION))
        } else {
            None
        };

        // Calculate ratio for adding 150kbps bandwidth
        let ratio_add_150kbps = if current_bitrate > 0 {
            Some((current_bitrate + 150) as f32 * current_ratio / current_bitrate as f32)
        } else {
            None
        };

        // Set minimum ratio based on quality mode
        let min = match target_quality {
            Quality::Best => {
                // For Best quality, ensure minimum 1Mbps for high resolution
                let mut min = BR_BEST / 2.5;
                if let Some(ratio_1mbps) = ratio_1mbps {
                    if min > ratio_1mbps {
                        min = ratio_1mbps;
                    }
                }
                min.max(BR_MIN)
            }
            Quality::Balanced => {
                let mut min = (BR_BALANCED / 2.0).min(0.4);
                if let Some(ratio_1mbps) = ratio_1mbps {
                    if min > ratio_1mbps {
                        min = ratio_1mbps;
                    }
                }
                min.max(BR_MIN_HIGH_RESOLUTION)
            }
            Quality::Low => BR_MIN_HIGH_RESOLUTION,
            Quality::Custom(_) => BR_MIN_HIGH_RESOLUTION,
        };
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
        if let Some(ratio_add_150kbps) = ratio_add_150kbps {
            if v > ratio_add_150kbps
                && ratio_add_150kbps > current_ratio
                && current_ratio >= BR_SPEED
            {
                v = ratio_add_150kbps;
            }
        }

        if let Some(display) = self.displays.get_mut(video_service_name) {
            let next_ratio = v.clamp(min, max);
            if display.ratio != next_ratio {
                log::info!(
                    "diag video qos ratio: service={}, previous={:.3}, current={:.3}, best_delay_ms={}, dynamic_screen={}, bitrate={}",
                    video_service_name,
                    display.ratio,
                    next_ratio,
                    best_delay,
                    dynamic_screen,
                    current_bitrate
                );
            }
            display.ratio = next_ratio;
            display.adjust_ratio_instant = Instant::now();
        }
    }

    // Adjust fps based on network delay and user response time
    fn adjust_fps(&mut self, video_service_name: &str) {
        if let Some(fps) = self.locked_fps(video_service_name) {
            if let Some(display) = self.displays.get_mut(video_service_name) {
                display.fps = fps;
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

        let next_fps = fps.clamp(MIN_FPS, highest_fps);
        let startup_safe = self.startup_safe_mode(video_service_name);
        if let Some(display) = self.displays.get_mut(video_service_name) {
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

    fn healthy_movie_sample(now: Instant, pipeline_us: u64) -> MovieCadenceSample {
        MovieCadenceSample {
            now,
            target_fps: 60,
            host_pipeline_p95_us: pipeline_us,
            host_iterations: 30,
            host_missed_slots: 0,
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
        pressure.host_missed_slots = 2;
        assert_eq!(controller.evaluate(pressure), None);
        pressure.now += MOVIE_PRESSURE_DURATION;
        let decision = controller.evaluate(pressure).unwrap();
        assert_eq!(decision.previous_fps, 60);
        assert_eq!(decision.current_fps, 30);
        assert_eq!(decision.reason, MovieCadenceReason::HostCapacity);
    }

    #[test]
    fn movie_cadence_requires_long_health_window_after_downshift() {
        let start = Instant::now();
        let mut controller = MovieCadenceController::new(60, 0, start);
        controller.evaluate(healthy_movie_sample(start, 5_000));
        controller.evaluate(healthy_movie_sample(start + MOVIE_PROBATION_HEALTHY, 5_000));

        let pressure_started = start + Duration::from_secs(3);
        let mut pressure = healthy_movie_sample(pressure_started, 16_000);
        pressure.host_missed_slots = 2;
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
            &VideoFeedback {
                display: 0,
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
    fn startup_safe_mode_expires() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.users.get_mut(&1).unwrap().video_startup_instant =
            Some(Instant::now() - STARTUP_SAFE_WINDOW - Duration::from_secs(1));

        assert!(!qos.startup_safe_mode(MONITOR_SERVICE));
        assert_eq!(qos.ratio(MONITOR_SERVICE), BR_BALANCED);
    }

    #[test]
    fn legacy_viewer_keeps_time_based_startup_fallback() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.user_video_feedback_capability(1, false);

        assert!(!qos.user_video_frame_rendered(1));
        assert!(qos.startup_safe_mode(MONITOR_SERVICE));
        qos.users.get_mut(&1).unwrap().video_startup_instant =
            Some(Instant::now() - STARTUP_SAFE_WINDOW - Duration::from_secs(1));
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
    fn expired_existing_viewer_does_not_extend_new_viewer_startup() {
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.users.get_mut(&1).unwrap().video_startup_instant =
            Some(Instant::now() - STARTUP_SAFE_WINDOW - Duration::from_secs(1));
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
    fn transport_loss_backs_off_adaptive_fps_and_ratio_with_cooldown() {
        let now = Instant::now();
        let mut qos = qos_with_viewers(MONITOR_SERVICE, &[1]);
        qos.set_support_changing_quality(MONITOR_SERVICE, true);
        qos.store_bitrate(MONITOR_SERVICE, 4_000);
        qos.user_video_feedback_capability(1, true);
        qos.user_custom_fps(1, 60);
        assert!(qos.user_video_frame_rendered(1));
        assert_eq!(qos.fps(MONITOR_SERVICE), 60);
        let initial_ratio = qos.displays.get(MONITOR_SERVICE).unwrap().ratio;

        assert!(qos.user_transport_loss_at(1, 1, now));
        assert_eq!(qos.fps(MONITOR_SERVICE), 45);
        let first_loss_ratio = qos.displays.get(MONITOR_SERVICE).unwrap().ratio;
        assert!(first_loss_ratio < initial_ratio);

        assert!(!qos.user_transport_loss_at(1, 2, now + Duration::from_millis(999)));
        assert_eq!(qos.fps(MONITOR_SERVICE), 45);
        assert_eq!(
            qos.displays.get(MONITOR_SERVICE).unwrap().ratio,
            first_loss_ratio
        );

        assert!(qos.user_transport_loss_at(1, 2, now + TRANSPORT_LOSS_ADAPTATION_COOLDOWN,));
        assert_eq!(qos.fps(MONITOR_SERVICE), 33);
        assert!(qos.displays.get(MONITOR_SERVICE).unwrap().ratio < first_loss_ratio);
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
        qos.users.get_mut(&1).unwrap().video_render_started = true;
        qos.users.get_mut(&2).unwrap().delay.fps = Some(2);
        qos.users.get_mut(&2).unwrap().delay.response_delayed = true;
        qos.users.get_mut(&2).unwrap().video_render_started = true;

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
        qos.users.get_mut(&1).unwrap().video_render_started = true;
        qos.users.get_mut(&2).unwrap().delay.fps = Some(2);
        qos.users.get_mut(&2).unwrap().delay.response_delayed = true;
        qos.users.get_mut(&2).unwrap().video_render_started = true;

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
