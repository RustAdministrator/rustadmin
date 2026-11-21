//! The ladder a host goes down when an encoder fails, and what it tells the user about it.
//!
//! On a Windows host built with `vram` the rungs are: the encoder fed from a GPU texture,
//! the encoder of the same GPU fed through RAM, software VP8 or VP9. A texture encoder that
//! could not be created or stopped producing frames used to send the session straight to
//! software. It now steps down one rung: a copy of every frame, but the same codec and the
//! same hardware. This module remembers which rung failed and why, so that the next runs of
//! the video service start below it, and so that the quality monitor can say why a display
//! is not encoded the way the hardware would allow.

use std::{
    collections::HashMap,
    time::{Duration, Instant},
};

/// A rung that failed is tried again after this long, and its reason is shown for as long.
pub(crate) const RETRY_AFTER: Duration = Duration::from_secs(600);

/// The failures of one rung, by the name of the video service.
#[derive(Debug, Default)]
pub(crate) struct RungFailures {
    by_service: HashMap<String, (Instant, String)>,
}

impl RungFailures {
    pub(crate) fn record(&mut self, service: &str, reason: String, now: Instant) {
        self.by_service.insert(service.to_owned(), (now, reason));
    }

    /// Why the rung failed for this service, if it did lately.
    pub(crate) fn reason(&mut self, service: &str, now: Instant) -> Option<String> {
        let (failed_at, reason) = self.by_service.get(service)?;
        if now.saturating_duration_since(*failed_at) < RETRY_AFTER {
            return Some(reason.clone());
        }
        self.by_service.remove(service);
        None
    }
}

/// Why this run does not encode from a texture: the host's `enable-texture-encode` option
/// is `N`, or the texture encoder failed lately.
#[cfg(any(feature = "vram", test))]
pub(crate) fn texture_off_reason(option: &str, failure: Option<String>) -> Option<String> {
    if option == "N" {
        Some("switched off by enable-texture-encode".to_owned())
    } else {
        failure
    }
}

/// What the quality monitor shows as the encoder's input: with the reason when the display
/// could be encoded from a texture and is not (`texture_off`), and when it is encoded in
/// software because the hardware encoder failed (`hardware_off`).
pub(crate) fn encoder_input_label(
    texture: bool,
    texture_off: Option<&str>,
    hardware_off: Option<&str>,
) -> String {
    if texture {
        return "GPU texture".to_owned();
    }
    let mut label = "CPU YUV frame".to_owned();
    if let Some(reason) = hardware_off {
        label.push_str(&format!(" (hardware encoder off: {reason})"));
    } else if let Some(reason) = texture_off {
        label.push_str(&format!(" (GPU texture off: {reason})"));
    }
    label
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failure_keeps_a_rung_off_for_a_while_and_only_for_its_display() {
        let start = Instant::now();
        let mut failures = RungFailures::default();
        assert_eq!(failures.reason("monitor-0", start), None);
        failures.record("monitor-0", "3 encode errors in a row".to_owned(), start);
        assert_eq!(
            failures.reason("monitor-0", start + Duration::from_secs(1)),
            Some("3 encode errors in a row".to_owned())
        );
        assert_eq!(failures.reason("monitor-1", start), None);
        assert_eq!(
            failures.reason("monitor-0", start + RETRY_AFTER - Duration::from_secs(1)),
            Some("3 encode errors in a row".to_owned())
        );
        // Then it is tried again, and the old failure is forgotten.
        assert_eq!(failures.reason("monitor-0", start + RETRY_AFTER), None);
        assert_eq!(failures.reason("monitor-0", start), None);
        // A new failure starts a new period.
        let later = start + RETRY_AFTER * 2;
        failures.record(
            "monitor-0",
            "no packet in the warm-up time".to_owned(),
            later,
        );
        assert_eq!(
            failures.reason("monitor-0", later + Duration::from_secs(5)),
            Some("no packet in the warm-up time".to_owned())
        );
    }

    #[test]
    fn option_switches_texture_encoding_off_whatever_else_is_known() {
        assert_eq!(texture_off_reason("", None), None);
        assert_eq!(texture_off_reason("Y", None), None);
        assert_eq!(
            texture_off_reason("N", None),
            Some("switched off by enable-texture-encode".to_owned())
        );
        assert_eq!(
            texture_off_reason("N", Some("failed".to_owned())),
            Some("switched off by enable-texture-encode".to_owned())
        );
        assert_eq!(
            texture_off_reason("", Some("failed".to_owned())),
            Some("failed".to_owned())
        );
    }

    #[test]
    fn quality_monitor_says_why_the_encoder_is_fed_through_ram() {
        assert_eq!(encoder_input_label(true, None, None), "GPU texture");
        assert_eq!(encoder_input_label(false, None, None), "CPU YUV frame");
        assert_eq!(
            encoder_input_label(false, Some("3 encode errors in a row"), None),
            "CPU YUV frame (GPU texture off: 3 encode errors in a row)"
        );
        // The lowest rung: what sent the session to software is what matters.
        assert_eq!(
            encoder_input_label(
                false,
                Some("3 encode errors in a row"),
                Some("the encoder could not be created")
            ),
            "CPU YUV frame (hardware encoder off: the encoder could not be created)"
        );
    }
}
