#[cfg(not(target_os = "android"))]
use arboard::{ClipboardData, ClipboardFormat};
#[cfg(not(target_os = "android"))]
use hbb_common::config::LocalConfig;
use hbb_common::config::{keys, Config};
use hbb_common::{bail, log, message_proto::*, ResultType};
#[cfg(not(target_os = "android"))]
use std::collections::VecDeque;
#[cfg(not(target_os = "android"))]
use std::time::{SystemTime, UNIX_EPOCH};
use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

pub const CLIPBOARD_NAME: &'static str = "clipboard";
#[cfg(feature = "unix-file-copy-paste")]
pub const FILE_CLIPBOARD_NAME: &'static str = "file-clipboard";
pub const CLIPBOARD_INTERVAL: u64 = 333;
const LOCAL_CLIPBOARD_QUIET_DUR: Duration = Duration::from_millis(750);
#[cfg(target_os = "windows")]
const WINDOWS_LOCAL_CLIPBOARD_READ_DEBOUNCE_DUR: Duration = Duration::from_millis(120);
#[cfg(not(target_os = "android"))]
const CLIPBOARD_DEBUG_ENV: &str = "RUSTDESK_CLIPBOARD_DEBUG";
#[cfg(not(target_os = "android"))]
const CLIPBOARD_DEBUG_CATEGORY: &str = "clipboard";
#[cfg(not(target_os = "android"))]
const CLIPBOARD_DEBUG_MAX_EVENTS: usize = 64;
#[cfg(not(target_os = "android"))]
const CLIPBOARD_DEBUG_MAX_LINE: usize = 1200;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ClipboardDirectionPolicy {
    Both,
    LocalToRemote,
    RemoteToLocal,
    Off,
}

impl ClipboardDirectionPolicy {
    pub(crate) fn from_option_value(value: &str) -> Self {
        let value = value.trim();
        if value.is_empty()
            || value.eq_ignore_ascii_case("N")
            || value.eq_ignore_ascii_case("both")
            || value.eq_ignore_ascii_case("bidirectional")
            || value.eq_ignore_ascii_case("all")
        {
            return Self::Both;
        }
        if value.eq_ignore_ascii_case("local-to-remote")
            || value.eq_ignore_ascii_case("local_to_remote")
            || value.eq_ignore_ascii_case("send")
            || value.eq_ignore_ascii_case("send-only")
            || value.eq_ignore_ascii_case("outbound")
        {
            return Self::LocalToRemote;
        }
        if value.eq_ignore_ascii_case("Y")
            || value.eq_ignore_ascii_case("yes")
            || value.eq_ignore_ascii_case("true")
            || value == "1"
            || value.eq_ignore_ascii_case("remote-to-local")
            || value.eq_ignore_ascii_case("remote_to_local")
            || value.eq_ignore_ascii_case("receive")
            || value.eq_ignore_ascii_case("receive-only")
            || value.eq_ignore_ascii_case("inbound")
        {
            return Self::RemoteToLocal;
        }
        if value.eq_ignore_ascii_case("off")
            || value.eq_ignore_ascii_case("none")
            || value.eq_ignore_ascii_case("disabled")
        {
            return Self::Off;
        }
        Self::Off
    }

    pub(crate) fn allows_local_to_remote(self) -> bool {
        matches!(self, Self::Both | Self::LocalToRemote)
    }

    pub(crate) fn allows_remote_to_local(self) -> bool {
        matches!(self, Self::Both | Self::RemoteToLocal)
    }

    pub(crate) fn as_option_value(self) -> &'static str {
        match self {
            Self::Both => "both",
            Self::LocalToRemote => "local-to-remote",
            Self::RemoteToLocal => "remote-to-local",
            Self::Off => "off",
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Both => "both",
            Self::LocalToRemote => "local-to-remote",
            Self::RemoteToLocal => "remote-to-local",
            Self::Off => "off",
        }
    }
}

pub(crate) fn clipboard_direction_policy_from_option_value(
    value: &str,
) -> ClipboardDirectionPolicy {
    ClipboardDirectionPolicy::from_option_value(value)
}

// This format is used to store the flag in the clipboard.
const RUSTDESK_CLIPBOARD_OWNER_FORMAT: &'static str = "dyn.com.rustdesk.owner";

// Add special format for Excel XML Spreadsheet
const CLIPBOARD_FORMAT_EXCEL_XML_SPREADSHEET: &'static str = "XML Spreadsheet";

#[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
const SAFE_REGISTERED_FORMATS: &[&str] = &[
    "TARGETS",
    "SAVE_TARGETS",
    "TIMESTAMP",
    "MULTIPLE",
    "UTF8_STRING",
    "TEXT",
    "STRING",
    "COMPOUND_TEXT",
    "HTML Format",
    "Rich Text Format",
    "text/richtext",
    "text/rtf",
    "text/html",
    "text/plain",
    "text/plain;charset=utf-8",
    "text/uri-list",
    "image/png",
    "image/tiff",
    "PNG",
    "image/svg+xml",
    "public.utf8-plain-text",
    "public.text",
    "public.html",
    "public.rtf",
    "public.png",
    "public.tiff",
    "public.svg-image",
    "public.file-url",
    "NSStringPboardType",
    "NSRTFPboardType",
    "NSHTMLPboardType",
    "NSFilenamesPboardType",
    "NSURLPboardType",
    "Chromium Web Custom MIME Data Format",
    "WebKit Smart Paste Format",
    "UniformResourceLocator",
    "UniformResourceLocatorW",
    "DataObjectAttributes",
    "CanIncludeInClipboardHistory",
    "CanUploadToCloudClipboard",
    "ExcludeClipboardContentFromMonitorProcessing",
    CLIPBOARD_FORMAT_EXCEL_XML_SPREADSHEET,
    RUSTDESK_CLIPBOARD_OWNER_FORMAT,
];

#[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
const OPAQUE_NATIVE_FORMAT_PATTERNS: &[&str] = &[
    "adobe illustrator",
    "illustrator",
    "aicb",
    "ai private",
    "com.adobe",
    "portable document format",
    "application/pdf",
    "application/postscript",
    "application/eps",
    "application/vnd.adobe.illustrator",
    "application/x-adobe-illustrator",
    "pdf",
    "public.pdf",
    "public.eps",
    "public.postscript",
    "encapsulated postscript",
    "postscript",
    "eps",
];

#[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
const WINDOWS_OPAQUE_REGISTERED_FORMATS: &[&str] = &[
    "CF_HDROP",
    "CF_METAFILEPICT",
    "CF_TIFF",
    "CF_ENHMETAFILE",
    "DataObject",
    "Object Descriptor",
    "Ole Private Data",
    "Embed Source",
    "Embedded Object",
    "Link Source",
    "Link Source Descriptor",
    "Native",
    "OwnerLink",
    "System.Drawing.Bitmap",
];

#[cfg(any(test, target_os = "windows"))]
const WINDOWS_TEXT_FALLBACK_FORMATS: &[&str] = &[
    "CF_UNICODETEXT",
    "CF_TEXT",
    "CF_OEMTEXT",
    "TEXT",
    "UTF8_STRING",
    "STRING",
    "HTML Format",
    "Rich Text Format",
    "text/plain",
    "text/plain;charset=utf-8",
    "text/html",
    "text/markdown",
];

#[cfg(any(test, target_os = "windows"))]
const WINDOWS_TEXT_OLE_WRAPPER_FORMATS: &[&str] = &["DataObject", "Ole Private Data"];

#[cfg(not(target_os = "android"))]
lazy_static::lazy_static! {
    static ref ARBOARD_MTX: Arc<Mutex<()>> = Arc::new(Mutex::new(()));
    static ref CLIPBOARD_TIMING: Arc<Mutex<ClipboardTiming>> = Arc::new(Mutex::new(ClipboardTiming::default()));
    // cache the clipboard msg
    static ref LAST_MULTI_CLIPBOARDS: Arc<Mutex<MultiClipboards>> = Arc::new(Mutex::new(MultiClipboards::new()));
    // For updating in server and getting content in cm.
    // Clipboard on Linux is "server--clients" mode.
    // The clipboard content is owned by the server and passed to the clients when requested.
    // Plain text is the only exception, it does not require the server to be present.
    static ref CLIPBOARD_CTX: Arc<Mutex<Option<ClipboardContext>>> = Arc::new(Mutex::new(None));
    static ref CLIPBOARD_DEBUG_EVENTS: Arc<Mutex<VecDeque<String>>> = Arc::new(Mutex::new(VecDeque::new()));
}

#[cfg(not(target_os = "android"))]
const CLIPBOARD_GET_MAX_RETRY: usize = 3;
#[cfg(not(target_os = "android"))]
const CLIPBOARD_GET_RETRY_INTERVAL_DUR: Duration = Duration::from_millis(33);

#[cfg(not(target_os = "android"))]
#[derive(Default)]
struct ClipboardTiming {
    last_local_change_at: Option<Instant>,
    last_remote_apply_at: Option<Instant>,
    last_external_opaque_signature: Option<String>,
}

#[cfg(not(target_os = "android"))]
impl ClipboardTiming {
    fn mark_local_change(&mut self, now: Instant) {
        self.last_external_opaque_signature = None;
        self.last_local_change_at = Some(now);
    }

    fn mark_external_opaque_change(&mut self, signature: &str, now: Instant) -> bool {
        if self.last_external_opaque_signature.as_deref() == Some(signature) {
            return false;
        }
        self.last_external_opaque_signature = Some(signature.to_owned());
        self.last_local_change_at = Some(now);
        true
    }

    fn mark_remote_apply(&mut self, now: Instant) {
        self.last_external_opaque_signature = None;
        self.last_remote_apply_at = Some(now);
    }

    fn remote_update_delay(&self, now: Instant) -> Option<Duration> {
        let Some(local_change_at) = self.last_local_change_at else {
            return None;
        };
        if self
            .last_remote_apply_at
            .is_some_and(|remote_apply_at| local_change_at <= remote_apply_at)
        {
            return None;
        }
        let elapsed = now.saturating_duration_since(local_change_at);
        if elapsed < LOCAL_CLIPBOARD_QUIET_DUR {
            Some(LOCAL_CLIPBOARD_QUIET_DUR - elapsed)
        } else {
            None
        }
    }
}

#[cfg(not(target_os = "android"))]
pub(crate) fn mark_local_external_opaque_clipboard_change(
    side: ClipboardSide,
    signature: &str,
) -> bool {
    let changed = CLIPBOARD_TIMING
        .lock()
        .unwrap()
        .mark_external_opaque_change(signature, Instant::now());
    if changed {
        log::debug!("Observed local {} opaque clipboard change", side);
        emit_clipboard_debug(format!("observed-local-change side={side} kind=opaque"));
    }
    changed
}

#[cfg(not(target_os = "android"))]
pub(crate) fn mark_local_clipboard_change(side: ClipboardSide) {
    CLIPBOARD_TIMING
        .lock()
        .unwrap()
        .mark_local_change(Instant::now());
    log::debug!("Observed local {} clipboard change", side);
    emit_clipboard_debug(format!("observed-local-change side={side}"));
}

#[cfg(not(target_os = "android"))]
fn mark_remote_clipboard_applied(side: ClipboardSide) {
    CLIPBOARD_TIMING
        .lock()
        .unwrap()
        .mark_remote_apply(Instant::now());
    log::debug!("Applied remote clipboard on {}", side);
    emit_clipboard_debug(format!("remote-apply-accepted side={side}"));
}

#[cfg(not(target_os = "android"))]
fn clear_cached_clipboard() {
    *LAST_MULTI_CLIPBOARDS.lock().unwrap() = MultiClipboards::new();
}

#[cfg(not(target_os = "android"))]
fn remote_clipboard_update_delay(side: ClipboardSide) -> Option<Duration> {
    let delay = CLIPBOARD_TIMING
        .lock()
        .unwrap()
        .remote_update_delay(Instant::now());
    if let Some(delay) = delay {
        log::debug!(
            "Delay updating {} clipboard for {:?} because the local clipboard changed recently",
            side,
            delay
        );
    }
    delay
}

pub(crate) fn clipboard_direction_policy_for_side(side: ClipboardSide) -> ClipboardDirectionPolicy {
    match side {
        ClipboardSide::Host => {
            let built_in = crate::get_builtin_option(keys::OPTION_ONE_WAY_CLIPBOARD_REDIRECTION);
            let value = if built_in.is_empty() {
                Config::get_option(keys::OPTION_ONE_WAY_CLIPBOARD_REDIRECTION)
            } else {
                built_in
            };
            ClipboardDirectionPolicy::from_option_value(&value)
        }
        ClipboardSide::Client => client_clipboard_direction_policy(),
    }
}

#[cfg(not(target_os = "android"))]
fn client_clipboard_direction_policy() -> ClipboardDirectionPolicy {
    let local = LocalConfig::get_option(keys::OPTION_ONE_WAY_CLIPBOARD_REDIRECTION);
    let value = if local.is_empty() {
        Config::get_option(keys::OPTION_ONE_WAY_CLIPBOARD_REDIRECTION)
    } else {
        local
    };
    ClipboardDirectionPolicy::from_option_value(&value)
}

#[cfg(target_os = "android")]
fn client_clipboard_direction_policy() -> ClipboardDirectionPolicy {
    ClipboardDirectionPolicy::from_option_value(&Config::get_option(
        keys::OPTION_ONE_WAY_CLIPBOARD_REDIRECTION,
    ))
}

pub(crate) fn is_local_to_remote_clipboard_allowed(side: ClipboardSide) -> bool {
    clipboard_direction_policy_for_side(side).allows_local_to_remote()
}

pub(crate) fn is_remote_to_local_clipboard_allowed(side: ClipboardSide) -> bool {
    clipboard_direction_policy_for_side(side).allows_remote_to_local()
}

#[cfg(not(target_os = "android"))]
fn emit_clipboard_direction_skip(
    action: &str,
    side: ClipboardSide,
    policy: ClipboardDirectionPolicy,
) {
    log::debug!(
        "Skip {} {} clipboard because direction policy is {}",
        action,
        side,
        policy.as_str()
    );
    emit_clipboard_debug(format!(
        "skip-{action} side={side} reason=direction-policy policy={}",
        policy.as_str()
    ));
}

#[cfg(not(target_os = "android"))]
fn remote_special_format_block_reason(name: &str) -> Option<&'static str> {
    #[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
    {
        if name.eq_ignore_ascii_case(CLIPBOARD_FORMAT_EXCEL_XML_SPREADSHEET)
            || name.eq_ignore_ascii_case(RUSTDESK_CLIPBOARD_OWNER_FORMAT)
        {
            return None;
        }
        if is_windows_opaque_registered_format_name(name)
            || should_preserve_native_format_name(name)
        {
            return Some("opaque-native-format");
        }
        return Some("unknown-special-format");
    }

    #[cfg(not(any(test, target_os = "windows", target_os = "macos", target_os = "linux")))]
    {
        if name.eq_ignore_ascii_case(CLIPBOARD_FORMAT_EXCEL_XML_SPREADSHEET)
            || name.eq_ignore_ascii_case(RUSTDESK_CLIPBOARD_OWNER_FORMAT)
        {
            None
        } else {
            Some("unknown-special-format")
        }
    }
}

#[cfg(not(target_os = "android"))]
fn remote_clipboard_data_block_reason(data: &[ClipboardData]) -> Option<&'static str> {
    for item in data {
        match item {
            ClipboardData::Special((name, _)) => {
                if let Some(reason) = remote_special_format_block_reason(name) {
                    return Some(reason);
                }
            }
            ClipboardData::Unsupported | ClipboardData::None => {
                return Some("unsupported-format");
            }
            _ => {}
        }
    }
    None
}

#[cfg(not(target_os = "android"))]
fn is_rustdesk_owner_clipboard_data(data: &ClipboardData) -> bool {
    matches!(
        data,
        ClipboardData::Special((name, _)) if name.eq_ignore_ascii_case(RUSTDESK_CLIPBOARD_OWNER_FORMAT)
    )
}

#[cfg(not(target_os = "android"))]
fn remove_remote_owner_markers(data: &mut Vec<ClipboardData>) {
    data.retain(|item| !is_rustdesk_owner_clipboard_data(item));
}

#[cfg(not(target_os = "android"))]
fn should_skip_remote_clipboard_update(
    data: &[ClipboardData],
    side: ClipboardSide,
    direction_policy: ClipboardDirectionPolicy,
    phase: &str,
) -> bool {
    if !direction_policy.allows_remote_to_local() {
        emit_clipboard_direction_skip("remote-apply", side, direction_policy);
        return true;
    }

    if let Some(reason) = remote_clipboard_data_block_reason(data) {
        log::debug!(
            "Skip applying remote {} clipboard because the payload contains {}",
            side,
            reason
        );
        emit_clipboard_debug(format!(
            "skip-remote-apply side={side} phase={phase} reason={reason}"
        ));
        return true;
    }

    #[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
    {
        let signature = platform_clipboard::external_opaque_native_clipboard_signature();
        if let Some(signature) = signature {
            let signature_changed = mark_local_external_opaque_clipboard_change(side, &signature);
            emit_clipboard_debug(format!(
                "remote-apply-will-replace-local-opaque side={side} phase={phase} signature_changed={signature_changed}"
            ));
        }
    }

    #[allow(unreachable_code)]
    false
}

#[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
fn contains_ignore_ascii_case(value: &str, needle: &str) -> bool {
    value
        .as_bytes()
        .windows(needle.len())
        .any(|window| window.eq_ignore_ascii_case(needle.as_bytes()))
}

#[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
fn is_safe_registered_format_name(name: &str) -> bool {
    SAFE_REGISTERED_FORMATS
        .iter()
        .any(|safe| safe.eq_ignore_ascii_case(name))
}

#[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
fn is_opaque_native_format_name(name: &str) -> bool {
    OPAQUE_NATIVE_FORMAT_PATTERNS
        .iter()
        .any(|pattern| contains_ignore_ascii_case(name, pattern))
}

#[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
fn is_windows_opaque_format_name(name: &str) -> bool {
    name.starts_with("format#")
        || WINDOWS_OPAQUE_REGISTERED_FORMATS
            .iter()
            .any(|opaque| opaque.eq_ignore_ascii_case(name))
        || is_opaque_native_format_name(name)
}

#[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
fn is_windows_opaque_registered_format_name(name: &str) -> bool {
    is_windows_opaque_format_name(name)
}

#[cfg(any(test, target_os = "windows"))]
fn is_windows_text_fallback_format_name(name: &str) -> bool {
    WINDOWS_TEXT_FALLBACK_FORMATS
        .iter()
        .any(|text| text.eq_ignore_ascii_case(name))
}

#[cfg(any(test, target_os = "windows"))]
fn is_windows_text_ole_wrapper_format_name(name: &str) -> bool {
    WINDOWS_TEXT_OLE_WRAPPER_FORMATS
        .iter()
        .any(|wrapper| wrapper.eq_ignore_ascii_case(name))
}

#[cfg(any(test, target_os = "windows"))]
fn windows_opaque_formats_are_only_text_ole_wrappers(opaque_formats: &[&str]) -> bool {
    !opaque_formats.is_empty()
        && opaque_formats
            .iter()
            .all(|name| is_windows_text_ole_wrapper_format_name(name))
}

#[cfg(any(test, target_os = "windows"))]
fn windows_external_opaque_signature_from_format_names(
    sequence: u32,
    has_owner: bool,
    names: &[String],
) -> Option<String> {
    if has_owner {
        return None;
    }
    if names.is_empty() {
        return Some(format!("windows:{sequence}:empty-format-list"));
    }
    let mut opaque_formats = names
        .iter()
        .filter(|name| is_windows_opaque_format_name(name))
        .map(String::as_str)
        .collect::<Vec<_>>();
    if opaque_formats.is_empty() {
        return None;
    }
    opaque_formats.sort_unstable();
    opaque_formats.dedup();
    if names
        .iter()
        .any(|name| is_windows_text_fallback_format_name(name))
        && windows_opaque_formats_are_only_text_ole_wrappers(&opaque_formats)
    {
        return None;
    }
    Some(format!("windows:{sequence}:{}", opaque_formats.join("|")))
}

#[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
fn is_risky_native_format_name(name: &str) -> bool {
    if is_safe_registered_format_name(name) {
        return false;
    }
    let name = name.trim();
    contains_ignore_ascii_case(name, "application/")
        || contains_ignore_ascii_case(name, "public.")
        || contains_ignore_ascii_case(name, "com.adobe")
        || contains_ignore_ascii_case(name, "org.inkscape")
        || contains_ignore_ascii_case(name, "gimp")
        || contains_ignore_ascii_case(name, "libreoffice")
}

#[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
fn should_preserve_native_format_name(name: &str) -> bool {
    is_opaque_native_format_name(name) || is_risky_native_format_name(name)
}

#[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
fn contains_rustdesk_owner_format_name(names: &[String]) -> bool {
    names
        .iter()
        .any(|name| name.eq_ignore_ascii_case(RUSTDESK_CLIPBOARD_OWNER_FORMAT))
}

#[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
fn contains_preserved_native_format_name(names: &[String]) -> bool {
    names
        .iter()
        .any(|name| should_preserve_native_format_name(name))
}

#[cfg(test)]
fn contains_external_preserved_native_format_name(names: &[String]) -> bool {
    !contains_rustdesk_owner_format_name(names) && contains_preserved_native_format_name(names)
}

#[cfg(any(test, target_os = "windows", target_os = "macos", target_os = "linux"))]
fn external_preserved_native_formats_signature(names: &[String]) -> Option<String> {
    if contains_rustdesk_owner_format_name(names) {
        return None;
    }
    let mut preserved = names
        .iter()
        .filter(|name| should_preserve_native_format_name(name))
        .map(String::as_str)
        .collect::<Vec<_>>();
    if preserved.is_empty() {
        return None;
    }
    preserved.sort_unstable();
    preserved.dedup();
    Some(preserved.join("|"))
}

#[cfg(not(target_os = "android"))]
fn clipboard_debug_enabled() -> bool {
    clipboard_debug_env_enabled() || clipboard_debug_exchange_enabled()
}

#[cfg(not(target_os = "android"))]
fn clipboard_debug_env_enabled() -> bool {
    std::env::var(CLIPBOARD_DEBUG_ENV)
        .map(|value| {
            matches!(
                value.to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

#[cfg(not(target_os = "android"))]
fn clipboard_debug_exchange_enabled() -> bool {
    LocalConfig::get_bool_option(keys::OPTION_ALLOW_CLIPBOARD_DEBUG)
}

#[cfg(not(target_os = "android"))]
fn truncate_clipboard_debug_line(mut line: String) -> String {
    if line.len() <= CLIPBOARD_DEBUG_MAX_LINE {
        return line;
    }
    let mut end = CLIPBOARD_DEBUG_MAX_LINE;
    while !line.is_char_boundary(end) {
        end -= 1;
    }
    line.truncate(end);
    line.push_str("...");
    line
}

#[cfg(not(target_os = "android"))]
fn push_clipboard_debug_line(line: String) {
    if !clipboard_debug_exchange_enabled() {
        return;
    }
    let mut queue = CLIPBOARD_DEBUG_EVENTS.lock().unwrap();
    if queue.len() == CLIPBOARD_DEBUG_MAX_EVENTS {
        queue.pop_front();
    }
    queue.push_back(line);
}

#[cfg(not(target_os = "android"))]
fn emit_clipboard_debug(line: String) {
    if !clipboard_debug_enabled() {
        return;
    }
    let line = truncate_clipboard_debug_line(line);
    log::warn!("[clipboard-debug] {line}");
    push_clipboard_debug_line(line);
}

#[cfg(not(target_os = "android"))]
pub fn queue_clipboard_debug_lines(lines: Vec<String>) {
    if !clipboard_debug_exchange_enabled() {
        return;
    }
    for line in lines {
        push_clipboard_debug_line(truncate_clipboard_debug_line(line));
    }
}

#[cfg(not(target_os = "android"))]
pub fn take_clipboard_debug_lines() -> Vec<String> {
    if !clipboard_debug_exchange_enabled() {
        CLIPBOARD_DEBUG_EVENTS.lock().unwrap().clear();
        return Vec::new();
    }
    CLIPBOARD_DEBUG_EVENTS.lock().unwrap().drain(..).collect()
}

#[cfg(not(target_os = "android"))]
fn clipboard_debug_timestamp_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or_default()
}

#[cfg(not(target_os = "android"))]
fn make_clipboard_debug_message(text: String) -> Message {
    let mut misc = Misc::new();
    misc.set_debug_event(DebugEvent {
        category: CLIPBOARD_DEBUG_CATEGORY.to_owned(),
        text,
        timestamp_ms: clipboard_debug_timestamp_ms(),
        ..Default::default()
    });
    let mut msg = Message::new();
    msg.set_misc(misc);
    msg
}

#[cfg(not(target_os = "android"))]
pub fn take_clipboard_debug_messages() -> Vec<Message> {
    take_clipboard_debug_lines()
        .into_iter()
        .map(make_clipboard_debug_message)
        .collect()
}

#[cfg(not(target_os = "android"))]
pub fn log_remote_debug_event(event: DebugEvent) {
    if !clipboard_debug_enabled() {
        return;
    }
    if event.category != CLIPBOARD_DEBUG_CATEGORY {
        return;
    }
    let text = truncate_clipboard_debug_line(event.text);
    log::warn!(
        "[clipboard-debug][remote] category={} timestamp_ms={} {}",
        event.category,
        event.timestamp_ms,
        text
    );
}

#[cfg(target_os = "android")]
pub fn log_remote_debug_event(_event: DebugEvent) {}

#[cfg(not(target_os = "android"))]
fn debug_clipboard_data(label: &str, side: ClipboardSide, data: &[ClipboardData]) {
    if !clipboard_debug_enabled() {
        return;
    }
    let mut items = Vec::with_capacity(data.len());
    for item in data {
        let item = match item {
            ClipboardData::Text(text) => format!("Text({} bytes)", text.len()),
            ClipboardData::Html(html) => format!("Html({} bytes)", html.len()),
            ClipboardData::Rtf(rtf) => format!("Rtf({} bytes)", rtf.len()),
            ClipboardData::Image(arboard::ImageData::Rgba(image)) => {
                format!(
                    "ImageRgba({}x{}, {} bytes)",
                    image.width,
                    image.height,
                    image.bytes.len()
                )
            }
            ClipboardData::Image(arboard::ImageData::Png(png)) => {
                format!("ImagePng({} bytes)", png.len())
            }
            ClipboardData::Image(arboard::ImageData::Svg(svg)) => {
                format!("ImageSvg({} bytes)", svg.len())
            }
            #[cfg(any(target_os = "linux", target_os = "macos"))]
            ClipboardData::FileUrl(urls) => format!("FileUrl({} urls)", urls.len()),
            ClipboardData::Special((name, bytes)) => {
                format!("Special({name}, {} bytes)", bytes.len())
            }
            ClipboardData::Unsupported => "Unsupported".to_owned(),
            ClipboardData::None => "None".to_owned(),
        };
        items.push(item);
    }
    emit_clipboard_debug(format!(
        "{label} side={side} data_count={} data=[{}]",
        data.len(),
        items.join(", ")
    ));
}

#[cfg(not(target_os = "android"))]
const SUPPORTED_FORMATS: &[ClipboardFormat] = &[
    ClipboardFormat::Text,
    ClipboardFormat::Html,
    ClipboardFormat::Rtf,
    #[cfg(feature = "unix-file-copy-paste")]
    ClipboardFormat::FileUrl,
    ClipboardFormat::Special(CLIPBOARD_FORMAT_EXCEL_XML_SPREADSHEET),
    ClipboardFormat::Special(RUSTDESK_CLIPBOARD_OWNER_FORMAT),
];

#[cfg(target_os = "windows")]
mod platform_clipboard {
    use hbb_common::{bail, log, ResultType};
    use std::{ffi::OsStr, os::windows::ffi::OsStrExt, ptr::null_mut, thread, time::Duration};
    use winapi::um::winuser::{
        CloseClipboard, EnumClipboardFormats, GetClipboardFormatNameW, GetClipboardSequenceNumber,
        IsClipboardFormatAvailable, OpenClipboard, RegisterClipboardFormatW,
    };

    const CF_TEXT: u32 = 1;
    const CF_BITMAP: u32 = 2;
    const CF_METAFILEPICT: u32 = 3;
    const CF_TIFF: u32 = 6;
    const CF_OEMTEXT: u32 = 7;
    const CF_DIB: u32 = 8;
    const CF_PALETTE: u32 = 9;
    const CF_UNICODETEXT: u32 = 13;
    const CF_ENHMETAFILE: u32 = 14;
    const CF_HDROP: u32 = 15;
    const CF_LOCALE: u32 = 16;
    const CF_DIBV5: u32 = 17;

    struct ClipboardGuard;

    impl Drop for ClipboardGuard {
        fn drop(&mut self) {
            // Safety: ClipboardGuard is only constructed after OpenClipboard succeeds.
            unsafe {
                CloseClipboard();
            }
        }
    }

    fn open_clipboard() -> ResultType<ClipboardGuard> {
        for _ in 0..5 {
            // Safety: Passing a null HWND opens the clipboard for the current task.
            if unsafe { OpenClipboard(null_mut()) } != 0 {
                return Ok(ClipboardGuard);
            }
            thread::sleep(Duration::from_millis(5));
        }
        bail!("clipboard is occupied");
    }

    fn wide_z(value: &str) -> Vec<u16> {
        OsStr::new(value).encode_wide().chain(Some(0)).collect()
    }

    fn registered_id(name: &str) -> u32 {
        let name = wide_z(name);
        // Safety: wide_z returns a valid null-terminated UTF-16 string.
        unsafe { RegisterClipboardFormatW(name.as_ptr()) }
    }

    fn registered_name(format: u32) -> Option<String> {
        let mut name = [0u16; 256];
        // Safety: name is a writable UTF-16 buffer and len matches its capacity.
        let len = unsafe { GetClipboardFormatNameW(format, name.as_mut_ptr(), name.len() as i32) };
        if len <= 0 {
            None
        } else {
            Some(String::from_utf16_lossy(&name[..len as usize]))
        }
    }

    fn predefined_name(format: u32) -> Option<&'static str> {
        match format {
            CF_TEXT => Some("CF_TEXT"),
            CF_BITMAP => Some("CF_BITMAP"),
            CF_METAFILEPICT => Some("CF_METAFILEPICT"),
            CF_TIFF => Some("CF_TIFF"),
            CF_OEMTEXT => Some("CF_OEMTEXT"),
            CF_DIB => Some("CF_DIB"),
            CF_PALETTE => Some("CF_PALETTE"),
            CF_UNICODETEXT => Some("CF_UNICODETEXT"),
            CF_ENHMETAFILE => Some("CF_ENHMETAFILE"),
            CF_HDROP => Some("CF_HDROP"),
            CF_LOCALE => Some("CF_LOCALE"),
            CF_DIBV5 => Some("CF_DIBV5"),
            _ => None,
        }
    }

    fn format_name(format: u32) -> String {
        predefined_name(format)
            .map(str::to_owned)
            .or_else(|| registered_name(format))
            .unwrap_or_else(|| format!("format#{format}"))
    }

    fn is_safe_predefined(format: u32) -> bool {
        matches!(
            format,
            CF_TEXT
                | CF_BITMAP
                | CF_OEMTEXT
                | CF_DIB
                | CF_PALETTE
                | CF_UNICODETEXT
                | CF_LOCALE
                | CF_DIBV5
        )
    }

    fn is_opaque_native_format(format: u32) -> bool {
        if matches!(
            format,
            CF_HDROP | CF_METAFILEPICT | CF_TIFF | CF_ENHMETAFILE
        ) {
            return true;
        }
        if is_safe_predefined(format) {
            return false;
        }
        registered_name(format)
            .as_deref()
            .map(super::is_windows_opaque_registered_format_name)
            .unwrap_or(true)
    }

    fn external_opaque_native_signature() -> ResultType<Option<String>> {
        let _clipboard = open_clipboard()?;
        let owner_format = registered_id(super::RUSTDESK_CLIPBOARD_OWNER_FORMAT);
        let mut has_owner = false;
        let mut format_names = Vec::new();
        let mut format = 0;
        loop {
            // Safety: the clipboard is open for the lifetime of _clipboard.
            format = unsafe { EnumClipboardFormats(format) };
            if format == 0 {
                break;
            }
            let name = format_name(format);
            if owner_format != 0 && format == owner_format {
                has_owner = true;
            }
            format_names.push(name);
        }
        // Safety: The call has no parameters and only reads the OS clipboard generation.
        let sequence = unsafe { GetClipboardSequenceNumber() };
        Ok(super::windows_external_opaque_signature_from_format_names(
            sequence,
            has_owner,
            &format_names,
        ))
    }

    pub fn debug_dump_clipboard_formats(reason: &str) {
        if !super::clipboard_debug_enabled() {
            return;
        }
        match open_clipboard() {
            Ok(_clipboard) => {
                let mut format = 0;
                let mut formats = Vec::new();
                let mut format_names = Vec::new();
                loop {
                    // Safety: the clipboard is open for the lifetime of _clipboard.
                    format = unsafe { EnumClipboardFormats(format) };
                    if format == 0 {
                        break;
                    }
                    let name = format_name(format);
                    format_names.push(name.clone());
                    formats.push(format!(
                        "{}:{}:safe={}:opaque={}",
                        format,
                        name,
                        is_safe_predefined(format) || super::is_safe_registered_format_name(&name),
                        is_opaque_native_format(format)
                    ));
                }
                let has_owner = has_rustdesk_owner();
                let opaque = formats.iter().any(|item| item.ends_with("opaque=true"));
                let external_opaque = super::windows_external_opaque_signature_from_format_names(
                    0,
                    has_owner,
                    &format_names,
                )
                .is_some();
                super::emit_clipboard_debug(format!(
                    "{reason} owner_marker={has_owner} opaque={opaque} external_opaque={external_opaque} formats=[{}]",
                    formats.join(", ")
                ));
            }
            Err(e) => {
                super::emit_clipboard_debug(format!("{reason} failed to open clipboard: {e}"));
            }
        }
    }

    pub fn has_rustdesk_owner() -> bool {
        let format = registered_id(super::RUSTDESK_CLIPBOARD_OWNER_FORMAT);
        // Safety: IsClipboardFormatAvailable accepts a registered format id without
        // requiring the clipboard to be opened by this process.
        format != 0 && unsafe { IsClipboardFormatAvailable(format) != 0 }
    }

    pub fn external_opaque_native_clipboard_signature() -> Option<String> {
        match external_opaque_native_signature() {
            Ok(signature) => signature,
            Err(e) => {
                log::debug!("Failed to inspect clipboard formats: {}", e);
                None
            }
        }
    }
}

#[cfg(target_os = "macos")]
mod platform_clipboard {
    use cocoa::{
        appkit::{NSPasteboard, NSPasteboardItem},
        base::{id, nil},
        foundation::{NSArray, NSString},
    };
    use hbb_common::{bail, log, ResultType};
    use std::ffi::CStr;

    unsafe fn nsstring_to_string(value: id) -> Option<String> {
        if value == nil {
            return None;
        }
        // Safety: Cocoa returns a null-terminated UTF-8 view for NSString.
        let bytes = unsafe { NSString::UTF8String(value) };
        if bytes.is_null() {
            None
        } else {
            // Safety: bytes is valid for the lifetime of the Objective-C object.
            Some(
                unsafe { CStr::from_ptr(bytes) }
                    .to_string_lossy()
                    .into_owned(),
            )
        }
    }

    unsafe fn append_type_names(types: id, names: &mut Vec<String>) {
        if types == nil {
            return;
        }
        // Safety: types is an NSArray returned by NSPasteboard APIs.
        let count = unsafe { NSArray::count(types) };
        names.reserve(count as usize);
        for index in 0..count {
            // Safety: index is below count and NSArray elements are NSString instances.
            let value = unsafe { NSArray::objectAtIndex(types, index) };
            if let Some(name) = unsafe { nsstring_to_string(value) } {
                names.push(name);
            }
        }
    }

    fn pasteboard_type_names() -> ResultType<Vec<String>> {
        let mut names = Vec::new();
        unsafe {
            // Safety: generalPasteboard is an AppKit singleton and does not require ownership.
            let pasteboard = NSPasteboard::generalPasteboard(nil);
            if pasteboard == nil {
                bail!("failed to get macOS general pasteboard");
            }
            // Prefer item-local types because vector editors often attach native
            // formats to pasteboard items while still publishing plain fallbacks.
            let items = NSPasteboard::pasteboardItems(pasteboard);
            if items != nil {
                let count = NSArray::count(items);
                for index in 0..count {
                    let item = NSArray::objectAtIndex(items, index);
                    let types = NSPasteboardItem::types(item);
                    append_type_names(types, &mut names);
                }
            }
            if names.is_empty() {
                append_type_names(NSPasteboard::types(pasteboard), &mut names);
            }
        }
        Ok(names)
    }

    fn pasteboard_change_count() -> ResultType<isize> {
        unsafe {
            // Safety: generalPasteboard is an AppKit singleton and does not require ownership.
            let pasteboard = NSPasteboard::generalPasteboard(nil);
            if pasteboard == nil {
                bail!("failed to get macOS general pasteboard");
            }
            // Safety: changeCount only reads the pasteboard generation counter.
            Ok(NSPasteboard::changeCount(pasteboard) as isize)
        }
    }

    fn external_opaque_native_signature() -> ResultType<Option<String>> {
        let names = pasteboard_type_names()?;
        let change_count = pasteboard_change_count()?;
        Ok(super::external_preserved_native_formats_signature(&names)
            .map(|signature| format!("macos:{change_count}:{signature}")))
    }

    pub fn debug_dump_clipboard_formats(reason: &str) {
        if !super::clipboard_debug_enabled() {
            return;
        }
        match pasteboard_type_names() {
            Ok(names) => {
                let has_owner = super::contains_rustdesk_owner_format_name(&names);
                let opaque = super::contains_preserved_native_format_name(&names);
                super::emit_clipboard_debug(format!(
                    "{reason} owner_marker={has_owner} opaque={opaque} external_opaque={} types=[{}]",
                    opaque && !has_owner,
                    names.join(", ")
                ));
            }
            Err(e) => {
                super::emit_clipboard_debug(format!(
                    "{reason} failed to inspect macOS clipboard: {e}"
                ));
            }
        }
    }

    pub fn external_opaque_native_clipboard_signature() -> Option<String> {
        match external_opaque_native_signature() {
            Ok(signature) => signature,
            Err(e) => {
                log::debug!("Failed to inspect macOS clipboard types: {}", e);
                None
            }
        }
    }
}

#[cfg(target_os = "linux")]
mod platform_clipboard {
    use hbb_common::{bail, log, ResultType};
    use std::{
        thread,
        time::{Duration, Instant},
    };
    use wl_clipboard_rs::paste::{get_mime_types, ClipboardType, Seat};
    use x11rb_clipboard::{
        connection::Connection,
        protocol::{
            xproto::{Atom, AtomEnum, ConnectionExt as _, CreateWindowAux, EventMask, WindowClass},
            Event,
        },
        rust_connection::RustConnection,
        COPY_DEPTH_FROM_PARENT, COPY_FROM_PARENT, CURRENT_TIME, NONE,
    };

    const X11_TARGET_WAIT_DUR: Duration = Duration::from_millis(250);
    const X11_TARGET_POLL_DUR: Duration = Duration::from_millis(5);
    const X11_CLIPBOARD_ATOM: &str = "CLIPBOARD";
    const X11_TARGETS_ATOM: &str = "TARGETS";
    const X11_TARGET_PROPERTY_ATOM: &str = "RUSTDESK_CLIPBOARD_TARGETS";

    fn wayland_type_names() -> Option<Vec<String>> {
        if std::env::var_os("WAYLAND_DISPLAY").is_none() {
            return None;
        }
        match get_mime_types(ClipboardType::Regular, Seat::Unspecified) {
            Ok(names) => Some(names.into_iter().collect()),
            Err(e) => {
                log::debug!("Failed to inspect Wayland clipboard MIME types: {}", e);
                None
            }
        }
    }

    fn intern_atom(conn: &RustConnection, name: &str) -> ResultType<Atom> {
        Ok(conn.intern_atom(false, name.as_bytes())?.reply()?.atom)
    }

    fn atom_name(conn: &RustConnection, atom: Atom) -> ResultType<String> {
        Ok(String::from_utf8(conn.get_atom_name(atom)?.reply()?.name)?)
    }

    fn read_x11_target_names(
        conn: &RustConnection,
        win: u32,
        clipboard: Atom,
        targets: Atom,
        property: Atom,
    ) -> ResultType<Vec<String>> {
        conn.convert_selection(win, clipboard, targets, property, CURRENT_TIME)?;
        conn.flush()?;

        let deadline = Instant::now() + X11_TARGET_WAIT_DUR;
        loop {
            if Instant::now() >= deadline {
                bail!("timed out waiting for X11 clipboard TARGETS");
            }
            if let Some(event) = conn.poll_for_event()? {
                let Event::SelectionNotify(event) = event else {
                    continue;
                };
                if event.requestor != win || event.selection != clipboard || event.target != targets
                {
                    continue;
                }
                if event.property == NONE {
                    return Ok(Vec::new());
                }
                let reply = conn
                    .get_property(true, win, property, AtomEnum::ATOM, 0, 4096)?
                    .reply()?;
                let Some(atoms) = reply.value32() else {
                    return Ok(Vec::new());
                };
                let mut names = Vec::with_capacity(reply.value_len as usize);
                for atom in atoms {
                    names.push(atom_name(conn, atom)?);
                }
                return Ok(names);
            }
            thread::sleep(X11_TARGET_POLL_DUR);
        }
    }

    fn x11_type_names() -> ResultType<Vec<String>> {
        let (conn, screen_num) = RustConnection::connect(None)?;
        let screen = conn
            .setup()
            .roots
            .get(screen_num)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("no X11 screen found"))?;
        let win = conn.generate_id()?;
        conn.create_window(
            COPY_DEPTH_FROM_PARENT,
            win,
            screen.root,
            0,
            0,
            1,
            1,
            0,
            WindowClass::COPY_FROM_PARENT,
            COPY_FROM_PARENT,
            &CreateWindowAux::new().event_mask(EventMask::PROPERTY_CHANGE),
        )?;
        conn.flush()?;

        let clipboard = intern_atom(&conn, X11_CLIPBOARD_ATOM)?;
        let owner = conn.get_selection_owner(clipboard)?.reply()?.owner;
        if owner == NONE {
            let _ = conn.destroy_window(win);
            return Ok(Vec::new());
        }
        let targets = intern_atom(&conn, X11_TARGETS_ATOM)?;
        let property = intern_atom(&conn, X11_TARGET_PROPERTY_ATOM)?;
        let result = read_x11_target_names(&conn, win, clipboard, targets, property);
        let _ = conn.destroy_window(win);
        result
    }

    fn clipboard_type_names() -> ResultType<Vec<String>> {
        if let Some(names) = wayland_type_names() {
            return Ok(names);
        }
        x11_type_names()
    }

    fn external_opaque_native_signature() -> ResultType<Option<String>> {
        let names = clipboard_type_names()?;
        Ok(super::external_preserved_native_formats_signature(&names))
    }

    pub fn debug_dump_clipboard_formats(reason: &str) {
        if !super::clipboard_debug_enabled() {
            return;
        }
        match clipboard_type_names() {
            Ok(names) => {
                let has_owner = super::contains_rustdesk_owner_format_name(&names);
                let opaque = super::contains_preserved_native_format_name(&names);
                super::emit_clipboard_debug(format!(
                    "{reason} owner_marker={has_owner} opaque={opaque} external_opaque={} types=[{}]",
                    opaque && !has_owner,
                    names.join(", ")
                ));
            }
            Err(e) => {
                super::emit_clipboard_debug(format!(
                    "{reason} failed to inspect Linux clipboard: {e}"
                ));
            }
        }
    }

    pub fn external_opaque_native_clipboard_signature() -> Option<String> {
        match external_opaque_native_signature() {
            Ok(signature) => signature,
            Err(e) => {
                log::debug!("Failed to inspect Linux clipboard types: {}", e);
                None
            }
        }
    }
}

#[cfg(not(target_os = "android"))]
pub fn check_clipboard(
    ctx: &mut Option<ClipboardContext>,
    side: ClipboardSide,
    force: bool,
) -> Option<Message> {
    if matches!(side, ClipboardSide::Host) {
        let direction_policy = clipboard_direction_policy_for_side(side);
        if !direction_policy.allows_local_to_remote() {
            emit_clipboard_direction_skip("local-read", side, direction_policy);
            return None;
        }
    }

    if ctx.is_none() {
        *ctx = ClipboardContext::new().ok();
    }
    let ctx2 = ctx.as_mut()?;
    match ctx2.get(side, force) {
        Ok(content) => {
            if !content.is_empty() {
                mark_local_clipboard_change(side);
                let mut msg = Message::new();
                let clipboards = proto::create_multi_clipboards(content);
                msg.set_multi_clipboards(clipboards.clone());
                *LAST_MULTI_CLIPBOARDS.lock().unwrap() = clipboards;
                return Some(msg);
            }
        }
        Err(e) => {
            log::error!("Failed to get clipboard content. {}", e);
        }
    }
    None
}

#[cfg(all(feature = "unix-file-copy-paste", target_os = "macos"))]
pub fn is_file_url_set_by_rustdesk(url: &Vec<String>) -> bool {
    if url.len() != 1 {
        return false;
    }
    url.iter()
        .next()
        .map(|s| {
            for prefix in &["file:///tmp/.rustdesk_", "//tmp/.rustdesk_"] {
                if s.starts_with(prefix) {
                    return s[prefix.len()..].parse::<uuid::Uuid>().is_ok();
                }
            }
            false
        })
        .unwrap_or(false)
}

#[cfg(feature = "unix-file-copy-paste")]
pub fn check_clipboard_files(
    ctx: &mut Option<ClipboardContext>,
    side: ClipboardSide,
    force: bool,
) -> Option<Vec<String>> {
    if ctx.is_none() {
        *ctx = ClipboardContext::new().ok();
    }
    let ctx2 = ctx.as_mut()?;
    match ctx2.get_files(side, force) {
        Ok(Some(urls)) => {
            if !urls.is_empty() {
                return Some(urls);
            }
        }
        Err(e) => {
            log::error!("Failed to get clipboard file urls. {}", e);
        }
        _ => {}
    }
    None
}

#[cfg(all(target_os = "linux", feature = "unix-file-copy-paste"))]
pub fn update_clipboard_files(files: Vec<String>, side: ClipboardSide) {
    if !files.is_empty() {
        std::thread::spawn(move || {
            do_update_clipboard_(
                vec![ClipboardData::FileUrl(files)],
                side,
                clipboard_direction_policy_for_side(side),
            );
        });
    }
}

#[cfg(feature = "unix-file-copy-paste")]
pub fn try_empty_clipboard_files(_side: ClipboardSide, _conn_id: i32) {
    std::thread::spawn(move || {
        let mut ctx = CLIPBOARD_CTX.lock().unwrap();
        if ctx.is_none() {
            match ClipboardContext::new() {
                Ok(x) => {
                    *ctx = Some(x);
                }
                Err(e) => {
                    log::error!("Failed to create clipboard context: {}", e);
                    return;
                }
            }
        }
        #[allow(unused_mut)]
        if let Some(mut ctx) = ctx.as_mut() {
            #[cfg(target_os = "linux")]
            {
                use clipboard::platform::unix;
                if unix::fuse::empty_local_files(_side == ClipboardSide::Client, _conn_id) {
                    ctx.try_empty_clipboard_files(_side);
                }
            }
            #[cfg(target_os = "macos")]
            {
                ctx.try_empty_clipboard_files(_side);
                // No need to make sure the context is enabled.
                clipboard::ContextSend::proc(|context| -> ResultType<()> {
                    context.empty_clipboard(_conn_id).ok();
                    Ok(())
                })
                .ok();
            }
        }
    });
}

#[cfg(target_os = "windows")]
pub fn try_empty_clipboard_files(side: ClipboardSide, conn_id: i32) {
    log::debug!("try to empty {} cliprdr for conn_id {}", side, conn_id);
    let _ = clipboard::ContextSend::proc(|context| -> ResultType<()> {
        context.empty_clipboard(conn_id)?;
        Ok(())
    });
}

#[cfg(target_os = "windows")]
pub fn check_clipboard_cm() -> ResultType<MultiClipboards> {
    let direction_policy = clipboard_direction_policy_for_side(ClipboardSide::Host);
    if !direction_policy.allows_local_to_remote() {
        emit_clipboard_direction_skip("local-read", ClipboardSide::Host, direction_policy);
        return Ok(MultiClipboards::new());
    }

    let mut ctx = CLIPBOARD_CTX.lock().unwrap();
    if ctx.is_none() {
        match ClipboardContext::new() {
            Ok(x) => {
                *ctx = Some(x);
            }
            Err(e) => {
                hbb_common::bail!("Failed to create clipboard context: {}", e);
            }
        }
    }
    if let Some(ctx) = ctx.as_mut() {
        let content = ctx.get(ClipboardSide::Host, false)?;
        let clipboards = proto::create_multi_clipboards(content);
        Ok(clipboards)
    } else {
        hbb_common::bail!("Failed to create clipboard context");
    }
}

#[cfg(not(target_os = "android"))]
fn update_clipboard_(
    multi_clipboards: Vec<Clipboard>,
    side: ClipboardSide,
    direction_policy: ClipboardDirectionPolicy,
) {
    let to_update_data = proto::from_multi_clipboards(multi_clipboards);
    if to_update_data.is_empty() {
        return;
    }
    do_update_clipboard_(to_update_data, side, direction_policy);
}

#[cfg(not(target_os = "android"))]
fn do_update_clipboard_(
    mut to_update_data: Vec<ClipboardData>,
    side: ClipboardSide,
    direction_policy: ClipboardDirectionPolicy,
) {
    if should_skip_remote_clipboard_update(&to_update_data, side, direction_policy, "before-delay")
    {
        return;
    }
    if let Some(delay) = remote_clipboard_update_delay(side) {
        std::thread::sleep(delay);
        if should_skip_remote_clipboard_update(
            &to_update_data,
            side,
            direction_policy,
            "after-delay",
        ) {
            return;
        }
        if remote_clipboard_update_delay(side).is_some() {
            log::debug!(
                "Skip delayed {} clipboard update because a newer local clipboard change was observed",
                side
            );
            emit_clipboard_debug(format!(
                "skip-remote-apply side={side} phase=after-delay reason=newer-local-change"
            ));
            return;
        }
    }
    let mut ctx = CLIPBOARD_CTX.lock().unwrap();
    if ctx.is_none() {
        match ClipboardContext::new() {
            Ok(x) => {
                *ctx = Some(x);
            }
            Err(e) => {
                log::error!("Failed to create clipboard context: {}", e);
                return;
            }
        }
    }
    if let Some(ctx) = ctx.as_mut() {
        remove_remote_owner_markers(&mut to_update_data);
        if to_update_data.is_empty() {
            return;
        }
        to_update_data.push(ClipboardData::Special((
            RUSTDESK_CLIPBOARD_OWNER_FORMAT.to_owned(),
            side.get_owner_data(),
        )));
        if let Err(e) = ctx.set(&to_update_data, side) {
            log::debug!("Failed to set clipboard: {}", e);
        } else {
            mark_remote_clipboard_applied(side);
            log::debug!("{} updated on {}", CLIPBOARD_NAME, side);
        }
    }
}

#[cfg(not(target_os = "android"))]
pub fn update_clipboard(multi_clipboards: Vec<Clipboard>, side: ClipboardSide) {
    update_clipboard_with_direction(
        multi_clipboards,
        side,
        clipboard_direction_policy_for_side(side),
    );
}

#[cfg(not(target_os = "android"))]
pub(crate) fn update_clipboard_with_direction(
    multi_clipboards: Vec<Clipboard>,
    side: ClipboardSide,
    direction_policy: ClipboardDirectionPolicy,
) {
    std::thread::spawn(move || {
        update_clipboard_(multi_clipboards, side, direction_policy);
    });
}

#[cfg(not(target_os = "android"))]
pub struct ClipboardContext {
    inner: arboard::Clipboard,
}

#[cfg(not(target_os = "android"))]
#[allow(unreachable_code)]
impl ClipboardContext {
    pub fn new() -> ResultType<ClipboardContext> {
        let board;
        #[cfg(not(target_os = "linux"))]
        {
            board = arboard::Clipboard::new()?;
        }
        #[cfg(target_os = "linux")]
        {
            let mut i = 1;
            loop {
                // Try 5 times to create clipboard
                // Arboard::new() connect to X server or Wayland compositor, which should be OK most times
                // But sometimes, the connection may fail, so we retry here.
                match arboard::Clipboard::new() {
                    Ok(x) => {
                        board = x;
                        break;
                    }
                    Err(e) => {
                        if i == 5 {
                            return Err(e.into());
                        } else {
                            std::thread::sleep(std::time::Duration::from_millis(30 * i));
                        }
                    }
                }
                i += 1;
            }
        }

        Ok(ClipboardContext { inner: board })
    }

    fn get_formats(&mut self, formats: &[ClipboardFormat]) -> ResultType<Vec<ClipboardData>> {
        // If there're multiple threads or processes trying to access the clipboard at the same time,
        // the previous clipboard owner will fail to access the clipboard.
        // `GetLastError()` will return `ERROR_CLIPBOARD_NOT_OPEN` (OSError(1418): Thread does not have a clipboard open) at this time.
        // See https://github.com/rustdesk-org/arboard/blob/747ab2d9b40a5c9c5102051cf3b0bb38b4845e60/src/platform/windows.rs#L34
        //
        // This is a common case on Windows, so we retry here.
        // Related issues:
        // https://github.com/rustdesk/rustdesk/issues/9263
        // https://github.com/rustdesk/rustdesk/issues/9222#issuecomment-2329233175
        for i in 0..CLIPBOARD_GET_MAX_RETRY {
            match self.inner.get_formats(formats) {
                Ok(data) => {
                    return Ok(data
                        .into_iter()
                        .filter(|c| !matches!(c, arboard::ClipboardData::None))
                        .collect())
                }
                Err(e) => match e {
                    arboard::Error::ClipboardOccupied => {
                        log::debug!("Failed to get clipboard formats, clipboard is occupied, retrying... {}", i + 1);
                        std::thread::sleep(CLIPBOARD_GET_RETRY_INTERVAL_DUR);
                    }
                    _ => {
                        log::error!("Failed to get clipboard formats, {}", e);
                        return Err(e.into());
                    }
                },
            }
        }
        bail!("Failed to get clipboard formats, clipboard is occupied, {CLIPBOARD_GET_MAX_RETRY} retries failed");
    }

    pub fn get(&mut self, side: ClipboardSide, force: bool) -> ResultType<Vec<ClipboardData>> {
        #[cfg(target_os = "windows")]
        if !force {
            // Windows apps such as Illustrator can publish delayed-render clipboard
            // formats shortly after an empty clipboard-change notification. Do not
            // inspect the clipboard while the owner is still assembling native data.
            std::thread::sleep(WINDOWS_LOCAL_CLIPBOARD_READ_DEBOUNCE_DUR);
        }

        #[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
        {
            // Inspect native format names before reading payloads. Some apps delay-render
            // vector clipboard data, and reading fallbacks can disturb their native clipboard.
            platform_clipboard::debug_dump_clipboard_formats("get-before-native-guard");
            if let Some(signature) =
                platform_clipboard::external_opaque_native_clipboard_signature()
            {
                mark_local_external_opaque_clipboard_change(side, &signature);
                clear_cached_clipboard();
                log::debug!(
                    "Skip transferring {} clipboard because it contains opaque native formats",
                    side
                );
                emit_clipboard_debug(format!(
                    "native-clipboard-preserved side={side} action=skip-transfer reason=opaque-native-formats"
                ));
                return Ok(vec![]);
            }
        }

        let data = self.get_formats_filter(SUPPORTED_FORMATS, side, force)?;
        debug_clipboard_data("get-supported-formats", side, &data);
        // We have a separate service named `file-clipboard` to handle file copy-paste.
        // We need to read the file urls because file copy may set the other clipboard formats such as text.
        #[cfg(feature = "unix-file-copy-paste")]
        {
            if data.iter().any(|c| matches!(c, ClipboardData::FileUrl(_))) {
                return Ok(vec![]);
            }
        }
        Ok(data)
    }

    fn get_formats_filter(
        &mut self,
        formats: &[ClipboardFormat],
        side: ClipboardSide,
        force: bool,
    ) -> ResultType<Vec<ClipboardData>> {
        let _lock = ARBOARD_MTX.lock().unwrap();
        let data = self.get_formats(formats)?;
        if data.is_empty() {
            return Ok(data);
        }
        if !force {
            for c in data.iter() {
                if let ClipboardData::Special((s, d)) = c {
                    if s == RUSTDESK_CLIPBOARD_OWNER_FORMAT && side.is_owner(d) {
                        return Ok(vec![]);
                    }
                }
            }
        }
        Ok(data
            .into_iter()
            .filter(|c| match c {
                ClipboardData::Special((s, _)) => s != RUSTDESK_CLIPBOARD_OWNER_FORMAT,
                // Skip synchronizing empty text to the remote clipboard
                ClipboardData::Text(text) => !text.is_empty(),
                _ => true,
            })
            .collect())
    }

    #[cfg(feature = "unix-file-copy-paste")]
    pub fn get_files(
        &mut self,
        side: ClipboardSide,
        force: bool,
    ) -> ResultType<Option<Vec<String>>> {
        let data = self.get_formats_filter(
            &[
                ClipboardFormat::FileUrl,
                ClipboardFormat::Special(RUSTDESK_CLIPBOARD_OWNER_FORMAT),
            ],
            side,
            force,
        )?;
        Ok(data.into_iter().find_map(|c| match c {
            ClipboardData::FileUrl(urls) => Some(urls),
            _ => None,
        }))
    }

    fn set(&mut self, data: &[ClipboardData], side: ClipboardSide) -> ResultType<()> {
        let _lock = ARBOARD_MTX.lock().unwrap();
        debug_clipboard_data("set-incoming-formats", side, data);
        #[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
        {
            platform_clipboard::debug_dump_clipboard_formats("set-before-native-guard");
        }
        self.inner.set_formats(data)?;
        Ok(())
    }

    #[cfg(all(feature = "unix-file-copy-paste", target_os = "macos"))]
    fn get_file_urls_set_by_rustdesk(
        data: Vec<ClipboardData>,
        _side: ClipboardSide,
    ) -> Vec<String> {
        for item in data.into_iter() {
            if let ClipboardData::FileUrl(urls) = item {
                if is_file_url_set_by_rustdesk(&urls) {
                    return urls;
                }
            }
        }
        vec![]
    }

    #[cfg(all(feature = "unix-file-copy-paste", target_os = "linux"))]
    fn get_file_urls_set_by_rustdesk(data: Vec<ClipboardData>, side: ClipboardSide) -> Vec<String> {
        let exclude_path =
            clipboard::platform::unix::fuse::get_exclude_paths(side == ClipboardSide::Client);
        data.into_iter()
            .filter_map(|c| match c {
                ClipboardData::FileUrl(urls) => Some(
                    urls.into_iter()
                        .filter(|s| s.starts_with(&*exclude_path))
                        .collect::<Vec<_>>(),
                ),
                _ => None,
            })
            .flatten()
            .collect::<Vec<_>>()
    }

    #[cfg(feature = "unix-file-copy-paste")]
    fn try_empty_clipboard_files(&mut self, side: ClipboardSide) {
        let _lock = ARBOARD_MTX.lock().unwrap();
        if let Ok(data) = self.get_formats(&[ClipboardFormat::FileUrl]) {
            let urls = Self::get_file_urls_set_by_rustdesk(data, side);
            if !urls.is_empty() {
                // FIXME:
                // The host-side clear file clipboard `let _ = self.inner.clear();`,
                // does not work on KDE Plasma for the installed version.

                // Don't use `hbb_common::platform::linux::is_kde()` here.
                // It's not correct in the server process.
                #[cfg(target_os = "linux")]
                let is_kde_x11 = hbb_common::platform::linux::is_kde_session()
                    && crate::platform::linux::is_x11();
                #[cfg(target_os = "macos")]
                let is_kde_x11 = false;
                let clear_holder_text = if is_kde_x11 {
                    "RustDesk placeholder to clear the file clipboard"
                } else {
                    ""
                }
                .to_string();
                self.inner
                    .set_formats(&[
                        ClipboardData::Text(clear_holder_text),
                        ClipboardData::Special((
                            RUSTDESK_CLIPBOARD_OWNER_FORMAT.to_owned(),
                            side.get_owner_data(),
                        )),
                    ])
                    .ok();
            }
        }
    }
}

pub fn is_support_multi_clipboard(peer_version: &str, peer_platform: &str) -> bool {
    use hbb_common::get_version_number;
    if get_version_number(peer_version) < get_version_number("1.3.0") {
        return false;
    }
    if ["", &hbb_common::whoami::Platform::Ios.to_string()].contains(&peer_platform) {
        return false;
    }
    if "Android" == peer_platform && get_version_number(peer_version) < get_version_number("1.3.3")
    {
        return false;
    }
    true
}

#[cfg(not(target_os = "android"))]
pub fn get_current_clipboard_msg(
    peer_version: &str,
    peer_platform: &str,
    side: ClipboardSide,
) -> Option<Message> {
    if matches!(side, ClipboardSide::Host) {
        let direction_policy = clipboard_direction_policy_for_side(side);
        if !direction_policy.allows_local_to_remote() {
            emit_clipboard_direction_skip("initial-local-read", side, direction_policy);
            return None;
        }
    }

    let mut multi_clipboards = LAST_MULTI_CLIPBOARDS.lock().unwrap();
    if multi_clipboards.clipboards.is_empty() {
        let mut ctx = ClipboardContext::new().ok()?;
        let content = ctx.get(side, true).ok()?;
        if !content.is_empty() {
            mark_local_clipboard_change(side);
        }
        *multi_clipboards = proto::create_multi_clipboards(content);
    }
    if multi_clipboards.clipboards.is_empty() {
        return None;
    }

    if is_support_multi_clipboard(peer_version, peer_platform) {
        let mut msg = Message::new();
        msg.set_multi_clipboards(multi_clipboards.clone());
        Some(msg)
    } else {
        // Find the first text clipboard and send it.
        multi_clipboards
            .clipboards
            .iter()
            .find(|c| c.format.enum_value() == Ok(hbb_common::message_proto::ClipboardFormat::Text))
            .map(|c| {
                let mut msg = Message::new();
                msg.set_clipboard(c.clone());
                msg
            })
    }
}

#[derive(PartialEq, Eq, Clone, Copy)]
pub enum ClipboardSide {
    Host,
    Client,
}

impl ClipboardSide {
    // 01: the clipboard is owned by the host
    // 10: the clipboard is owned by the client
    fn get_owner_data(&self) -> Vec<u8> {
        match self {
            ClipboardSide::Host => vec![0b01],
            ClipboardSide::Client => vec![0b10],
        }
    }

    fn is_owner(&self, data: &[u8]) -> bool {
        if data.len() == 0 {
            return false;
        }
        let owner_bit = match self {
            ClipboardSide::Host => 0b01,
            ClipboardSide::Client => 0b10,
        };
        data[0] & owner_bit != 0
    }
}

impl std::fmt::Display for ClipboardSide {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClipboardSide::Host => write!(f, "host"),
            ClipboardSide::Client => write!(f, "client"),
        }
    }
}

#[cfg(all(test, not(target_os = "android")))]
mod clipboard_timing_tests {
    use super::*;

    #[test]
    fn recent_local_change_delays_remote_update() {
        let start = Instant::now();
        let now = start + Duration::from_millis(100);
        let mut timing = ClipboardTiming::default();

        timing.mark_local_change(start);

        assert!(timing.remote_update_delay(now).is_some());
    }

    #[test]
    fn expired_local_change_allows_remote_update() {
        let start = Instant::now();
        let now = start + LOCAL_CLIPBOARD_QUIET_DUR + Duration::from_millis(1);
        let mut timing = ClipboardTiming::default();

        timing.mark_local_change(start);

        assert!(timing.remote_update_delay(now).is_none());
    }

    #[test]
    fn remote_apply_after_local_change_allows_next_remote_update() {
        let start = Instant::now();
        let now = start + Duration::from_millis(300);
        let mut timing = ClipboardTiming::default();

        timing.mark_local_change(start + Duration::from_millis(100));
        timing.mark_remote_apply(start + Duration::from_millis(200));

        assert!(timing.remote_update_delay(now).is_none());
    }

    #[test]
    fn remote_text_can_replace_local_opaque_clipboard() {
        let data = vec![ClipboardData::Text("remote text".to_owned())];

        assert!(remote_clipboard_data_block_reason(&data).is_none());
    }

    #[test]
    fn remote_opaque_special_format_is_not_applied() {
        let data = vec![ClipboardData::Special((
            "Ole Private Data".to_owned(),
            vec![0x01, 0x02],
        ))];

        assert_eq!(
            remote_clipboard_data_block_reason(&data),
            Some("opaque-native-format")
        );
    }

    #[test]
    fn remote_unknown_special_format_is_not_applied() {
        let data = vec![ClipboardData::Special((
            "private-editor-state".to_owned(),
            vec![0x01],
        ))];

        assert_eq!(
            remote_clipboard_data_block_reason(&data),
            Some("unknown-special-format")
        );
    }

    #[test]
    fn remote_safe_special_format_can_be_applied() {
        let data = vec![ClipboardData::Special((
            CLIPBOARD_FORMAT_EXCEL_XML_SPREADSHEET.to_owned(),
            b"<Workbook/>".to_vec(),
        ))];

        assert!(remote_clipboard_data_block_reason(&data).is_none());
    }

    #[test]
    fn remote_registered_special_format_is_not_applied() {
        for name in [
            "text/html",
            "image/png",
            "Chromium Web Custom MIME Data Format",
        ] {
            let data = vec![ClipboardData::Special((name.to_owned(), vec![0x01]))];

            assert_eq!(
                remote_clipboard_data_block_reason(&data),
                Some("unknown-special-format"),
                "{name}"
            );
        }
    }

    #[test]
    fn remote_owner_marker_is_stripped_before_local_apply() {
        let mut data = vec![
            ClipboardData::Text("remote text".to_owned()),
            ClipboardData::Special((RUSTDESK_CLIPBOARD_OWNER_FORMAT.to_owned(), vec![0b11])),
        ];

        remove_remote_owner_markers(&mut data);

        assert_eq!(data.len(), 1);
        assert!(matches!(&data[0], ClipboardData::Text(text) if text == "remote text"));
    }

    #[test]
    fn remote_unsupported_format_is_not_applied() {
        let data = vec![ClipboardData::Unsupported];

        assert_eq!(
            remote_clipboard_data_block_reason(&data),
            Some("unsupported-format")
        );
    }

    #[test]
    fn repeated_same_opaque_clipboard_does_not_refresh_local_change() {
        let start = Instant::now();
        let mut timing = ClipboardTiming::default();

        assert!(timing.mark_external_opaque_change("opaque:illustrator:1", start));
        assert!(!timing.mark_external_opaque_change(
            "opaque:illustrator:1",
            start + Duration::from_millis(500)
        ));

        assert!(timing
            .remote_update_delay(start + LOCAL_CLIPBOARD_QUIET_DUR + Duration::from_millis(1))
            .is_none());
    }

    #[test]
    fn different_opaque_clipboard_starts_new_quiet_window() {
        let start = Instant::now();
        let mut timing = ClipboardTiming::default();

        assert!(timing.mark_external_opaque_change("opaque:illustrator:1", start));
        assert!(timing.mark_external_opaque_change(
            "opaque:illustrator:2",
            start + Duration::from_millis(500)
        ));

        assert!(timing
            .remote_update_delay(start + LOCAL_CLIPBOARD_QUIET_DUR + Duration::from_millis(1))
            .is_some());
    }

    #[test]
    fn stable_opaque_clipboard_does_not_refresh_quiet_window() {
        let start = Instant::now();
        let mut timing = ClipboardTiming::default();

        assert!(timing.mark_external_opaque_change("opaque:illustrator:1", start));
        assert!(!timing.mark_external_opaque_change(
            "opaque:illustrator:1",
            start + Duration::from_millis(300)
        ));
        assert!(!timing.mark_external_opaque_change(
            "opaque:illustrator:1",
            start + Duration::from_millis(600)
        ));

        assert!(timing
            .remote_update_delay(start + LOCAL_CLIPBOARD_QUIET_DUR + Duration::from_millis(1))
            .is_none());
    }

    #[test]
    fn remote_apply_clears_opaque_signature_for_future_local_copy() {
        let start = Instant::now();
        let mut timing = ClipboardTiming::default();

        assert!(timing.mark_external_opaque_change("opaque:illustrator:1", start));
        timing.mark_remote_apply(start + LOCAL_CLIPBOARD_QUIET_DUR + Duration::from_millis(1));

        assert!(timing.mark_external_opaque_change(
            "opaque:illustrator:1",
            start + LOCAL_CLIPBOARD_QUIET_DUR + Duration::from_millis(10)
        ));
    }

    #[test]
    fn normal_local_change_clears_opaque_signature_for_future_local_copy() {
        let start = Instant::now();
        let mut timing = ClipboardTiming::default();

        assert!(timing.mark_external_opaque_change("opaque:illustrator:1", start));
        timing.mark_local_change(start + LOCAL_CLIPBOARD_QUIET_DUR + Duration::from_millis(1));

        assert!(timing.mark_external_opaque_change(
            "opaque:illustrator:1",
            start + LOCAL_CLIPBOARD_QUIET_DUR + Duration::from_millis(10)
        ));
    }

    #[test]
    fn owner_marker_is_side_specific_for_multi_hop_clipboard() {
        assert!(ClipboardSide::Host.is_owner(&ClipboardSide::Host.get_owner_data()));
        assert!(!ClipboardSide::Host.is_owner(&ClipboardSide::Client.get_owner_data()));
        assert!(ClipboardSide::Client.is_owner(&ClipboardSide::Client.get_owner_data()));
        assert!(!ClipboardSide::Client.is_owner(&ClipboardSide::Host.get_owner_data()));
        assert!(!ClipboardSide::Host.is_owner(&[]));
        assert!(!ClipboardSide::Client.is_owner(&[]));
    }

    #[test]
    fn clipboard_direction_policy_defaults_to_bidirectional() {
        for value in ["", "N", "both", "bidirectional", "all"] {
            let policy = ClipboardDirectionPolicy::from_option_value(value);
            assert_eq!(policy, ClipboardDirectionPolicy::Both, "{value}");
            assert!(policy.allows_local_to_remote(), "{value}");
            assert!(policy.allows_remote_to_local(), "{value}");
        }
    }

    #[test]
    fn legacy_one_way_clipboard_policy_is_remote_to_local() {
        for value in ["Y", "yes", "true", "1", "remote-to-local", "receive-only"] {
            let policy = ClipboardDirectionPolicy::from_option_value(value);
            assert_eq!(policy, ClipboardDirectionPolicy::RemoteToLocal, "{value}");
            assert!(!policy.allows_local_to_remote(), "{value}");
            assert!(policy.allows_remote_to_local(), "{value}");
        }
    }

    #[test]
    fn clipboard_direction_policy_supports_send_only_and_off() {
        let local_to_remote = ClipboardDirectionPolicy::from_option_value("local-to-remote");
        assert_eq!(local_to_remote, ClipboardDirectionPolicy::LocalToRemote);
        assert!(local_to_remote.allows_local_to_remote());
        assert!(!local_to_remote.allows_remote_to_local());

        for value in ["off", "none", "disabled", "invalid"] {
            let policy = ClipboardDirectionPolicy::from_option_value(value);
            assert_eq!(policy, ClipboardDirectionPolicy::Off, "{value}");
            assert!(!policy.allows_local_to_remote(), "{value}");
            assert!(!policy.allows_remote_to_local(), "{value}");
        }
    }

    #[test]
    fn adobe_vector_formats_are_opaque() {
        for name in [
            "Adobe Illustrator Document",
            "AICB",
            "AI Private Data",
            "Portable Document Format",
            "application/pdf",
            "application/vnd.adobe.illustrator",
            "public.pdf",
            "public.postscript",
            "Encapsulated PostScript",
            "EPS",
        ] {
            assert!(is_opaque_native_format_name(name), "{name}");
        }
    }

    #[test]
    fn common_text_and_web_formats_are_not_opaque() {
        for name in [
            "HTML Format",
            "Rich Text Format",
            "text/plain",
            "text/plain;charset=utf-8",
            "Chromium Web Custom MIME Data Format",
            "WebKit Smart Paste Format",
            "public.utf8-plain-text",
            "public.html",
            "TARGETS",
            RUSTDESK_CLIPBOARD_OWNER_FORMAT,
        ] {
            assert!(is_safe_registered_format_name(name), "{name}");
            assert!(!is_opaque_native_format_name(name), "{name}");
            assert!(!should_preserve_native_format_name(name), "{name}");
        }
    }

    #[test]
    fn eager_clipboard_formats_do_not_materialize_images() {
        assert!(SUPPORTED_FORMATS
            .iter()
            .any(|format| matches!(format, ClipboardFormat::Text)));
        assert!(SUPPORTED_FORMATS
            .iter()
            .any(|format| matches!(format, ClipboardFormat::Html)));
        assert!(SUPPORTED_FORMATS
            .iter()
            .any(|format| matches!(format, ClipboardFormat::Rtf)));
        assert!(!SUPPORTED_FORMATS.iter().any(|format| matches!(
            format,
            ClipboardFormat::ImageRgba | ClipboardFormat::ImagePng | ClipboardFormat::ImageSvg
        )));
    }

    #[test]
    fn risky_desktop_native_formats_are_preserved() {
        for name in [
            "application/vnd.oasis.opendocument.text",
            "public.rtf",
            "public.pdf",
            "com.adobe.illustrator.aicb",
            "org.inkscape.output",
        ] {
            if name == "public.rtf" {
                assert!(!should_preserve_native_format_name(name), "{name}");
            } else {
                assert!(should_preserve_native_format_name(name), "{name}");
            }
        }
    }

    #[test]
    fn windows_editor_private_text_metadata_is_not_opaque() {
        assert!(!is_windows_opaque_registered_format_name(
            "sublime-text-extra"
        ));
        assert!(!is_windows_opaque_registered_format_name(
            "DataObjectAttributes"
        ));
        assert!(is_windows_opaque_registered_format_name(
            "Adobe Illustrator Document"
        ));
    }

    #[test]
    fn windows_ole_private_formats_are_opaque() {
        for name in [
            "CF_METAFILEPICT",
            "CF_TIFF",
            "CF_ENHMETAFILE",
            "DataObject",
            "Object Descriptor",
            "Ole Private Data",
            "Embed Source",
            "Embedded Object",
            "Link Source",
            "Link Source Descriptor",
            "Native",
            "OwnerLink",
            "System.Drawing.Bitmap",
        ] {
            assert!(is_windows_opaque_registered_format_name(name), "{name}");
        }
    }

    #[test]
    fn windows_empty_external_format_list_is_opaque() {
        assert_eq!(
            windows_external_opaque_signature_from_format_names(42, false, &[]).as_deref(),
            Some("windows:42:empty-format-list")
        );
        assert!(windows_external_opaque_signature_from_format_names(42, true, &[]).is_none());
    }

    #[test]
    fn windows_text_with_generic_ole_wrappers_is_not_opaque() {
        let names = vec![
            "CF_UNICODETEXT".to_owned(),
            "DataObject".to_owned(),
            "Ole Private Data".to_owned(),
            "HTML Format".to_owned(),
        ];

        assert!(windows_external_opaque_signature_from_format_names(7, false, &names).is_none());
    }

    #[test]
    fn windows_qt_text_with_ole_wrappers_is_not_opaque() {
        let names = vec![
            "DataObject".to_owned(),
            "CF_UNICODETEXT".to_owned(),
            "CF_TEXT".to_owned(),
            "HTML Format".to_owned(),
            "text/markdown".to_owned(),
            "application/vnd.oasis.opendocument.text".to_owned(),
            "Ole Private Data".to_owned(),
            "CF_LOCALE".to_owned(),
            "CF_OEMTEXT".to_owned(),
        ];

        assert!(windows_external_opaque_signature_from_format_names(8, false, &names).is_none());
    }

    #[test]
    fn windows_text_ole_wrappers_without_text_fallback_are_opaque() {
        let names = vec!["DataObject".to_owned(), "Ole Private Data".to_owned()];

        assert_eq!(
            windows_external_opaque_signature_from_format_names(9, false, &names).as_deref(),
            Some("windows:9:DataObject|Ole Private Data")
        );
    }

    #[test]
    fn windows_vector_formats_remain_opaque_even_with_text_fallbacks() {
        let names = vec![
            "CF_UNICODETEXT".to_owned(),
            "DataObject".to_owned(),
            "Ole Private Data".to_owned(),
            "Adobe Illustrator Document".to_owned(),
            "HTML Format".to_owned(),
        ];

        assert_eq!(
            windows_external_opaque_signature_from_format_names(10, false, &names).as_deref(),
            Some("windows:10:Adobe Illustrator Document|DataObject|Ole Private Data")
        );
    }

    #[test]
    fn opaque_native_formats_take_precedence_over_text_fallbacks() {
        let names = vec!["text/plain".to_owned(), "application/pdf".to_owned()];

        assert!(contains_external_preserved_native_format_name(&names));
    }

    #[test]
    fn opaque_native_signature_ignores_safe_fallbacks() {
        let names = vec![
            "text/plain".to_owned(),
            "application/pdf".to_owned(),
            "HTML Format".to_owned(),
            "com.adobe.illustrator.aicb".to_owned(),
        ];

        assert_eq!(
            external_preserved_native_formats_signature(&names).as_deref(),
            Some("application/pdf|com.adobe.illustrator.aicb")
        );
    }

    #[test]
    fn rustdesk_owned_formats_are_not_external_opaque() {
        let names = vec![
            RUSTDESK_CLIPBOARD_OWNER_FORMAT.to_owned(),
            "public.pdf".to_owned(),
        ];

        assert!(contains_rustdesk_owner_format_name(&names));
        assert!(contains_preserved_native_format_name(&names));
        assert!(!contains_external_preserved_native_format_name(&names));
        assert!(external_preserved_native_formats_signature(&names).is_none());
    }
}

#[cfg(all(test, target_os = "windows"))]
mod clipboard_windows_integration_tests {
    use super::*;
    use std::{
        ffi::OsStr,
        os::windows::ffi::OsStrExt,
        ptr::{copy_nonoverlapping, null, null_mut},
        sync::{
            atomic::{AtomicUsize, Ordering},
            Mutex as StdMutex,
        },
        thread,
        time::Duration,
    };
    use winapi::{
        shared::{
            minwindef::{LPARAM, LRESULT, UINT, WPARAM},
            windef::HWND,
        },
        um::{
            libloaderapi::GetModuleHandleW,
            winbase::{GlobalAlloc, GlobalFree, GlobalLock, GlobalUnlock, GMEM_MOVEABLE},
            winuser::{
                CloseClipboard, CreateWindowExW, DefWindowProcW, DestroyWindow, EmptyClipboard,
                IsClipboardFormatAvailable, OpenClipboard, RegisterClassW,
                RegisterClipboardFormatW, SetClipboardData, HWND_MESSAGE, WM_RENDERALLFORMATS,
                WM_RENDERFORMAT, WNDCLASSW,
            },
        },
    };

    const CF_UNICODETEXT: UINT = 13;
    const WINDOWS_CLIPBOARD_INTEGRATION_ENV: &str = "RUSTDESK_CLIPBOARD_INTEGRATION_TESTS";
    static TEST_MUTEX: StdMutex<()> = StdMutex::new(());
    static RENDER_REQUESTS: AtomicUsize = AtomicUsize::new(0);

    unsafe extern "system" fn delayed_render_window_proc(
        hwnd: HWND,
        msg: UINT,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        if msg == WM_RENDERFORMAT || msg == WM_RENDERALLFORMATS {
            RENDER_REQUESTS.fetch_add(1, Ordering::SeqCst);
        }
        // Safety: Parameters are forwarded unchanged from the system callback.
        unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
    }

    struct TestWindow {
        hwnd: HWND,
    }

    impl TestWindow {
        fn new() -> Result<Self, String> {
            let class_name = wide_z("RustDeskClipboardIntegrationWindow");
            // Safety: GetModuleHandleW accepts a null module name for the current process.
            let instance = unsafe { GetModuleHandleW(null()) };
            if instance.is_null() {
                return Err("GetModuleHandleW failed".to_owned());
            }
            let wnd_class = WNDCLASSW {
                style: 0,
                lpfnWndProc: Some(delayed_render_window_proc),
                cbClsExtra: 0,
                cbWndExtra: 0,
                hInstance: instance,
                hIcon: null_mut(),
                hCursor: null_mut(),
                hbrBackground: null_mut(),
                lpszMenuName: null(),
                lpszClassName: class_name.as_ptr(),
            };
            // Safety: wnd_class points to valid data for the duration of the call.
            unsafe {
                RegisterClassW(&wnd_class);
            }
            // Safety: The class was registered above or already existed from another test.
            let hwnd = unsafe {
                CreateWindowExW(
                    0,
                    class_name.as_ptr(),
                    class_name.as_ptr(),
                    0,
                    0,
                    0,
                    0,
                    0,
                    HWND_MESSAGE,
                    null_mut(),
                    instance,
                    null_mut(),
                )
            };
            if hwnd.is_null() {
                Err("CreateWindowExW failed".to_owned())
            } else {
                Ok(Self { hwnd })
            }
        }
    }

    impl Drop for TestWindow {
        fn drop(&mut self) {
            // Safety: hwnd was returned by CreateWindowExW and is owned by TestWindow.
            unsafe {
                DestroyWindow(self.hwnd);
            }
        }
    }

    struct ClipboardOpenGuard;

    impl ClipboardOpenGuard {
        fn open(owner: HWND) -> Result<Self, String> {
            for _ in 0..20 {
                // Safety: owner is a valid test window handle for these tests.
                if unsafe { OpenClipboard(owner) } != 0 {
                    return Ok(Self);
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err("OpenClipboard failed".to_owned())
        }
    }

    impl Drop for ClipboardOpenGuard {
        fn drop(&mut self) {
            // Safety: ClipboardOpenGuard is only constructed after OpenClipboard succeeds.
            unsafe {
                CloseClipboard();
            }
        }
    }

    struct ClipboardFixture {
        window: TestWindow,
    }

    impl ClipboardFixture {
        fn new() -> Result<Self, String> {
            Ok(Self {
                window: TestWindow::new()?,
            })
        }

        fn set_formats(
            &self,
            text: Option<&str>,
            data_format_names: &[&str],
            delayed_format_names: &[&str],
        ) -> Result<(), String> {
            let _clipboard = ClipboardOpenGuard::open(self.window.hwnd)?;
            // Safety: The clipboard is open and owned by the test window.
            if unsafe { EmptyClipboard() } == 0 {
                return Err("EmptyClipboard failed".to_owned());
            }
            if let Some(text) = text {
                set_unicode_text(text)?;
            }
            for name in data_format_names {
                set_registered_data_format(name, b"RustDesk clipboard integration wrapper")?;
            }
            for name in delayed_format_names {
                set_delayed_format(name)?;
            }
            Ok(())
        }
    }

    impl Drop for ClipboardFixture {
        fn drop(&mut self) {
            if let Ok(_clipboard) = ClipboardOpenGuard::open(self.window.hwnd) {
                // Safety: The clipboard is open and owned by the test window.
                unsafe {
                    EmptyClipboard();
                }
                let _ = set_unicode_text("RustDesk clipboard integration test completed.");
            }
        }
    }

    fn wide_z(value: &str) -> Vec<u16> {
        OsStr::new(value).encode_wide().chain(Some(0)).collect()
    }

    fn integration_enabled() -> bool {
        std::env::var(WINDOWS_CLIPBOARD_INTEGRATION_ENV)
            .map(|value| {
                matches!(
                    value.to_ascii_lowercase().as_str(),
                    "1" | "true" | "yes" | "y"
                )
            })
            .unwrap_or(false)
    }

    fn skip_if_disabled() -> bool {
        if integration_enabled() {
            false
        } else {
            eprintln!(
                "skipping Windows clipboard integration test; set {WINDOWS_CLIPBOARD_INTEGRATION_ENV}=1"
            );
            true
        }
    }

    fn register_clipboard_format(name: &str) -> Result<UINT, String> {
        let name = wide_z(name);
        // Safety: wide_z returns a valid null-terminated UTF-16 string.
        let format = unsafe { RegisterClipboardFormatW(name.as_ptr()) };
        if format == 0 {
            Err("RegisterClipboardFormatW failed".to_owned())
        } else {
            Ok(format)
        }
    }

    fn set_unicode_text(text: &str) -> Result<(), String> {
        let data = wide_z(text);
        let bytes = data.len() * std::mem::size_of::<u16>();
        // Safety: GlobalAlloc is called with a non-zero size and GMEM_MOVEABLE,
        // as required by SetClipboardData for CF_UNICODETEXT.
        let handle = unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes) };
        if handle.is_null() {
            return Err("GlobalAlloc failed".to_owned());
        }
        // Safety: handle was allocated by GlobalAlloc and is lockable.
        let ptr = unsafe { GlobalLock(handle) } as *mut u16;
        if ptr.is_null() {
            // Safety: handle has not been transferred to the clipboard.
            unsafe {
                GlobalFree(handle);
            }
            return Err("GlobalLock failed".to_owned());
        }
        // Safety: ptr points to a writable global allocation of at least bytes.
        unsafe {
            copy_nonoverlapping(data.as_ptr(), ptr, data.len());
            GlobalUnlock(handle);
        }
        // Safety: The clipboard is open, and ownership of handle transfers on success.
        let result = unsafe { SetClipboardData(CF_UNICODETEXT, handle as _) };
        if result.is_null() {
            // Safety: SetClipboardData failed, so ownership was not transferred.
            unsafe {
                GlobalFree(handle);
            }
            Err("SetClipboardData(CF_UNICODETEXT) failed".to_owned())
        } else {
            Ok(())
        }
    }

    fn set_registered_data_format(name: &str, bytes: &[u8]) -> Result<(), String> {
        if bytes.is_empty() {
            return Err(format!("SetClipboardData({name}) requires non-empty data"));
        }
        let format = register_clipboard_format(name)?;
        // Safety: GlobalAlloc is called with a non-zero size and GMEM_MOVEABLE,
        // as required by SetClipboardData for movable clipboard memory.
        let handle = unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes.len()) };
        if handle.is_null() {
            return Err("GlobalAlloc failed".to_owned());
        }
        // Safety: handle was allocated by GlobalAlloc and is lockable.
        let ptr = unsafe { GlobalLock(handle) } as *mut u8;
        if ptr.is_null() {
            // Safety: handle has not been transferred to the clipboard.
            unsafe {
                GlobalFree(handle);
            }
            return Err("GlobalLock failed".to_owned());
        }
        // Safety: ptr points to a writable global allocation of at least bytes.len().
        unsafe {
            copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len());
            GlobalUnlock(handle);
        }
        // Safety: The clipboard is open, and ownership of handle transfers on success.
        let result = unsafe { SetClipboardData(format, handle as _) };
        if result.is_null() {
            // Safety: SetClipboardData failed, so ownership was not transferred.
            unsafe {
                GlobalFree(handle);
            }
            Err(format!("SetClipboardData({name}) failed"))
        } else {
            Ok(())
        }
    }

    fn set_delayed_format(name: &str) -> Result<(), String> {
        let format = register_clipboard_format(name)?;
        // Safety: Passing a null handle requests delayed rendering for this format.
        unsafe {
            SetClipboardData(format, null_mut());
        }
        // Safety: IsClipboardFormatAvailable only checks format registration state.
        if unsafe { IsClipboardFormatAvailable(format) } == 0 {
            Err(format!("SetClipboardData({name}) failed"))
        } else {
            Ok(())
        }
    }

    #[test]
    #[ignore = "mutates the real Windows clipboard; set RUSTDESK_CLIPBOARD_INTEGRATION_TESTS=1"]
    fn text_with_ole_wrappers_is_read_as_text() -> Result<(), String> {
        if skip_if_disabled() {
            return Ok(());
        }
        let _guard = TEST_MUTEX.lock().unwrap();
        RENDER_REQUESTS.store(0, Ordering::SeqCst);
        let fixture = ClipboardFixture::new()?;
        let text = "RustDesk clipboard integration text";

        fixture.set_formats(Some(text), &["DataObject", "Ole Private Data"], &[])?;

        assert!(platform_clipboard::external_opaque_native_clipboard_signature().is_none());
        let mut ctx = ClipboardContext::new().map_err(|e| e.to_string())?;
        let data = ctx
            .get(ClipboardSide::Client, false)
            .map_err(|e| e.to_string())?;

        assert!(data
            .iter()
            .any(|item| matches!(item, ClipboardData::Text(value) if value == text)));
        assert_eq!(RENDER_REQUESTS.load(Ordering::SeqCst), 0);
        Ok(())
    }

    #[test]
    #[ignore = "mutates the real Windows clipboard; set RUSTDESK_CLIPBOARD_INTEGRATION_TESTS=1"]
    fn delayed_ole_wrappers_with_text_fallback_are_not_opaque_without_rendering(
    ) -> Result<(), String> {
        if skip_if_disabled() {
            return Ok(());
        }
        let _guard = TEST_MUTEX.lock().unwrap();
        RENDER_REQUESTS.store(0, Ordering::SeqCst);
        let fixture = ClipboardFixture::new()?;

        fixture.set_formats(
            Some("RustDesk delayed wrapper text fallback"),
            &[],
            &["DataObject", "Ole Private Data"],
        )?;

        assert!(platform_clipboard::external_opaque_native_clipboard_signature().is_none());
        assert_eq!(RENDER_REQUESTS.load(Ordering::SeqCst), 0);
        Ok(())
    }

    #[test]
    #[ignore = "mutates the real Windows clipboard; set RUSTDESK_CLIPBOARD_INTEGRATION_TESTS=1"]
    fn delayed_illustrator_formats_are_blocked_without_rendering() -> Result<(), String> {
        if skip_if_disabled() {
            return Ok(());
        }
        let _guard = TEST_MUTEX.lock().unwrap();
        RENDER_REQUESTS.store(0, Ordering::SeqCst);
        let fixture = ClipboardFixture::new()?;

        fixture.set_formats(
            Some("Illustrator text fallback"),
            &[],
            &[
                "DataObject",
                "Encapsulated PostScript",
                "Adobe Illustrator 30.4",
                "Portable Document Format",
                "Adobe Illustrator PGF 14.0",
                "Ole Private Data",
            ],
        )?;

        assert!(platform_clipboard::external_opaque_native_clipboard_signature().is_some());
        assert_eq!(RENDER_REQUESTS.load(Ordering::SeqCst), 0);
        Ok(())
    }
}

pub use proto::get_msg_if_not_support_multi_clip;
mod proto {
    #[cfg(not(target_os = "android"))]
    use arboard::ClipboardData;
    use hbb_common::{
        compress::{compress as compress_func, decompress},
        message_proto::{Clipboard, ClipboardFormat, Message, MultiClipboards},
    };

    fn plain_to_proto(s: String, format: ClipboardFormat) -> Clipboard {
        let compressed = compress_func(s.as_bytes());
        let compress = compressed.len() < s.as_bytes().len();
        let content = if compress {
            compressed
        } else {
            s.bytes().collect::<Vec<u8>>()
        };
        Clipboard {
            compress,
            content: content.into(),
            format: format.into(),
            ..Default::default()
        }
    }

    #[cfg(not(target_os = "android"))]
    fn image_to_proto(a: arboard::ImageData) -> Clipboard {
        match &a {
            arboard::ImageData::Rgba(rgba) => {
                let compressed = compress_func(&a.bytes());
                let compress = compressed.len() < a.bytes().len();
                let content = if compress {
                    compressed
                } else {
                    a.bytes().to_vec()
                };
                Clipboard {
                    compress,
                    content: content.into(),
                    width: rgba.width as _,
                    height: rgba.height as _,
                    format: ClipboardFormat::ImageRgba.into(),
                    ..Default::default()
                }
            }
            arboard::ImageData::Png(png) => Clipboard {
                compress: false,
                content: png.to_owned().to_vec().into(),
                format: ClipboardFormat::ImagePng.into(),
                ..Default::default()
            },
            arboard::ImageData::Svg(_) => {
                let compressed = compress_func(&a.bytes());
                let compress = compressed.len() < a.bytes().len();
                let content = if compress {
                    compressed
                } else {
                    a.bytes().to_vec()
                };
                Clipboard {
                    compress,
                    content: content.into(),
                    format: ClipboardFormat::ImageSvg.into(),
                    ..Default::default()
                }
            }
        }
    }

    fn special_to_proto(d: Vec<u8>, s: String) -> Clipboard {
        let compressed = compress_func(&d);
        let compress = compressed.len() < d.len();
        let content = if compress { compressed } else { d };
        Clipboard {
            compress,
            content: content.into(),
            format: ClipboardFormat::Special.into(),
            special_name: s,
            ..Default::default()
        }
    }

    #[cfg(not(target_os = "android"))]
    fn clipboard_data_to_proto(data: ClipboardData) -> Option<Clipboard> {
        let d = match data {
            ClipboardData::Text(s) => plain_to_proto(s, ClipboardFormat::Text),
            ClipboardData::Rtf(s) => plain_to_proto(s, ClipboardFormat::Rtf),
            ClipboardData::Html(s) => plain_to_proto(s, ClipboardFormat::Html),
            ClipboardData::Image(a) => image_to_proto(a),
            ClipboardData::Special((s, d)) => special_to_proto(d, s),
            _ => return None,
        };
        Some(d)
    }

    #[cfg(not(target_os = "android"))]
    pub fn create_multi_clipboards(vec_data: Vec<ClipboardData>) -> MultiClipboards {
        MultiClipboards {
            clipboards: vec_data
                .into_iter()
                .filter_map(clipboard_data_to_proto)
                .collect(),
            ..Default::default()
        }
    }

    #[cfg(not(target_os = "android"))]
    fn from_clipboard(clipboard: Clipboard) -> Option<ClipboardData> {
        let data = if clipboard.compress {
            decompress(&clipboard.content)
        } else {
            clipboard.content.into()
        };
        match clipboard.format.enum_value() {
            Ok(ClipboardFormat::Text) => String::from_utf8(data).ok().map(ClipboardData::Text),
            Ok(ClipboardFormat::Rtf) => String::from_utf8(data).ok().map(ClipboardData::Rtf),
            Ok(ClipboardFormat::Html) => String::from_utf8(data).ok().map(ClipboardData::Html),
            Ok(ClipboardFormat::ImageRgba) => Some(ClipboardData::Image(arboard::ImageData::rgba(
                clipboard.width as _,
                clipboard.height as _,
                data.into(),
            ))),
            Ok(ClipboardFormat::ImagePng) => {
                Some(ClipboardData::Image(arboard::ImageData::png(data.into())))
            }
            Ok(ClipboardFormat::ImageSvg) => Some(ClipboardData::Image(arboard::ImageData::svg(
                std::str::from_utf8(&data).unwrap_or_default(),
            ))),
            Ok(ClipboardFormat::Special) => {
                Some(ClipboardData::Special((clipboard.special_name, data)))
            }
            _ => None,
        }
    }

    #[cfg(not(target_os = "android"))]
    pub fn from_multi_clipboards(multi_clipboards: Vec<Clipboard>) -> Vec<ClipboardData> {
        multi_clipboards
            .into_iter()
            .filter_map(from_clipboard)
            .collect()
    }

    pub fn get_msg_if_not_support_multi_clip(
        version: &str,
        platform: &str,
        multi_clipboards: &MultiClipboards,
    ) -> Option<Message> {
        if crate::clipboard::is_support_multi_clipboard(version, platform) {
            return None;
        }

        // Find the first text clipboard and send it.
        multi_clipboards
            .clipboards
            .iter()
            .find(|c| c.format.enum_value() == Ok(ClipboardFormat::Text))
            .map(|c| {
                let mut msg = Message::new();
                msg.set_clipboard(c.clone());
                msg
            })
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn special_clipboard_keeps_uncompressed_payload() {
            let payload = vec![0x01];
            let clipboard = special_to_proto(payload.clone(), "dyn.test.owner".to_owned());

            assert!(!clipboard.compress);
            assert_eq!(clipboard.content.as_ref(), payload.as_slice());
            assert_eq!(clipboard.special_name, "dyn.test.owner");
        }
    }
}

#[cfg(target_os = "android")]
pub fn handle_msg_clipboard(mut cb: Clipboard) {
    use hbb_common::protobuf::Message;

    if cb.compress {
        cb.content = bytes::Bytes::from(hbb_common::compress::decompress(&cb.content));
    }
    let multi_clips = MultiClipboards {
        clipboards: vec![cb],
        ..Default::default()
    };
    if let Ok(bytes) = multi_clips.write_to_bytes() {
        let _ = scrap::android::ffi::call_clipboard_manager_update_clipboard(&bytes);
    }
}

#[cfg(target_os = "android")]
pub fn handle_msg_multi_clipboards(mut mcb: MultiClipboards) {
    use hbb_common::protobuf::Message;

    for cb in mcb.clipboards.iter_mut() {
        if cb.compress {
            cb.content = bytes::Bytes::from(hbb_common::compress::decompress(&cb.content));
        }
    }
    if let Ok(bytes) = mcb.write_to_bytes() {
        let _ = scrap::android::ffi::call_clipboard_manager_update_clipboard(&bytes);
    }
}

#[cfg(target_os = "android")]
pub fn get_clipboards_msg(client: bool) -> Option<Message> {
    let mut clipboards = scrap::android::ffi::get_clipboards(client)?;
    let mut msg = Message::new();
    for c in &mut clipboards.clipboards {
        let compressed = hbb_common::compress::compress(&c.content);
        let compress = compressed.len() < c.content.len();
        if compress {
            c.content = compressed.into();
        }
        c.compress = compress;
    }
    msg.set_multi_clipboards(clipboards);
    Some(msg)
}

// We need this mod to notify multiple subscribers when the clipboard changes.
// A single platform clipboard listener fans out change events to all RustAdmin
// subscribers. Linux Wayland uses the local adapter; other platforms use
// upstream clipboard-master.
#[cfg(not(target_os = "android"))]
pub mod clipboard_listener {
    use clipboard_master::{CallbackResult, ClipboardHandler, Master, Shutdown as MasterShutdown};
    use hbb_common::{bail, log, ResultType};
    use std::{
        collections::HashMap,
        io,
        sync::mpsc::{channel, Sender},
        sync::{Arc, Mutex},
        thread::JoinHandle,
    };

    lazy_static::lazy_static! {
        pub static ref CLIPBOARD_LISTENER: Arc<Mutex<ClipboardListener>> = Default::default();
    }

    enum ListenerShutdown {
        Master(MasterShutdown),
        #[cfg(target_os = "linux")]
        Wayland(crate::clipboard_wayland_listener::Shutdown),
    }

    impl ListenerShutdown {
        fn signal(self) {
            match self {
                Self::Master(shutdown) => shutdown.signal(),
                #[cfg(target_os = "linux")]
                Self::Wayland(shutdown) => shutdown.signal(),
            }
        }
    }

    struct Handler {
        subscribers: Arc<Mutex<HashMap<String, Sender<CallbackResult>>>>,
    }

    impl ClipboardHandler for Handler {
        fn on_clipboard_change(&mut self) -> CallbackResult {
            let sub_lock = self.subscribers.lock().unwrap();
            for tx in sub_lock.values() {
                tx.send(CallbackResult::Next).ok();
            }
            CallbackResult::Next
        }

        fn on_clipboard_error(&mut self, error: io::Error) -> CallbackResult {
            let msg = format!("Clipboard listener error: {}", error);
            let sub_lock = self.subscribers.lock().unwrap();
            for tx in sub_lock.values() {
                tx.send(CallbackResult::StopWithError(io::Error::new(
                    io::ErrorKind::Other,
                    msg.clone(),
                )))
                .ok();
            }
            CallbackResult::Next
        }
    }

    #[derive(Default)]
    pub struct ClipboardListener {
        subscribers: Arc<Mutex<HashMap<String, Sender<CallbackResult>>>>,
        handle: Option<(ListenerShutdown, JoinHandle<()>)>,
    }

    pub fn subscribe(name: String, tx: Sender<CallbackResult>) -> ResultType<()> {
        log::info!("Subscribe clipboard listener: {}", &name);
        let mut listener_lock = CLIPBOARD_LISTENER.lock().unwrap();
        listener_lock
            .subscribers
            .lock()
            .unwrap()
            .insert(name.clone(), tx);

        if listener_lock.handle.is_none() {
            log::info!("Start clipboard listener thread");
            let handler = Handler {
                subscribers: listener_lock.subscribers.clone(),
            };
            let (tx_start_res, rx_start_res) = channel();
            let h = start_clipboard_listener_thread(handler, tx_start_res);
            let shutdown = match rx_start_res.recv() {
                Ok((Some(s), _)) => s,
                Ok((None, err)) => {
                    bail!(err);
                }

                Err(e) => {
                    bail!("Failed to create clipboard listener: {}", e);
                }
            };
            listener_lock.handle = Some((shutdown, h));
            log::info!("Clipboard listener thread started");
        }

        log::info!("Clipboard listener subscribed: {}", name);
        Ok(())
    }

    pub fn unsubscribe(name: &str) {
        log::info!("Unsubscribe clipboard listener: {}", name);
        let mut listener_lock = CLIPBOARD_LISTENER.lock().unwrap();
        let is_empty = {
            let mut sub_lock = listener_lock.subscribers.lock().unwrap();
            if let Some(tx) = sub_lock.remove(name) {
                tx.send(CallbackResult::Stop).ok();
            }
            sub_lock.is_empty()
        };
        if is_empty {
            if let Some((shutdown, h)) = listener_lock.handle.take() {
                log::info!("Stop clipboard listener thread");
                shutdown.signal();
                h.join().ok();
                log::info!("Clipboard listener thread stopped");
            }
        }
        log::info!("Clipboard listener unsubscribed: {}", name);
    }

    fn start_clipboard_listener_thread(
        handler: impl ClipboardHandler + Send + 'static,
        tx_start_res: Sender<(Option<ListenerShutdown>, String)>,
    ) -> JoinHandle<()> {
        #[cfg(target_os = "linux")]
        {
            if crate::clipboard_wayland_listener::should_use_wayland_listener() {
                return crate::clipboard_wayland_listener::start_thread(handler, move |result| {
                    let start_result = match result {
                        Ok(shutdown) => (Some(ListenerShutdown::Wayland(shutdown)), String::new()),
                        Err(error) => (None, error),
                    };
                    tx_start_res.send(start_result).ok();
                });
            }
        }
        start_clipboard_master_thread(handler, tx_start_res)
    }

    fn start_clipboard_master_thread(
        handler: impl ClipboardHandler + Send + 'static,
        tx_start_res: Sender<(Option<ListenerShutdown>, String)>,
    ) -> JoinHandle<()> {
        // https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmessage#:~:text=The%20window%20must%20belong%20to%20the%20current%20thread.
        let h = std::thread::spawn(move || match Master::new(handler) {
            Ok(mut master) => {
                tx_start_res
                    .send((
                        Some(ListenerShutdown::Master(master.shutdown_channel())),
                        "".to_owned(),
                    ))
                    .ok();
                log::debug!("Clipboard listener started");
                if let Err(err) = master.run() {
                    log::error!("Failed to run clipboard listener: {}", err);
                } else {
                    log::debug!("Clipboard listener stopped");
                }
            }
            Err(err) => {
                tx_start_res
                    .send((
                        None,
                        format!("Failed to create clipboard listener: {}", err),
                    ))
                    .ok();
            }
        });
        h
    }
}
