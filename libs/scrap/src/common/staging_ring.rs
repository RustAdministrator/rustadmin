//! Bookkeeping for a small ring of GPU staging textures that a capture backend
//! copies frames into and reads back one frame later.
//!
//! The rules live here, free of any graphics API, so that they can be tested:
//! which slot to copy into next (never the one still waiting to be read), and
//! what is pending after a read attempt.

/// The outcome of trying to read the pending slot.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StagingRead {
    /// The pending frame was read.
    Done,
    /// The GPU has not finished with it yet (`DXGI_ERROR_WAS_STILL_DRAWING`).
    Busy,
}

/// What is pending after a read attempt.
///
/// `copied` is the slot filled during this very call (the newest frame), if
/// any; `pending` is the slot that was being read.
///
/// When the read is busy the newest copy replaces the pending slot: on a static
/// desktop no further frame will arrive, so keeping the older slot would leave
/// the viewer one frame behind until something changes.
pub fn pending_after_read(
    read: StagingRead,
    copied: Option<usize>,
    pending: usize,
) -> Option<usize> {
    match read {
        StagingRead::Done => copied,
        StagingRead::Busy => copied.or(Some(pending)),
    }
}

/// The slot to copy into next, and the cursor to continue from. A slot that
/// is pending is skipped; with a single slot there is nothing to skip to.
pub fn next_copy_index(next: usize, len: usize, pending: Option<usize>) -> (usize, usize) {
    if len == 0 {
        return (0, 0);
    }
    let mut cursor = next % len;
    for _ in 0..len {
        let index = cursor;
        cursor = (cursor + 1) % len;
        if Some(index) != pending {
            return (index, cursor);
        }
    }
    (0, cursor)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_busy_read_keeps_the_newest_copy_pending() {
        // Frame B was copied while A was busy: B is what to read next.
        assert_eq!(pending_after_read(StagingRead::Busy, Some(1), 0), Some(1));
        // Nothing newer arrived: keep waiting for A.
        assert_eq!(pending_after_read(StagingRead::Busy, None, 0), Some(0));
    }

    #[test]
    fn a_finished_read_leaves_only_the_new_copy_pending() {
        assert_eq!(pending_after_read(StagingRead::Done, Some(2), 1), Some(2));
        assert_eq!(pending_after_read(StagingRead::Done, None, 1), None);
    }

    #[test]
    fn the_copy_slot_is_never_the_pending_one() {
        for len in 2..6 {
            for pending in 0..len {
                let mut cursor = 0;
                for _ in 0..(len * 3) {
                    let (index, next) = next_copy_index(cursor, len, Some(pending));
                    assert_ne!(index, pending, "len={len} pending={pending}");
                    assert!(index < len);
                    cursor = next;
                }
            }
        }
    }

    #[test]
    fn a_busy_streak_with_three_slots_never_overwrites_the_waiting_frame() {
        // The waiting frame sits in slot 0; every new frame goes elsewhere and
        // replaces it as the pending one (keeping at most one frame behind).
        let (len, mut cursor, mut pending) = (3, 0, 0usize);
        for _ in 0..20 {
            let (index, next) = next_copy_index(cursor, len, Some(pending));
            cursor = next;
            assert_ne!(index, pending);
            pending = pending_after_read(StagingRead::Busy, Some(index), pending).unwrap();
            assert_eq!(pending, index);
        }
    }

    #[test]
    fn degenerate_sizes_do_not_panic() {
        assert_eq!(next_copy_index(5, 0, None), (0, 0));
        assert_eq!(next_copy_index(0, 1, Some(0)), (0, 0));
        assert_eq!(next_copy_index(0, 1, None), (0, 0));
    }
}
