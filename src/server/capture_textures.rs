//! Texture mode of the user capture helper: the frames go to the service through D3D11
//! textures the service shares with the helper, one per slot of `capture_slots`, instead of
//! the slots' bytes, so that a texture encoder takes them without a copy through RAM.
//!
//! The service makes the textures on the adapter of the captured display and offers them
//! (`TextureControl::offer`); the helper opens them and reports the generation it opened, or
//! why it could not use them. A frame published with a texture generation is in the texture of
//! its slot; the slot protocol decides, as for bytes, which side may touch it. This module
//! holds the control block and the decisions of both sides; the D3D work is in
//! `scrap::dxgi::shared_texture` and `user_capture_helper`.

use super::capture_slots::SLOT_COUNT;
use std::{
    sync::atomic::{AtomicU32, AtomicU64, Ordering::SeqCst},
    time::{Duration, Instant},
};

/// How long the service waits, after it offered textures, for the first frame in one. Until
/// then frames that still come as bytes are skipped (the helper has not switched yet); after
/// it the service goes on with bytes.
pub(crate) const FIRST_TEXTURE_WAIT: Duration = Duration::from_secs(2);

/// Why the helper could not use the textures it was offered.
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TextureFailure {
    /// Its capture gives no texture (GDI, or capture through RAM only).
    NoTextureCapture = 1,
    /// Its capture runs on another adapter than the textures.
    OtherAdapter = 2,
    /// It could not open the textures.
    Open = 3,
    /// The captured frame differs from the textures in size or format.
    SizeOrFormat = 4,
    /// Copying a frame into a texture failed.
    Copy = 5,
}

impl TextureFailure {
    fn from_raw(value: u32) -> Option<Self> {
        [
            Self::NoTextureCapture,
            Self::OtherAdapter,
            Self::Open,
            Self::SizeOrFormat,
            Self::Copy,
        ]
        .into_iter()
        .find(|failure| *failure as u32 == value)
    }

    /// For the quality monitor and the log.
    pub(crate) fn describe(self) -> &'static str {
        match self {
            Self::NoTextureCapture => "the helper's capture gives no texture",
            Self::OtherAdapter => "the helper captures on another adapter",
            Self::Open => "the helper could not open the shared textures",
            Self::SizeOrFormat => "the captured frame differs from the shared textures",
            Self::Copy => "the helper could not copy a frame into a shared texture",
        }
    }
}

/// The textures the service offers: one per slot, all of this size, BGRA, on this adapter.
/// The handles are valid in the helper's process.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct TextureOffer {
    pub generation: u32,
    pub width: u32,
    pub height: u32,
    pub luid: i64,
    pub handles: [u64; SLOT_COUNT],
}

/// The control block of texture mode, in the shared memory beside the slots' one. Memory
/// filled with zeros: nothing offered, nothing opened.
#[repr(C)]
#[derive(Default)]
pub(crate) struct TextureControl {
    /// The generation of the offer below, written last by the service; zero: no offer.
    offered: AtomicU32,
    width: AtomicU32,
    height: AtomicU32,
    /// The generation the helper has opened; zero: none.
    opened: AtomicU32,
    luid: AtomicU64,
    handles: [AtomicU64; SLOT_COUNT],
    /// The generation the helper could not use, and why (`TextureFailure`).
    failed: AtomicU32,
    failure: AtomicU32,
}

impl TextureControl {
    /// The control block at `address`.
    ///
    /// # Safety
    /// As for `SlotControl::at`: aligned, mapped and writable for `'a`, and only ever used as
    /// this structure of atomics.
    pub(crate) unsafe fn at<'a>(address: *mut u8) -> &'a Self {
        debug_assert_eq!(address as usize % std::mem::align_of::<Self>(), 0);
        &*(address as *const Self)
    }

    /// The service: offers textures. The generation is cleared first and written last, so the
    /// helper never takes fields of two offers for one.
    pub(crate) fn offer(&self, offer: &TextureOffer) {
        debug_assert_ne!(offer.generation, 0);
        self.offered.store(0, SeqCst);
        self.width.store(offer.width, SeqCst);
        self.height.store(offer.height, SeqCst);
        self.luid.store(offer.luid as u64, SeqCst);
        for (slot, handle) in self.handles.iter().zip(offer.handles) {
            slot.store(handle, SeqCst);
        }
        self.offered.store(offer.generation, SeqCst);
    }

    /// The service: takes the offer back; the helper stops writing into the textures.
    pub(crate) fn withdraw(&self) {
        self.offered.store(0, SeqCst);
    }

    /// The helper: the offer standing now, if there is one.
    pub(crate) fn offer_now(&self) -> Option<TextureOffer> {
        let generation = self.offered.load(SeqCst);
        if generation == 0 {
            return None;
        }
        let offer = TextureOffer {
            generation,
            width: self.width.load(SeqCst),
            height: self.height.load(SeqCst),
            luid: self.luid.load(SeqCst) as i64,
            handles: std::array::from_fn(|slot| self.handles[slot].load(SeqCst)),
        };
        // Changed while the fields were read: a new offer is being written.
        (self.offered.load(SeqCst) == generation).then_some(offer)
    }

    /// The helper: it writes frames into the textures of `generation` from now on; zero: into
    /// none.
    pub(crate) fn report_opened(&self, generation: u32) {
        self.opened.store(generation, SeqCst);
    }

    /// The helper: it cannot use the textures of `generation`.
    pub(crate) fn report_failure(&self, generation: u32, failure: TextureFailure) {
        self.failure.store(failure as u32, SeqCst);
        self.failed.store(generation, SeqCst);
        let _ = self.opened.compare_exchange(generation, 0, SeqCst, SeqCst);
    }

    pub(crate) fn opened(&self) -> u32 {
        self.opened.load(SeqCst)
    }

    pub(crate) fn failed(&self) -> u32 {
        self.failed.load(SeqCst)
    }

    /// The service: why the helper could not use the textures of `generation`, if it said so.
    pub(crate) fn failure_of(&self, generation: u32) -> Option<TextureFailure> {
        if generation == 0 || self.failed.load(SeqCst) != generation {
            return None;
        }
        TextureFailure::from_raw(self.failure.load(SeqCst))
    }
}

/// What the helper does about the textures.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HelperStep {
    /// Nothing changes.
    Keep,
    /// Open the textures of this offer (and give up any older ones).
    Open(TextureOffer),
    /// Give up the textures it holds and write bytes again.
    Close,
}

/// The helper's step, given the offer standing now, the generation it holds open and the one
/// it last failed to use. A failed generation is not tried again: the service makes a new
/// generation if it wants another try.
pub(crate) fn helper_step(offer: Option<TextureOffer>, opened: u32, failed: u32) -> HelperStep {
    match offer {
        Some(offer) if offer.generation == opened => HelperStep::Keep,
        Some(offer) if offer.generation != failed => HelperStep::Open(offer),
        _ if opened != 0 => HelperStep::Close,
        _ => HelperStep::Keep,
    }
}

/// What the service does with a frame it took from the slots.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FrameUse {
    /// The frame is in the texture of its slot.
    Texture,
    /// The frame is the slot's bytes.
    Bytes,
    /// Neither can be used now; wait for the next frame.
    Skip,
}

/// The service's side of texture mode for one helper.
#[derive(Debug)]
pub(crate) struct ServiceTextures {
    /// The generation offered; zero: none.
    generation: u32,
    offered_at: Instant,
    /// Set when texture mode was given up, with the reason.
    off: Option<String>,
}

impl ServiceTextures {
    /// No textures offered: frames come as bytes.
    pub(crate) fn none(now: Instant) -> Self {
        Self {
            generation: 0,
            offered_at: now,
            off: None,
        }
    }

    /// Textures of `generation` were offered at `now`.
    pub(crate) fn offered(generation: u32, now: Instant) -> Self {
        Self {
            generation,
            offered_at: now,
            off: None,
        }
    }

    pub(crate) fn generation(&self) -> u32 {
        self.generation
    }

    /// Frames are expected in textures.
    pub(crate) fn texture_mode(&self) -> bool {
        self.generation != 0 && self.off.is_none()
    }

    /// Why texture mode was given up, if it was.
    pub(crate) fn off_reason(&self) -> Option<&str> {
        self.off.as_deref()
    }

    /// Gives texture mode up; the first reason stays.
    pub(crate) fn turn_off(&mut self, reason: &str) {
        if self.generation != 0 && self.off.is_none() {
            self.off = Some(reason.to_owned());
        }
    }

    /// A failure the helper reported turns texture mode off, with or without a frame.
    pub(crate) fn check_failure(&mut self, failure: Option<TextureFailure>) {
        if let Some(failure) = failure {
            self.turn_off(failure.describe());
        }
    }

    /// What to do with a frame taken from the slots: `frame_texture` is the texture generation
    /// it was published with (zero: bytes), `failure` what the helper reported for the
    /// generation offered.
    pub(crate) fn frame_use(
        &mut self,
        frame_texture: u32,
        failure: Option<TextureFailure>,
        now: Instant,
    ) -> FrameUse {
        self.check_failure(failure);
        if !self.texture_mode() {
            return if frame_texture == 0 {
                FrameUse::Bytes
            } else {
                FrameUse::Skip
            };
        }
        if frame_texture == self.generation {
            return FrameUse::Texture;
        }
        if frame_texture != 0 {
            // In the textures of an older offer: those may be gone.
            return FrameUse::Skip;
        }
        if now.saturating_duration_since(self.offered_at) < FIRST_TEXTURE_WAIT {
            return FrameUse::Skip;
        }
        self.turn_off("the helper kept sending frames as bytes");
        FrameUse::Bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn offer(generation: u32) -> TextureOffer {
        TextureOffer {
            generation,
            width: 1920,
            height: 1080,
            luid: -(1i64 << 40) + 65149,
            handles: [0x1a4, 0x1b8],
        }
    }

    #[test]
    fn an_offer_reaches_the_helper_whole_and_can_be_withdrawn() {
        let block = TextureControl::default();
        // The two processes see the block through its address in the shared memory.
        let control = unsafe { TextureControl::at(&block as *const TextureControl as *mut u8) };
        assert_eq!(control.offer_now(), None);
        control.offer(&offer(3));
        assert_eq!(control.offer_now(), Some(offer(3)));
        control.offer(&offer(4));
        assert_eq!(control.offer_now(), Some(offer(4)));
        control.withdraw();
        assert_eq!(control.offer_now(), None);
    }

    #[test]
    fn a_failure_is_reported_for_its_generation_only() {
        let control = TextureControl::default();
        control.report_opened(3);
        assert_eq!(control.opened(), 3);
        control.report_failure(3, TextureFailure::SizeOrFormat);
        assert_eq!(control.opened(), 0, "a failed generation is not open");
        assert_eq!(control.failed(), 3);
        assert_eq!(control.failure_of(3), Some(TextureFailure::SizeOrFormat));
        assert_eq!(control.failure_of(4), None);
        assert_eq!(control.failure_of(0), None);
        // A failure of an older generation leaves a newer open one alone.
        control.report_opened(5);
        control.report_failure(4, TextureFailure::Copy);
        assert_eq!(control.opened(), 5);
    }

    #[test]
    fn every_failure_has_a_code_and_a_description() {
        for failure in [
            TextureFailure::NoTextureCapture,
            TextureFailure::OtherAdapter,
            TextureFailure::Open,
            TextureFailure::SizeOrFormat,
            TextureFailure::Copy,
        ] {
            assert_eq!(TextureFailure::from_raw(failure as u32), Some(failure));
            assert!(!failure.describe().is_empty());
        }
        assert_eq!(TextureFailure::from_raw(0), None);
    }

    #[test]
    fn the_helper_opens_a_new_offer_once_and_closes_when_it_is_gone() {
        assert_eq!(helper_step(None, 0, 0), HelperStep::Keep);
        assert_eq!(
            helper_step(Some(offer(1)), 0, 0),
            HelperStep::Open(offer(1))
        );
        assert_eq!(helper_step(Some(offer(1)), 1, 0), HelperStep::Keep);
        // A newer offer replaces the one held.
        assert_eq!(
            helper_step(Some(offer(2)), 1, 0),
            HelperStep::Open(offer(2))
        );
        // Withdrawn: back to bytes.
        assert_eq!(helper_step(None, 2, 0), HelperStep::Close);
        // A generation that failed is not tried again.
        assert_eq!(helper_step(Some(offer(3)), 0, 3), HelperStep::Keep);
        assert_eq!(helper_step(Some(offer(3)), 2, 3), HelperStep::Close);
        assert_eq!(
            helper_step(Some(offer(4)), 0, 3),
            HelperStep::Open(offer(4))
        );
    }

    #[test]
    fn without_an_offer_frames_are_bytes() {
        let now = Instant::now();
        let mut service = ServiceTextures::none(now);
        assert!(!service.texture_mode());
        assert_eq!(service.frame_use(0, None, now), FrameUse::Bytes);
        assert_eq!(service.frame_use(1, None, now), FrameUse::Skip);
        assert_eq!(service.off_reason(), None);
    }

    #[test]
    fn frames_in_the_offered_textures_are_textures() {
        let now = Instant::now();
        let mut service = ServiceTextures::offered(7, now);
        assert!(service.texture_mode());
        assert_eq!(service.generation(), 7);
        assert_eq!(service.frame_use(7, None, now), FrameUse::Texture);
        // A frame in the textures of an older offer is not used.
        assert_eq!(service.frame_use(6, None, now), FrameUse::Skip);
        assert!(service.texture_mode());
    }

    #[test]
    fn bytes_are_skipped_while_the_helper_switches_then_texture_mode_ends() {
        let start = Instant::now();
        let mut service = ServiceTextures::offered(7, start);
        assert_eq!(service.frame_use(0, None, start), FrameUse::Skip);
        let just_before = start + FIRST_TEXTURE_WAIT - Duration::from_millis(1);
        assert_eq!(service.frame_use(0, None, just_before), FrameUse::Skip);
        assert!(service.texture_mode());
        let after = start + FIRST_TEXTURE_WAIT;
        assert_eq!(service.frame_use(0, None, after), FrameUse::Bytes);
        assert!(!service.texture_mode());
        assert_eq!(
            service.off_reason(),
            Some("the helper kept sending frames as bytes")
        );
        // Once off, a late texture frame is not used.
        assert_eq!(service.frame_use(7, None, after), FrameUse::Skip);
    }

    #[test]
    fn a_failure_the_helper_reports_ends_texture_mode_at_once() {
        let now = Instant::now();
        let mut service = ServiceTextures::offered(7, now);
        assert_eq!(
            service.frame_use(0, Some(TextureFailure::OtherAdapter), now),
            FrameUse::Bytes
        );
        assert_eq!(
            service.off_reason(),
            Some(TextureFailure::OtherAdapter.describe())
        );
        // The first reason stays.
        service.turn_off("later");
        assert_eq!(
            service.off_reason(),
            Some(TextureFailure::OtherAdapter.describe())
        );
        // Without any frame, too.
        let mut service = ServiceTextures::offered(8, now);
        service.check_failure(Some(TextureFailure::Open));
        assert!(!service.texture_mode());
    }
}
