//! PCM helpers shared by audio capture and playback paths.

use std::collections::VecDeque;

/// Bounded FIFO of interleaved f32 samples.
///
/// When the capacity is exceeded the oldest whole frames are dropped, so a
/// stalled consumer cannot grow latency without bound and channels stay
/// aligned.
pub struct PcmQueue {
    samples: VecDeque<f32>,
    channels: usize,
    capacity: usize,
    dropped_samples: u64,
}

impl PcmQueue {
    /// `capacity` is rounded down to whole frames and holds at least one frame.
    pub fn new(channels: u16, capacity: usize) -> Self {
        let channels = usize::from(channels.max(1));
        let capacity = (capacity / channels).max(1) * channels;
        Self {
            samples: VecDeque::with_capacity(capacity),
            channels,
            capacity,
            dropped_samples: 0,
        }
    }

    pub fn len(&self) -> usize {
        self.samples.len()
    }

    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }

    pub fn clear(&mut self) {
        self.samples.clear();
    }

    /// Total number of samples dropped because the queue was full.
    pub fn dropped_samples(&self) -> u64 {
        self.dropped_samples
    }

    /// Appends whole frames; a trailing partial frame is ignored.
    pub fn push(&mut self, input: &[f32]) {
        let input = &input[..input.len() / self.channels * self.channels];
        let input = if input.len() > self.capacity {
            self.dropped_samples += (self.samples.len() + input.len() - self.capacity) as u64;
            self.samples.clear();
            &input[input.len() - self.capacity..]
        } else {
            let overflow = (self.samples.len() + input.len()).saturating_sub(self.capacity);
            if overflow > 0 {
                self.samples.drain(..overflow);
                self.dropped_samples += overflow as u64;
            }
            input
        };
        self.samples.extend(input.iter().copied());
    }

    /// Appends native-endian f32 samples from raw bytes; a trailing partial
    /// frame is ignored. Returns the number of ignored bytes.
    pub fn push_ne_bytes(&mut self, bytes: &[u8]) -> usize {
        const SAMPLE_BYTES: usize = std::mem::size_of::<f32>();
        let frame_bytes = SAMPLE_BYTES * self.channels;
        let whole = bytes.len() / frame_bytes * frame_bytes;
        let samples: Vec<f32> = bytes[..whole]
            .chunks_exact(SAMPLE_BYTES)
            .map(|sample| f32::from_ne_bytes([sample[0], sample[1], sample[2], sample[3]]))
            .collect();
        self.push(&samples);
        bytes.len() - whole
    }

    /// Fills `output` completely if enough samples are queued.
    pub fn pop_exact(&mut self, output: &mut [f32]) -> bool {
        let requested = output.len();
        if requested == 0 || self.samples.len() < requested {
            return false;
        }
        for (dst, src) in output.iter_mut().zip(self.samples.drain(..requested)) {
            *dst = src;
        }
        true
    }
}

/// Streaming linear resampler for interleaved f32 PCM.
///
/// The phase and the last input frame are kept across calls, so splitting a
/// stream into packets does not introduce discontinuities or drift. Equal
/// rates pass samples through without delay.
pub struct StreamingResampler {
    channels: usize,
    step: f64,
    position: f64,
    previous: Vec<f32>,
    passthrough: bool,
}

impl StreamingResampler {
    pub fn new(in_rate: u32, out_rate: u32, channels: u16) -> Self {
        let passthrough = in_rate == out_rate || in_rate == 0 || out_rate == 0;
        Self {
            channels: usize::from(channels.max(1)),
            step: if passthrough {
                1.0
            } else {
                f64::from(in_rate) / f64::from(out_rate)
            },
            position: 0.0,
            previous: Vec::new(),
            passthrough,
        }
    }

    pub fn is_passthrough(&self) -> bool {
        self.passthrough
    }

    /// Resamples whole frames of `input` and appends them to `output`. A
    /// trailing partial frame is ignored.
    pub fn process(&mut self, input: &[f32], output: &mut Vec<f32>) {
        let channels = self.channels;
        let input = &input[..input.len() / channels * channels];
        if self.passthrough {
            output.extend_from_slice(input);
            return;
        }
        let offset = usize::from(!self.previous.is_empty());
        let frames = input.len() / channels + offset;
        if frames == 0 {
            return;
        }
        let previous = &self.previous;
        let frame = |index: usize| -> &[f32] {
            if index < offset {
                previous
            } else {
                let start = (index - offset) * channels;
                &input[start..start + channels]
            }
        };
        loop {
            let index = self.position as usize;
            if index + 1 >= frames {
                break;
            }
            let fraction = (self.position - index as f64) as f32;
            let (a, b) = (frame(index), frame(index + 1));
            output.extend(
                a.iter()
                    .zip(b.iter())
                    .map(|(a, b)| a + (b - a) * fraction),
            );
            self.position += self.step;
        }
        self.position -= (frames - 1) as f64;
        let last = frame(frames - 1).to_vec();
        self.previous = last;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_keeps_whole_frames_and_drops_oldest_when_full() {
        let mut queue = PcmQueue::new(2, 7);
        queue.push(&[1.0, -1.0, 2.0, -2.0, 3.0]);
        assert_eq!(queue.len(), 4, "partial trailing frame is ignored");
        queue.push(&[4.0, -4.0, 5.0, -5.0]);
        assert_eq!(queue.len(), 6, "capacity is rounded to whole frames");
        assert_eq!(queue.dropped_samples(), 2);
        let mut out = [0.0; 6];
        assert!(queue.pop_exact(&mut out));
        assert_eq!(out, [2.0, -2.0, 4.0, -4.0, 5.0, -5.0]);
        assert!(queue.is_empty());
    }

    #[test]
    fn queue_accepts_oversized_input_by_keeping_the_newest_frames() {
        let mut queue = PcmQueue::new(1, 4);
        queue.push(&[0.0, 1.0]);
        queue.push(&[2.0, 3.0, 4.0, 5.0, 6.0, 7.0]);
        assert_eq!(queue.dropped_samples(), 4);
        let mut out = [0.0; 4];
        assert!(queue.pop_exact(&mut out));
        assert_eq!(out, [4.0, 5.0, 6.0, 7.0]);
    }

    #[test]
    fn queue_pops_only_complete_requests() {
        let mut queue = PcmQueue::new(2, 100);
        queue.push(&[0.5; 6]);
        let mut out = [0.0; 8];
        assert!(!queue.pop_exact(&mut out));
        assert_eq!(queue.len(), 6);
        queue.push(&[0.25; 2]);
        assert!(queue.pop_exact(&mut out));
        assert!(!queue.pop_exact(&mut []));
    }

    #[test]
    fn queue_decodes_native_endian_bytes_in_whole_frames() {
        let mut queue = PcmQueue::new(2, 100);
        let mut bytes: Vec<u8> = [0.5f32, -0.5, 0.25]
            .iter()
            .flat_map(|sample| sample.to_ne_bytes())
            .collect();
        bytes.push(7);
        assert_eq!(queue.push_ne_bytes(&bytes), 5);
        let mut out = [0.0; 2];
        assert!(queue.pop_exact(&mut out));
        assert_eq!(out, [0.5, -0.5]);
    }

    #[test]
    fn resampler_passes_equal_rates_through() {
        let mut resampler = StreamingResampler::new(48000, 48000, 2);
        assert!(resampler.is_passthrough());
        let mut out = Vec::new();
        resampler.process(&[1.0, 2.0, 3.0, 4.0, 5.0], &mut out);
        assert_eq!(out, [1.0, 2.0, 3.0, 4.0]);
    }

    fn ramp(frames: usize, channels: usize) -> Vec<f32> {
        (0..frames)
            .flat_map(|frame| (0..channels).map(move |c| frame as f32 * if c == 0 { 1.0 } else { -1.0 }))
            .collect()
    }

    #[test]
    fn resampler_is_continuous_across_packet_boundaries() {
        // Linear interpolation reproduces a ramp exactly, so any packet-edge
        // restart or phase error shows up as a deviation.
        let (in_rate, out_rate) = (44100, 48000);
        let input = ramp(4410, 2);
        let mut resampler = StreamingResampler::new(in_rate, out_rate, 2);
        let mut out = Vec::new();
        for chunk in input.chunks(441 * 2) {
            resampler.process(chunk, &mut out);
        }
        let step = f64::from(in_rate) / f64::from(out_rate);
        assert!(out.len() / 2 >= 4799, "frames={}", out.len() / 2);
        for (k, frame) in out.chunks_exact(2).enumerate() {
            let expected = (k as f64 * step) as f32;
            assert!((frame[0] - expected).abs() < 1e-2, "k={} {:?} {}", k, frame, expected);
            assert!((frame[1] + expected).abs() < 1e-2, "k={} {:?} {}", k, frame, expected);
        }
    }

    #[test]
    fn resampler_output_does_not_depend_on_packet_sizes() {
        let input: Vec<f32> = (0..9600)
            .map(|n| ((n as f32) * 0.013).sin())
            .collect();
        let mut whole = Vec::new();
        StreamingResampler::new(48000, 16000, 1).process(&input, &mut whole);
        let mut split = Vec::new();
        let mut resampler = StreamingResampler::new(48000, 16000, 1);
        let mut rest = &input[..];
        for size in [1usize, 7, 480, 3, 960].iter().cycle() {
            if rest.is_empty() {
                break;
            }
            let size = (*size).min(rest.len());
            resampler.process(&rest[..size], &mut split);
            rest = &rest[size..];
        }
        assert_eq!(whole.len(), split.len());
        for (a, b) in whole.iter().zip(split.iter()) {
            assert!((a - b).abs() < 1e-4);
        }
    }

    #[test]
    fn resampler_rate_does_not_drift_over_many_packets() {
        let mut resampler = StreamingResampler::new(44100, 48000, 2);
        let packet = vec![0.0f32; 441 * 2];
        let mut out = Vec::new();
        for _ in 0..1000 {
            resampler.process(&packet, &mut out);
        }
        let frames = out.len() / 2;
        assert!((479_990..=480_000).contains(&frames), "frames={}", frames);
    }
}
