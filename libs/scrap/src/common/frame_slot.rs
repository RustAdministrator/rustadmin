use std::time::{Duration, Instant};

/// Latest captured frame, filled by a platform callback whose buffer is only
/// valid during the call.
///
/// The frame is copied into owned storage on update; `take` hands it to the
/// consumer by swapping buffers, so each frame is still copied only once.
pub struct CaptureFrameSlot {
    name: &'static str,
    frame: Vec<u8>,
    ready: bool,
    last_update: Instant,
    timeout: Duration,
    enable: bool,
}

impl CaptureFrameSlot {
    pub fn new(name: &'static str, timeout: Duration) -> Self {
        Self {
            name,
            frame: Vec::new(),
            ready: false,
            last_update: Instant::now(),
            timeout,
            enable: false,
        }
    }

    pub fn set_enable(&mut self, value: bool) {
        self.enable = value;
        self.ready = false;
    }

    /// Copies `data` as the latest frame while capture is enabled.
    pub fn update(&mut self, data: &[u8]) {
        if !self.enable {
            return;
        }
        self.frame.clear();
        self.frame.extend_from_slice(data);
        self.ready = true;
        self.last_update = Instant::now();
    }

    /// Moves the latest frame into `dst`. Returns `None` when capture is
    /// disabled, no new frame arrived, the frame is older than the timeout, or
    /// it equals `last` (which is refreshed when the lengths match).
    pub fn take(&mut self, dst: &mut Vec<u8>, last: &mut Vec<u8>) -> Option<()> {
        if !self.enable || !self.ready {
            return None;
        }
        if self.last_update.elapsed() > self.timeout {
            hbb_common::log::trace!("Failed to take {} raw, timeout!", self.name);
            return None;
        }
        self.ready = false;
        if last.len() == self.frame.len() && crate::would_block_if_equal(last, &self.frame).is_err()
        {
            return None;
        }
        std::mem::swap(dst, &mut self.frame);
        Some(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn enabled_slot() -> CaptureFrameSlot {
        let mut slot = CaptureFrameSlot::new("test", Duration::from_secs(60));
        slot.set_enable(true);
        slot
    }

    #[test]
    fn update_copies_the_frame_and_take_moves_it_once() {
        let mut slot = enabled_slot();
        let mut source = vec![1u8, 2, 3, 4];
        slot.update(&source);
        // The callback buffer may be reused as soon as update returns.
        source.fill(9);
        let (mut dst, mut last) = (Vec::new(), Vec::new());
        assert_eq!(slot.take(&mut dst, &mut last), Some(()));
        assert_eq!(dst, [1, 2, 3, 4]);
        assert_eq!(slot.take(&mut dst, &mut last), None, "no new frame");
    }

    #[test]
    fn identical_frames_would_block_when_lengths_match() {
        let mut slot = enabled_slot();
        let (mut dst, mut last) = (Vec::new(), vec![5u8, 6]);
        slot.update(&[5, 6]);
        assert_eq!(slot.take(&mut dst, &mut last), None);
        slot.update(&[7, 8]);
        assert_eq!(slot.take(&mut dst, &mut last), Some(()));
        assert_eq!(dst, [7, 8]);
        assert_eq!(last, [7, 8], "a different frame refreshes the comparison copy");
    }

    #[test]
    fn disabled_or_stale_frames_are_not_taken() {
        let mut slot = CaptureFrameSlot::new("test", Duration::ZERO);
        let (mut dst, mut last) = (Vec::new(), Vec::new());
        slot.update(&[1]);
        assert_eq!(slot.take(&mut dst, &mut last), None, "disabled");
        slot.set_enable(true);
        slot.update(&[1]);
        std::thread::sleep(Duration::from_millis(2));
        assert_eq!(slot.take(&mut dst, &mut last), None, "timed out");

        let mut slot = enabled_slot();
        slot.update(&[1]);
        slot.set_enable(false);
        slot.set_enable(true);
        assert_eq!(slot.take(&mut dst, &mut last), None, "disable clears the frame");
    }
}
