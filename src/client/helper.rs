use hbb_common::{
    get_time,
    message_proto::{Message, VoiceCallRequest, VoiceCallResponse},
};
use scrap::CodecFormat;
use std::collections::HashMap;

#[derive(Debug, Default)]
pub struct QualityStatus {
    pub speed: Option<String>,
    pub fps: HashMap<usize, i32>,
    pub delay: Option<i32>,
    pub target_bitrate: Option<i32>,
    pub codec_format: Option<CodecFormat>,
    pub chroma: Option<String>,
    pub connection_type: Option<String>,
    pub decoder: Option<String>,
    pub renderer: Option<String>,
    pub capture_backend: Option<String>,
    pub encoder_backend: Option<String>,
    pub encoder_input: Option<String>,
    pub capture_frame: Option<String>,
    pub decode_fps: HashMap<usize, usize>,
    pub video_queue: HashMap<usize, usize>,
    pub frame_resolution: HashMap<usize, String>,
    pub video_threads: Option<usize>,
    pub texture_render: Option<bool>,
    pub direct: Option<bool>,
    pub fps_mode: Option<String>,
    pub auto_fps: Option<usize>,
    pub video_progress: HashMap<usize, String>,
    pub video_dropped: HashMap<usize, u64>,
    pub video_decode_time_us: HashMap<usize, u32>,
    pub video_render_submit_time_us: HashMap<usize, u32>,
    pub video_feedback_queue: HashMap<usize, u32>,
    pub video_delivery_phase: Option<String>,
    pub video_recovery_count: Option<u64>,
    pub video_stall_ms: Option<u64>,
}

#[inline]
pub fn new_voice_call_request(is_connect: bool) -> Message {
    let mut req = VoiceCallRequest::new();
    req.is_connect = is_connect;
    req.req_timestamp = get_time();
    let mut msg = Message::new();
    msg.set_voice_call_request(req);
    msg
}

#[inline]
pub fn new_voice_call_response(request_timestamp: i64, accepted: bool) -> Message {
    let mut resp = VoiceCallResponse::new();
    resp.accepted = accepted;
    resp.req_timestamp = request_timestamp;
    resp.ack_timestamp = get_time();
    let mut msg = Message::new();
    msg.set_voice_call_response(resp);
    msg
}
