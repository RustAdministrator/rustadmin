//! When the viewer gives up decoding into a GPU texture.
//!
//! With texture rendering on, H.264 and H.265 are decoded straight into a Direct3D texture
//! and the renderer plugin shows it. A decoder that fails is handled by `decoder_recovery`.
//! This is about the other half: the decoder works, a render target exists, and the
//! renderer does not take the texture. The picture is then black although every frame
//! "decodes". After a short while the display is decoded through RAM instead, which every
//! renderer can show.
//!
//! What cannot be seen from here: a texture the plugin accepts and then fails to show. Its
//! call returns nothing. The lever for that case stays the user's `allow-d3d-render`.

use std::time::{Duration, Instant};

/// Texture frames have to be refused for this long, and at least this many of them.
pub(crate) const REFUSED_FOR: Duration = Duration::from_secs(2);
pub(crate) const REFUSED_FRAMES: u32 = 30;

#[derive(Debug, Default)]
pub(crate) struct TextureRenderWatch {
    refused_since: Option<Instant>,
    refused_frames: u32,
}

impl TextureRenderWatch {
    /// A decoded texture frame was offered to the renderer: `submitted` render targets took
    /// it and `refused` of them exist but could not take a texture. Returns true when the
    /// display should be decoded through RAM from now on.
    pub(crate) fn offered(&mut self, submitted: u16, refused: u16, now: Instant) -> bool {
        // A frame that was shown somewhere, or that had no target to go to (a hidden
        // window, a view that is still being built), says nothing against the renderer.
        if submitted > 0 || refused == 0 {
            *self = Self::default();
            return false;
        }
        let since = *self.refused_since.get_or_insert(now);
        self.refused_frames = self.refused_frames.saturating_add(1);
        self.refused_frames >= REFUSED_FRAMES && now.saturating_duration_since(since) >= REFUSED_FOR
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(index: u32) -> Duration {
        Duration::from_millis(u64::from(index) * 17)
    }

    #[test]
    fn renderer_that_refuses_textures_for_two_seconds_loses_them() {
        let start = Instant::now();
        let mut watch = TextureRenderWatch::default();
        let mut gave_up_at = None;
        for index in 0..300 {
            if watch.offered(0, 1, start + frame(index)) {
                gave_up_at = Some(index);
                break;
            }
        }
        // 2 s at 60 frames a second.
        assert_eq!(gave_up_at, Some(118));
    }

    #[test]
    fn few_frames_in_a_long_time_are_not_enough() {
        let start = Instant::now();
        let mut watch = TextureRenderWatch::default();
        // A still picture: a frame a second.
        for second in 0..(REFUSED_FRAMES - 1) {
            assert!(!watch.offered(0, 1, start + Duration::from_secs(u64::from(second))));
        }
        assert!(watch.offered(0, 1, start + Duration::from_secs(60)));
    }

    #[test]
    fn frame_that_is_shown_or_has_no_target_clears_the_count() {
        let start = Instant::now();
        let mut watch = TextureRenderWatch::default();
        for index in 0..100 {
            assert!(!watch.offered(0, 1, start + frame(index)));
        }
        // One window took it.
        assert!(!watch.offered(1, 1, start + frame(100)));
        for index in 101..200 {
            assert!(!watch.offered(0, 1, start + frame(index)), "frame {index}");
        }
        // No target at all: the window is hidden.
        assert!(!watch.offered(0, 0, start + frame(200)));
        for index in 201..300 {
            assert!(!watch.offered(0, 1, start + frame(index)), "frame {index}");
        }
    }
}
