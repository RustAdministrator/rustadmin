#[cfg(not(any(target_os = "android", target_os = "ios")))]
use crate::clipboard::{update_clipboard_with_direction, ClipboardSide};
#[cfg(not(any(target_os = "ios")))]
use crate::{audio_service, clipboard::CLIPBOARD_INTERVAL, ConnInner, CLIENT_SERVER};
use crate::{
    client::{
        self, new_voice_call_request, Client, Data, Interface, MediaData, MediaSender,
        QualityStatus, MILLI1,
    },
    common::get_default_sound_input,
    ui_session_interface::{InvokeUiSession, Session},
};
#[cfg(feature = "unix-file-copy-paste")]
use crate::{clipboard::try_empty_clipboard_files, clipboard_file::unix_file_clip};
#[cfg(any(
    target_os = "windows",
    all(target_os = "macos", feature = "unix-file-copy-paste")
))]
use clipboard::ContextSend;
use crossbeam_queue::ArrayQueue;
#[cfg(not(target_os = "ios"))]
use hbb_common::tokio::sync::mpsc::error::TryRecvError;
use hbb_common::{
    allow_err,
    bytes::Bytes,
    config::{self, LocalConfig, PeerConfig, TransferSerde},
    fs::{
        self, can_enable_overwrite_detection, get_job, get_string, new_send_confirm,
        DigestCheckResult, RemoveJobMeta,
    },
    get_time, log,
    message_proto::{permission_info::Permission, supported_decoding::PreferCodec, *},
    protobuf::Message as _,
    rendezvous_proto::ConnType,
    timeout,
    tokio::{
        self,
        sync::mpsc,
        time::{self, Duration, Instant},
    },
    Stream,
};
#[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
use hbb_common::{tokio::sync::Mutex as TokioMutex, ResultType};
use scrap::CodecFormat;
use std::{
    collections::HashMap,
    ffi::c_void,
    num::NonZeroI64,
    path::PathBuf,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, RwLock,
    },
};

const NO_VIDEO_START_TIMEOUT: Duration = Duration::from_secs(15);
const NO_VIDEO_START_FALLBACK_INTERVAL: Duration = Duration::from_secs(5);
const NO_VIDEO_START_MAX_FALLBACKS: usize = 3;
const NO_VIDEO_START_RECONNECT_GRACE: Duration = Duration::from_millis(500);
const NO_VIDEO_START_STALLED_LOG_INTERVAL: Duration = Duration::from_secs(30);
const FPS_CONTROL_SUMMARY_LOG_INTERVAL: Duration = Duration::from_secs(30);
const VIDEO_RECEIVER_FREEZE_TIMEOUT: Duration = Duration::from_secs(3);
const VIDEO_KEYFRAME_REQUEST_INTERVAL: Duration = Duration::from_secs(2);
const CONNECTION_RECEIVE_TIMEOUT: Duration = Duration::from_secs(15);
const VIDEO_KEYFRAME_REASON_FRAME_GAP: u32 = 1;
const VIDEO_KEYFRAME_REASON_QUEUE_DROP: u32 = 2;
const VIDEO_FRAME_CHUNK_REASSEMBLY_TIMEOUT: Duration = Duration::from_secs(5);
const VIDEO_FRAME_CHUNK_MAX_ORIGINAL_SIZE: usize = 16 * 1024 * 1024;
const VIDEO_FRAME_CHUNK_MAX_CHUNKS: usize = 2048;

fn video_received_msg(vf: &VideoFrame) -> Message {
    let mut misc = Misc::new();
    misc.set_video_received(true);
    misc.video_ack_frame_id = vf.frame_id;
    misc.video_ack_display = vf.display;
    let mut msg = Message::new();
    msg.set_misc(misc);
    msg
}

fn video_keyframe_request_msg(display: i32, last_frame_id: u64, reason: u32) -> Message {
    let mut misc = Misc::new();
    misc.set_video_keyframe_request(VideoKeyframeRequest {
        display,
        last_frame_id,
        reason,
        ..Default::default()
    });
    let mut msg = Message::new();
    msg.set_misc(misc);
    msg
}

fn auto_adjust_fps_msg(fps: usize) -> Message {
    let mut misc = Misc::new();
    misc.union = Some(misc::Union::AutoAdjustFps(usize_to_u32(fps.max(1))));
    let mut msg = Message::new();
    msg.set_misc(misc);
    msg
}

fn video_receiver_stats_msg(stats: VideoReceiverStats) -> Message {
    let mut misc = Misc::new();
    misc.set_video_receiver_stats(stats);
    let mut msg = Message::new();
    msg.set_misc(misc);
    msg
}

fn next_adaptive_auto_fps(
    custom_fps: usize,
    last_auto_fps: Option<usize>,
    limited_fps: usize,
    max_queue_len: usize,
    should_decrease: bool,
    should_increase: bool,
) -> usize {
    if should_decrease && limited_fps < max_queue_len {
        return (limited_fps / 2).max(1);
    }
    if should_increase {
        let custom_fps = custom_fps.max(1);
        let previous = last_auto_fps.unwrap_or(limited_fps).max(1);
        let probe_step = (custom_fps / 5).clamp(5, 15);
        return previous.saturating_add(probe_step).min(custom_fps).max(1);
    }
    limited_fps.max(1)
}

fn usize_to_u32(value: usize) -> u32 {
    value.min(u32::MAX as usize) as u32
}

#[derive(Debug, Default)]
struct VideoReceiverStatsTracker {
    first_frame_id: u64,
    last_frame_id: u64,
    frames_received: u64,
    frames_dropped: u64,
    bytes_received: u64,
    skipped_frame_ids: u64,
    encoded_frames_received: u64,
    keyframes_received: u64,
    video_chunks_received: u64,
    video_chunk_bytes_received: u64,
    video_chunk_frames_reassembled: u64,
    video_chunk_frames_expired: u64,
    last_observed_frame_id: u64,
    freeze_count: u64,
    last_rendered_frames: u64,
    last_render_progress: Option<Instant>,
    last_freeze_report: Option<Instant>,
    last_keyframe_request: Option<Instant>,
}

impl VideoReceiverStatsTracker {
    fn record_frame_received(
        &mut self,
        vf: &VideoFrame,
        bytes_received: usize,
        encoded_frame_count: usize,
        has_keyframe: bool,
        now: Instant,
    ) -> Option<u32> {
        self.frames_received = self.frames_received.saturating_add(1);
        self.bytes_received = self
            .bytes_received
            .saturating_add(bytes_received.min(u64::MAX as usize) as u64);
        self.encoded_frames_received = self
            .encoded_frames_received
            .saturating_add(encoded_frame_count.min(u64::MAX as usize) as u64);
        if has_keyframe {
            self.keyframes_received = self.keyframes_received.saturating_add(1);
        }

        if self.first_frame_id == 0 && vf.frame_id != 0 {
            self.first_frame_id = vf.frame_id;
        }

        let gap_reason = if vf.frame_id != 0
            && self.last_frame_id != 0
            && vf.frame_id > self.last_frame_id.saturating_add(1)
        {
            let skipped = vf
                .frame_id
                .saturating_sub(self.last_frame_id)
                .saturating_sub(1);
            self.skipped_frame_ids = self.skipped_frame_ids.saturating_add(skipped);
            Some(VIDEO_KEYFRAME_REASON_FRAME_GAP)
        } else {
            None
        };

        if vf.frame_id != 0 {
            self.last_frame_id = vf.frame_id;
        }
        if self.last_render_progress.is_none() {
            self.last_render_progress = Some(now);
        }

        gap_reason
    }

    fn record_video_chunk(&mut self, frame_id: u64, bytes_received: usize) {
        self.video_chunks_received = self.video_chunks_received.saturating_add(1);
        self.video_chunk_bytes_received = self
            .video_chunk_bytes_received
            .saturating_add(bytes_received.min(u64::MAX as usize) as u64);
        if frame_id > self.last_observed_frame_id {
            self.last_observed_frame_id = frame_id;
        }
    }

    fn record_video_chunk_reassembled(&mut self) {
        self.video_chunk_frames_reassembled = self.video_chunk_frames_reassembled.saturating_add(1);
    }

    fn record_video_chunk_expired(&mut self, summary: VideoFrameChunkExpirySummary) {
        self.video_chunk_frames_expired = self
            .video_chunk_frames_expired
            .saturating_add(summary.frames.min(u64::MAX as usize) as u64);
        if summary.last_frame_id > self.last_observed_frame_id {
            self.last_observed_frame_id = summary.last_frame_id;
        }
    }

    fn has_transport_progress(&self) -> bool {
        self.frames_received > 0
            || self.video_chunks_received > 0
            || self.video_chunk_frames_expired > 0
            || self.last_observed_frame_id != 0
    }

    fn record_queue_drop(&mut self) {
        self.frames_dropped = self.frames_dropped.saturating_add(1);
    }

    fn should_send_keyframe_request(&mut self, now: Instant) -> bool {
        if self
            .last_keyframe_request
            .map(|last| now.saturating_duration_since(last) < VIDEO_KEYFRAME_REQUEST_INTERVAL)
            .unwrap_or(false)
        {
            return false;
        }
        self.last_keyframe_request = Some(now);
        true
    }

    fn update_render_progress(&mut self, frames_rendered: u64, now: Instant) {
        if frames_rendered > self.last_rendered_frames {
            self.last_rendered_frames = frames_rendered;
            self.last_render_progress = Some(now);
            return;
        }

        if self.frames_received == 0 {
            return;
        }

        let stalled = self
            .last_render_progress
            .map(|last| now.saturating_duration_since(last) >= VIDEO_RECEIVER_FREEZE_TIMEOUT)
            .unwrap_or(false);
        let can_report = self
            .last_freeze_report
            .map(|last| now.saturating_duration_since(last) >= VIDEO_RECEIVER_FREEZE_TIMEOUT)
            .unwrap_or(true);
        if stalled && can_report {
            self.freeze_count = self.freeze_count.saturating_add(1);
            self.last_freeze_report = Some(now);
        }
    }

    fn to_proto(
        &mut self,
        display: usize,
        interval_ms: u32,
        decode_queue_len: usize,
        render_queue_len: usize,
        decode_snapshot: client::VideoThreadStatsSnapshot,
        now: Instant,
    ) -> VideoReceiverStats {
        self.update_render_progress(decode_snapshot.frames_rendered, now);
        VideoReceiverStats {
            display: display.min(i32::MAX as usize) as i32,
            first_frame_id: self.first_frame_id,
            last_frame_id: self.last_frame_id,
            frames_received: self.frames_received,
            frames_decoded: decode_snapshot.frames_decoded,
            frames_rendered: decode_snapshot.frames_rendered,
            frames_dropped: self.frames_dropped,
            bytes_received: self.bytes_received,
            skipped_frame_ids: self.skipped_frame_ids,
            decode_queue_len: usize_to_u32(decode_queue_len),
            render_queue_len: usize_to_u32(render_queue_len),
            decode_ms_avg: decode_snapshot.decode_ms_avg,
            decode_ms_p95: decode_snapshot.decode_ms_p95,
            freeze_count: self.freeze_count,
            last_render_age_ms: decode_snapshot.last_render_age_ms,
            interval_ms,
            encoded_frames_received: self.encoded_frames_received,
            keyframes_received: self.keyframes_received,
            decode_errors: decode_snapshot.decode_errors,
            video_chunks_received: self.video_chunks_received,
            video_chunk_bytes_received: self.video_chunk_bytes_received,
            video_chunk_frames_reassembled: self.video_chunk_frames_reassembled,
            video_chunk_frames_expired: self.video_chunk_frames_expired,
            last_observed_frame_id: self.last_observed_frame_id,
            ..Default::default()
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
enum NoVideoStartupAction {
    None,
    Reconnect {
        attempt: usize,
        elapsed_ms: u128,
    },
    Stalled {
        elapsed_ms: u128,
    },
    GiveUp {
        elapsed_ms: u128,
        fallback_count: usize,
    },
}

#[derive(Default)]
struct NoVideoStartupWatchdog {
    since: Option<Instant>,
    last_fallback: Option<Instant>,
    fallback_count: usize,
    last_stalled_log: Option<Instant>,
}

impl NoVideoStartupWatchdog {
    fn reset(&mut self) {
        self.since = None;
        self.last_fallback = None;
        self.fallback_count = 0;
        self.last_stalled_log = None;
    }

    fn tick(
        &mut self,
        expects_video: bool,
        is_connected: bool,
        first_frame: bool,
        video_transport_seen: bool,
        now: Instant,
    ) -> NoVideoStartupAction {
        if !expects_video || !is_connected || first_frame {
            self.reset();
            return NoVideoStartupAction::None;
        }

        let Some(since) = self.since else {
            self.since = Some(now);
            return NoVideoStartupAction::None;
        };

        let elapsed = now.saturating_duration_since(since);
        if elapsed < NO_VIDEO_START_TIMEOUT {
            return NoVideoStartupAction::None;
        }

        if video_transport_seen {
            let should_log_stalled = self
                .last_stalled_log
                .map(|last| {
                    now.saturating_duration_since(last) >= NO_VIDEO_START_STALLED_LOG_INTERVAL
                })
                .unwrap_or(true);
            if should_log_stalled {
                self.last_stalled_log = Some(now);
                return NoVideoStartupAction::Stalled {
                    elapsed_ms: elapsed.as_millis(),
                };
            }
            return NoVideoStartupAction::None;
        }

        let can_fallback = self.fallback_count < NO_VIDEO_START_MAX_FALLBACKS
            && self
                .last_fallback
                .map(|last| now.saturating_duration_since(last) >= NO_VIDEO_START_FALLBACK_INTERVAL)
                .unwrap_or(true);
        if can_fallback {
            self.fallback_count += 1;
            self.last_fallback = Some(now);
            return NoVideoStartupAction::Reconnect {
                attempt: self.fallback_count,
                elapsed_ms: elapsed.as_millis(),
            };
        }

        if self.fallback_count >= NO_VIDEO_START_MAX_FALLBACKS {
            return NoVideoStartupAction::GiveUp {
                elapsed_ms: elapsed.as_millis(),
                fallback_count: self.fallback_count,
            };
        }

        let should_log_stalled = self
            .last_stalled_log
            .map(|last| now.saturating_duration_since(last) >= NO_VIDEO_START_STALLED_LOG_INTERVAL)
            .unwrap_or(true);
        if should_log_stalled {
            self.last_stalled_log = Some(now);
            return NoVideoStartupAction::Stalled {
                elapsed_ms: elapsed.as_millis(),
            };
        }

        NoVideoStartupAction::None
    }
}

fn codec_marked_unsupported(mark_unsupported: &[CodecFormat], format: CodecFormat) -> bool {
    match format {
        CodecFormat::AV1 | CodecFormat::AV1Vulkan => mark_unsupported
            .iter()
            .any(|codec| matches!(codec, CodecFormat::AV1 | CodecFormat::AV1Vulkan)),
        CodecFormat::Unknown => true,
        _ => mark_unsupported.contains(&format),
    }
}

fn decoding_supports_codec(decoding: &SupportedDecoding, format: CodecFormat) -> bool {
    match format {
        CodecFormat::VP8 => decoding.ability_vp8 > 0,
        CodecFormat::VP9 => decoding.ability_vp9 > 0,
        CodecFormat::AV1 | CodecFormat::AV1Vulkan => decoding.ability_av1 > 0,
        CodecFormat::H264 => decoding.ability_h264 > 0,
        CodecFormat::H265 => decoding.ability_h265 > 0,
        CodecFormat::Unknown => false,
    }
}

fn encoding_supports_codec(encoding: &SupportedEncoding, format: CodecFormat) -> bool {
    match format {
        CodecFormat::VP8 => encoding.vp8,
        // VP9 is always available when the server-side software encoder is built.
        CodecFormat::VP9 => true,
        CodecFormat::AV1 => encoding.av1,
        CodecFormat::AV1Vulkan => encoding.av1_vulkan,
        CodecFormat::H264 => encoding.h264,
        CodecFormat::H265 => encoding.h265,
        CodecFormat::Unknown => false,
    }
}

fn preferred_codec_format(prefer: PreferCodec) -> Option<CodecFormat> {
    match prefer {
        PreferCodec::VP8 => Some(CodecFormat::VP8),
        PreferCodec::VP9 => Some(CodecFormat::VP9),
        PreferCodec::AV1 => Some(CodecFormat::AV1),
        PreferCodec::AV1Vulkan => Some(CodecFormat::AV1Vulkan),
        PreferCodec::H264 => Some(CodecFormat::H264),
        PreferCodec::H265 => Some(CodecFormat::H265),
        PreferCodec::Auto => None,
    }
}

fn next_no_video_startup_fallback_codec(
    decoding: &SupportedDecoding,
    encoding: &SupportedEncoding,
    mark_unsupported: &[CodecFormat],
    observed_format: CodecFormat,
) -> Option<CodecFormat> {
    let preferred = preferred_codec_format(decoding.prefer.enum_value_or(PreferCodec::Auto))
        .unwrap_or(CodecFormat::Unknown);
    let candidates = [
        observed_format,
        preferred,
        CodecFormat::H265,
        CodecFormat::H264,
        CodecFormat::AV1,
        CodecFormat::VP9,
        CodecFormat::VP8,
    ];

    for candidate in candidates {
        if codec_marked_unsupported(mark_unsupported, candidate) {
            continue;
        }
        if decoding_supports_codec(decoding, candidate)
            && encoding_supports_codec(encoding, candidate)
        {
            return Some(candidate);
        }
    }

    None
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct VideoFrameChunkKey {
    display: i32,
    frame_id: u64,
}

struct PendingVideoFrameChunk {
    chunks: Vec<Option<Bytes>>,
    received_chunks: usize,
    received_bytes: usize,
    original_size: usize,
    first_seen: Instant,
}

impl PendingVideoFrameChunk {
    fn new(chunk_count: usize, original_size: usize, now: Instant) -> Self {
        Self {
            chunks: vec![None; chunk_count],
            received_chunks: 0,
            received_bytes: 0,
            original_size,
            first_seen: now,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct VideoFrameChunkExpirySummary {
    frames: usize,
    chunks: usize,
    last_display: i32,
    last_frame_id: u64,
}

impl VideoFrameChunkExpirySummary {
    fn record(&mut self, key: VideoFrameChunkKey, pending: &PendingVideoFrameChunk) {
        self.frames = self.frames.saturating_add(1);
        self.chunks = self.chunks.saturating_add(pending.received_chunks);
        if key.frame_id >= self.last_frame_id {
            self.last_display = key.display;
            self.last_frame_id = key.frame_id;
        }
    }

    fn has_expired(&self) -> bool {
        self.frames > 0
    }
}

#[derive(Debug)]
struct VideoFrameChunkPush {
    frame: Option<(VideoFrame, usize)>,
    expired: VideoFrameChunkExpirySummary,
}

#[derive(Default)]
struct VideoFrameChunkAssembler {
    pending: HashMap<VideoFrameChunkKey, PendingVideoFrameChunk>,
}

impl VideoFrameChunkAssembler {
    fn push(&mut self, chunk: VideoFrameChunk) -> Result<VideoFrameChunkPush, String> {
        let now = Instant::now();
        let expired = self.cleanup_expired(now);

        let chunk_count = chunk.chunk_count as usize;
        let chunk_index = chunk.chunk_index as usize;
        let original_size = chunk.original_size as usize;
        if chunk_count == 0 {
            return Err("video frame chunk has zero chunk_count".to_owned());
        }
        if chunk_count > VIDEO_FRAME_CHUNK_MAX_CHUNKS {
            return Err(format!(
                "video frame chunk_count too large: count={}, max={}",
                chunk_count, VIDEO_FRAME_CHUNK_MAX_CHUNKS
            ));
        }
        if chunk_index >= chunk_count {
            return Err(format!(
                "video frame chunk index out of range: index={}, count={}",
                chunk_index, chunk_count
            ));
        }
        if original_size == 0 || original_size > VIDEO_FRAME_CHUNK_MAX_ORIGINAL_SIZE {
            return Err(format!(
                "video frame chunk original_size invalid: size={}, max={}",
                original_size, VIDEO_FRAME_CHUNK_MAX_ORIGINAL_SIZE
            ));
        }
        if chunk.data.is_empty() {
            return Err("video frame chunk has empty data".to_owned());
        }

        let key = VideoFrameChunkKey {
            display: chunk.display,
            frame_id: chunk.frame_id,
        };
        let should_reset = self
            .pending
            .get(&key)
            .map(|pending| {
                pending.chunks.len() != chunk_count || pending.original_size != original_size
            })
            .unwrap_or(true);
        if should_reset {
            self.pending.insert(
                key,
                PendingVideoFrameChunk::new(chunk_count, original_size, now),
            );
        }

        let pending = self
            .pending
            .get_mut(&key)
            .ok_or_else(|| "video frame chunk state missing".to_owned())?;
        if pending.chunks[chunk_index].is_some() {
            return Ok(VideoFrameChunkPush {
                frame: None,
                expired,
            });
        }
        pending.received_bytes = pending.received_bytes.saturating_add(chunk.data.len());
        if pending.received_bytes > pending.original_size {
            let received_bytes = pending.received_bytes;
            self.pending.remove(&key);
            return Err(format!(
                "video frame chunks exceed declared size: received={}, declared={}",
                received_bytes, original_size
            ));
        }
        pending.chunks[chunk_index] = Some(chunk.data);
        pending.received_chunks += 1;
        if pending.received_chunks != chunk_count {
            return Ok(VideoFrameChunkPush {
                frame: None,
                expired,
            });
        }

        let pending = self
            .pending
            .remove(&key)
            .ok_or_else(|| "complete video frame chunk state missing".to_owned())?;
        let mut frame_bytes = Vec::with_capacity(pending.original_size);
        for chunk in pending.chunks {
            let chunk =
                chunk.ok_or_else(|| "complete video frame chunk missing data".to_owned())?;
            frame_bytes.extend_from_slice(&chunk);
        }
        if frame_bytes.len() != original_size {
            return Err(format!(
                "reassembled video frame size mismatch: received={}, declared={}",
                frame_bytes.len(),
                original_size
            ));
        }
        let vf = VideoFrame::parse_from_bytes(&frame_bytes)
            .map_err(|err| format!("reassembled video frame parse failed: {err}"))?;
        if vf.display != key.display || vf.frame_id != key.frame_id {
            return Err(format!(
                "reassembled video frame identity mismatch: chunk_display={}, frame_display={}, chunk_frame_id={}, frame_id={}",
                key.display, vf.display, key.frame_id, vf.frame_id
            ));
        }
        Ok(VideoFrameChunkPush {
            frame: Some((vf, frame_bytes.len())),
            expired,
        })
    }

    fn cleanup_expired(&mut self, now: Instant) -> VideoFrameChunkExpirySummary {
        let mut summary = VideoFrameChunkExpirySummary::default();
        self.pending.retain(|key, pending| {
            let keep = now.saturating_duration_since(pending.first_seen)
                < VIDEO_FRAME_CHUNK_REASSEMBLY_TIMEOUT;
            if !keep {
                summary.record(*key, pending);
            }
            keep
        });
        summary
    }
}

pub struct Remote<T: InvokeUiSession> {
    handler: Session<T>,
    audio_sender: MediaSender,
    receiver: mpsc::UnboundedReceiver<Data>,
    sender: mpsc::UnboundedSender<Data>,
    // Stop sending local audio to remote client.
    stop_voice_call_sender: Option<std::sync::mpsc::Sender<()>>,
    voice_call_request_timestamp: Option<NonZeroI64>,
    read_jobs: Vec<fs::TransferJob>,
    write_jobs: Vec<fs::TransferJob>,
    remove_jobs: HashMap<i32, RemoveJob>,
    timer: crate::RustDeskInterval,
    last_update_jobs_status: (Instant, HashMap<i32, u64>),
    is_connected: bool,
    first_frame: bool,
    #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
    client_conn_id: i32, // used for file clipboard
    data_count: Arc<AtomicUsize>,
    video_format: CodecFormat,
    elevation_requested: bool,
    peer_info: ParsedPeerInfo,
    video_threads: HashMap<usize, VideoThread>,
    video_frame_chunks_seen: u64,
    video_chunk_assembler: VideoFrameChunkAssembler,
    video_receiver_stats: HashMap<usize, VideoReceiverStatsTracker>,
    chroma: Arc<RwLock<Option<Chroma>>>,
    last_record_state: bool,
    sent_close_reason: bool,
    last_fps_control_summary_log: Option<Instant>,
}

#[derive(Default)]
struct ParsedPeerInfo {
    platform: String,
    is_installed: bool,
    idd_impl: String,
    support_view_camera: bool,
    support_terminal: bool,
}

fn session_permission_response_msgbox_type(approved: bool) -> &'static str {
    if approved {
        "custom-nocancel-success"
    } else {
        "custom-nocancel-error"
    }
}

impl ParsedPeerInfo {
    fn is_support_virtual_display(&self) -> bool {
        self.is_installed
            && self.platform == "Windows"
            && (self.idd_impl == "rustdesk_idd" || self.idd_impl == "amyuni_idd")
    }
}

impl<T: InvokeUiSession> Remote<T> {
    pub fn new(
        handler: Session<T>,
        receiver: mpsc::UnboundedReceiver<Data>,
        sender: mpsc::UnboundedSender<Data>,
    ) -> Self {
        Self {
            handler,
            audio_sender: crate::client::start_audio_thread(),
            receiver,
            sender,
            read_jobs: Vec::new(),
            write_jobs: Vec::new(),
            remove_jobs: Default::default(),
            timer: crate::rustdesk_interval(time::interval(CONNECTION_RECEIVE_TIMEOUT)),
            last_update_jobs_status: (Instant::now(), Default::default()),
            is_connected: false,
            first_frame: false,
            #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
            client_conn_id: 0,
            data_count: Arc::new(AtomicUsize::new(0)),
            video_format: CodecFormat::Unknown,
            stop_voice_call_sender: None,
            voice_call_request_timestamp: None,
            elevation_requested: false,
            peer_info: Default::default(),
            video_threads: Default::default(),
            video_frame_chunks_seen: 0,
            video_chunk_assembler: Default::default(),
            video_receiver_stats: Default::default(),
            chroma: Default::default(),
            last_record_state: false,
            sent_close_reason: false,
            last_fps_control_summary_log: None,
        }
    }

    fn connection_error_with_state(&self, reason: impl AsRef<str>) -> String {
        format!(
            "{}\n\nClient state: connected={}, video_packet_seen={}, video_chunks_seen={}, video_format={:?}, video_threads={}",
            reason.as_ref(),
            self.is_connected,
            self.first_frame,
            self.video_frame_chunks_seen,
            self.video_format,
            self.video_threads.len()
        )
    }

    fn show_connection_error_with_state(&self, reason: impl AsRef<str>) {
        let err = self.connection_error_with_state(reason);
        log::warn!(
            "diag client connection error shown: id={}, {}",
            self.handler.get_id(),
            err.replace('\n', " | ")
        );
        self.handler.on_establish_connection_error(err);
    }

    fn no_video_startup_mark_codec_unsupported(&self) -> Option<CodecFormat> {
        let id = self.handler.get_id();
        let mut lc = self.handler.lc.write().unwrap();
        let decoding = lc.get_supported_decoding();
        let encoding = lc.supported_encoding.clone();
        let Some(format) = next_no_video_startup_fallback_codec(
            &decoding,
            &encoding,
            &lc.mark_unsupported,
            self.video_format,
        ) else {
            log::warn!(
                "diag client no video startup has no codec fallback: id={}, video_format={:?}, mark_unsupported={:?}, supported_encoding={:?}, supported_decoding=(h264={}, h265={}, vp9={}, av1={}, prefer={:?}, prefer_chroma={:?})",
                id,
                self.video_format,
                lc.mark_unsupported,
                encoding,
                decoding.ability_h264,
                decoding.ability_h265,
                decoding.ability_vp9,
                decoding.ability_av1,
                decoding.prefer.enum_value_or(PreferCodec::Auto),
                decoding.prefer_chroma.enum_value_or(Chroma::I420)
            );
            return None;
        };

        lc.mark_unsupported.push(format);
        log::warn!(
            "diag client no video startup marking codec unsupported: id={}, codec={:?}, mark_unsupported={:?}, supported_encoding={:?}",
            id,
            format,
            lc.mark_unsupported,
            encoding
        );
        Some(format)
    }

    pub async fn io_loop(&mut self, key: &str, token: &str, round: u32) {
        #[cfg(target_os = "windows")]
        let _file_clip_context_holder = {
            // `is_port_forward()` will not reach here, but we still check it for clarity.
            if self.handler.is_default() {
                // It is ok to call this function multiple times.
                ContextSend::enable(true);
                Some(crate::SimpleCallOnReturn {
                    b: true,
                    f: Box::new(|| {
                        // No need to call `enable(false)` for sciter version, because each client of sciter version is a new process.
                        // It's better to check if the peers are windows(support file copy&paste), but it's not necessary.
                        #[cfg(feature = "flutter")]
                        if !crate::flutter::sessions::has_sessions_running(ConnType::DEFAULT_CONN) {
                            ContextSend::enable(false);
                        };
                    }),
                })
            } else {
                None
            }
        };

        let mut last_recv_time = Instant::now();
        let mut received = false;
        let conn_type = if self.handler.is_file_transfer() {
            ConnType::FILE_TRANSFER
        } else if self.handler.is_view_camera() {
            ConnType::VIEW_CAMERA
        } else if self.handler.is_terminal() {
            ConnType::TERMINAL
        } else {
            ConnType::default()
        };
        let expects_video =
            conn_type == ConnType::DEFAULT_CONN || conn_type == ConnType::VIEW_CAMERA;
        let mut reconnect_after_disconnect = false;

        match Client::start(
            &self.handler.get_id(),
            key,
            token,
            conn_type,
            self.handler.clone(),
        )
        .await
        {
            Ok(((mut peer, direct, pk, kcp, stream_type), (feedback, rendezvous_server))) => {
                self.handler
                    .connection_round_state
                    .lock()
                    .unwrap()
                    .set_connected();
                self.handler
                    .set_connection_type(peer.is_secured(), direct, stream_type); // flutter -> connection_ready
                self.handler.update_direct(Some(direct));
                if conn_type == ConnType::DEFAULT_CONN || conn_type == ConnType::VIEW_CAMERA {
                    self.handler
                        .set_fingerprint(crate::common::pk_to_fingerprint(pk.unwrap_or_default()));
                }

                // just build for now
                #[cfg(not(any(target_os = "windows", feature = "unix-file-copy-paste")))]
                let (_tx_holder, mut rx_clip_client) = mpsc::unbounded_channel::<i32>();

                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                let (_tx_holder, rx) = mpsc::unbounded_channel();
                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                let mut rx_clip_client_holder = (Arc::new(TokioMutex::new(rx)), None);
                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                {
                    if self.handler.is_default() {
                        (self.client_conn_id, rx_clip_client_holder.0) =
                            clipboard::get_rx_cliprdr_client(&self.handler.get_id());
                        log::debug!("get cliprdr client for conn_id {}", self.client_conn_id);
                        let client_conn_id = self.client_conn_id;
                        rx_clip_client_holder.1 = Some(crate::SimpleCallOnReturn {
                            b: true,
                            f: Box::new(move || {
                                clipboard::remove_channel_by_conn_id(client_conn_id);
                            }),
                        });
                    };
                }
                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                let mut rx_clip_client = rx_clip_client_holder.0.lock().await;

                let mut status_timer =
                    crate::rustdesk_interval(time::interval(Duration::new(1, 0)));
                let mut fps_instant = Instant::now();
                let mut no_video_watchdog = NoVideoStartupWatchdog::default();

                let _keep_it = client::hc_connection(feedback, rendezvous_server, token).await;

                loop {
                    tokio::select! {
                        res = peer.next() => {
                            if let Some(res) = res {
                                match res {
                                    Err(err) => {
                                        log::warn!(
                                            "diag client stream read error: id={}, is_connected={}, video_packet_seen={}, video_format={:?}, err={}",
                                            self.handler.get_id(),
                                            self.is_connected,
                                            self.first_frame,
                                            self.video_format,
                                            err
                                        );
                                        self.show_connection_error_with_state(format!(
                                            "Connection stream read error: {err}"
                                        ));
                                        break;
                                    }
                                    Ok(ref bytes) => {
                                        last_recv_time = Instant::now();
                                        if !received {
                                            received = true;
                                            self.handler.update_received(true);
                                        }
                                        self.data_count.fetch_add(bytes.len(), Ordering::Relaxed);
                                        if !self.first_frame && bytes.len() > 4096 {
                                            log::info!(
                                                "diag client pre-video framed message received: id={}, bytes={}, is_connected={}, video_format={:?}",
                                                self.handler.get_id(),
                                                bytes.len(),
                                                self.is_connected,
                                                self.video_format
                                            );
                                        }
                                        if !self.handle_msg_from_peer(bytes, &mut peer).await {
                                            log::info!(
                                                "diag client peer handler requested exit: id={}, is_connected={}, video_packet_seen={}, video_format={:?}",
                                                self.handler.get_id(),
                                                self.is_connected,
                                                self.first_frame,
                                                self.video_format
                                            );
                                            break
                                        }
                                    }
                                }
                            } else {
                                log::warn!(
                                    "diag client stream ended by peer: id={}, is_connected={}, video_packet_seen={}, video_format={:?}",
                                    self.handler.get_id(),
                                    self.is_connected,
                                    self.first_frame,
                                    self.video_format
                                );
                                if self.handler.is_restarting_remote_device() {
                                    log::info!("Restart remote device");
                                    self.handler.msgbox("restarting", "Restarting remote device", "remote_restarting_tip", "");
                                } else {
                                    log::info!("Reset by the peer");
                                    self.show_connection_error_with_state("Reset by the peer");
                                }
                                break;
                            }
                        }
                        d = self.receiver.recv() => {
                            if let Some(d) = d {
                                if !self.handle_msg_from_ui(d, &mut peer).await {
                                    break;
                                }
                            }
                        }
                        _msg = rx_clip_client.recv() => {
                            #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                            self.handle_local_clipboard_msg(&mut peer, _msg).await;
                        }
                        _ = self.timer.tick() => {
                            if last_recv_time.elapsed() >= CONNECTION_RECEIVE_TIMEOUT {
                                log::warn!(
                                    "diag client receive timeout: id={}, is_connected={}, video_packet_seen={}, video_chunks_seen={}, video_format={:?}, elapsed_ms={}",
                                    self.handler.get_id(),
                                    self.is_connected,
                                    self.first_frame,
                                    self.video_frame_chunks_seen,
                                    self.video_format,
                                    last_recv_time.elapsed().as_millis()
                                );
                                self.show_connection_error_with_state("Connection receive timeout");
                                break;
                            }
                            if !self.read_jobs.is_empty() {
                                if let Err(err) = fs::handle_read_jobs(&mut self.read_jobs, &mut peer).await {
                                    self.handler.msgbox("error", "Connection Error", &err.to_string(), "");
                                    break;
                                }
                                self.update_jobs_status();
                            } else {
                                self.timer = crate::rustdesk_interval(time::interval_at(
                                    Instant::now() + CONNECTION_RECEIVE_TIMEOUT,
                                    CONNECTION_RECEIVE_TIMEOUT,
                                ));
                            }
                        }
                        _ = status_timer.tick() => {
                            match no_video_watchdog.tick(
                                expects_video,
                                self.is_connected,
                                self.first_frame,
                                self.video_frame_chunks_seen > 0,
                                Instant::now(),
                            ) {
                                NoVideoStartupAction::Reconnect { attempt, elapsed_ms } => {
                                    log::warn!(
                                        "diag client no video startup reconnect fallback: id={}, is_connected={}, video_packet_seen={}, video_chunks_seen={}, video_format={:?}, elapsed_ms={}, local_fallback_attempt={}",
                                        self.handler.get_id(),
                                        self.is_connected,
                                        self.first_frame,
                                        self.video_frame_chunks_seen,
                                        self.video_format,
                                        elapsed_ms,
                                        attempt
                                    );
                                    if self.video_frame_chunks_seen > 0 {
                                        log::warn!(
                                            "diag client no video startup transport reconnect without codec blacklist: id={}, attempt={}, video_chunks_seen={}, video_format={:?}",
                                            self.handler.get_id(),
                                            attempt,
                                            self.video_frame_chunks_seen,
                                            self.video_format
                                        );
                                        self.send_close_reason(
                                            &mut peer,
                                            "startup video chunk transport reconnect",
                                        )
                                        .await;
                                        reconnect_after_disconnect = true;
                                        break;
                                    }
                                    if let Some(format) = self.no_video_startup_mark_codec_unsupported() {
                                        log::warn!(
                                            "diag client no video startup scheduling reconnect after stream close: id={}, attempt={}, codec={:?}",
                                            self.handler.get_id(),
                                            attempt,
                                            format
                                        );
                                        self.send_close_reason(
                                            &mut peer,
                                            "startup video fallback reconnect",
                                        )
                                        .await;
                                        reconnect_after_disconnect = true;
                                        break;
                                    } else {
                                        self.show_connection_error_with_state(format!(
                                            "Video stream did not start after {elapsed_ms} ms; no codec fallback is available"
                                        ));
                                        break;
                                    }
                                }
                                NoVideoStartupAction::Stalled { elapsed_ms } => {
                                    log::warn!(
                                        "diag client no video startup still waiting: id={}, is_connected={}, video_packet_seen={}, video_chunks_seen={}, video_format={:?}, elapsed_ms={}, local_fallback_attempts={}",
                                        self.handler.get_id(),
                                        self.is_connected,
                                        self.first_frame,
                                        self.video_frame_chunks_seen,
                                        self.video_format,
                                        elapsed_ms,
                                        no_video_watchdog.fallback_count
                                    );
                                }
                                NoVideoStartupAction::GiveUp {
                                    elapsed_ms,
                                    fallback_count,
                                } => {
                                    self.show_connection_error_with_state(format!(
                                        "Video stream did not start after {elapsed_ms} ms and {fallback_count} reconnect fallback attempts"
                                    ));
                                    break;
                                }
                                NoVideoStartupAction::None => {}
                            }

                            let elapsed = fps_instant.elapsed().as_millis();
                            if elapsed < 1000 {
                                continue;
                            }
                            fps_instant = Instant::now();
                            let mut speed = self.data_count.swap(0, Ordering::Relaxed);
                            speed = speed * 1000 / elapsed as usize;
                            let speed = format!("{:.2}kB/s", speed as f32 / 1024 as f32);

                            let fps = self.video_threads.iter().map(|(k, v)| {
                                // Correcting the inaccuracy of status_timer
                                (k.clone(), (*v.frame_count.read().unwrap() as i32) * 1000 / elapsed as i32)
                            }).collect::<HashMap<usize, i32>>();
                            self.video_threads.iter().for_each(|(_, v)| {
                                *v.frame_count.write().unwrap() = 0;
                            });
                            self.fps_control(direct, fps.clone());
                            self.send_video_receiver_stats(
                                &mut peer,
                                elapsed.min(u32::MAX as u128) as u32,
                            )
                            .await;
                            let chroma = self.chroma.read().unwrap().clone();
                            let chroma = match chroma {
                                Some(Chroma::I444) => "4:4:4",
                                Some(Chroma::I420) => "4:2:0",
                                None => "-",
                            };
                            let chroma = Some(chroma.to_string());
                            let codec_format = if self.video_format == CodecFormat::Unknown {
                                None
                            } else {
                                Some(self.video_format.clone())
                            };
                            self.handler.update_quality_status(QualityStatus {
                                speed: Some(speed),
                                fps,
                                chroma,
                                codec_format,
                                ..Default::default()
                            });
                        }
                    }
                }
                log::debug!("Exit io_loop of id={}", self.handler.get_id());
                // Stop client audio server.
                if let Some(s) = self.stop_voice_call_sender.take() {
                    s.send(()).ok();
                }
                if kcp.is_some() {
                    // Send the close reason if it hasn't been sent yet, as KCP cannot detect the socket close event.
                    self.send_close_reason(&mut peer, "kcp").await;
                    // KCP does not send messages immediately, so wait to ensure the last message is sent.
                    // 1ms works in my test, but 30ms is more reliable.
                    tokio::time::sleep(Duration::from_millis(30)).await;
                }
            }
            Err(err) => {
                self.handler.on_establish_connection_error(err.to_string());
            }
        }
        // set_disconnected_ok is used to check if new connection round is started.
        let _set_disconnected_ok = self
            .handler
            .connection_round_state
            .lock()
            .unwrap()
            .set_disconnected(round);

        if reconnect_after_disconnect && _set_disconnected_ok {
            log::info!(
                "diag client no video startup reconnect after disconnect: id={}, grace_ms={}",
                self.handler.get_id(),
                NO_VIDEO_START_RECONNECT_GRACE.as_millis()
            );
            tokio::time::sleep(NO_VIDEO_START_RECONNECT_GRACE).await;
            self.handler.reconnect(false);
            return;
        }

        #[cfg(not(target_os = "ios"))]
        if self.handler.is_default() && _set_disconnected_ok {
            Client::try_stop_clipboard();
        }

        #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
        if self.handler.is_default() && _set_disconnected_ok {
            crate::clipboard::try_empty_clipboard_files(ClipboardSide::Client, self.client_conn_id);
        }
    }

    #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
    async fn handle_local_clipboard_msg(
        &self,
        peer: &mut Stream,
        msg: Option<clipboard::ClipboardFile>,
    ) {
        match msg {
            Some(clip) => match clip {
                clipboard::ClipboardFile::NotifyCallback {
                    r#type,
                    title,
                    text,
                } => {
                    self.handler.msgbox(&r#type, &title, &text, "");
                }
                _ => {
                    let is_stopping_allowed = clip.is_stopping_allowed();
                    let server_file_transfer_enabled =
                        *self.handler.server_file_transfer_enabled.read().unwrap();
                    let file_transfer_enabled =
                        self.handler.lc.read().unwrap().enable_file_copy_paste.v;
                    let view_only = self.handler.lc.read().unwrap().view_only.v;
                    let stop = is_stopping_allowed
                        && (view_only
                            || !self.is_connected
                            || !(server_file_transfer_enabled && file_transfer_enabled));
                    log::debug!(
                        "Process clipboard message from system, stop: {}, is_stopping_allowed: {}, view_only: {}, server_file_transfer_enabled: {}, file_transfer_enabled: {}",
                        view_only, stop, is_stopping_allowed, server_file_transfer_enabled, file_transfer_enabled
                    );
                    if stop {
                        #[cfg(target_os = "windows")]
                        {
                            ContextSend::set_is_stopped();
                        }
                    } else {
                        #[cfg(target_os = "windows")]
                        if let Err(e) = ContextSend::make_sure_enabled() {
                            log::error!("failed to restart clipboard context: {}", e);
                            // to-do: Show msgbox with "Don't show again" option
                        };
                        log::debug!("Send system clipboard message to remote");
                        let msg = crate::clipboard_file::clip_2_msg(clip);
                        allow_err!(peer.send(&msg).await);
                    }
                }
            },
            None => {
                // unreachable!()
            }
        }
    }

    fn handle_job_status(&mut self, id: i32, file_num: i32, err: Option<String>) {
        if let Some(job) = self.remove_jobs.get_mut(&id) {
            if job.no_confirm {
                let file_num = (file_num + 1) as usize;
                if file_num < job.files.len() {
                    let path = format!("{}{}{}", job.path, job.sep, job.files[file_num].name);
                    self.sender
                        .send(Data::RemoveFile((id, path, file_num as i32, job.is_remote)))
                        .ok();
                    let elapsed = job.last_update_job_status.elapsed().as_millis() as i32;
                    if elapsed >= 1000 {
                        job.last_update_job_status = Instant::now();
                    } else {
                        return;
                    }
                } else {
                    self.remove_jobs.remove(&id);
                }
            }
        }
        if let Some(err) = err {
            self.handler.job_error(id, err, file_num);
        } else {
            self.handler.job_done(id, file_num);
        }
    }

    fn stop_voice_call(&mut self) {
        let voice_call_sender = std::mem::replace(&mut self.stop_voice_call_sender, None);
        if let Some(stopper) = voice_call_sender {
            let _ = stopper.send(());
        }
    }

    // Start a voice call recorder, records audio and send to remote
    fn start_voice_call(&mut self) -> Option<std::sync::mpsc::Sender<()>> {
        if self.handler.is_file_transfer()
            || self.handler.is_port_forward()
            || self.handler.is_terminal()
        {
            return None;
        }
        // iOS does not have this server.
        #[cfg(not(any(target_os = "ios")))]
        {
            // NOTE:
            // The client server and --server both use the same sound input device.
            // It's better to distinguish the server side and client side.
            // But it' not necessary for now, because it's not a common case.
            // And it is immediately known when the input device is changed.
            crate::audio_service::set_voice_call_input_device(get_default_sound_input(), false);
            // Create a channel to receive error or closed message
            let (tx, rx) = std::sync::mpsc::channel();
            let (tx_audio_data, mut rx_audio_data) =
                hbb_common::tokio::sync::mpsc::unbounded_channel();
            // Create a stand-alone inner, add subscribe to audio service
            let conn_id = CLIENT_SERVER.write().unwrap().get_new_id();
            let client_conn_inner = ConnInner::new(conn_id.clone(), Some(tx_audio_data), None);
            // now we subscribe
            CLIENT_SERVER.write().unwrap().subscribe(
                audio_service::NAME,
                client_conn_inner.clone(),
                true,
            );
            let tx_audio = self.sender.clone();
            std::thread::spawn(move || {
                loop {
                    // check if client is closed
                    match rx.try_recv() {
                        Ok(_) | Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                            log::debug!("Exit voice call audio service of client");
                            // unsubscribe
                            CLIENT_SERVER.write().unwrap().subscribe(
                                audio_service::NAME,
                                client_conn_inner,
                                false,
                            );
                            crate::audio_service::set_voice_call_input_device(None, true);
                            break;
                        }
                        _ => {}
                    }
                    match rx_audio_data.try_recv() {
                        Ok((_instant, msg)) => match &msg.union {
                            Some(message::Union::AudioFrame(frame)) => {
                                let mut msg = Message::new();
                                msg.set_audio_frame(frame.clone());
                                tx_audio.send(Data::Message(msg)).ok();
                            }
                            Some(message::Union::Misc(misc)) => {
                                let mut msg = Message::new();
                                msg.set_misc(misc.clone());
                                tx_audio.send(Data::Message(msg)).ok();
                            }
                            _ => {}
                        },
                        Err(err) => {
                            if err == TryRecvError::Empty {
                                // ignore
                            } else {
                                log::debug!("Failed to record local audio channel: {}", err);
                            }
                        }
                    }
                }
            });
            return Some(tx);
        }
        #[cfg(target_os = "ios")]
        {
            None
        }
    }

    async fn send_close_reason(&mut self, peer: &mut Stream, reason: &str) {
        if self.sent_close_reason {
            return;
        }
        let mut misc = Misc::new();
        misc.set_close_reason(reason.to_owned());
        let mut msg = Message::new();
        msg.set_misc(misc);
        allow_err!(peer.send(&msg).await);
        self.sent_close_reason = true;
    }

    async fn send_video_keyframe_request(
        &mut self,
        peer: &mut Stream,
        display: i32,
        last_frame_id: u64,
        reason: u32,
    ) {
        let now = Instant::now();
        let display_key = display.max(0) as usize;
        let Some(stats) = self.video_receiver_stats.get_mut(&display_key) else {
            return;
        };
        if !stats.should_send_keyframe_request(now) {
            return;
        }
        let msg = video_keyframe_request_msg(display, last_frame_id, reason);
        if let Err(err) = peer.send(&msg).await {
            log::warn!(
                "diag client video keyframe request send failed: id={}, display={}, last_frame_id={}, reason={}, err={}",
                self.handler.get_id(),
                display,
                last_frame_id,
                reason,
                err
            );
        } else {
            log::info!(
                "diag client video keyframe request sent: id={}, display={}, last_frame_id={}, reason={}",
                self.handler.get_id(),
                display,
                last_frame_id,
                reason
            );
        }
    }

    async fn send_video_receiver_stats(&mut self, peer: &mut Stream, interval_ms: u32) {
        let now = Instant::now();
        let expired = self.video_chunk_assembler.cleanup_expired(now);
        if expired.has_expired() {
            log::warn!(
                "diag client video frame chunks expired on stats tick: id={}, display={}, last_frame_id={}, expired_frames={}, expired_chunks={}, total_chunks_seen={}",
                self.handler.get_id(),
                expired.last_display,
                expired.last_frame_id,
                expired.frames,
                expired.chunks,
                self.video_frame_chunks_seen
            );
            self.video_receiver_stats
                .entry(expired.last_display.max(0) as usize)
                .or_default()
                .record_video_chunk_expired(expired);
            self.send_video_keyframe_request(
                peer,
                expired.last_display,
                expired.last_frame_id,
                VIDEO_KEYFRAME_REASON_FRAME_GAP,
            )
            .await;
        }
        let video_threads = &self.video_threads;
        let messages = self
            .video_receiver_stats
            .iter_mut()
            .filter(|(_, tracker)| tracker.has_transport_progress())
            .map(|(display, tracker)| {
                let (decode_queue_len, decode_snapshot) =
                    if let Some(thread) = video_threads.get(display) {
                        (
                            thread.video_queue.read().unwrap().len(),
                            thread.stats.snapshot(),
                        )
                    } else {
                        (0, client::VideoThreadStatsSnapshot::default())
                    };
                video_receiver_stats_msg(tracker.to_proto(
                    *display,
                    interval_ms,
                    decode_queue_len,
                    0,
                    decode_snapshot,
                    now,
                ))
            })
            .collect::<Vec<_>>();

        for msg in messages {
            if let Err(err) = peer.send(&msg).await {
                log::warn!(
                    "diag client video receiver stats send failed: id={}, interval_ms={}, err={}",
                    self.handler.get_id(),
                    interval_ms,
                    err
                );
                return;
            }
        }
    }

    async fn handle_msg_from_ui(&mut self, data: Data, peer: &mut Stream) -> bool {
        match data {
            Data::Close => {
                log::info!(
                                        "diag client io_loop received Data::Close: id={}, is_connected={}, video_packet_seen={}, video_chunks_seen={}, video_format={:?}, video_threads={}, sent_close_reason={}",
                                        self.handler.get_id(),
                                        self.is_connected,
                                        self.first_frame,
                                        self.video_frame_chunks_seen,
                                        self.video_format,
                                        self.video_threads.len(),
                                        self.sent_close_reason
                );
                self.send_close_reason(peer, "").await;
                return false;
            }
            Data::Login((os_username, os_password, password, remember)) => {
                self.handler
                    .handle_login_from_ui(os_username, os_password, password, remember, peer)
                    .await;
            }
            #[cfg(all(target_os = "windows", not(feature = "flutter")))]
            Data::ToggleClipboardFile => {
                self.check_clipboard_file_context();
            }
            Data::Message(msg) => {
                match &msg.union {
                    Some(message::Union::Misc(misc)) => match misc.union {
                        Some(misc::Union::RefreshVideo(_)) => {
                            self.video_threads.iter().for_each(|(_, v)| {
                                *v.discard_queue.write().unwrap() = true;
                            });
                        }
                        Some(misc::Union::RefreshVideoDisplay(display)) => {
                            if let Some(v) = self.video_threads.get_mut(&(display as usize)) {
                                *v.discard_queue.write().unwrap() = true;
                            }
                        }
                        _ => {}
                    },
                    _ => {}
                }
                allow_err!(peer.send(&msg).await);
            }
            Data::SendFiles((id, r#type, path, to, file_num, include_hidden, is_remote)) => {
                log::info!("send files, is remote {}", is_remote);
                let od = can_enable_overwrite_detection(self.handler.lc.read().unwrap().version);
                if is_remote {
                    log::debug!("New job {}, write to {} from remote {}", id, to, path);
                    let to = match r#type {
                        fs::JobType::Generic => fs::DataSource::FilePath(PathBuf::from(&to)),
                        fs::JobType::Printer => {
                            fs::DataSource::MemoryCursor(std::io::Cursor::new(Vec::new()))
                        }
                    };
                    self.write_jobs.push(fs::TransferJob::new_write(
                        id,
                        r#type,
                        path.clone(),
                        to,
                        file_num,
                        include_hidden,
                        is_remote,
                        od,
                    ));
                    allow_err!(
                        peer.send(&fs::new_send(id, r#type, path, file_num, include_hidden))
                            .await
                    );
                } else {
                    match fs::TransferJob::new_read(
                        id,
                        r#type,
                        to.clone(),
                        fs::DataSource::FilePath(PathBuf::from(&path)),
                        file_num,
                        include_hidden,
                        is_remote,
                        od,
                    ) {
                        Err(err) => {
                            self.handle_job_status(id, -1, Some(err.to_string()));
                        }
                        Ok(job) => {
                            log::debug!(
                                "New job {}, read {} to remote {}, {} files",
                                id,
                                path,
                                to,
                                job.files().len()
                            );
                            self.handler.update_folder_files(
                                job.id(),
                                job.files(),
                                path,
                                !is_remote,
                                true,
                            );
                            #[cfg(not(windows))]
                            let files = job.files().clone();
                            #[cfg(windows)]
                            let mut files = job.files().clone();
                            #[cfg(windows)]
                            if self.handler.peer_platform() != "Windows" {
                                // peer is not windows, need transform \ to /
                                fs::transform_windows_path(&mut files);
                            }
                            let total_size = job.total_size();
                            self.read_jobs.push(job);
                            self.timer = crate::rustdesk_interval(time::interval(MILLI1));
                            allow_err!(
                                peer.send(&fs::new_receive(id, to, file_num, files, total_size))
                                    .await
                            );
                        }
                    }
                }
            }
            Data::AddJob((id, r#type, path, to, file_num, include_hidden, is_remote)) => {
                let od = can_enable_overwrite_detection(self.handler.lc.read().unwrap().version);
                if is_remote {
                    log::debug!(
                        "new write waiting job {}, write to {} from remote {}",
                        id,
                        to,
                        path
                    );
                    let mut job = fs::TransferJob::new_write(
                        id,
                        r#type,
                        path.clone(),
                        fs::DataSource::FilePath(PathBuf::from(&to)),
                        file_num,
                        include_hidden,
                        is_remote,
                        od,
                    );
                    job.is_last_job = true;
                    self.write_jobs.push(job);
                } else {
                    match fs::TransferJob::new_read(
                        id,
                        r#type,
                        to.clone(),
                        fs::DataSource::FilePath(PathBuf::from(&path)),
                        file_num,
                        include_hidden,
                        is_remote,
                        od,
                    ) {
                        Err(err) => {
                            self.handle_job_status(id, -1, Some(err.to_string()));
                        }
                        Ok(mut job) => {
                            log::debug!(
                                "new read waiting job {}, read {} to remote {}, {} files",
                                id,
                                path,
                                to,
                                job.files().len()
                            );
                            self.handler.update_folder_files(
                                job.id(),
                                job.files(),
                                path,
                                !is_remote,
                                true,
                            );
                            job.is_last_job = true;
                            self.read_jobs.push(job);
                            self.timer = crate::rustdesk_interval(time::interval(MILLI1));
                        }
                    }
                }
            }
            Data::ResumeJob((id, is_remote)) => {
                if is_remote {
                    if let Some(job) = get_job(id, &mut self.write_jobs) {
                        job.is_last_job = false;
                        job.is_resume = true;
                        allow_err!(
                            peer.send(&fs::new_send(
                                id,
                                fs::JobType::Generic,
                                job.remote.clone(),
                                job.file_num,
                                job.show_hidden
                            ))
                            .await
                        );
                    }
                } else {
                    if let Some(job) = get_job(id, &mut self.read_jobs) {
                        match &job.data_source {
                            fs::DataSource::FilePath(_p) => {
                                job.is_last_job = false;
                                job.is_resume = true;
                                job.set_finished_size_on_resume();
                                #[cfg(not(windows))]
                                let files = job.files().clone();
                                #[cfg(windows)]
                                let mut files = job.files().clone();
                                #[cfg(windows)]
                                if self.handler.peer_platform() != "Windows" {
                                    // peer is not windows, need transform \ to /
                                    fs::transform_windows_path(&mut files);
                                }
                                allow_err!(
                                    peer.send(&fs::new_receive(
                                        id,
                                        job.remote.clone(),
                                        job.file_num,
                                        files,
                                        job.total_size(),
                                    ))
                                    .await
                                );
                            }
                            fs::DataSource::MemoryCursor(_) => {
                                // unreachable!()
                                log::error!("Resume job with memory cursor");
                            }
                        }
                    }
                }
            }
            Data::SetNoConfirm(id) => {
                if let Some(job) = self.remove_jobs.get_mut(&id) {
                    job.no_confirm = true;
                }
            }
            Data::ConfirmDeleteFiles((id, file_num)) => {
                if let Some(job) = self.remove_jobs.get_mut(&id) {
                    let i = file_num as usize;
                    if i < job.files.len() {
                        self.handler.ui_handler.confirm_delete_files(
                            id,
                            file_num,
                            job.files[i].name.clone(),
                        );
                    }
                }
            }
            Data::SetConfirmOverrideFile((id, file_num, need_override, remember, is_upload)) => {
                if is_upload {
                    if let Some(job) = fs::get_job(id, &mut self.read_jobs) {
                        if remember {
                            job.set_overwrite_strategy(Some(need_override));
                        }
                        job.confirm(&FileTransferSendConfirmRequest {
                            id,
                            file_num,
                            union: if need_override {
                                Some(file_transfer_send_confirm_request::Union::OffsetBlk(0))
                            } else {
                                Some(file_transfer_send_confirm_request::Union::Skip(true))
                            },
                            ..Default::default()
                        })
                        .await;
                    }
                } else {
                    if let Some(job) = fs::get_job(id, &mut self.write_jobs) {
                        if remember {
                            job.set_overwrite_strategy(Some(need_override));
                        }
                        let mut msg = Message::new();
                        let mut file_action = FileAction::new();
                        let req = FileTransferSendConfirmRequest {
                            id,
                            file_num,
                            union: if need_override {
                                Some(file_transfer_send_confirm_request::Union::OffsetBlk(0))
                            } else {
                                Some(file_transfer_send_confirm_request::Union::Skip(true))
                            },
                            ..Default::default()
                        };
                        job.confirm(&req).await;
                        file_action.set_send_confirm(req);
                        msg.set_file_action(file_action);
                        allow_err!(peer.send(&msg).await);
                    }
                }
            }
            Data::RemoveDirAll((id, path, is_remote, include_hidden)) => {
                let sep = self.handler.get_path_sep(is_remote);
                if is_remote {
                    let mut msg_out = Message::new();
                    let mut file_action = FileAction::new();
                    file_action.set_all_files(ReadAllFiles {
                        id,
                        path: path.clone(),
                        include_hidden,
                        ..Default::default()
                    });
                    msg_out.set_file_action(file_action);
                    allow_err!(peer.send(&msg_out).await);
                    self.remove_jobs
                        .insert(id, RemoveJob::new(Vec::new(), path, sep, is_remote));
                } else {
                    match fs::get_recursive_files(&path, include_hidden) {
                        Ok(entries) => {
                            self.handler.update_folder_files(
                                id,
                                &entries,
                                path.clone(),
                                !is_remote,
                                false,
                            );
                            self.remove_jobs
                                .insert(id, RemoveJob::new(entries, path, sep, is_remote));
                        }
                        Err(err) => {
                            self.handle_job_status(id, -1, Some(err.to_string()));
                        }
                    }
                }
            }
            Data::CancelJob(id) => {
                self.cancel_transfer_job(id, peer).await;
            }
            Data::RemoveDir((id, path)) => {
                let mut msg_out = Message::new();
                let mut file_action = FileAction::new();
                file_action.set_remove_dir(FileRemoveDir {
                    id,
                    path,
                    recursive: true,
                    ..Default::default()
                });
                msg_out.set_file_action(file_action);
                allow_err!(peer.send(&msg_out).await);
            }
            Data::RemoveFile((id, path, file_num, is_remote)) => {
                if is_remote {
                    let mut msg_out = Message::new();
                    let mut file_action = FileAction::new();
                    file_action.set_remove_file(FileRemoveFile {
                        id,
                        path,
                        file_num,
                        ..Default::default()
                    });
                    msg_out.set_file_action(file_action);
                    allow_err!(peer.send(&msg_out).await);
                } else {
                    match fs::remove_file(&path) {
                        Err(err) => {
                            self.handle_job_status(id, file_num, Some(err.to_string()));
                        }
                        Ok(()) => {
                            self.handle_job_status(id, file_num, None);
                        }
                    }
                }
            }
            Data::CreateDir((id, path, is_remote)) => {
                if is_remote {
                    let mut msg_out = Message::new();
                    let mut file_action = FileAction::new();
                    file_action.set_create(FileDirCreate {
                        id,
                        path,
                        ..Default::default()
                    });
                    msg_out.set_file_action(file_action);
                    allow_err!(peer.send(&msg_out).await);
                } else {
                    match fs::create_dir(&path) {
                        Err(err) => {
                            self.handle_job_status(id, -1, Some(err.to_string()));
                        }
                        Ok(()) => {
                            self.handle_job_status(id, -1, None);
                        }
                    }
                }
            }
            Data::RenameFile((id, path, new_name, is_remote)) => {
                if is_remote {
                    let mut msg_out = Message::new();
                    let mut file_action = FileAction::new();
                    file_action.set_rename(FileRename {
                        id,
                        path,
                        new_name,
                        ..Default::default()
                    });
                    msg_out.set_file_action(file_action);
                    allow_err!(peer.send(&msg_out).await);
                } else {
                    let err = fs::rename_file(&path, &new_name)
                        .err()
                        .map(|e| e.to_string());
                    self.handle_job_status(id, -1, err);
                }
            }
            Data::RecordScreen(start) => {
                self.handler.lc.write().unwrap().record_state = start;
                self.update_record_state();
            }
            Data::ElevateDirect => {
                let mut request = ElevationRequest::new();
                request.set_direct(true);
                let mut misc = Misc::new();
                misc.set_elevation_request(request);
                let mut msg = Message::new();
                msg.set_misc(misc);
                allow_err!(peer.send(&msg).await);
                self.elevation_requested = true;
            }
            Data::ElevateWithLogon(username, password) => {
                let mut request = ElevationRequest::new();
                request.set_logon(ElevationRequestWithLogon {
                    username,
                    password,
                    ..Default::default()
                });
                let mut misc = Misc::new();
                misc.set_elevation_request(request);
                let mut msg = Message::new();
                msg.set_misc(misc);
                allow_err!(peer.send(&msg).await);
                self.elevation_requested = true;
            }
            Data::NewVoiceCall => {
                let msg = new_voice_call_request(true);
                // Save the voice call request timestamp for the further validation.
                self.voice_call_request_timestamp = Some(
                    NonZeroI64::new(msg.voice_call_request().req_timestamp)
                        .unwrap_or(NonZeroI64::new(get_time()).unwrap()),
                );
                allow_err!(peer.send(&msg).await);
                self.handler.on_voice_call_waiting();
            }
            Data::CloseVoiceCall => {
                self.stop_voice_call();
                let msg = new_voice_call_request(false);
                self.handler
                    .on_voice_call_closed("Closed manually by the peer");
                allow_err!(peer.send(&msg).await);
            }
            Data::ResetDecoder(display) => match display {
                Some(display) => {
                    if let Some(v) = self.video_threads.get_mut(&display) {
                        v.video_sender.send(MediaData::Reset).ok();
                    }
                }
                None => {
                    for (_, v) in self.video_threads.iter_mut() {
                        v.video_sender.send(MediaData::Reset).ok();
                    }
                }
            },
            Data::TakeScreenshot((display, sid)) => {
                let mut msg = Message::new();
                msg.set_screenshot_request(ScreenshotRequest {
                    display,
                    sid,
                    ..Default::default()
                });
                allow_err!(peer.send(&msg).await);
            }
            _ => {}
        }
        true
    }

    #[inline]
    fn update_job_status(
        job: &fs::TransferJob,
        elapsed: i32,
        last_update_jobs_status: &mut (Instant, HashMap<i32, u64>),
        handler: &Session<T>,
    ) {
        if elapsed <= 0 {
            return;
        }
        let transferred = job.transferred();
        let last_transferred = {
            if let Some(v) = last_update_jobs_status.1.get(&job.id()) {
                v.to_owned()
            } else {
                0
            }
        };
        last_update_jobs_status.1.insert(job.id(), transferred);
        let speed = (transferred - last_transferred) as f64 / (elapsed as f64 / 1000.);
        let file_num = job.file_num() - 1;
        handler.job_progress(job.id(), file_num, speed, job.finished_size() as f64);
    }

    fn update_jobs_status(&mut self) {
        let elapsed = self.last_update_jobs_status.0.elapsed().as_millis() as i32;
        if elapsed >= 1000 {
            for job in self.read_jobs.iter() {
                Self::update_job_status(
                    job,
                    elapsed,
                    &mut self.last_update_jobs_status,
                    &self.handler,
                );
            }
            for job in self.write_jobs.iter() {
                Self::update_job_status(
                    job,
                    elapsed,
                    &mut self.last_update_jobs_status,
                    &mut self.handler,
                );
            }
            self.last_update_jobs_status.0 = Instant::now();
        }
    }

    async fn cancel_transfer_job(&mut self, id: i32, peer: &mut Stream) {
        let mut msg_out = Message::new();
        let mut file_action = FileAction::new();
        file_action.set_cancel(FileTransferCancel {
            id,
            ..Default::default()
        });
        msg_out.set_file_action(file_action);
        allow_err!(peer.send(&msg_out).await);
        if let Some(job) = fs::remove_job(id, &mut self.write_jobs) {
            job.remove_download_file();
        }
        let _ = fs::remove_job(id, &mut self.read_jobs);
        self.remove_jobs.remove(&id);
    }

    pub async fn sync_jobs_status_to_local(&mut self) -> bool {
        if !self.is_connected {
            return false;
        }
        let mut config: PeerConfig = self.handler.load_config();
        let mut transfer_metas = TransferSerde::default();
        for job in self.read_jobs.iter() {
            let json_str = serde_json::to_string(&job.gen_meta()).unwrap_or_default();
            transfer_metas.read_jobs.push(json_str);
        }
        for job in self.write_jobs.iter() {
            let json_str = serde_json::to_string(&job.gen_meta()).unwrap_or_default();
            transfer_metas.write_jobs.push(json_str);
        }
        log::info!("meta: {:?}", transfer_metas);
        if config.transfer != transfer_metas {
            config.transfer = transfer_metas;
            self.handler.save_config(config);
        }
        true
    }

    async fn send_toggle_virtual_display_msg(&self, peer: &mut Stream) {
        if !self.peer_info.is_support_virtual_display() {
            return;
        }
        let lc = self.handler.lc.read().unwrap();
        let displays = lc.get_option("virtual-display");
        for d in displays.split(',') {
            if let Ok(index) = d.parse::<i32>() {
                let mut misc = Misc::new();
                misc.set_toggle_virtual_display(ToggleVirtualDisplay {
                    display: index,
                    on: true,
                    ..Default::default()
                });
                let mut msg_out = Message::new();
                msg_out.set_misc(misc);
                allow_err!(peer.send(&msg_out).await);
            }
        }
    }

    async fn send_toggle_privacy_mode_msg(&self, peer: &mut Stream) {
        let lc = self.handler.lc.read().unwrap();
        if lc.version >= hbb_common::get_version_number("1.2.4")
            && lc.get_toggle_option("privacy-mode")
        {
            let impl_key = lc.get_option("privacy-mode-impl-key");
            if impl_key == crate::privacy_mode::PRIVACY_MODE_IMPL_WIN_VIRTUAL_DISPLAY
                && !self.peer_info.is_support_virtual_display()
            {
                return;
            }
            let mut misc = Misc::new();
            misc.set_toggle_privacy_mode(TogglePrivacyMode {
                impl_key,
                on: true,
                ..Default::default()
            });
            let mut msg_out = Message::new();
            msg_out.set_misc(misc);
            allow_err!(peer.send(&msg_out).await);
        }
    }

    fn contains_key_frame(vf: &VideoFrame) -> bool {
        use video_frame::Union::*;
        match &vf.union {
            Some(vf) => match vf {
                Vp8s(f) | Vp9s(f) | Av1s(f) | H264s(f) | H265s(f) => f.frames.iter().any(|e| e.key),
                _ => false,
            },
            None => false,
        }
    }

    // Currently, this function only considers decoding speed and queue length, not network delay.
    // The controlled end can consider auto fps as the maximum decoding fps.
    #[inline]
    fn fps_control(&mut self, direct: bool, real_fps_map: HashMap<usize, i32>) {
        let now = Instant::now();
        let log_summary = self
            .last_fps_control_summary_log
            .map(|last| now.saturating_duration_since(last) >= FPS_CONTROL_SUMMARY_LOG_INTERVAL)
            .unwrap_or(true);
        if log_summary {
            self.last_fps_control_summary_log = Some(now);
        }

        self.video_threads.iter_mut().for_each(|(k, v)| {
            let real_fps = real_fps_map.get(k).cloned().unwrap_or_default();
            if real_fps == 0 {
                v.fps_control.inactive_counter += 1;
            } else {
                v.fps_control.inactive_counter = 0;
            }
        });
        let fixed_fps = self
            .handler
            .lc
            .read()
            .unwrap()
            .get_option(config::keys::OPTION_CUSTOM_FPS_MODE)
            == "fixed";
        let custom_fps = self.handler.lc.read().unwrap().custom_fps.clone();
        let custom_fps = custom_fps.lock().unwrap().clone();
        let mut custom_fps = custom_fps.unwrap_or(30);
        if custom_fps < 5 || custom_fps > 120 {
            custom_fps = 30;
        }
        let inactive_threshold = 15;
        let max_queue_len = self
            .video_threads
            .iter()
            .map(|v| v.1.video_queue.read().unwrap().len())
            .max()
            .unwrap_or_default();
        let last_auto_fps = self.handler.lc.read().unwrap().last_auto_fps;
        let min_decode_fps = self
            .video_threads
            .iter()
            .filter(|v| v.1.fps_control.inactive_counter < inactive_threshold)
            .map(|v| *v.1.decode_fps.read().unwrap())
            .min()
            .flatten();
        let Some(min_decode_fps) = min_decode_fps else {
            if log_summary {
                let (decode_fps_by_display, queue_len_by_display, inactive_by_display) =
                    self.fps_control_snapshot();
                log::info!(
                    "diag fps control: id={}, mode={}, direct={}, codec={:?}, custom_fps={}, last_auto_fps={:?}, real_fps={:?}, decode_fps={:?}, queue_len={:?}, inactive={:?}, reason=no_active_decode_fps",
                    self.handler.get_id(),
                    if fixed_fps { "fixed" } else { "adaptive" },
                    direct,
                    self.video_format,
                    custom_fps,
                    last_auto_fps,
                    real_fps_map,
                    decode_fps_by_display,
                    queue_len_by_display,
                    inactive_by_display
                );
            }
            return;
        };
        if fixed_fps {
            if log_summary {
                let (decode_fps_by_display, queue_len_by_display, inactive_by_display) =
                    self.fps_control_snapshot();
                log::info!(
                    "diag fps control: id={}, mode=fixed, direct={}, codec={:?}, custom_fps={}, last_auto_fps={:?}, real_fps={:?}, decode_fps={:?}, min_decode_fps={}, max_queue_len={}, queue_len={:?}, inactive={:?}",
                    self.handler.get_id(),
                    direct,
                    self.video_format,
                    custom_fps,
                    last_auto_fps,
                    real_fps_map,
                    decode_fps_by_display,
                    min_decode_fps,
                    max_queue_len,
                    queue_len_by_display,
                    inactive_by_display
                );
            }
        } else {
            let mut limited_fps = if direct {
                min_decode_fps * 9 / 10 // 30 got 27
            } else {
                min_decode_fps * 4 / 5 // 30 got 24
            };
            if limited_fps > custom_fps {
                limited_fps = custom_fps;
            }
            let displays = self.video_threads.keys().cloned().collect::<Vec<_>>();
            let mut fps_trending = |display: usize| {
                let thread = self.video_threads.get_mut(&display)?;
                let ctl = &mut thread.fps_control;
                let len = thread.video_queue.read().unwrap().len();
                let decode_fps = thread.decode_fps.read().unwrap().clone()?;
                let last_auto_fps = last_auto_fps.unwrap_or(custom_fps as _);
                if ctl.inactive_counter > inactive_threshold {
                    return None;
                }
                if len > 1 && last_auto_fps > limited_fps || len > std::cmp::max(1, decode_fps / 2)
                {
                    ctl.idle_counter = 0;
                    return Some(false);
                }
                if len <= 1 {
                    ctl.idle_counter += 1;
                    if ctl.idle_counter > 3 && last_auto_fps + 3 <= custom_fps {
                        return Some(true);
                    }
                }
                if len > 1 {
                    ctl.idle_counter = 0;
                }
                None
            };
            let trendings: Vec<_> = displays.iter().map(|k| fps_trending(*k)).collect();
            let should_decrease = trendings.iter().any(|v| *v == Some(false));
            let should_increase = !should_decrease && trendings.iter().any(|v| *v == Some(true));
            // limited_fps is a conservative steady-state estimate. If the decode queue stays
            // empty, probe above it so a low current decode rate does not become a permanent cap.
            let auto_fps = next_adaptive_auto_fps(
                custom_fps,
                last_auto_fps,
                limited_fps,
                max_queue_len,
                should_decrease,
                should_increase,
            );
            let should_send_auto_fps =
                (last_auto_fps.is_none() || should_decrease || should_increase)
                    && Some(auto_fps) != last_auto_fps;
            if log_summary || should_send_auto_fps {
                let (decode_fps_by_display, queue_len_by_display, inactive_by_display) =
                    self.fps_control_snapshot();
                if log_summary {
                    log::info!(
                        "diag fps control: id={}, mode=adaptive, direct={}, codec={:?}, custom_fps={}, last_auto_fps={:?}, real_fps={:?}, decode_fps={:?}, min_decode_fps={}, limited_fps={}, max_queue_len={}, queue_len={:?}, inactive={:?}, trendings={:?}, decrease={}, increase={}",
                        self.handler.get_id(),
                        direct,
                        self.video_format,
                        custom_fps,
                        last_auto_fps,
                        real_fps_map,
                        decode_fps_by_display,
                        min_decode_fps,
                        limited_fps,
                        max_queue_len,
                        queue_len_by_display,
                        inactive_by_display,
                        trendings,
                        should_decrease,
                        should_increase
                    );
                }
                if should_send_auto_fps {
                    let msg = auto_adjust_fps_msg(auto_fps);
                    self.sender.send(Data::Message(msg)).ok();
                    log::info!(
                        "diag fps control set_auto_fps: id={}, auto_fps={}, previous_auto_fps={:?}, direct={}, codec={:?}, custom_fps={}, min_decode_fps={}, limited_fps={}, max_queue_len={}, real_fps={:?}, decode_fps={:?}, queue_len={:?}, inactive={:?}, trendings={:?}, decrease={}, increase={}",
                        self.handler.get_id(),
                        auto_fps,
                        last_auto_fps,
                        direct,
                        self.video_format,
                        custom_fps,
                        min_decode_fps,
                        limited_fps,
                        max_queue_len,
                        real_fps_map,
                        decode_fps_by_display,
                        queue_len_by_display,
                        inactive_by_display,
                        trendings,
                        should_decrease,
                        should_increase
                    );
                    self.handler.lc.write().unwrap().last_auto_fps = Some(auto_fps);
                }
            }
        }
        // send refresh
        for (display, thread) in self.video_threads.iter_mut() {
            let ctl = &mut thread.fps_control;
            let video_queue = thread.video_queue.read().unwrap();
            let tolerable = std::cmp::min(min_decode_fps, video_queue.capacity() / 2);
            if ctl.refresh_times < 20 // enough
                    && (video_queue.len() > tolerable
                            && (ctl.refresh_times == 0 || ctl.last_refresh_instant.map(|t|t.elapsed().as_secs() > 10).unwrap_or(false)))
            {
                // Refresh causes client set_display, left frames cause flickering.
                drop(video_queue);
                self.handler.refresh_video(*display as _);
                log::info!("Refresh display {} to reduce delay", display);
                ctl.refresh_times += 1;
                ctl.last_refresh_instant = Some(Instant::now());
            }
        }
    }

    fn fps_control_snapshot(
        &self,
    ) -> (
        Vec<(usize, usize)>,
        Vec<(usize, usize)>,
        Vec<(usize, usize)>,
    ) {
        let decode_fps_by_display = self
            .video_threads
            .iter()
            .filter_map(|(display, thread)| {
                thread
                    .decode_fps
                    .read()
                    .unwrap()
                    .map(|decode_fps| (*display, decode_fps))
            })
            .collect::<Vec<_>>();
        let queue_len_by_display = self
            .video_threads
            .iter()
            .map(|(display, thread)| (*display, thread.video_queue.read().unwrap().len()))
            .collect::<Vec<_>>();
        let inactive_by_display = self
            .video_threads
            .iter()
            .map(|(display, thread)| (*display, thread.fps_control.inactive_counter))
            .collect::<Vec<_>>();
        (
            decode_fps_by_display,
            queue_len_by_display,
            inactive_by_display,
        )
    }

    fn check_view_camera_support(&self, peer_version: &str, peer_platform: &str) -> bool {
        if self.peer_info.support_view_camera {
            return true;
        }
        if hbb_common::get_version_number(&peer_version) < hbb_common::get_version_number("1.3.9")
            && (peer_platform == "Windows" || peer_platform == "Linux")
        {
            self.handler.msgbox(
                "error",
                "Download new version",
                "upgrade_remote_rustdesk_client_to_{1.3.9}_tip",
                "",
            );
        } else {
            self.handler.on_error("view_camera_unsupported_tip");
        }
        return false;
    }

    fn check_terminal_support(&self, peer_version: &str) -> bool {
        if self.peer_info.support_terminal {
            return true;
        }
        if hbb_common::get_version_number(&peer_version) < hbb_common::get_version_number("1.4.1") {
            self.handler.msgbox(
                "error",
                "Remote terminal not supported",
                "Remote terminal is not supported by the remote side. Please upgrade to version 1.4.1 or higher.",
                "",
            );
        } else {
            self.handler
                .on_error("Remote terminal is not supported by the remote side");
        }
        return false;
    }

    async fn handle_video_frame_from_peer(
        &mut self,
        vf: VideoFrame,
        received_bytes: usize,
        peer: &mut Stream,
    ) -> bool {
        let (payload_bytes, frame_count, has_keyframe) =
            scrap::codec::video_frame_payload_stats(&vf).unwrap_or((0, 0, false));
        let display_i32 = vf.display;
        let display = display_i32.max(0) as usize;
        let frame_id = vf.frame_id;
        let mut keyframe_request_reason = self
            .video_receiver_stats
            .entry(display)
            .or_default()
            .record_frame_received(
                &vf,
                if payload_bytes == 0 {
                    received_bytes
                } else {
                    payload_bytes
                },
                frame_count,
                has_keyframe,
                Instant::now(),
            );

        let ack = video_received_msg(&vf);
        if let Err(err) = peer.send(&ack).await {
            log::warn!(
                "diag client video ack send failed: id={}, display={}, format={:?}, err={}",
                self.handler.get_id(),
                vf.display,
                CodecFormat::from(&vf),
                err
            );
            self.show_connection_error_with_state(format!("Video acknowledgement failed: {err}"));
            return false;
        }
        if !self.first_frame {
            log::info!(
                "diag first video frame received from stream: display={}, frame_id={}, format={:?}, payload_bytes={}, frame_count={}, keyframe={}",
                vf.display,
                vf.frame_id,
                CodecFormat::from(&vf),
                payload_bytes,
                frame_count,
                has_keyframe
            );
            self.first_frame = true;
            self.handler.close_success();
            self.handler.adapt_size();
            self.send_toggle_virtual_display_msg(peer).await;
            self.send_toggle_privacy_mode_msg(peer).await;
        }
        self.video_format = CodecFormat::from(&vf);

        if !self.video_threads.contains_key(&display) {
            self.new_video_thread(display);
        }
        let Some(thread) = self.video_threads.get_mut(&display) else {
            return true;
        };
        if Self::contains_key_frame(&vf) {
            thread
                .video_sender
                .send(MediaData::VideoFrame(Box::new(vf)))
                .ok();
        } else {
            let video_queue = thread.video_queue.read().unwrap();
            if video_queue.force_push(vf).is_some() {
                drop(video_queue);
                if let Some(stats) = self.video_receiver_stats.get_mut(&display) {
                    stats.record_queue_drop();
                }
                keyframe_request_reason =
                    keyframe_request_reason.or(Some(VIDEO_KEYFRAME_REASON_QUEUE_DROP));
                self.handler.refresh_video(display as _);
            } else {
                thread.video_sender.send(MediaData::VideoQueue).ok();
            }
        }
        if let Some(reason) = keyframe_request_reason {
            self.send_video_keyframe_request(peer, display_i32, frame_id, reason)
                .await;
        }
        true
    }

    async fn handle_msg_from_peer(&mut self, data: &[u8], peer: &mut Stream) -> bool {
        let msg_in = match Message::parse_from_bytes(data) {
            Ok(msg) => msg,
            Err(err) => {
                log::warn!(
                    "diag client invalid peer message: id={}, bytes={}, is_connected={}, video_packet_seen={}, video_format={:?}, err={}",
                    self.handler.get_id(),
                    data.len(),
                    self.is_connected,
                    self.first_frame,
                    self.video_format,
                    err
                );
                self.show_connection_error_with_state(format!(
                    "Invalid peer message received: bytes={}, error={err}",
                    data.len()
                ));
                return false;
            }
        };
        {
            match msg_in.union {
                Some(message::Union::VideoFrame(vf)) => {
                    if !self
                        .handle_video_frame_from_peer(vf, data.len(), peer)
                        .await
                    {
                        return false;
                    }
                }
                Some(message::Union::VideoFrameChunk(chunk)) => {
                    let display = chunk.display;
                    let frame_id = chunk.frame_id;
                    let chunk_index = chunk.chunk_index;
                    let chunk_count = chunk.chunk_count;
                    let chunk_len = chunk.data.len();
                    let original_size = chunk.original_size;
                    let chunk_number = chunk_index.saturating_add(1);
                    self.video_frame_chunks_seen = self.video_frame_chunks_seen.saturating_add(1);
                    self.video_receiver_stats
                        .entry(display.max(0) as usize)
                        .or_default()
                        .record_video_chunk(frame_id, chunk_len);
                    if !self.first_frame
                        && (self.video_frame_chunks_seen <= 8 || chunk_number == chunk_count)
                    {
                        log::info!(
                            "diag client video frame chunk received before first frame: id={}, display={}, frame_id={}, chunk={}/{}, bytes={}, original_size={}, total_chunks_seen={}",
                            self.handler.get_id(),
                            display,
                            frame_id,
                            chunk_number,
                            chunk_count,
                            chunk_len,
                            original_size,
                            self.video_frame_chunks_seen
                        );
                    }
                    match self.video_chunk_assembler.push(chunk) {
                        Ok(push) => {
                            if push.expired.has_expired() {
                                log::warn!(
                                    "diag client video frame chunks expired: id={}, display={}, last_frame_id={}, expired_frames={}, expired_chunks={}, total_chunks_seen={}",
                                    self.handler.get_id(),
                                    push.expired.last_display,
                                    push.expired.last_frame_id,
                                    push.expired.frames,
                                    push.expired.chunks,
                                    self.video_frame_chunks_seen
                                );
                                self.video_receiver_stats
                                    .entry(push.expired.last_display.max(0) as usize)
                                    .or_default()
                                    .record_video_chunk_expired(push.expired);
                                self.send_video_keyframe_request(
                                    peer,
                                    push.expired.last_display,
                                    push.expired.last_frame_id,
                                    VIDEO_KEYFRAME_REASON_FRAME_GAP,
                                )
                                .await;
                            }
                            let Some((vf, received_bytes)) = push.frame else {
                                return true;
                            };
                            self.video_receiver_stats
                                .entry(display.max(0) as usize)
                                .or_default()
                                .record_video_chunk_reassembled();
                            log::info!(
                                "diag client video frame chunks reassembled: id={}, display={}, frame_id={}, received_bytes={}, total_chunks_seen={}",
                                self.handler.get_id(),
                                display,
                                frame_id,
                                received_bytes,
                                self.video_frame_chunks_seen
                            );
                            if !self
                                .handle_video_frame_from_peer(vf, received_bytes, peer)
                                .await
                            {
                                return false;
                            }
                        }
                        Err(err) => {
                            log::warn!(
                                "diag client video frame chunk rejected: id={}, display={}, frame_id={}, err={}",
                                self.handler.get_id(),
                                display,
                                frame_id,
                                err
                            );
                            self.send_video_keyframe_request(
                                peer,
                                display,
                                frame_id,
                                VIDEO_KEYFRAME_REASON_FRAME_GAP,
                            )
                            .await;
                        }
                    }
                }
                Some(message::Union::Hash(hash)) => {
                    self.handler
                        .handle_hash(&self.handler.password.clone(), hash, peer)
                        .await;
                }
                Some(message::Union::LoginResponse(lr)) => match lr.union {
                    Some(login_response::Union::Error(err)) => {
                        if err == client::REQUIRE_2FA {
                            self.handler.lc.write().unwrap().enable_trusted_devices =
                                lr.enable_trusted_devices;
                        }
                        if !self.handler.handle_login_error(&err) {
                            return false;
                        }
                    }
                    Some(login_response::Union::PeerInfo(pi)) => {
                        let peer_version = pi.version.clone();
                        let peer_platform = pi.platform.clone();
                        self.set_peer_info(&pi);
                        if self.handler.is_view_camera() {
                            if !self.check_view_camera_support(&peer_version, &peer_platform) {
                                self.handler.lc.write().unwrap().handle_peer_info(&pi);
                                return false;
                            }
                        }
                        if self.handler.is_terminal() {
                            if !self.check_terminal_support(&peer_version) {
                                self.handler.lc.write().unwrap().handle_peer_info(&pi);
                                return false;
                            }
                        }
                        self.handler.handle_peer_info(pi);
                        #[cfg(all(target_os = "windows", not(feature = "flutter")))]
                        self.check_clipboard_file_context();
                        if self.handler.is_default() {
                            #[cfg(feature = "flutter")]
                            #[cfg(not(target_os = "ios"))]
                            let rx = Client::try_start_clipboard(None);
                            #[cfg(not(feature = "flutter"))]
                            #[cfg(not(any(target_os = "android", target_os = "ios")))]
                            let rx = Client::try_start_clipboard(Some(
                                crate::client::ClientClipboardContext {
                                    cfg: self.handler.get_permission_config(),
                                    tx: self.sender.clone(),
                                    #[cfg(feature = "unix-file-copy-paste")]
                                    is_file_supported: crate::is_support_file_copy_paste(
                                        &peer_version,
                                    ),
                                },
                            ));
                            // To make sure current text clipboard data is updated.
                            #[cfg(not(target_os = "ios"))]
                            if let Some(mut rx) = rx {
                                timeout(CLIPBOARD_INTERVAL, rx.recv()).await.ok();
                            }

                            #[cfg(not(any(target_os = "android", target_os = "ios")))]
                            if self.handler.lc.read().unwrap().sync_init_clipboard.v
                                && self
                                    .handler
                                    .get_permission_config()
                                    .is_text_clipboard_required()
                            {
                                if let Some(msg_out) = crate::clipboard::get_current_clipboard_msg(
                                    &peer_version,
                                    &peer_platform,
                                    crate::clipboard::ClipboardSide::Client,
                                ) {
                                    let sender = self.sender.clone();
                                    tokio::spawn(async move {
                                        sender.send(Data::Message(msg_out)).ok();
                                    });
                                }
                            }
                            // to-do: Android, is `sync_init_clipboard` really needed?
                            // https://github.com/rustdesk/rustdesk/discussions/9010

                            #[cfg(feature = "flutter")]
                            #[cfg(not(target_os = "ios"))]
                            crate::flutter::update_text_clipboard_required();

                            #[cfg(all(feature = "flutter", feature = "unix-file-copy-paste"))]
                            crate::flutter::update_file_clipboard_required();

                            // on connection established client
                            #[cfg(all(feature = "flutter", feature = "plugin_framework"))]
                            #[cfg(not(any(target_os = "android", target_os = "ios")))]
                            crate::plugin::handle_listen_event(
                                crate::plugin::EVENT_ON_CONN_CLIENT.to_owned(),
                                self.handler.get_id(),
                            );
                        }

                        if self.handler.is_file_transfer() {
                            self.handler.load_last_jobs();
                        }

                        self.is_connected = true;
                    }
                    _ => {}
                },
                Some(message::Union::CursorData(cd)) => {
                    self.handler.set_cursor_data(cd);
                }
                Some(message::Union::CursorId(id)) => {
                    self.handler.set_cursor_id(id.to_string());
                }
                Some(message::Union::CursorPosition(cp)) => {
                    self.handler.set_cursor_position(cp);
                }
                Some(message::Union::Clipboard(cb)) => {
                    #[cfg(not(any(target_os = "android", target_os = "ios")))]
                    {
                        let clipboard_policy =
                            self.handler.lc.read().unwrap().clipboard_direction_policy();
                        if clipboard_policy.allows_remote_to_local()
                            && !self.handler.lc.read().unwrap().disable_clipboard.v
                        {
                            update_clipboard_with_direction(
                                vec![cb],
                                ClipboardSide::Client,
                                clipboard_policy,
                            );
                        }
                    }
                    #[cfg(target_os = "ios")]
                    if !self.handler.lc.read().unwrap().disable_clipboard.v {
                        {
                            let content = if cb.compress {
                                hbb_common::compress::decompress(&cb.content)
                            } else {
                                cb.content.into()
                            };
                            if let Ok(content) = String::from_utf8(content) {
                                self.handler.clipboard(content);
                            }
                        }
                    }
                    #[cfg(target_os = "android")]
                    if !self.handler.lc.read().unwrap().disable_clipboard.v {
                        crate::clipboard::handle_msg_clipboard(cb);
                    }
                }
                Some(message::Union::MultiClipboards(_mcb)) => {
                    #[cfg(not(any(target_os = "android", target_os = "ios")))]
                    {
                        let clipboard_policy =
                            self.handler.lc.read().unwrap().clipboard_direction_policy();
                        if clipboard_policy.allows_remote_to_local()
                            && !self.handler.lc.read().unwrap().disable_clipboard.v
                        {
                            update_clipboard_with_direction(
                                _mcb.clipboards,
                                ClipboardSide::Client,
                                clipboard_policy,
                            );
                        }
                    }
                    #[cfg(target_os = "android")]
                    if !self.handler.lc.read().unwrap().disable_clipboard.v {
                        crate::clipboard::handle_msg_multi_clipboards(_mcb);
                    }
                }
                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                Some(message::Union::Cliprdr(clip)) => {
                    self.handle_cliprdr_msg(clip, peer).await;
                }
                Some(message::Union::FileResponse(fr)) => {
                    match fr.union {
                        Some(file_response::Union::EmptyDirs(res)) => {
                            self.handler.update_empty_dirs(res);
                        }
                        Some(file_response::Union::Dir(fd)) => {
                            #[cfg(windows)]
                            let entries = fd.entries.to_vec();
                            #[cfg(not(windows))]
                            let mut entries = fd.entries.to_vec();
                            #[cfg(not(windows))]
                            {
                                if self.handler.peer_platform() == "Windows" {
                                    fs::transform_windows_path(&mut entries);
                                }
                            }
                            // We cannot call cancel_transfer_job/handle_job_status while holding
                            // a mutable borrow from fs::get_job(&mut self.write_jobs), so defer
                            // the error handling until after the borrow scope ends.
                            let mut set_files_err = None;
                            if let Some(job) = fs::get_job(fd.id, &mut self.write_jobs) {
                                log::info!("job set_files: {:?}", entries);
                                if let Err(err) = job.set_files(entries) {
                                    set_files_err = Some(err.to_string());
                                } else {
                                    job.set_finished_size_on_resume();
                                    self.handler.update_folder_files(
                                        fd.id,
                                        job.files(),
                                        fd.path,
                                        false,
                                        false,
                                    );
                                }
                            } else if let Some(job) = self.remove_jobs.get_mut(&fd.id) {
                                // Intentionally keep raw entries here:
                                // - remote remove flow executes deletions on peer side;
                                // - local remove flow is populated from local get_recursive_files().
                                job.files = entries;
                                self.handler
                                    .update_folder_files(fd.id, &job.files, fd.path, false, false);
                            } else {
                                self.handler
                                    .update_folder_files(fd.id, &entries, fd.path, false, false);
                            }
                            if let Some(err) = set_files_err {
                                log::warn!(
                                    "Rejected unsafe file list from remote peer for job {}: {}",
                                    fd.id,
                                    err
                                );
                                self.cancel_transfer_job(fd.id, peer).await;
                                self.handle_job_status(fd.id, -1, Some(err));
                            }
                        }
                        Some(file_response::Union::Digest(digest)) => {
                            if digest.is_upload {
                                if let Some(job) = fs::get_job(digest.id, &mut self.read_jobs) {
                                    if let Some(file) = job.files().get(digest.file_num as usize) {
                                        if let fs::DataSource::FilePath(p) = &job.data_source {
                                            let read_path =
                                                get_string(&fs::TransferJob::join(p, &file.name));
                                            let mut overwrite_strategy =
                                                job.default_overwrite_strategy();
                                            let mut offset = 0;
                                            if digest.is_identical && job.is_resume {
                                                if digest.transferred_size > 0 {
                                                    overwrite_strategy = Some(true);
                                                    offset = digest.transferred_size as _;
                                                }
                                            }
                                            if let Some(overwrite) = overwrite_strategy {
                                                let req = FileTransferSendConfirmRequest {
                                                    id: digest.id,
                                                    file_num: digest.file_num,
                                                    union: Some(if overwrite {
                                                        file_transfer_send_confirm_request::Union::OffsetBlk(offset)
                                                    } else {
                                                        file_transfer_send_confirm_request::Union::Skip(
                                                            true,
                                                        )
                                                    }),
                                                    ..Default::default()
                                                };
                                                job.confirm(&req).await;
                                                let msg = new_send_confirm(req);
                                                allow_err!(peer.send(&msg).await);
                                            } else {
                                                self.handler.override_file_confirm(
                                                    digest.id,
                                                    digest.file_num,
                                                    read_path,
                                                    true,
                                                    digest.is_identical,
                                                );
                                            }
                                        }
                                    }
                                }
                            } else {
                                if let Some(job) = fs::get_job(digest.id, &mut self.write_jobs) {
                                    if let Some(file) = job.files().get(digest.file_num as usize) {
                                        if let fs::DataSource::FilePath(p) = &job.data_source {
                                            let write_path =
                                                get_string(&fs::TransferJob::join(p, &file.name));
                                            job.set_digest(digest.file_size, digest.last_modified);
                                            let peer_ver = self.handler.lc.read().unwrap().version;
                                            let is_support_resume =
                                                crate::is_support_file_transfer_resume_num(
                                                    peer_ver,
                                                );
                                            match fs::is_write_need_confirmation(
                                                is_support_resume && job.is_resume,
                                                &write_path,
                                                &digest,
                                            ) {
                                                Ok(res) => match res {
                                                    DigestCheckResult::IsSame => {
                                                        let req = FileTransferSendConfirmRequest {
                                                            id: digest.id,
                                                            file_num: digest.file_num,
                                                            union: Some(file_transfer_send_confirm_request::Union::Skip(true)),
                                                            ..Default::default()
                                                        };
                                                        job.confirm(&req).await;
                                                        let msg = new_send_confirm(req);
                                                        allow_err!(peer.send(&msg).await);
                                                    }
                                                    DigestCheckResult::NeedConfirm(digest) => {
                                                        let mut overwrite_strategy =
                                                            job.default_overwrite_strategy();
                                                        let mut offset = 0;
                                                        if digest.is_identical
                                                            && job.is_resume
                                                            && digest.transferred_size > 0
                                                        {
                                                            overwrite_strategy = Some(true);
                                                            offset = digest.transferred_size as _;
                                                        }
                                                        if let Some(overwrite) = overwrite_strategy
                                                        {
                                                            let req =
                                                                FileTransferSendConfirmRequest {
                                                                    id: digest.id,
                                                                    file_num: digest.file_num,
                                                                    union: Some(if overwrite {
                                                                        file_transfer_send_confirm_request::Union::OffsetBlk(offset)
                                                                    } else {
                                                                        file_transfer_send_confirm_request::Union::Skip(true)
                                                                    }),
                                                                    ..Default::default()
                                                                };
                                                            job.confirm(&req).await;
                                                            let msg = new_send_confirm(req);
                                                            allow_err!(peer.send(&msg).await);
                                                        } else {
                                                            self.handler.override_file_confirm(
                                                                digest.id,
                                                                digest.file_num,
                                                                write_path,
                                                                false,
                                                                digest.is_identical,
                                                            );
                                                        }
                                                    }
                                                    DigestCheckResult::NoSuchFile => {
                                                        let req = FileTransferSendConfirmRequest {
                                                        id: digest.id,
                                                        file_num: digest.file_num,
                                                        union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)),
                                                        ..Default::default()
                                                    };
                                                        job.confirm(&req).await;
                                                        let msg = new_send_confirm(req);
                                                        allow_err!(peer.send(&msg).await);
                                                    }
                                                },
                                                Err(err) => {
                                                    println!("error receiving digest: {}", err);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        Some(file_response::Union::Block(block)) => {
                            if let Some(job) = fs::get_job(block.id, &mut self.write_jobs) {
                                if let Err(_err) = job.write(block).await {
                                    // to-do: add "skip" for writing job
                                }
                                if job.r#type == fs::JobType::Generic {
                                    self.update_jobs_status();
                                }
                            }
                        }
                        Some(file_response::Union::Done(d)) => {
                            let mut err: Option<String> = None;
                            let mut job_type = fs::JobType::Generic;
                            let mut printer_data = None;
                            if let Some(job) = fs::remove_job(d.id, &mut self.write_jobs) {
                                job.modify_time();
                                err = job.job_error();
                                job_type = job.r#type;
                                printer_data = match job.get_buf_data().await {
                                    Ok(d) => d,
                                    Err(e) => {
                                        log::error!("Failed to get the printer data: {}", e);
                                        None
                                    }
                                };
                            }
                            match job_type {
                                fs::JobType::Generic => {
                                    self.handle_job_status(d.id, d.file_num, err);
                                }
                                fs::JobType::Printer => {
                                    if let Some(err) = err {
                                        log::error!("Receive print job failed, error {err}");
                                    } else {
                                        log::info!(
                                            "Receive print job done, data len: {:?}",
                                            printer_data.as_ref().map(|d| d.len()).unwrap_or(0)
                                        );
                                        #[cfg(target_os = "windows")]
                                        if let Some(data) = printer_data {
                                            let printer_name = self
                                                .handler
                                                .printer_names
                                                .write()
                                                .unwrap()
                                                .remove(&d.id);
                                            // Spawn a new thread to handle the print job.
                                            // Or print job will block the ui thread.
                                            std::thread::spawn(move || {
                                                if let Err(e) =
                                                    crate::platform::send_raw_data_to_printer(
                                                        printer_name,
                                                        data,
                                                    )
                                                {
                                                    log::error!("Print job error: {}", e);
                                                }
                                            });
                                        }
                                    }
                                }
                            }
                        }
                        Some(file_response::Union::Error(e)) => {
                            let job_type = fs::remove_job(e.id, &mut self.write_jobs)
                                .or_else(|| fs::remove_job(e.id, &mut self.read_jobs))
                                .map(|j| j.r#type)
                                .unwrap_or(fs::JobType::Generic);
                            match job_type {
                                fs::JobType::Generic => {
                                    self.handle_job_status(e.id, e.file_num, Some(e.error));
                                }
                                fs::JobType::Printer => {
                                    log::error!("Printer job error: {}", e.error);
                                }
                            }
                        }
                        _ => {}
                    }
                }
                Some(message::Union::Misc(misc)) => match misc.union {
                    Some(misc::Union::AudioFormat(f)) => {
                        self.audio_sender.send(MediaData::AudioFormat(f)).ok();
                    }
                    Some(misc::Union::ChatMessage(c)) => {
                        self.handler.new_message(c.text);
                    }
                    Some(misc::Union::DebugEvent(event)) => {
                        crate::clipboard::log_remote_debug_event(event);
                    }
                    Some(misc::Union::PermissionInfo(p)) => {
                        log::info!(
                            "Host permission update received: {:?} -> {}",
                            p.permission,
                            p.enabled
                        );
                        // https://github.com/rustdesk/rustdesk/issues/3703#issuecomment-1474734754
                        match p.permission.enum_value() {
                            Ok(Permission::Keyboard) => {
                                *self.handler.server_keyboard_enabled.write().unwrap() = p.enabled;
                                #[cfg(feature = "flutter")]
                                #[cfg(not(target_os = "ios"))]
                                crate::flutter::update_text_clipboard_required();
                                #[cfg(all(feature = "flutter", feature = "unix-file-copy-paste"))]
                                crate::flutter::update_file_clipboard_required();
                                self.handler.set_permission("keyboard", p.enabled);
                            }
                            Ok(Permission::Clipboard) => {
                                *self.handler.server_clipboard_enabled.write().unwrap() = p.enabled;
                                #[cfg(feature = "flutter")]
                                #[cfg(not(target_os = "ios"))]
                                crate::flutter::update_text_clipboard_required();
                                self.handler.set_permission("clipboard", p.enabled);
                            }
                            Ok(Permission::Audio) => {
                                self.handler.set_permission("audio", p.enabled);
                            }
                            Ok(Permission::File) => {
                                *self.handler.server_file_transfer_enabled.write().unwrap() =
                                    p.enabled;
                                if !p.enabled && self.handler.is_file_transfer() {
                                    return true;
                                }
                                #[cfg(all(feature = "flutter", feature = "unix-file-copy-paste"))]
                                crate::flutter::update_file_clipboard_required();
                                self.handler.set_permission("file", p.enabled);
                                #[cfg(feature = "unix-file-copy-paste")]
                                if !p.enabled {
                                    try_empty_clipboard_files(
                                        ClipboardSide::Client,
                                        self.client_conn_id,
                                    );
                                }
                            }
                            Ok(Permission::Restart) => {
                                self.handler.set_permission("restart", p.enabled);
                            }
                            Ok(Permission::Recording) => {
                                self.handler.lc.write().unwrap().record_permission = p.enabled;
                                self.update_record_state();
                                self.handler.set_permission("recording", p.enabled);
                            }
                            Ok(Permission::BlockInput) => {
                                self.handler.set_permission("block_input", p.enabled);
                            }
                            _ => {}
                        }
                    }
                    Some(misc::Union::SessionPermissionResponse(r)) => {
                        log::info!(
                            "Host permission request response: request_id={}, name={}, enabled={}, approved={}, reason={}",
                            r.request_id,
                            r.name,
                            r.enabled,
                            r.approved,
                            r.reason
                        );
                        if r.approved
                            && matches!(
                                r.name.as_str(),
                                "file_transfer" | "port_forward" | "view_camera" | "terminal"
                            )
                        {
                            self.handler.set_permission(&r.name, true);
                        }
                        let text = if r.approved {
                            if matches!(
                                r.name.as_str(),
                                "file_transfer" | "port_forward" | "view_camera" | "terminal"
                            ) {
                                "Permission approved. Open the requested tool again.".to_owned()
                            } else {
                                "Permission approved.".to_owned()
                            }
                        } else if r.reason.is_empty() {
                            "Permission request declined.".to_owned()
                        } else {
                            r.reason
                        };
                        let msgtype = session_permission_response_msgbox_type(r.approved);
                        self.handler
                            .msgbox(msgtype, "Permission request", &text, "");
                    }
                    Some(misc::Union::SwitchDisplay(s)) => {
                        self.handler.handle_peer_switch_display(&s);
                        if let Some(thread) = self.video_threads.get_mut(&(s.display as usize)) {
                            thread.video_sender.send(MediaData::Reset).ok();
                        }

                        let mut scale = 1.0;
                        if let Some(pi) = &self.handler.lc.read().unwrap().peer_info {
                            if let Some(d) = pi.displays.get(s.display as usize) {
                                scale = d.scale;
                            }
                        }

                        if s.width > 0 && s.height > 0 {
                            self.handler.set_display(
                                s.x,
                                s.y,
                                s.width,
                                s.height,
                                s.cursor_embedded,
                                scale,
                            );
                        }
                    }
                    Some(misc::Union::CloseReason(c)) => {
                        log::warn!(
                            "diag client received remote close reason: id={}, is_connected={}, video_packet_seen={}, video_format={:?}, reason={}",
                            self.handler.get_id(),
                            self.is_connected,
                            self.first_frame,
                            self.video_format,
                            c
                        );
                        self.sent_close_reason = true; // The controlled end will close, no need to send close reason
                        self.show_connection_error_with_state(c);
                        return false;
                    }
                    Some(misc::Union::BackNotification(notification)) => {
                        if !self.handle_back_notification(notification).await {
                            return false;
                        }
                    }
                    Some(misc::Union::Uac(uac)) => {
                        let keyboard = self.handler.server_keyboard_enabled.read().unwrap().clone();
                        #[cfg(feature = "flutter")]
                        {
                            if uac && keyboard {
                                self.handler.msgbox(
                                    "on-uac",
                                    "Prompt",
                                    "Please wait for confirmation of UAC...",
                                    "",
                                );
                            } else {
                                self.handler.cancel_msgbox("on-uac");
                                self.handler.cancel_msgbox("wait-uac");
                                self.handler.cancel_msgbox("elevation-error");
                            }
                        }
                        #[cfg(not(feature = "flutter"))]
                        {
                            let msgtype = "custom-uac-nocancel";
                            let title = "Prompt";
                            let text = "Please wait for confirmation of UAC...";
                            let link = "";
                            if uac && keyboard {
                                self.handler.msgbox(msgtype, title, text, link);
                            } else {
                                self.handler.cancel_msgbox(&format!(
                                    "{}-{}-{}-{}",
                                    msgtype, title, text, link,
                                ));
                            }
                        }
                    }
                    Some(misc::Union::ForegroundWindowElevated(elevated)) => {
                        let keyboard = self.handler.server_keyboard_enabled.read().unwrap().clone();
                        #[cfg(feature = "flutter")]
                        {
                            if elevated && keyboard {
                                self.handler.msgbox(
                                    "on-foreground-elevated",
                                    "Prompt",
                                    "elevated_foreground_window_tip",
                                    "",
                                );
                            } else {
                                self.handler.cancel_msgbox("on-foreground-elevated");
                                self.handler.cancel_msgbox("wait-uac");
                                self.handler.cancel_msgbox("elevation-error");
                            }
                        }
                        #[cfg(not(feature = "flutter"))]
                        {
                            let msgtype = "custom-elevated-foreground-nocancel";
                            let title = "Prompt";
                            let text = "elevated_foreground_window_tip";
                            let link = "";
                            if elevated && keyboard {
                                self.handler.msgbox(msgtype, title, text, link);
                            } else {
                                self.handler.cancel_msgbox(&format!(
                                    "{}-{}-{}-{}",
                                    msgtype, title, text, link,
                                ));
                            }
                        }
                    }
                    Some(misc::Union::ElevationResponse(err)) => {
                        if err.is_empty() {
                            self.handler.msgbox("wait-uac", "", "", "");
                        } else {
                            self.handler.cancel_msgbox("wait-uac");
                            self.handler
                                .msgbox("elevation-error", "Elevation Error", &err, "");
                        }
                    }
                    Some(misc::Union::PortableServiceRunning(b)) => {
                        self.handler.portable_service_running(b);
                        if self.elevation_requested && b {
                            self.handler.msgbox(
                                "custom-nocancel-success",
                                "Successful",
                                "Elevate successfully",
                                "",
                            );
                        }
                    }
                    #[cfg(feature = "flutter")]
                    #[cfg(not(any(target_os = "android", target_os = "ios")))]
                    Some(misc::Union::SwitchBack(_)) => {
                        let allow_switch_back = self
                            .handler
                            .lc
                            .write()
                            .unwrap()
                            .consume_switch_back_permission();
                        if allow_switch_back {
                            self.handler.switch_back(&self.handler.get_id());
                        } else {
                            log::warn!(
                                "Ignored unsolicited SwitchBack from {}",
                                self.handler.get_id()
                            );
                        }
                    }
                    #[cfg(all(feature = "flutter", feature = "plugin_framework"))]
                    #[cfg(not(any(target_os = "android", target_os = "ios")))]
                    Some(misc::Union::PluginRequest(p)) => {
                        allow_err!(crate::plugin::handle_server_event(
                            &p.id,
                            &self.handler.get_id(),
                            &p.content
                        ));
                        // to-do: show message box on UI when error occurs?
                    }
                    #[cfg(all(feature = "flutter", feature = "plugin_framework"))]
                    #[cfg(not(any(target_os = "android", target_os = "ios")))]
                    Some(misc::Union::PluginFailure(p)) => {
                        let name = if p.name.is_empty() {
                            "plugin".to_string()
                        } else {
                            p.name
                        };
                        self.handler.msgbox("custom-nocancel", &name, &p.msg, "");
                    }
                    Some(misc::Union::SupportedEncoding(e)) => {
                        log::info!("update supported encoding:{:?}", e);
                        self.handler.lc.write().unwrap().supported_encoding = e;
                    }
                    Some(misc::Union::FollowCurrentDisplay(d_idx)) => {
                        self.handler.set_current_display(d_idx);
                    }
                    _ => {}
                },
                Some(message::Union::TestDelay(t)) => {
                    self.handler.handle_test_delay(t, peer).await;
                }
                Some(message::Union::AudioFrame(frame)) => {
                    if !self.handler.lc.read().unwrap().disable_audio.v {
                        self.audio_sender
                            .send(MediaData::AudioFrame(Box::new(frame)))
                            .ok();
                    }
                }
                Some(message::Union::FileAction(action)) => match action.union {
                    Some(file_action::Union::Send(_s)) => match _s.file_type.enum_value() {
                        #[cfg(target_os = "windows")]
                        Ok(file_transfer_send_request::FileType::Printer) => {
                            #[cfg(feature = "flutter")]
                            let action = LocalConfig::get_option(
                                config::keys::OPTION_PRINTER_INCOMING_JOB_ACTION,
                            );
                            #[cfg(not(feature = "flutter"))]
                            let action = "";
                            if action == "dismiss" {
                                // Just ignore the incoming print job.
                            } else {
                                let id = fs::get_next_job_id();
                                #[cfg(feature = "flutter")]
                                let allow_auto_print = LocalConfig::get_bool_option(
                                    config::keys::OPTION_PRINTER_ALLOW_AUTO_PRINT,
                                );
                                #[cfg(not(feature = "flutter"))]
                                let allow_auto_print = false;
                                if allow_auto_print {
                                    let printer_name = if action == "" {
                                        "".to_string()
                                    } else {
                                        LocalConfig::get_option(
                                            config::keys::OPTION_PRINTER_SELECTED_NAME,
                                        )
                                    };
                                    self.handler.printer_response(id, _s.path, printer_name);
                                } else {
                                    self.handler.printer_request(id, _s.path);
                                }
                            }
                        }
                        _ => {}
                    },
                    Some(file_action::Union::SendConfirm(c)) => {
                        if let Some(job) = fs::get_job(c.id, &mut self.read_jobs) {
                            job.confirm(&c).await;
                        }
                    }
                    _ => {}
                },
                Some(message::Union::MessageBox(msgbox)) => {
                    let mut link = msgbox.link;
                    if let Some(v) = config::HELPER_URL.get(&link as &str) {
                        link = v.to_string();
                    } else {
                        log::warn!("Message box ignore link {} for security", &link);
                        link = "".to_string();
                    }
                    self.handler
                        .msgbox(&msgbox.msgtype, &msgbox.title, &msgbox.text, &link);
                }
                Some(message::Union::VoiceCallRequest(request)) => {
                    if request.is_connect {
                        // TODO: maybe we will do a voice call from the peer in the future.
                    } else {
                        log::debug!("The remote has requested to close the voice call");
                        if let Some(sender) = self.stop_voice_call_sender.take() {
                            allow_err!(sender.send(()));
                            self.handler.on_voice_call_closed("");
                        }
                    }
                }
                Some(message::Union::VoiceCallResponse(response)) => {
                    let ts = std::mem::replace(&mut self.voice_call_request_timestamp, None);
                    if let Some(ts) = ts {
                        if response.req_timestamp != ts.get() {
                            log::debug!("Possible encountering a voice call attack.");
                        } else {
                            if response.accepted {
                                // The peer accepted the voice call.
                                self.handler.on_voice_call_started();
                                self.stop_voice_call_sender = self.start_voice_call();
                            } else {
                                // The peer refused the voice call.
                                self.handler.on_voice_call_closed("");
                            }
                        }
                    }
                }
                Some(message::Union::PeerInfo(pi)) => {
                    self.handler.set_displays(&pi.displays);
                    self.handler.set_platform_additions(&pi.platform_additions);
                }
                Some(message::Union::ScreenshotResponse(response)) => {
                    crate::client::screenshot::set_screenshot(response.data);
                    self.handler
                        .handle_screenshot_resp(response.sid, response.msg);
                }
                Some(message::Union::TerminalResponse(response)) => {
                    use hbb_common::message_proto::terminal_response::Union;
                    if let Some(Union::Opened(opened)) = &response.union {
                        if opened.success && !opened.service_id.is_empty() {
                            let mut lc = self.handler.lc.write().unwrap();
                            let key = lc.get_key_terminal_service_id().to_owned();
                            lc.set_option(key, opened.service_id.clone());
                        }
                    }
                    self.handler.handle_terminal_response(response);
                }
                _ => {}
            }
        }
        true
    }

    fn set_peer_info(&mut self, pi: &PeerInfo) {
        self.peer_info.platform = pi.platform.clone();

        // Check features field for terminal support
        if let Some(features) = pi.features.as_ref() {
            self.peer_info.support_terminal = features.terminal;
        }

        if let Ok(platform_additions) =
            serde_json::from_str::<HashMap<String, serde_json::Value>>(&pi.platform_additions)
        {
            self.peer_info.is_installed = platform_additions
                .get("is_installed")
                .map(|v| v.as_bool())
                .flatten()
                .unwrap_or(false);
            self.peer_info.idd_impl = platform_additions
                .get("idd_impl")
                .map(|v| v.as_str())
                .flatten()
                .unwrap_or_default()
                .to_string();
            self.peer_info.support_view_camera = platform_additions
                .get("support_view_camera")
                .map(|v| v.as_bool())
                .flatten()
                .unwrap_or(false);
        }
    }

    async fn handle_back_notification(&mut self, notification: BackNotification) -> bool {
        match notification.union {
            Some(back_notification::Union::BlockInputState(state)) => {
                self.handle_back_msg_block_input(
                    state.enum_value_or(back_notification::BlockInputState::BlkStateUnknown),
                    notification.details,
                )
                .await;
            }
            Some(back_notification::Union::PrivacyModeState(state)) => {
                if !self
                    .handle_back_msg_privacy_mode(
                        state.enum_value_or(back_notification::PrivacyModeState::PrvStateUnknown),
                        notification.details,
                        notification.impl_key,
                    )
                    .await
                {
                    return false;
                }
            }
            _ => {}
        }
        true
    }

    #[inline(always)]
    fn update_block_input_state(&mut self, on: bool) {
        self.handler.update_block_input_state(on);
    }

    async fn handle_back_msg_block_input(
        &mut self,
        state: back_notification::BlockInputState,
        details: String,
    ) {
        match state {
            back_notification::BlockInputState::BlkOnSucceeded => {
                self.update_block_input_state(true);
            }
            back_notification::BlockInputState::BlkOnFailed => {
                self.handler.msgbox(
                    "custom-error",
                    "Block user input",
                    if details.is_empty() {
                        "Failed"
                    } else {
                        &details
                    },
                    "",
                );
                self.update_block_input_state(false);
            }
            back_notification::BlockInputState::BlkOffSucceeded => {
                self.update_block_input_state(false);
            }
            back_notification::BlockInputState::BlkOffFailed => {
                self.handler.msgbox(
                    "custom-error",
                    "Unblock user input",
                    if details.is_empty() {
                        "Failed"
                    } else {
                        &details
                    },
                    "",
                );
            }
            _ => {}
        }
    }

    #[inline(always)]
    fn update_privacy_mode(&mut self, impl_key: String, on: bool) {
        let mut config = self.handler.load_config();
        config.privacy_mode.v = on;
        if on {
            // For compatibility, version < 1.2.4, the default value is 'privacy_mode_impl_mag'.
            let impl_key = if impl_key.is_empty() {
                "privacy_mode_impl_mag".to_string()
            } else {
                impl_key
            };
            config
                .options
                .insert("privacy-mode-impl-key".to_string(), impl_key);
        }
        self.handler.save_config(config);

        self.handler.update_privacy_mode();
    }

    async fn handle_back_msg_privacy_mode(
        &mut self,
        state: back_notification::PrivacyModeState,
        details: String,
        impl_key: String,
    ) -> bool {
        match state {
            back_notification::PrivacyModeState::PrvOnByOther => {
                self.handler.msgbox(
                    "error",
                    "Connecting...",
                    "Someone turns on privacy mode, exit",
                    "",
                );
                return false;
            }
            back_notification::PrivacyModeState::PrvNotSupported => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Unsupported", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOnSucceeded => {
                self.handler
                    .msgbox("custom-nocancel", "Privacy mode", "Enter privacy mode", "");
                self.update_privacy_mode(impl_key, true);
            }
            back_notification::PrivacyModeState::PrvOnFailedDenied => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Peer denied", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOnFailedPlugin => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Please install plugins", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOnFailed => {
                self.handler.msgbox(
                    "custom-error",
                    "Privacy mode",
                    if details.is_empty() {
                        "Failed"
                    } else {
                        &details
                    },
                    "",
                );
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOffSucceeded => {
                self.handler
                    .msgbox("custom-nocancel", "Privacy mode", "Exit privacy mode", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOffByPeer => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Peer exit", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOffFailed => {
                self.handler.msgbox(
                    "custom-error",
                    "Privacy mode",
                    if details.is_empty() {
                        "Failed to turn off"
                    } else {
                        &details
                    },
                    "",
                );
            }
            back_notification::PrivacyModeState::PrvOffUnknown => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Turned off", "");
                // log::error!("Privacy mode is turned off with unknown reason");
                self.update_privacy_mode(impl_key, false);
            }
            _ => {}
        }
        true
    }

    #[cfg(all(target_os = "windows", not(feature = "flutter")))]
    fn check_clipboard_file_context(&self) {
        let enabled = *self.handler.server_file_transfer_enabled.read().unwrap()
            && self.handler.lc.read().unwrap().enable_file_copy_paste.v;
        ContextSend::enable(enabled);
    }

    #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
    async fn handle_cliprdr_msg(
        &mut self,
        clip: hbb_common::message_proto::Cliprdr,
        _peer: &mut Stream,
    ) {
        log::debug!("handling cliprdr msg from server peer");
        #[cfg(feature = "flutter")]
        if let Some(hbb_common::message_proto::cliprdr::Union::FormatList(_)) = &clip.union {
            if self.client_conn_id
                != clipboard::get_client_conn_id(&crate::flutter::get_cur_peer_id()).unwrap_or(0)
            {
                return;
            }
        }

        let Some(clip) = crate::clipboard_file::msg_2_clip(clip) else {
            log::warn!("failed to decode cliprdr msg from server peer");
            return;
        };

        let is_stopping_allowed = clip.is_beginning_message();
        let file_transfer_enabled = self.handler.is_file_clipboard_required();
        let stop = is_stopping_allowed && !file_transfer_enabled;
        log::debug!(
                "Process clipboard message from server peer, stop: {}, is_stopping_allowed: {}, file_transfer_enabled: {}",
                stop, is_stopping_allowed, file_transfer_enabled);
        if !stop {
            #[cfg(any(
                target_os = "windows",
                all(target_os = "macos", feature = "unix-file-copy-paste")
            ))]
            if let Err(e) = ContextSend::make_sure_enabled() {
                log::error!("failed to restart clipboard context: {}", e);
            };
            #[cfg(target_os = "windows")]
            {
                let _ = ContextSend::proc(|context| -> ResultType<()> {
                    context
                        .server_clip_file(self.client_conn_id, clip)
                        .map_err(|e| e.into())
                });
            }
            #[cfg(feature = "unix-file-copy-paste")]
            if crate::is_support_file_copy_paste_num(self.handler.lc.read().unwrap().version) {
                let mut out_msgs = vec![];

                #[cfg(target_os = "macos")]
                if clipboard::platform::unix::macos::should_handle_msg(&clip) {
                    if let Err(e) = ContextSend::proc(|context| -> ResultType<()> {
                        context
                            .server_clip_file(self.client_conn_id, clip)
                            .map_err(|e| e.into())
                    }) {
                        log::error!("failed to handle cliprdr msg: {}", e);
                    }
                } else {
                    out_msgs = unix_file_clip::serve_clip_messages(
                        ClipboardSide::Client,
                        clip,
                        self.client_conn_id,
                    );
                }

                #[cfg(not(target_os = "macos"))]
                {
                    out_msgs = unix_file_clip::serve_clip_messages(
                        ClipboardSide::Client,
                        clip,
                        self.client_conn_id,
                    );
                }

                for msg in out_msgs.into_iter() {
                    allow_err!(_peer.send(&msg).await);
                }
            }
        }
    }

    fn new_video_thread(&mut self, display: usize) {
        let video_queue = Arc::new(RwLock::new(ArrayQueue::new(client::VIDEO_QUEUE_SIZE)));
        let (video_sender, video_receiver) = std::sync::mpsc::channel::<MediaData>();
        let decode_fps = Arc::new(RwLock::new(None));
        let frame_count = Arc::new(RwLock::new(0));
        let discard_queue = Arc::new(RwLock::new(false));
        let stats = Arc::new(client::VideoThreadStats::default());
        let video_thread = VideoThread {
            video_queue: video_queue.clone(),
            video_sender,
            decode_fps: decode_fps.clone(),
            frame_count: frame_count.clone(),
            fps_control: Default::default(),
            discard_queue: discard_queue.clone(),
            stats: stats.clone(),
        };
        let handler = self.handler.ui_handler.clone();
        crate::client::start_video_thread(
            self.handler.clone(),
            display,
            video_receiver,
            video_queue,
            decode_fps,
            self.chroma.clone(),
            discard_queue,
            stats,
            move |display: usize,
                  data: &mut scrap::ImageRgb,
                  _texture: *mut c_void,
                  pixelbuffer: bool| {
                *frame_count.write().unwrap() += 1;
                if pixelbuffer {
                    handler.on_rgba(display, data);
                } else {
                    #[cfg(all(feature = "vram", feature = "flutter"))]
                    handler.on_texture(display, _texture);
                }
            },
        );
        self.video_threads.insert(display, video_thread);
        if self.video_threads.len() == 1 {
            let auto_record =
                LocalConfig::get_bool_option(config::keys::OPTION_ALLOW_AUTO_RECORD_OUTGOING);
            self.handler.lc.write().unwrap().record_state = auto_record;
            self.update_record_state();
        }
    }

    fn update_record_state(&mut self) {
        // state
        let permission = self.handler.lc.read().unwrap().record_permission;
        if !permission {
            self.handler.lc.write().unwrap().record_state = false;
        }
        let state = self.handler.lc.read().unwrap().record_state;
        let start = state && permission;
        if self.last_record_state == start {
            return;
        }
        self.last_record_state = start;
        log::info!("record screen start: {start}");
        // update local
        for (_, v) in self.video_threads.iter_mut() {
            v.video_sender.send(MediaData::RecordScreen(start)).ok();
        }
        self.handler.update_record_status(start);
        // update remote
        let mut misc = Misc::new();
        misc.set_client_record_status(start);
        let mut msg = Message::new();
        msg.set_misc(misc);
        self.sender.send(Data::Message(msg)).ok();
    }
}

struct RemoveJob {
    files: Vec<FileEntry>,
    path: String,
    sep: &'static str,
    is_remote: bool,
    no_confirm: bool,
    last_update_job_status: Instant,
}

impl RemoveJob {
    fn new(files: Vec<FileEntry>, path: String, sep: &'static str, is_remote: bool) -> Self {
        Self {
            files,
            path,
            sep,
            is_remote,
            no_confirm: false,
            last_update_job_status: Instant::now(),
        }
    }

    pub fn _gen_meta(&self) -> RemoveJobMeta {
        RemoveJobMeta {
            path: self.path.clone(),
            is_remote: self.is_remote,
            no_confirm: self.no_confirm,
        }
    }
}

#[derive(Debug, Default)]
struct FpsControl {
    refresh_times: usize,
    last_refresh_instant: Option<Instant>,
    idle_counter: usize,
    inactive_counter: usize,
}

struct VideoThread {
    video_queue: Arc<RwLock<ArrayQueue<VideoFrame>>>,
    video_sender: MediaSender,
    decode_fps: Arc<RwLock<Option<usize>>>,
    frame_count: Arc<RwLock<usize>>,
    discard_queue: Arc<RwLock<bool>>,
    fps_control: FpsControl,
    stats: Arc<client::VideoThreadStats>,
}

impl Drop for VideoThread {
    fn drop(&mut self) {
        // since channels are buffered, messages sent before the disconnect will still be properly received.
        *self.discard_queue.write().unwrap() = true;
    }
}

#[cfg(test)]
mod tests {
    use super::{
        auto_adjust_fps_msg, next_adaptive_auto_fps, next_no_video_startup_fallback_codec,
        session_permission_response_msgbox_type, video_keyframe_request_msg, video_received_msg,
        NoVideoStartupAction, NoVideoStartupWatchdog, VideoFrameChunkAssembler,
        VideoReceiverStatsTracker, NO_VIDEO_START_FALLBACK_INTERVAL, NO_VIDEO_START_MAX_FALLBACKS,
        NO_VIDEO_START_TIMEOUT, VIDEO_FRAME_CHUNK_MAX_ORIGINAL_SIZE,
        VIDEO_FRAME_CHUNK_REASSEMBLY_TIMEOUT, VIDEO_KEYFRAME_REASON_FRAME_GAP,
    };
    use hbb_common::{
        bytes::{Bytes, BytesMut},
        bytes_codec::BytesCodec,
        message_proto::{
            message, misc, supported_decoding::PreferCodec, SupportedDecoding, SupportedEncoding,
            VideoFrame, VideoFrameChunk,
        },
        protobuf::Message as _,
        tokio::time::{Duration, Instant},
        tokio_util::codec::{Decoder, Encoder},
    };
    use scrap::CodecFormat;

    fn decoding(prefer: PreferCodec) -> SupportedDecoding {
        SupportedDecoding {
            ability_vp8: 1,
            ability_vp9: 1,
            ability_av1: 1,
            ability_h264: 1,
            ability_h265: 1,
            prefer: prefer.into(),
            ..Default::default()
        }
    }

    fn encoding() -> SupportedEncoding {
        SupportedEncoding {
            vp8: true,
            av1: true,
            av1_vulkan: true,
            h264: true,
            h265: true,
            ..Default::default()
        }
    }

    #[test]
    fn permission_response_dialogs_do_not_close_session_on_ok() {
        assert!(session_permission_response_msgbox_type(true).contains("custom"));
        assert!(session_permission_response_msgbox_type(false).contains("custom"));
    }

    #[test]
    fn video_received_ack_preserves_legacy_bool_and_frame_metadata() {
        let vf = VideoFrame {
            display: 3,
            frame_id: 42,
            ..Default::default()
        };
        let ack = video_received_msg(&vf);

        let Some(message::Union::Misc(misc)) = ack.union else {
            panic!("expected misc ack");
        };
        assert!(matches!(misc.union, Some(misc::Union::VideoReceived(true))));
        assert_eq!(misc.video_ack_frame_id, 42);
        assert_eq!(misc.video_ack_display, 3);
    }

    #[test]
    fn video_keyframe_request_preserves_display_frame_and_reason() {
        let msg = video_keyframe_request_msg(2, 77, VIDEO_KEYFRAME_REASON_FRAME_GAP);

        let Some(message::Union::Misc(misc)) = msg.union else {
            panic!("expected misc keyframe request");
        };
        let Some(misc::Union::VideoKeyframeRequest(request)) = misc.union else {
            panic!("expected video keyframe request");
        };
        assert_eq!(request.display, 2);
        assert_eq!(request.last_frame_id, 77);
        assert_eq!(request.reason, VIDEO_KEYFRAME_REASON_FRAME_GAP);
    }

    fn video_frame_chunk(
        display: i32,
        frame_id: u64,
        chunk_index: u32,
        chunk_count: u32,
        data: &[u8],
        original_size: usize,
    ) -> VideoFrameChunk {
        VideoFrameChunk {
            display,
            frame_id,
            chunk_index,
            chunk_count,
            data: Bytes::copy_from_slice(data),
            original_size: original_size as u32,
            ..Default::default()
        }
    }

    #[test]
    fn video_frame_chunk_assembler_reassembles_out_of_order_frame() {
        let vf = VideoFrame {
            display: 2,
            frame_id: 91,
            ..Default::default()
        };
        let serialized = vf.write_to_bytes().unwrap();
        let split = serialized.len() / 2;
        assert!(split > 0 && split < serialized.len());

        let mut assembler = VideoFrameChunkAssembler::default();
        let second = video_frame_chunk(2, 91, 1, 2, &serialized[split..], serialized.len());
        let push = assembler.push(second).unwrap();
        assert!(push.frame.is_none());
        assert!(!push.expired.has_expired());

        let first = video_frame_chunk(2, 91, 0, 2, &serialized[..split], serialized.len());
        let push = assembler.push(first).unwrap();
        assert!(!push.expired.has_expired());
        let Some((reassembled, received_bytes)) = push.frame else {
            panic!("expected reassembled video frame");
        };
        assert_eq!(reassembled.display, 2);
        assert_eq!(reassembled.frame_id, 91);
        assert_eq!(received_bytes, serialized.len());
    }

    #[test]
    fn video_frame_chunk_assembler_rejects_invalid_metadata() {
        let mut assembler = VideoFrameChunkAssembler::default();
        let err = match assembler.push(video_frame_chunk(0, 1, 2, 2, b"x", 1)) {
            Ok(_) => panic!("expected invalid chunk index error"),
            Err(err) => err,
        };
        assert!(err.contains("index out of range"));

        let err = match assembler.push(video_frame_chunk(
            0,
            1,
            0,
            1,
            b"x",
            VIDEO_FRAME_CHUNK_MAX_ORIGINAL_SIZE + 1,
        )) {
            Ok(_) => panic!("expected invalid original size error"),
            Err(err) => err,
        };
        assert!(err.contains("original_size invalid"));
    }

    #[test]
    fn video_frame_chunk_assembler_reports_expired_partial_frames() {
        let mut assembler = VideoFrameChunkAssembler::default();
        let chunk = video_frame_chunk(4, 123, 0, 2, b"x", 2);
        assert!(assembler.push(chunk).unwrap().frame.is_none());

        let expired =
            assembler.cleanup_expired(Instant::now() + VIDEO_FRAME_CHUNK_REASSEMBLY_TIMEOUT);
        assert_eq!(expired.frames, 1);
        assert_eq!(expired.chunks, 1);
        assert_eq!(expired.last_display, 4);
        assert_eq!(expired.last_frame_id, 123);
        assert!(expired.has_expired());

        let expired =
            assembler.cleanup_expired(Instant::now() + VIDEO_FRAME_CHUNK_REASSEMBLY_TIMEOUT * 2);
        assert!(!expired.has_expired());
    }

    #[test]
    fn video_receiver_stats_tracker_counts_gaps_drops_and_decode_stats() {
        let mut tracker = VideoReceiverStatsTracker::default();
        let now = Instant::now();
        let vf = VideoFrame {
            display: 1,
            frame_id: 10,
            ..Default::default()
        };
        assert_eq!(tracker.record_frame_received(&vf, 1200, 1, true, now), None);

        let vf = VideoFrame {
            display: 1,
            frame_id: 13,
            ..Default::default()
        };
        assert_eq!(
            tracker.record_frame_received(&vf, 800, 2, false, now + Duration::from_millis(16)),
            Some(VIDEO_KEYFRAME_REASON_FRAME_GAP)
        );
        tracker.record_queue_drop();

        let thread_stats = crate::client::VideoThreadStats::default();
        thread_stats.record_decoded(Duration::from_millis(7));
        thread_stats.record_rendered();
        let stats = tracker.to_proto(
            1,
            1000,
            2,
            0,
            thread_stats.snapshot(),
            now + Duration::from_millis(32),
        );

        assert_eq!(stats.display, 1);
        assert_eq!(stats.first_frame_id, 10);
        assert_eq!(stats.last_frame_id, 13);
        assert_eq!(stats.frames_received, 2);
        assert_eq!(stats.frames_decoded, 1);
        assert_eq!(stats.frames_rendered, 1);
        assert_eq!(stats.frames_dropped, 1);
        assert_eq!(stats.skipped_frame_ids, 2);
        assert_eq!(stats.bytes_received, 2000);
        assert_eq!(stats.encoded_frames_received, 3);
        assert_eq!(stats.keyframes_received, 1);
        assert_eq!(stats.decode_queue_len, 2);
        assert_eq!(stats.render_queue_len, 0);
        assert_eq!(stats.decode_ms_avg, 7);
        assert_eq!(stats.decode_ms_p95, 7);
    }

    #[test]
    fn video_receiver_stats_tracker_reports_chunk_transport_before_decoding() {
        let mut tracker = VideoReceiverStatsTracker::default();
        tracker.record_video_chunk(55, 1024);
        tracker.record_video_chunk(55, 512);
        tracker.record_video_chunk_reassembled();
        tracker.record_video_chunk_expired(super::VideoFrameChunkExpirySummary {
            frames: 1,
            chunks: 2,
            last_display: 0,
            last_frame_id: 56,
        });

        let stats = tracker.to_proto(
            0,
            1000,
            0,
            0,
            crate::client::VideoThreadStatsSnapshot::default(),
            Instant::now(),
        );

        assert!(tracker.has_transport_progress());
        assert_eq!(stats.frames_received, 0);
        assert_eq!(stats.video_chunks_received, 2);
        assert_eq!(stats.video_chunk_bytes_received, 1536);
        assert_eq!(stats.video_chunk_frames_reassembled, 1);
        assert_eq!(stats.video_chunk_frames_expired, 1);
        assert_eq!(stats.last_observed_frame_id, 56);
    }

    #[test]
    fn video_keyframe_requests_are_rate_limited() {
        let mut tracker = VideoReceiverStatsTracker::default();
        let now = Instant::now();

        assert!(tracker.should_send_keyframe_request(now));
        assert!(!tracker.should_send_keyframe_request(now + Duration::from_millis(500)));
        assert!(tracker.should_send_keyframe_request(now + Duration::from_secs(3)));
    }

    #[test]
    fn auto_adjust_fps_message_uses_dedicated_misc_field() {
        let msg = auto_adjust_fps_msg(12);
        let Some(message::Union::Misc(misc)) = msg.union else {
            panic!("expected misc message");
        };
        let Some(misc::Union::AutoAdjustFps(fps)) = misc.union else {
            panic!("expected auto adjust fps");
        };
        assert_eq!(fps, 12);
    }

    #[test]
    fn adaptive_auto_fps_probes_above_current_decode_rate_when_idle() {
        assert_eq!(next_adaptive_auto_fps(60, Some(12), 12, 0, false, true), 24);
        assert_eq!(next_adaptive_auto_fps(60, Some(55), 12, 0, false, true), 60);
        assert_eq!(next_adaptive_auto_fps(60, Some(12), 12, 20, true, false), 6);
        assert_eq!(
            next_adaptive_auto_fps(60, Some(12), 12, 0, false, false),
            12
        );
    }

    #[test]
    fn no_video_watchdog_waits_until_start_timeout() {
        let mut watchdog = NoVideoStartupWatchdog::default();
        let start = Instant::now();

        assert_eq!(
            watchdog.tick(true, true, false, false, start),
            NoVideoStartupAction::None
        );
        assert_eq!(
            watchdog.tick(
                true,
                true,
                false,
                false,
                start + NO_VIDEO_START_TIMEOUT - Duration::from_millis(1)
            ),
            NoVideoStartupAction::None
        );
    }

    #[test]
    fn no_video_watchdog_retries_by_requesting_reconnect_fallback() {
        let mut watchdog = NoVideoStartupWatchdog::default();
        let start = Instant::now();
        assert_eq!(
            watchdog.tick(true, true, false, false, start),
            NoVideoStartupAction::None
        );

        assert_eq!(
            watchdog.tick(true, true, false, false, start + NO_VIDEO_START_TIMEOUT),
            NoVideoStartupAction::Reconnect {
                attempt: 1,
                elapsed_ms: NO_VIDEO_START_TIMEOUT.as_millis()
            }
        );

        assert_eq!(
            watchdog.tick(
                true,
                true,
                false,
                false,
                start + NO_VIDEO_START_TIMEOUT + NO_VIDEO_START_FALLBACK_INTERVAL
            ),
            NoVideoStartupAction::Reconnect {
                attempt: 2,
                elapsed_ms: (NO_VIDEO_START_TIMEOUT + NO_VIDEO_START_FALLBACK_INTERVAL).as_millis()
            }
        );
    }

    #[test]
    fn no_video_watchdog_caps_reconnect_fallbacks_and_gives_up() {
        let mut watchdog = NoVideoStartupWatchdog::default();
        let start = Instant::now();
        assert_eq!(
            watchdog.tick(true, true, false, false, start),
            NoVideoStartupAction::None
        );

        for attempt in 1..=NO_VIDEO_START_MAX_FALLBACKS {
            let now = start
                + NO_VIDEO_START_TIMEOUT
                + NO_VIDEO_START_FALLBACK_INTERVAL * (attempt as u32 - 1);
            assert_eq!(
                watchdog.tick(true, true, false, false, now),
                NoVideoStartupAction::Reconnect {
                    attempt,
                    elapsed_ms: now.saturating_duration_since(start).as_millis()
                }
            );
        }

        let after_cap = start
            + NO_VIDEO_START_TIMEOUT
            + NO_VIDEO_START_FALLBACK_INTERVAL * NO_VIDEO_START_MAX_FALLBACKS as u32;
        assert!(matches!(
            watchdog.tick(true, true, false, false, after_cap),
            NoVideoStartupAction::GiveUp { .. }
        ));
    }

    #[test]
    fn no_video_watchdog_keeps_transport_alive_without_reconnect() {
        let mut watchdog = NoVideoStartupWatchdog::default();
        let start = Instant::now();
        assert_eq!(
            watchdog.tick(true, true, false, true, start),
            NoVideoStartupAction::None
        );

        assert_eq!(
            watchdog.tick(true, true, false, true, start + NO_VIDEO_START_TIMEOUT),
            NoVideoStartupAction::Stalled {
                elapsed_ms: NO_VIDEO_START_TIMEOUT.as_millis()
            }
        );

        assert_eq!(
            watchdog.tick(
                true,
                true,
                false,
                true,
                start + NO_VIDEO_START_TIMEOUT + NO_VIDEO_START_FALLBACK_INTERVAL
            ),
            NoVideoStartupAction::None
        );
    }

    #[test]
    fn no_video_watchdog_resets_after_first_frame() {
        let mut watchdog = NoVideoStartupWatchdog::default();
        let start = Instant::now();
        assert_eq!(
            watchdog.tick(true, true, false, false, start),
            NoVideoStartupAction::None
        );
        assert!(matches!(
            watchdog.tick(true, true, false, false, start + NO_VIDEO_START_TIMEOUT),
            NoVideoStartupAction::Reconnect { .. }
        ));

        assert_eq!(
            watchdog.tick(true, true, true, false, start + NO_VIDEO_START_TIMEOUT),
            NoVideoStartupAction::None
        );
        assert_eq!(
            watchdog.tick(true, true, false, false, start + NO_VIDEO_START_TIMEOUT),
            NoVideoStartupAction::None
        );
    }

    #[test]
    fn no_video_fallback_marks_explicit_h265_first() {
        assert_eq!(
            next_no_video_startup_fallback_codec(
                &decoding(PreferCodec::H265),
                &encoding(),
                &[],
                CodecFormat::Unknown,
            ),
            Some(CodecFormat::H265)
        );
    }

    #[test]
    fn no_video_fallback_skips_already_marked_codec() {
        assert_eq!(
            next_no_video_startup_fallback_codec(
                &decoding(PreferCodec::H265),
                &encoding(),
                &[CodecFormat::H265],
                CodecFormat::Unknown,
            ),
            Some(CodecFormat::H264)
        );
    }

    #[test]
    fn no_video_fallback_uses_auto_order_without_explicit_preference() {
        assert_eq!(
            next_no_video_startup_fallback_codec(
                &decoding(PreferCodec::Auto),
                &encoding(),
                &[],
                CodecFormat::Unknown,
            ),
            Some(CodecFormat::H265)
        );
    }

    #[test]
    fn framed_stream_waits_for_complete_first_large_frame() {
        let first_payload = vec![0xA5; 78_597];
        let second_payload = vec![0x5A; 512];
        let mut encoder = BytesCodec::new();
        let mut first_frame = BytesMut::new();
        let mut second_frame = BytesMut::new();
        encoder
            .encode(Bytes::from(first_payload.clone()), &mut first_frame)
            .unwrap();
        encoder
            .encode(Bytes::from(second_payload), &mut second_frame)
            .unwrap();

        let mut decoder = BytesCodec::new();
        let last_byte = first_frame.split_off(first_frame.len() - 1);
        assert!(decoder.decode(&mut first_frame).unwrap().is_none());

        first_frame.extend_from_slice(&last_byte);
        let decoded = decoder
            .decode(&mut first_frame)
            .unwrap()
            .expect("complete first frame must decode");
        assert_eq!(decoded.as_ref(), first_payload.as_slice());
        assert!(decoder.decode(&mut second_frame).unwrap().is_some());
    }
}
