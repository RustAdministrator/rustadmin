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
    pub codec_path: Option<String>,
    pub render_path: Option<String>,
    pub frame_resolution: Option<String>,
    pub queue_len: Option<usize>,
    pub decode_fps: Option<usize>,
    pub auto_fps: Option<usize>,
    pub fps_mode: Option<String>,
    pub direct: Option<bool>,
    pub connection_type: Option<String>,
    pub mediacodec_input_queue_ms: Option<String>,
    pub mediacodec_output_dequeue_ms: Option<String>,
    pub yuv_to_rgba_ms: Option<String>,
    pub mediacodec_decode_ms: Option<String>,
    pub handle_frame_ms: Option<String>,
    pub flutter_handoff_ms: Option<String>,
    pub end_to_end_ms: Option<String>,
    pub rgba_bytes: Option<usize>,
    pub rgba_reallocated: Option<bool>,
    pub output_buffer_bytes: Option<usize>,
    pub media_format: Option<String>,
    pub host_video_fps: Option<String>,
    pub host_video_codec: Option<String>,
    pub host_video_qos: Option<String>,
    pub host_video_wait: Option<String>,
    pub host_video_backend: Option<String>,
    pub host_video_fallback: Option<String>,
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
