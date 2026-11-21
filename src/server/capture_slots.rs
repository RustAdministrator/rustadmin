//! The hand-off of captured frames from a capture helper process to the service through
//! shared memory: no copy on the reading side, and never a frame put together from two
//! captures.
//!
//! There used to be one frame buffer. The helper wrote every capture into it and raised a
//! counter; the service saw the counter move and converted the picture straight out of the
//! shared memory. Nothing kept the helper from writing the next capture while the service
//! was still reading the previous one: on moving content the encoder then got a frame whose
//! upper part was one capture and whose lower part was the next.
//!
//! Now there are two buffers ("slots") and a small control block of atomics:
//!
//! * the writer publishes `{slot, sequence}` when a frame is complete;
//! * the reader pins the published slot before it reads it and keeps the pin until it asks
//!   for the next frame;
//! * the writer never writes into the pinned slot.
//!
//! With one slot pinned the writer has the other. If that one holds a published frame the
//! reader has not taken yet, the newer capture replaces it; while it is being written
//! nothing is published, and a reader that looks in that moment is told to look again in a
//! moment. Both sides re-check the other's word after writing their own (the reader the
//! published word after pinning, the writer the pin after withdrawing a publication), so one
//! of them always sees the other and yields.
//!
//! The memory for frames doubles. The helper and the service are the same executable, so
//! the layout needs no version.

use std::{
    fmt,
    sync::atomic::{AtomicU32, AtomicU64, Ordering::SeqCst},
};

pub(crate) const SLOT_COUNT: usize = 2;

/// `published`: the frame is being replaced; nothing can be taken now.
const WRITING: u64 = 0b10;
const SLOT_MASK: u64 = 0b01;
const SEQUENCE_SHIFT: u32 = 2;

/// The first write after the reader took a frame is counted when it starts within these
/// times of the take, in microseconds. With one buffer such a write went into the frame the
/// service was converting, if the conversion took that long.
const SOON_AFTER_TAKE_MICROS: [u64; 3] = [2_000, 5_000, 10_000];

#[repr(C)]
#[derive(Default)]
struct SlotInfo {
    length: AtomicU64,
    width: AtomicU32,
    height: AtomicU32,
    tag: AtomicU32,
    reserved: AtomicU32,
}

/// The control block. It lives in the shared memory at an address aligned to eight bytes;
/// memory filled with zeros is its initial state.
#[repr(C)]
#[derive(Default)]
pub(crate) struct SlotControl {
    /// Zero: nothing was published yet. Otherwise `sequence << 2 | WRITING? | slot`.
    published: AtomicU64,
    /// Wall clock of the reader's last take, in microseconds; for the counters only.
    taken_at_micros: AtomicU64,
    /// How many bytes one slot holds. Set by the side that creates the memory.
    slot_capacity: AtomicU64,
    /// Zero: the reader holds no slot. Otherwise the slot it holds, plus one.
    pinned: AtomicU32,
    /// Not zero: the old hand-off, for comparison and as a way back. The writer always
    /// writes slot 0 and the reader does not pin.
    single_slot: AtomicU32,
    written: AtomicU32,
    written_soon_after_take: [AtomicU32; SOON_AFTER_TAKE_MICROS.len()],
    replaced_unread: AtomicU32,
    skipped: AtomicU32,
    slots: [SlotInfo; SLOT_COUNT],
}

impl SlotControl {
    /// The control block at `address`.
    ///
    /// # Safety
    /// `address` must be aligned for `SlotControl`, point to at least
    /// `size_of::<SlotControl>()` bytes that stay mapped and writable for `'a`, and those
    /// bytes must only ever be accessed as this structure of atomics.
    pub(crate) unsafe fn at<'a>(address: *mut u8) -> &'a Self {
        debug_assert_eq!(address as usize % std::mem::align_of::<Self>(), 0);
        &*(address as *const Self)
    }

    /// Prepares a zeroed control block. For the side that creates the memory, before the
    /// writer starts.
    pub(crate) fn init(&self, slot_capacity: usize, single_slot: bool) {
        self.slot_capacity.store(slot_capacity as u64, SeqCst);
        self.single_slot.store(u32::from(single_slot), SeqCst);
    }

    pub(crate) fn slot_capacity(&self) -> usize {
        self.slot_capacity.load(SeqCst) as usize
    }

    pub(crate) fn single_slot(&self) -> bool {
        self.single_slot.load(SeqCst) != 0
    }

    pub(crate) fn counters(&self) -> SlotCounters {
        SlotCounters {
            written: self.written.load(SeqCst),
            written_soon_after_take: [
                self.written_soon_after_take[0].load(SeqCst),
                self.written_soon_after_take[1].load(SeqCst),
                self.written_soon_after_take[2].load(SeqCst),
            ],
            replaced_unread: self.replaced_unread.load(SeqCst),
            skipped: self.skipped.load(SeqCst),
        }
    }
}

/// What the writer has counted since the memory was created.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct SlotCounters {
    /// Frames written.
    pub written: u32,
    /// Of them, the ones whose writing began within 2, 5 and 10 ms after the reader took
    /// the frame before (each class includes the shorter ones).
    pub written_soon_after_take: [u32; SOON_AFTER_TAKE_MICROS.len()],
    /// Published frames that a newer one replaced before the reader took them.
    pub replaced_unread: u32,
    /// Captures dropped because the reader took the slot the writer was about to use.
    pub skipped: u32,
}

impl SlotCounters {
    /// What was counted since `earlier`.
    pub(crate) fn since(&self, earlier: &SlotCounters) -> SlotCounters {
        SlotCounters {
            written: self.written.wrapping_sub(earlier.written),
            written_soon_after_take: [
                self.written_soon_after_take[0].wrapping_sub(earlier.written_soon_after_take[0]),
                self.written_soon_after_take[1].wrapping_sub(earlier.written_soon_after_take[1]),
                self.written_soon_after_take[2].wrapping_sub(earlier.written_soon_after_take[2]),
            ],
            replaced_unread: self.replaced_unread.wrapping_sub(earlier.replaced_unread),
            skipped: self.skipped.wrapping_sub(earlier.skipped),
        }
    }
}

impl fmt::Display for SlotCounters {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "written={}, written_within_2ms_of_take={}, within_5ms={}, within_10ms={}, replaced_unread={}, skipped={}",
            self.written,
            self.written_soon_after_take[0],
            self.written_soon_after_take[1],
            self.written_soon_after_take[2],
            self.replaced_unread,
            self.skipped,
        )
    }
}

/// The wall clock in microseconds; the two processes compare their times through it.
pub(crate) fn wall_clock_micros() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_micros().min(u64::MAX as u128) as u64)
}

/// A frame the reader has taken. Its bytes are `length` bytes of slot `slot`, and they do
/// not change until the reader releases it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct TakenFrame {
    pub slot: usize,
    pub sequence: u64,
    pub length: usize,
    pub width: usize,
    pub height: usize,
    pub tag: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Take {
    Frame(TakenFrame),
    /// Nothing newer than the frame taken last.
    Nothing,
    /// A newer frame is being written right now: look again in a moment.
    BeingWritten,
}

/// The reading side: the service.
#[derive(Debug, Default)]
pub(crate) struct SlotReader {
    last_sequence: u64,
}

impl SlotReader {
    /// Gives up the frame taken before: from now on its slot may be written again.
    pub(crate) fn release(&mut self, control: &SlotControl) {
        control.pinned.store(0, SeqCst);
    }

    /// Takes the published frame if it is newer than the one taken last. Call `release`
    /// first: one frame is held at a time.
    pub(crate) fn take(&mut self, control: &SlotControl, now_micros: u64) -> Take {
        let single_slot = control.single_slot();
        // Losing the race with the writer twice in a row means it is writing all the time.
        for _ in 0..2 {
            let published = control.published.load(SeqCst);
            if published == 0 {
                return Take::Nothing;
            }
            if published & WRITING != 0 {
                return Take::BeingWritten;
            }
            let sequence = published >> SEQUENCE_SHIFT;
            if sequence == self.last_sequence {
                return Take::Nothing;
            }
            let slot = (published & SLOT_MASK) as usize;
            if !single_slot {
                Self::pin(control, published);
                if !Self::pin_holds(control, published) {
                    continue;
                }
            }
            self.last_sequence = sequence;
            control.taken_at_micros.store(now_micros.max(1), SeqCst);
            let info = &control.slots[slot];
            return Take::Frame(TakenFrame {
                slot,
                sequence,
                length: info.length.load(SeqCst) as usize,
                width: info.width.load(SeqCst) as usize,
                height: info.height.load(SeqCst) as usize,
                tag: info.tag.load(SeqCst),
            });
        }
        Take::BeingWritten
    }
}

impl SlotReader {
    /// First step of taking: pin the slot of the publication that was just read.
    fn pin(control: &SlotControl, published: u64) {
        control
            .pinned
            .store((published & SLOT_MASK) as u32 + 1, SeqCst);
    }

    /// Second step: the writer may have withdrawn or replaced the publication between the
    /// reader's look at it and the pin. Then the pin came too late and is taken back.
    fn pin_holds(control: &SlotControl, published: u64) -> bool {
        if control.published.load(SeqCst) == published {
            return true;
        }
        control.pinned.store(0, SeqCst);
        false
    }
}

/// The right to write one frame into a slot.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct WriteTicket {
    slot: usize,
    /// The publication that was withdrawn to write into its slot.
    withdrawn: Option<u64>,
}

impl WriteTicket {
    pub(crate) fn slot(&self) -> usize {
        self.slot
    }
}

/// The writing side: the capture helper.
#[derive(Debug, Default)]
pub(crate) struct SlotWriter {
    sequence: u64,
    counted_take: u64,
}

impl SlotWriter {
    /// Chooses the slot for the next frame. `None`: the reader took the only candidate in
    /// this very moment; the capture is dropped and the next one will find a slot.
    pub(crate) fn begin(&mut self, control: &SlotControl, now_micros: u64) -> Option<WriteTicket> {
        self.count_write_after_take(control, now_micros);
        if control.single_slot() {
            return Some(WriteTicket {
                slot: 0,
                withdrawn: None,
            });
        }
        let chosen = Self::choose(control);
        Self::confirm(control, chosen)
    }

    /// First step: the slot the reader does not hold. If that one carries a publication
    /// the reader has not taken, the publication is withdrawn: the newer capture replaces
    /// it, and until it is complete nothing is published.
    fn choose(control: &SlotControl) -> WriteTicket {
        let published = control.published.load(SeqCst);
        let front = (published != 0).then_some((published & SLOT_MASK) as usize);
        let slot = match control.pinned.load(SeqCst) {
            0 => front.map_or(0, |front| 1 - front),
            pinned => 1 - (pinned as usize - 1),
        };
        let mut withdrawn = None;
        if front == Some(slot) {
            control.published.store(published | WRITING, SeqCst);
            withdrawn = Some(published);
        }
        WriteTicket { slot, withdrawn }
    }

    /// Second step: the reader may have pinned the chosen slot after the writer looked at
    /// the pin. Then the slot is the reader's. A publication that was withdrawn for it is
    /// put back (its frame is untouched) and this capture is dropped.
    fn confirm(control: &SlotControl, chosen: WriteTicket) -> Option<WriteTicket> {
        if control.pinned.load(SeqCst) as usize == chosen.slot + 1 {
            if let Some(published) = chosen.withdrawn {
                control.published.store(published, SeqCst);
            }
            control.skipped.fetch_add(1, SeqCst);
            return None;
        }
        if chosen.withdrawn.is_some() {
            control.replaced_unread.fetch_add(1, SeqCst);
        }
        Some(chosen)
    }

    /// The frame is complete in the ticket's slot: describe and publish it.
    pub(crate) fn publish(
        &mut self,
        control: &SlotControl,
        ticket: WriteTicket,
        length: usize,
        width: usize,
        height: usize,
        tag: u32,
    ) {
        let info = &control.slots[ticket.slot];
        info.length.store(length as u64, SeqCst);
        info.width.store(width as u32, SeqCst);
        info.height.store(height as u32, SeqCst);
        info.tag.store(tag, SeqCst);
        self.sequence += 1;
        control.written.fetch_add(1, SeqCst);
        control.published.store(
            (self.sequence << SEQUENCE_SHIFT) | ticket.slot as u64,
            SeqCst,
        );
    }

    fn count_write_after_take(&mut self, control: &SlotControl, now_micros: u64) {
        let taken_at = control.taken_at_micros.load(SeqCst);
        if taken_at == 0 || taken_at == self.counted_take {
            return;
        }
        self.counted_take = taken_at;
        let since_take = now_micros.saturating_sub(taken_at);
        for (class, limit) in SOON_AFTER_TAKE_MICROS.iter().enumerate() {
            if since_take < *limit {
                control.written_soon_after_take[class].fetch_add(1, SeqCst);
            }
        }
    }
}

/// How the capture thread waits while the service does not take the frame it published:
/// briefly at first, then with a growing pause, and after a while without the capturer.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct UnreadWait;

impl UnreadWait {
    /// After this long without a reader the capturer is released: a desktop duplication
    /// that nobody reads still costs the GPU and the compositor.
    pub(crate) const RELEASE_CAPTURER_AFTER: std::time::Duration =
        std::time::Duration::from_secs(2);

    /// The pause before the next look, when the frame has been unread for `waited`.
    pub(crate) fn pause(waited: std::time::Duration) -> std::time::Duration {
        let millis = match waited.as_millis() {
            0..=199 => 1,
            200..=1_999 => 10,
            _ => 100,
        };
        std::time::Duration::from_millis(millis)
    }

    pub(crate) fn release_capturer(waited: std::time::Duration) -> bool {
        waited >= Self::RELEASE_CAPTURER_AFTER
    }
}

/// The pause before the capture thread tries again on its own after it reported a capture
/// failure: 1 s, 2 s, 4 s ... up to 30 s. A request to recreate the capturer ends the pause
/// at once.
pub(crate) fn failed_capture_retry_pause(failures: u32) -> std::time::Duration {
    let seconds = 1u64 << failures.saturating_sub(1).min(5);
    std::time::Duration::from_secs(seconds.min(30))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        sync::{
            atomic::{AtomicBool, AtomicUsize},
            Arc,
        },
        time::Duration,
    };

    const FRAME: usize = 64 * 1024;

    /// Two slots of frame memory, as the shared memory has them.
    struct Memory {
        bytes: std::cell::UnsafeCell<Vec<u8>>,
    }

    // The tests share it between the writer and the reader the way two processes share
    // the mapping; the protocol under test is what keeps them apart.
    unsafe impl Sync for Memory {}

    impl Memory {
        fn new() -> Self {
            Self {
                bytes: std::cell::UnsafeCell::new(vec![0; FRAME * SLOT_COUNT]),
            }
        }

        fn slot(&self, slot: usize) -> *mut u8 {
            unsafe { (*self.bytes.get()).as_mut_ptr().add(slot * FRAME) }
        }

        fn fill(&self, slot: usize, range: std::ops::Range<usize>, value: u8) {
            unsafe { std::ptr::write_bytes(self.slot(slot).add(range.start), value, range.len()) }
        }

        /// The distinct byte values in the slot: one for a whole frame.
        fn values(&self, slot: usize) -> Vec<u8> {
            let bytes = unsafe { std::slice::from_raw_parts(self.slot(slot), FRAME) };
            let mut values: Vec<u8> = bytes.to_vec();
            values.dedup();
            values
        }
    }

    fn write_frame(
        writer: &mut SlotWriter,
        control: &SlotControl,
        memory: &Memory,
        value: u8,
    ) -> Option<usize> {
        let ticket = writer.begin(control, 0)?;
        let slot = ticket.slot();
        memory.fill(slot, 0..FRAME, value);
        writer.publish(control, ticket, FRAME, 16, 16, u32::from(value));
        Some(slot)
    }

    fn taken(take: Take) -> TakenFrame {
        match take {
            Take::Frame(frame) => frame,
            other => panic!("expected a frame, got {:?}", other),
        }
    }

    #[test]
    fn control_block_is_plain_atomics_with_an_eight_byte_alignment() {
        assert_eq!(std::mem::align_of::<SlotControl>(), 8);
        assert_eq!(std::mem::size_of::<SlotControl>() % 8, 0);
        // Zeroed memory is the initial state.
        let mut zeroed = [0u64; 32];
        assert!(std::mem::size_of::<SlotControl>() <= std::mem::size_of_val(&zeroed));
        let control = unsafe { SlotControl::at(zeroed.as_mut_ptr() as *mut u8) };
        assert_eq!(SlotReader::default().take(control, 1), Take::Nothing);
        assert_eq!(control.counters(), SlotCounters::default());
        assert!(!control.single_slot());
    }

    /// The defect of the single buffer, step by step: the service has taken a frame and is
    /// converting it when the helper writes the next capture.
    #[test]
    fn with_one_buffer_the_next_capture_lands_in_the_frame_being_read() {
        let control = SlotControl::default();
        control.init(FRAME, true);
        let memory = Memory::new();
        let mut writer = SlotWriter::default();
        let mut reader = SlotReader::default();

        assert_eq!(write_frame(&mut writer, &control, &memory, 1), Some(0));
        reader.release(&control);
        let frame = taken(reader.take(&control, 1));
        assert_eq!(memory.values(frame.slot), vec![1]);
        // The helper starts on the next capture and gets halfway.
        let ticket = writer.begin(&control, 2).unwrap();
        assert_eq!(ticket.slot(), frame.slot);
        memory.fill(ticket.slot(), 0..FRAME / 2, 2);
        // The service is still reading its frame: two captures in one picture.
        assert_eq!(memory.values(frame.slot), vec![2, 1]);
    }

    /// The same steps with two slots.
    #[test]
    fn with_two_slots_the_frame_being_read_is_left_alone() {
        let control = SlotControl::default();
        control.init(FRAME, false);
        let memory = Memory::new();
        let mut writer = SlotWriter::default();
        let mut reader = SlotReader::default();

        assert_eq!(write_frame(&mut writer, &control, &memory, 1), Some(0));
        reader.release(&control);
        let frame = taken(reader.take(&control, 1));
        let ticket = writer.begin(&control, 2).unwrap();
        assert_ne!(ticket.slot(), frame.slot);
        memory.fill(ticket.slot(), 0..FRAME / 2, 2);
        assert_eq!(memory.values(frame.slot), vec![1]);
        memory.fill(ticket.slot(), FRAME / 2..FRAME, 2);
        writer.publish(&control, ticket, FRAME, 16, 16, 2);
        // Still untouched after the publication, until the service asks for the next one.
        assert_eq!(memory.values(frame.slot), vec![1]);
        reader.release(&control);
        let next = taken(reader.take(&control, 3));
        assert_eq!((next.sequence, next.tag), (2, 2));
        assert_eq!(memory.values(next.slot), vec![2]);
    }

    #[test]
    fn frame_is_described_by_what_was_published_with_it() {
        let control = SlotControl::default();
        control.init(FRAME, false);
        let mut writer = SlotWriter::default();
        let mut reader = SlotReader::default();
        assert_eq!(control.slot_capacity(), FRAME);
        let ticket = writer.begin(&control, 0).unwrap();
        writer.publish(&control, ticket, 1_234, 1920, 1080, 3);
        assert_eq!(
            reader.take(&control, 5),
            Take::Frame(TakenFrame {
                slot: 0,
                sequence: 1,
                length: 1_234,
                width: 1920,
                height: 1080,
                tag: 3,
            })
        );
        // The same frame is not handed out twice.
        reader.release(&control);
        assert_eq!(reader.take(&control, 6), Take::Nothing);
    }

    #[test]
    fn slow_reader_gets_the_newest_capture_not_the_first_one_after_its_last() {
        let control = SlotControl::default();
        control.init(FRAME, false);
        let memory = Memory::new();
        let mut writer = SlotWriter::default();
        let mut reader = SlotReader::default();

        write_frame(&mut writer, &control, &memory, 1);
        reader.release(&control);
        let held = taken(reader.take(&control, 1));
        // Three captures while the service is busy with the first.
        for value in 2..=4 {
            let slot = write_frame(&mut writer, &control, &memory, value);
            assert_eq!(slot, Some(1 - held.slot), "never the slot that is held");
            assert_eq!(memory.values(held.slot), vec![1]);
        }
        reader.release(&control);
        let next = taken(reader.take(&control, 2));
        assert_eq!(next.tag, 4);
        assert_eq!(memory.values(next.slot), vec![4]);
        // Captures 2 and 3 were published and replaced unread.
        assert_eq!(control.counters().replaced_unread, 2);
        assert_eq!(control.counters().written, 4);
    }

    #[test]
    fn nothing_can_be_taken_while_the_unread_frame_is_replaced() {
        let control = SlotControl::default();
        control.init(FRAME, false);
        let memory = Memory::new();
        let mut writer = SlotWriter::default();
        let mut reader = SlotReader::default();

        write_frame(&mut writer, &control, &memory, 1);
        reader.release(&control);
        let held = taken(reader.take(&control, 1));
        write_frame(&mut writer, &control, &memory, 2);
        // The third capture has to go where the second is; the helper is halfway.
        let ticket = writer.begin(&control, 0).unwrap();
        assert_eq!(ticket.slot(), 1 - held.slot);
        memory.fill(ticket.slot(), 0..FRAME / 2, 3);
        // The service is done with the first frame and looks for the next.
        reader.release(&control);
        assert_eq!(reader.take(&control, 2), Take::BeingWritten);
        assert_eq!(
            control.pinned.load(SeqCst),
            0,
            "nothing is pinned meanwhile"
        );
        memory.fill(ticket.slot(), FRAME / 2..FRAME, 3);
        writer.publish(&control, ticket, FRAME, 16, 16, 3);
        let next = taken(reader.take(&control, 3));
        assert_eq!(next.tag, 3);
        assert_eq!(memory.values(next.slot), vec![3]);
    }

    /// One frame held by the reader, a second one published and unread: the state in which
    /// the writer has to take the unread slot. Returns the slot that is held.
    fn held_and_unread(
        control: &SlotControl,
        memory: &Memory,
        writer: &mut SlotWriter,
        reader: &mut SlotReader,
    ) -> usize {
        control.init(FRAME, false);
        write_frame(writer, control, memory, 1);
        reader.release(control);
        let held = taken(reader.take(control, 1)).slot;
        assert_eq!(write_frame(writer, control, memory, 2), Some(1 - held));
        held
    }

    /// The reader looks at the publication, the writer withdraws it, the reader pins, the
    /// writer looks at the pin: the writer gives way and the reader's frame is whole.
    #[test]
    fn writer_gives_way_when_the_reader_pinned_before_its_second_look() {
        let control = SlotControl::default();
        let memory = Memory::new();
        let (mut writer, mut reader) = (SlotWriter::default(), SlotReader::default());
        let held = held_and_unread(&control, &memory, &mut writer, &mut reader);
        let unread = 1 - held;

        // Reader: lets go of its frame and reads the published word.
        reader.release(&control);
        let seen = control.published.load(SeqCst);
        // Writer: saw the old pin a moment before the release.
        control.pinned.store(held as u32 + 1, SeqCst);
        let chosen = SlotWriter::choose(&control);
        assert_eq!(chosen.slot(), unread);
        assert_eq!(control.published.load(SeqCst), seen | WRITING);
        // Reader: pins what it saw.
        SlotReader::pin(&control, seen);
        // Writer: second look.
        assert_eq!(SlotWriter::confirm(&control, chosen), None);
        assert_eq!(control.counters().skipped, 1);
        // Reader: second look. The publication is back, and its frame was not touched.
        assert!(SlotReader::pin_holds(&control, seen));
        assert_eq!(memory.values(unread), vec![2]);
    }

    /// The same start, but the writer's second look comes before the reader's pin: the
    /// writer writes, and the reader finds its pin too late and takes it back.
    #[test]
    fn reader_gives_way_when_the_writer_looked_twice_before_its_pin() {
        let control = SlotControl::default();
        let memory = Memory::new();
        let (mut writer, mut reader) = (SlotWriter::default(), SlotReader::default());
        let held = held_and_unread(&control, &memory, &mut writer, &mut reader);
        let unread = 1 - held;

        reader.release(&control);
        let seen = control.published.load(SeqCst);
        control.pinned.store(held as u32 + 1, SeqCst);
        let chosen = SlotWriter::choose(&control);
        // The old pin goes (the release, as the writer sees it now).
        control.pinned.store(0, SeqCst);
        let ticket = SlotWriter::confirm(&control, chosen).unwrap();
        assert_eq!(ticket.slot(), unread);
        memory.fill(unread, 0..FRAME / 2, 3);
        // Reader: pins what it saw before, then looks again.
        SlotReader::pin(&control, seen);
        assert!(!SlotReader::pin_holds(&control, seen));
        assert_eq!(control.pinned.load(SeqCst), 0);
        // Through the real call it is told to come back.
        assert_eq!(reader.take(&control, 2), Take::BeingWritten);
        memory.fill(unread, FRAME / 2..FRAME, 3);
        writer.publish(&control, ticket, FRAME, 16, 16, 3);
        // Even a reader that pinned on the old word and looks only now sees a new word.
        SlotReader::pin(&control, seen);
        assert!(!SlotReader::pin_holds(&control, seen));
        let next = taken(reader.take(&control, 3));
        assert_eq!((next.slot, next.tag), (unread, 3));
        assert_eq!(memory.values(unread), vec![3]);
    }

    /// A reader that read the published word long ago and pins only now, when that slot
    /// has become the one the writer fills next.
    #[test]
    fn stale_pin_on_the_slot_being_written_never_holds() {
        let control = SlotControl::default();
        control.init(FRAME, false);
        let memory = Memory::new();
        let (mut writer, mut reader) = (SlotWriter::default(), SlotReader::default());
        write_frame(&mut writer, &control, &memory, 1);
        let seen = control.published.load(SeqCst);
        let old_front = (seen & SLOT_MASK) as usize;
        // Nobody holds anything: the next frame goes to the other slot, the one after it
        // back to the first.
        assert_eq!(
            write_frame(&mut writer, &control, &memory, 2),
            Some(1 - old_front)
        );
        let ticket = writer.begin(&control, 0).unwrap();
        assert_eq!(ticket.slot(), old_front);
        memory.fill(old_front, 0..FRAME / 2, 3);
        SlotReader::pin(&control, seen);
        assert!(!SlotReader::pin_holds(&control, seen));
        // The real call takes frame 2 from the other slot instead.
        let frame = taken(reader.take(&control, 1));
        assert_eq!((frame.slot, frame.tag), (1 - old_front, 2));
        assert_eq!(memory.values(frame.slot), vec![2]);
    }

    #[test]
    fn writer_always_gets_the_slot_that_is_not_held() {
        let control = SlotControl::default();
        control.init(FRAME, false);
        let memory = Memory::new();
        let (mut writer, mut reader) = (SlotWriter::default(), SlotReader::default());
        write_frame(&mut writer, &control, &memory, 1);
        reader.release(&control);
        let held = taken(reader.take(&control, 1));
        for value in 2..10 {
            assert_eq!(
                write_frame(&mut writer, &control, &memory, value),
                Some(1 - held.slot)
            );
        }
        assert_eq!(memory.values(held.slot), vec![1]);
        assert_eq!(control.counters().skipped, 0);
    }

    #[test]
    fn pin_that_came_too_late_is_withdrawn() {
        let control = SlotControl::default();
        control.init(FRAME, false);
        let memory = Memory::new();
        let mut writer = SlotWriter::default();
        let mut reader = SlotReader::default();
        write_frame(&mut writer, &control, &memory, 1);
        // The publication is withdrawn (a replacement is being written): the reader must
        // not end up holding a pin.
        let published = control.published.load(SeqCst);
        control.published.store(published | WRITING, SeqCst);
        assert_eq!(reader.take(&control, 1), Take::BeingWritten);
        assert_eq!(control.pinned.load(SeqCst), 0);
    }

    #[test]
    fn writes_soon_after_a_take_are_counted_once_per_take() {
        let control = SlotControl::default();
        control.init(FRAME, false);
        let memory = Memory::new();
        let mut writer = SlotWriter::default();
        let mut reader = SlotReader::default();
        // (take at, ms; next write begins at, ms)
        let table = [(100u64, 101u64), (200, 203), (300, 308), (400, 430)];
        write_frame(&mut writer, &control, &memory, 1);
        for (index, (take_ms, write_ms)) in table.iter().enumerate() {
            reader.release(&control);
            taken(reader.take(&control, take_ms * 1_000));
            let ticket = writer.begin(&control, write_ms * 1_000).unwrap();
            writer.publish(&control, ticket, FRAME, 16, 16, index as u32);
            // A second write after the same take is not counted again.
            let ticket = writer.begin(&control, write_ms * 1_000 + 500).unwrap();
            writer.publish(&control, ticket, FRAME, 16, 16, index as u32);
        }
        let counters = control.counters();
        // 1 ms: all three classes; 3 ms: two; 8 ms: one; 30 ms: none.
        assert_eq!(counters.written_soon_after_take, [1, 2, 3]);
        assert_eq!(counters.written, 9);
        let later = SlotCounters {
            written: 20,
            ..counters
        };
        assert_eq!(later.since(&counters).written, 11);
        assert_eq!(later.since(&counters).written_soon_after_take, [0, 0, 0]);
        assert_eq!(
            counters.to_string(),
            "written=9, written_within_2ms_of_take=1, within_5ms=2, within_10ms=3, replaced_unread=4, skipped=0"
        );
    }

    /// A writer that hardly pauses and a reader that takes its time, as two threads.
    fn run_two_threads(frames: usize) -> (usize, usize) {
        let control = Arc::new(SlotControl::default());
        control.init(FRAME, false);
        let memory = Arc::new(Memory::new());
        let stop = Arc::new(AtomicBool::new(false));
        let torn = Arc::new(AtomicUsize::new(0));
        let read = Arc::new(AtomicUsize::new(0));

        let writer_thread = {
            let (control, memory, stop) = (control.clone(), memory.clone(), stop.clone());
            std::thread::spawn(move || {
                let mut writer = SlotWriter::default();
                let mut value = 0u8;
                while !stop.load(SeqCst) {
                    value = value % 250 + 1;
                    let Some(ticket) = writer.begin(&control, wall_clock_micros()) else {
                        continue;
                    };
                    // In pieces, so that the reader gets its turn in the middle of a frame.
                    for piece in 0..8 {
                        let start = piece * FRAME / 8;
                        memory.fill(ticket.slot(), start..start + FRAME / 8, value);
                        std::thread::yield_now();
                    }
                    writer.publish(&control, ticket, FRAME, 16, 16, u32::from(value));
                    // A capture takes time; without any pause the publication would be
                    // withdrawn again at once and the reader would never find one.
                    std::thread::sleep(Duration::from_micros(50));
                }
            })
        };
        let mut reader = SlotReader::default();
        let mut last_sequence = 0;
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while read.load(SeqCst) < frames && std::time::Instant::now() < deadline {
            reader.release(&control);
            let Take::Frame(frame) = reader.take(&control, wall_clock_micros()) else {
                std::thread::yield_now();
                continue;
            };
            assert!(frame.sequence > last_sequence);
            last_sequence = frame.sequence;
            // Read it twice with a pause between: the conversion takes time.
            let first = memory.values(frame.slot);
            std::thread::yield_now();
            let second = memory.values(frame.slot);
            if first != vec![frame.tag as u8] || second != first {
                torn.fetch_add(1, SeqCst);
            }
            read.fetch_add(1, SeqCst);
        }
        stop.store(true, SeqCst);
        writer_thread.join().unwrap();
        (read.load(SeqCst), torn.load(SeqCst))
    }

    #[test]
    fn two_threads_never_see_a_torn_frame_with_two_slots() {
        // Up to 3000 frames, or what five seconds give where the writer's short sleep is a
        // long one.
        let (read, torn) = run_two_threads(3_000);
        assert!(read >= 100, "the reader starved: {read} frames");
        assert_eq!(torn, 0, "of {read} frames");
    }

    #[test]
    fn unread_frame_wait_grows_and_then_lets_the_capturer_go() {
        let ms = Duration::from_millis;
        assert_eq!(UnreadWait::pause(ms(0)), ms(1));
        assert_eq!(UnreadWait::pause(ms(199)), ms(1));
        assert_eq!(UnreadWait::pause(ms(200)), ms(10));
        assert_eq!(UnreadWait::pause(ms(1_999)), ms(10));
        assert_eq!(UnreadWait::pause(ms(2_000)), ms(100));
        assert_eq!(UnreadWait::pause(Duration::from_secs(3_600)), ms(100));
        assert!(!UnreadWait::release_capturer(ms(1_999)));
        assert!(UnreadWait::release_capturer(ms(2_000)));
    }

    #[test]
    fn failed_capture_is_retried_with_a_growing_pause() {
        let seconds: Vec<u64> = (0..9)
            .map(|failures| failed_capture_retry_pause(failures).as_secs())
            .collect();
        assert_eq!(seconds, vec![1, 1, 2, 4, 8, 16, 30, 30, 30]);
    }
}
