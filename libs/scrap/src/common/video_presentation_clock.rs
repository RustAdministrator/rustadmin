const DEFAULT_REFRESH_PERIOD_NS: i64 = 16_666_667;
const MIN_REFRESH_PERIOD_NS: i64 = 4_000_000;
const MAX_REFRESH_PERIOD_NS: i64 = 33_333_334;
const MAX_FUTURE_LEAD_NS: i64 = 50_000_000;
const LATE_TOLERANCE_PERIODS: i64 = 3;
const MOVIE_PLAYOUT_DELAY_NS: i64 = 50_000_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PresentationResetReason {
    None,
    Initial,
    SourceRegressed,
    Late,
    Future,
}

impl PresentationResetReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Initial => "initial",
            Self::SourceRegressed => "source-regressed",
            Self::Late => "late",
            Self::Future => "future",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PresentationSchedule {
    pub target_ns: i64,
    pub source_clock: bool,
    pub reset: bool,
    pub reset_reason: PresentationResetReason,
}

#[derive(Debug)]
pub struct VideoPresentationClock {
    refresh_period_ns: i64,
    anchor_capture_time_ms: Option<u64>,
    anchor_target_ns: i64,
    last_capture_time_ms: u64,
    last_target_ns: i64,
    movie_mode: bool,
}

impl VideoPresentationClock {
    pub fn new(refresh_period_ns: i64) -> Self {
        Self {
            refresh_period_ns: normalized_refresh_period(refresh_period_ns),
            anchor_capture_time_ms: None,
            anchor_target_ns: 0,
            last_capture_time_ms: 0,
            last_target_ns: 0,
            movie_mode: false,
        }
    }

    pub fn update_refresh_period(&mut self, refresh_period_ns: i64) {
        let refresh_period_ns = normalized_refresh_period(refresh_period_ns);
        if self.refresh_period_ns != refresh_period_ns {
            self.refresh_period_ns = refresh_period_ns;
            self.reset_anchor();
        }
    }

    pub fn refresh_period_ns(&self) -> i64 {
        self.refresh_period_ns
    }

    pub fn set_movie_mode(&mut self, enabled: bool) {
        if self.movie_mode != enabled {
            self.movie_mode = enabled;
            self.reset_anchor();
        }
    }

    pub fn playout_delay_ms(&self) -> u32 {
        if self.movie_mode {
            (MOVIE_PLAYOUT_DELAY_NS / 1_000_000) as u32
        } else {
            0
        }
    }

    pub fn schedule(&mut self, capture_time_ms: Option<u64>, now_ns: i64) -> PresentationSchedule {
        if now_ns < 0 {
            self.reset_anchor();
            return PresentationSchedule {
                target_ns: 0,
                source_clock: false,
                reset: false,
                reset_reason: PresentationResetReason::None,
            };
        }
        let Some(capture_time_ms) = capture_time_ms else {
            return self.immediate_schedule(now_ns);
        };
        if capture_time_ms == 0 {
            self.reset_anchor();
            return self.immediate_schedule(now_ns);
        }

        let source_regressed =
            self.anchor_capture_time_ms.is_some() && capture_time_ms < self.last_capture_time_ms;
        let mut reset_reason = if source_regressed {
            PresentationResetReason::SourceRegressed
        } else if self.anchor_capture_time_ms.is_none() {
            PresentationResetReason::Initial
        } else {
            PresentationResetReason::None
        };
        let mut reset = reset_reason != PresentationResetReason::None;
        let reset_lead_ns = if self.movie_mode {
            MOVIE_PLAYOUT_DELAY_NS.max(self.refresh_period_ns)
        } else {
            self.refresh_period_ns
        };
        let mut target_ns = if reset {
            now_ns.saturating_add(reset_lead_ns)
        } else {
            let anchor_capture_time_ms = self.anchor_capture_time_ms.unwrap_or(capture_time_ms);
            let elapsed_ms = capture_time_ms.saturating_sub(anchor_capture_time_ms);
            let elapsed_ns = elapsed_ms.saturating_mul(1_000_000).min(i64::MAX as u64) as i64;
            self.anchor_target_ns.saturating_add(elapsed_ns)
        };

        let late_limit_ns = now_ns.saturating_sub(
            self.refresh_period_ns
                .saturating_mul(LATE_TOLERANCE_PERIODS),
        );
        let future_limit_ns =
            now_ns.saturating_add(MAX_FUTURE_LEAD_NS.max(self.refresh_period_ns.saturating_mul(3)));
        if target_ns < late_limit_ns {
            reset = true;
            reset_reason = PresentationResetReason::Late;
            target_ns = now_ns.saturating_add(reset_lead_ns);
        } else if target_ns > future_limit_ns {
            reset = true;
            reset_reason = PresentationResetReason::Future;
            target_ns = now_ns.saturating_add(reset_lead_ns);
        } else {
            target_ns = target_ns.max(now_ns);
        }

        target_ns = self.next_monotonic_target(target_ns);
        if reset {
            self.anchor_capture_time_ms = Some(capture_time_ms);
            self.anchor_target_ns = target_ns;
        }
        self.last_capture_time_ms = capture_time_ms;
        self.last_target_ns = target_ns;

        PresentationSchedule {
            target_ns,
            source_clock: true,
            reset,
            reset_reason,
        }
    }

    fn immediate_schedule(&mut self, now_ns: i64) -> PresentationSchedule {
        let target_ns = self.next_monotonic_target(now_ns);
        self.last_target_ns = target_ns;
        PresentationSchedule {
            target_ns,
            source_clock: false,
            reset: false,
            reset_reason: PresentationResetReason::None,
        }
    }

    fn next_monotonic_target(&self, target_ns: i64) -> i64 {
        if self.last_target_ns == 0 {
            target_ns
        } else {
            target_ns.max(self.last_target_ns.saturating_add(1))
        }
    }

    fn reset_anchor(&mut self) {
        self.anchor_capture_time_ms = None;
        self.anchor_target_ns = 0;
        self.last_capture_time_ms = 0;
    }
}

fn normalized_refresh_period(refresh_period_ns: i64) -> i64 {
    if (MIN_REFRESH_PERIOD_NS..=MAX_REFRESH_PERIOD_NS).contains(&refresh_period_ns) {
        refresh_period_ns
    } else {
        DEFAULT_REFRESH_PERIOD_NS
    }
}

#[cfg(test)]
mod tests {
    use super::{PresentationResetReason, VideoPresentationClock, DEFAULT_REFRESH_PERIOD_NS};

    #[test]
    fn schedules_sender_cadence_one_refresh_ahead() {
        let mut clock = VideoPresentationClock::new(8_333_333);
        let first = clock.schedule(Some(1_000), 10_000_000_000);
        let second = clock.schedule(Some(1_033), 10_033_000_000);

        assert_eq!(first.target_ns, 10_008_333_333);
        assert!(first.source_clock);
        assert!(first.reset);
        assert_eq!(second.target_ns - first.target_ns, 33_000_000);
        assert!(!second.reset);
    }

    #[test]
    fn movie_mode_adds_a_bounded_playout_lead() {
        let mut clock = VideoPresentationClock::new(8_333_333);
        clock.set_movie_mode(true);
        let first = clock.schedule(Some(1_000), 10_000_000_000);
        let second = clock.schedule(Some(1_033), 10_033_000_000);

        assert_eq!(clock.playout_delay_ms(), 50);
        assert_eq!(first.target_ns, 10_050_000_000);
        assert_eq!(second.target_ns - first.target_ns, 33_000_000);
        assert!(!second.reset);
    }

    #[test]
    fn reanchors_after_a_late_or_regressed_source_timestamp() {
        let mut clock = VideoPresentationClock::new(16_666_667);
        let first = clock.schedule(Some(1_000), 20_000_000_000);
        let late = clock.schedule(Some(1_033), 20_100_000_000);
        let regressed = clock.schedule(Some(900), 20_120_000_000);

        assert!(late.reset);
        assert_eq!(late.target_ns, 20_116_666_667);
        assert!(regressed.reset);
        assert_eq!(regressed.target_ns, 20_136_666_667);
        assert!(late.target_ns > first.target_ns);
    }

    #[test]
    fn zero_source_timestamp_preserves_immediate_compatibility() {
        let mut clock = VideoPresentationClock::new(8_333_333);
        let schedule = clock.schedule(Some(0), 30_000_000_000);

        assert_eq!(schedule.target_ns, 30_000_000_000);
        assert!(!schedule.source_clock);
        assert!(!schedule.reset);
    }

    #[test]
    fn invalid_refresh_period_uses_sixty_hertz_fallback() {
        let clock = VideoPresentationClock::new(0);
        assert_eq!(clock.refresh_period_ns(), DEFAULT_REFRESH_PERIOD_NS);
    }

    #[test]
    fn surface_refresh_change_reanchors_the_clock() {
        let mut clock = VideoPresentationClock::new(16_666_667);
        let first = clock.schedule(Some(1_000), 40_000_000_000);
        clock.update_refresh_period(8_333_333);
        let refreshed = clock.schedule(Some(1_033), 40_033_000_000);

        assert!(first.reset);
        assert!(refreshed.reset);
        assert_eq!(refreshed.target_ns, 40_041_333_333);
    }

    #[test]
    fn reanchor_never_moves_presentation_time_backwards() {
        let mut clock = VideoPresentationClock::new(8_333_333);
        let first = clock.schedule(Some(1_000), 50_000_000_000);
        let future = clock.schedule(Some(1_040), 50_002_000_000);
        let reset = clock.schedule(Some(1_200), 50_003_000_000);

        assert!(first.reset);
        assert!(!future.reset);
        assert!(reset.reset);
        assert!(reset.target_ns > future.target_ns);
    }

    #[test]
    fn missing_metadata_preserves_the_existing_anchor() {
        let mut clock = VideoPresentationClock::new(8_333_333);
        let first = clock.schedule(Some(1_000), 60_000_000_000);
        let unknown = clock.schedule(None, 60_002_000_000);
        let resumed = clock.schedule(Some(1_033), 60_033_000_000);

        assert!(first.reset);
        assert!(!unknown.source_clock);
        assert!(!resumed.reset);
        assert!(unknown.target_ns > first.target_ns);
        assert!(resumed.target_ns > unknown.target_ns);
    }

    #[test]
    fn duplicate_source_timestamp_stays_strictly_monotonic() {
        let mut clock = VideoPresentationClock::new(16_666_667);
        let first = clock.schedule(Some(1_000), 70_000_000_000);
        let duplicate = clock.schedule(Some(1_000), 70_001_000_000);

        assert_eq!(duplicate.target_ns, first.target_ns + 1);
    }

    #[test]
    fn slightly_late_frame_is_immediate_without_reanchoring() {
        let mut clock = VideoPresentationClock::new(8_333_333);
        let first = clock.schedule(Some(1_000), 80_000_000_000);
        let late = clock.schedule(Some(1_033), 80_050_000_000);

        assert!(first.reset);
        assert!(!late.reset);
        assert_eq!(late.target_ns, 80_050_000_000);
    }

    #[test]
    fn movie_late_frame_restores_the_configured_playout_lead() {
        let mut clock = VideoPresentationClock::new(16_666_667);
        clock.set_movie_mode(true);
        let _first = clock.schedule(Some(1_000), 90_000_000_000);
        let late = clock.schedule(Some(1_033), 90_200_000_000);

        assert!(late.reset);
        assert_eq!(late.reset_reason, PresentationResetReason::Late);
        assert_eq!(late.target_ns, 90_250_000_000);
    }

    #[test]
    fn reports_future_and_source_regression_reset_reasons() {
        let mut clock = VideoPresentationClock::new(16_666_667);
        clock.set_movie_mode(true);
        let initial = clock.schedule(Some(1_000), 100_000_000_000);
        let future = clock.schedule(Some(1_200), 100_033_000_000);
        let regressed = clock.schedule(Some(900), 100_100_000_000);

        assert_eq!(initial.reset_reason, PresentationResetReason::Initial);
        assert_eq!(future.reset_reason, PresentationResetReason::Future);
        assert_eq!(
            regressed.reset_reason,
            PresentationResetReason::SourceRegressed
        );
    }
}
