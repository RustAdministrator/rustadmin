use crate::{
    client::*,
    flutter_ffi::{EventToUI, SessionID},
    ui_session_interface::{io_loop, InvokeUiSession, Session},
};
use flutter_rust_bridge::StreamSink;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
use hbb_common::dlopen::{
    symbor::{Library, Symbol},
    Error as LibError,
};
use hbb_common::{
    anyhow::anyhow, bail, config::LocalConfig, get_version_number, log, message_proto::*,
    rendezvous_proto::ConnType, ResultType,
};
use serde::Serialize;
use serde_json::json;
#[cfg(all(target_os = "android", feature = "mediacodec"))]
use std::collections::HashSet;
#[cfg(target_os = "windows")]
use std::io::{Error as IoError, ErrorKind as IoErrorKind};
use std::{
    collections::{BTreeMap, HashMap},
    ffi::CString,
    os::raw::{c_char, c_int, c_void},
    str::FromStr,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, RwLock,
    },
    time::{Duration, Instant},
};

const VIEW_RENDER_LIVE_TIMEOUT: Duration = Duration::from_secs(3);

mod render_target;
use render_target::RenderTargetOwner;

/// tag "main" for [Desktop Main Page] and [Mobile (Client and Server)] (the mobile don't need multiple windows, only one global event stream is needed)
/// tag "cm" only for [Desktop CM Page]
pub(crate) const APP_TYPE_MAIN: &str = "main";
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub(crate) const APP_TYPE_CM: &str = "cm";
#[cfg(any(target_os = "android", target_os = "ios"))]
pub(crate) const APP_TYPE_CM: &str = "main";

// Do not remove the following constants.
// Uncomment them when they are used.
// pub(crate) const APP_TYPE_DESKTOP_REMOTE: &str = "remote";
// pub(crate) const APP_TYPE_DESKTOP_FILE_TRANSFER: &str = "file transfer";
// pub(crate) const APP_TYPE_DESKTOP_PORT_FORWARD: &str = "port forward";

pub type FlutterSession = Arc<Session<FlutterHandler>>;

lazy_static::lazy_static! {
    pub(crate) static ref CUR_SESSION_ID: RwLock<SessionID> = Default::default(); // For desktop only
    static ref GLOBAL_EVENT_STREAM: RwLock<HashMap<String, StreamSink<String>>> = Default::default(); // rust to dart event channel
}

#[cfg(target_os = "windows")]
lazy_static::lazy_static! {
    pub static ref TEXTURE_RGBA_RENDERER_PLUGIN: Result<Library, LibError> = load_plugin_in_app_path("texture_rgba_renderer_plugin.dll");
}

#[cfg(target_os = "linux")]
lazy_static::lazy_static! {
    pub static ref TEXTURE_RGBA_RENDERER_PLUGIN: Result<Library, LibError> = Library::open("libtexture_rgba_renderer_plugin.so");
}

#[cfg(target_os = "macos")]
lazy_static::lazy_static! {
    pub static ref TEXTURE_RGBA_RENDERER_PLUGIN: Result<Library, LibError> = Library::open_self();
}

#[cfg(target_os = "windows")]
lazy_static::lazy_static! {
    pub static ref TEXTURE_GPU_RENDERER_PLUGIN: Result<Library, LibError> = load_plugin_in_app_path("flutter_gpu_texture_renderer_plugin.dll");
}

// Move this function into `src/platform/windows.rs` if there're more calls to load plugins.
// Load dll with full path.
#[cfg(target_os = "windows")]
fn load_plugin_in_app_path(dll_name: &str) -> Result<Library, LibError> {
    match std::env::current_exe() {
        Ok(exe_file) => {
            if let Some(cur_dir) = exe_file.parent() {
                let full_path = cur_dir.join(dll_name);
                if !full_path.exists() {
                    Err(LibError::OpeningLibraryError(IoError::new(
                        IoErrorKind::NotFound,
                        format!("{} not found", dll_name),
                    )))
                } else {
                    Library::open(full_path)
                }
            } else {
                Err(LibError::OpeningLibraryError(IoError::new(
                    IoErrorKind::Other,
                    format!(
                        "Invalid exe parent for {}",
                        exe_file.to_string_lossy().as_ref()
                    ),
                )))
            }
        }
        Err(e) => Err(LibError::OpeningLibraryError(e)),
    }
}

/// FFI for rustdesk core's main entry.
/// Return true if the app should continue running with UI(possibly Flutter), false if the app should exit.
#[cfg(not(windows))]
#[no_mangle]
pub extern "C" fn rustdesk_core_main() -> bool {
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    if crate::core_main::core_main().is_some() {
        return true;
    } else {
        #[cfg(target_os = "macos")]
        std::process::exit(0);
    }
    #[cfg(not(target_os = "macos"))]
    false
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub extern "C" fn handle_applicationShouldOpenUntitledFile() {
    crate::platform::macos::handle_application_should_open_untitled_file();
}

#[cfg(windows)]
#[no_mangle]
pub extern "C" fn rustdesk_core_main_args(args_len: *mut c_int) -> *mut *mut c_char {
    unsafe { std::ptr::write(args_len, 0) };
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        if let Some(args) = crate::core_main::core_main() {
            return rust_args_to_c_args(args, args_len);
        }
        return std::ptr::null_mut() as _;
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    return std::ptr::null_mut() as _;
}

// https://gist.github.com/iskakaushik/1c5b8aa75c77479c33c4320913eebef6
#[cfg(windows)]
fn rust_args_to_c_args(args: Vec<String>, outlen: *mut c_int) -> *mut *mut c_char {
    let mut v = vec![];

    // Let's fill a vector with null-terminated strings
    for s in args {
        match CString::new(s) {
            Ok(s) => v.push(s),
            Err(_) => return std::ptr::null_mut() as _,
        }
    }

    // Turning each null-terminated string into a pointer.
    // `into_raw` takes ownershop, gives us the pointer and does NOT drop the data.
    let mut out = v.into_iter().map(|s| s.into_raw()).collect::<Vec<_>>();

    // Make sure we're not wasting space.
    out.shrink_to_fit();
    debug_assert!(out.len() == out.capacity());

    // Get the pointer to our vector.
    let len = out.len();
    let ptr = out.as_mut_ptr();
    std::mem::forget(out);

    // Let's write back the length the caller can expect
    unsafe { std::ptr::write(outlen, len as c_int) };

    // Finally return the data
    ptr
}

#[no_mangle]
pub unsafe extern "C" fn free_c_args(ptr: *mut *mut c_char, len: c_int) {
    let len = len as usize;

    // Get back our vector.
    // Previously we shrank to fit, so capacity == length.
    let v = Vec::from_raw_parts(ptr, len, len);

    // Now drop one string at a time.
    for elem in v {
        let s = CString::from_raw(elem);
        std::mem::drop(s);
    }

    // Afterwards the vector will be dropped and thus freed.
}

#[cfg(windows)]
#[no_mangle]
pub unsafe extern "C" fn get_rustdesk_app_name(buffer: *mut u16, length: i32) -> i32 {
    let name = crate::platform::wide_string(&crate::get_app_name());
    if length > name.len() as i32 {
        std::ptr::copy_nonoverlapping(name.as_ptr(), buffer, name.len());
        return 0;
    }
    -1
}

#[derive(Default)]
struct SessionHandler {
    event_stream: Option<StreamSink<EventToUI>>,
    display_intent: ViewDisplayIntent,
    event_stream_generation: u64,
    render_bindings: BTreeMap<usize, ViewDisplayRenderBinding>,
    renderer: VideoRenderer,
    #[cfg(all(target_os = "android", feature = "mediacodec"))]
    texture_notified: RwLock<HashSet<usize>>,
}

#[derive(Default)]
struct ViewDisplayIntent {
    displays: Vec<usize>,
    initialized: bool,
    generation: u64,
}

impl ViewDisplayIntent {
    fn set_wire_displays(&mut self, displays: &[i32]) -> bool {
        let mut next = Vec::with_capacity(displays.len());
        for display in displays
            .iter()
            .filter_map(|display| usize::try_from(*display).ok())
        {
            if !next.contains(&display) {
                next.push(display);
            }
        }
        let changed = !self.initialized || self.displays != next;
        if changed {
            self.displays = next;
            self.generation = self.generation.saturating_add(1).max(1);
        }
        self.initialized = true;
        changed
    }

    fn seed_initial_display(&mut self, display: usize) -> bool {
        if !self.initialized {
            self.displays.push(display);
            self.initialized = true;
            self.generation = self.generation.saturating_add(1).max(1);
            true
        } else {
            false
        }
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct DisplayDemandDelta {
    previous: Vec<usize>,
    current: Vec<usize>,
    retained: Vec<usize>,
    added: Vec<usize>,
    removed: Vec<usize>,
}

impl DisplayDemandDelta {
    fn between(mut previous: Vec<usize>, mut current: Vec<usize>) -> Self {
        previous.sort_unstable();
        previous.dedup();
        current.sort_unstable();
        current.dedup();

        let retained = current
            .iter()
            .copied()
            .filter(|display| previous.binary_search(display).is_ok())
            .collect();
        let added = current
            .iter()
            .copied()
            .filter(|display| previous.binary_search(display).is_err())
            .collect();
        let removed = previous
            .iter()
            .copied()
            .filter(|display| current.binary_search(display).is_err())
            .collect();

        Self {
            previous,
            current,
            retained,
            added,
            removed,
        }
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct ReducerViewIntent {
    displays: Vec<usize>,
    active: bool,
    generation: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum ViewIntentEvent {
    Upsert {
        view_id: SessionID,
        displays: Vec<usize>,
        active: bool,
    },
    Remove {
        view_id: SessionID,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DisplayIntentReducerState {
    logical_session_generation: u64,
    aggregate_generation: u64,
    views: BTreeMap<SessionID, ReducerViewIntent>,
    last_activation_generation: BTreeMap<usize, u64>,
    media_intent: DisplayMediaIntent,
}

impl Default for DisplayIntentReducerState {
    fn default() -> Self {
        Self {
            logical_session_generation: 1,
            aggregate_generation: 0,
            views: BTreeMap::new(),
            last_activation_generation: BTreeMap::new(),
            media_intent: DisplayMediaIntent {
                logical_session_generation: 1,
                ..Default::default()
            },
        }
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct DisplayIntentEffects {
    changed: bool,
    delta: DisplayDemandDelta,
    media_intent: DisplayMediaIntent,
}

fn reduce_display_intent(
    mut state: DisplayIntentReducerState,
    event: ViewIntentEvent,
) -> (DisplayIntentReducerState, DisplayIntentEffects) {
    let previous_media_intent = state.media_intent.clone();
    let changed = match event {
        ViewIntentEvent::Upsert {
            view_id,
            displays,
            active,
        } => {
            let previous = state.views.get(&view_id);
            let changed = previous
                .map(|view| view.displays != displays || view.active != active)
                .unwrap_or(true);
            if changed {
                let generation = previous
                    .map(|view| view.generation.saturating_add(1))
                    .unwrap_or(1);
                state.views.insert(
                    view_id,
                    ReducerViewIntent {
                        displays,
                        active,
                        generation,
                    },
                );
            }
            changed
        }
        ViewIntentEvent::Remove { view_id } => state.views.remove(&view_id).is_some(),
    };

    if !changed {
        return (
            state,
            DisplayIntentEffects {
                changed: false,
                delta: DisplayDemandDelta::between(
                    previous_media_intent
                        .displays
                        .iter()
                        .map(|entry| entry.display)
                        .collect(),
                    previous_media_intent
                        .displays
                        .iter()
                        .map(|entry| entry.display)
                        .collect(),
                ),
                media_intent: previous_media_intent,
            },
        );
    }

    let mut demand = BTreeMap::<usize, usize>::new();
    for view in state.views.values().filter(|view| view.active) {
        for display in &view.displays {
            *demand.entry(*display).or_default() += 1;
        }
    }

    let mut displays = Vec::with_capacity(demand.len());
    for (display, view_count) in demand {
        let generation = previous_media_intent
            .activation(display)
            .map(|activation| activation.generation)
            .unwrap_or_else(|| {
                let next = state
                    .last_activation_generation
                    .get(&display)
                    .copied()
                    .unwrap_or(0)
                    .saturating_add(1)
                    .max(1);
                state.last_activation_generation.insert(display, next);
                next
            });
        displays.push(DisplayActivation {
            display,
            generation,
            view_count,
        });
    }

    let displays_changed = previous_media_intent.displays != displays;
    if !displays_changed {
        return (
            state,
            DisplayIntentEffects {
                changed: false,
                delta: DisplayDemandDelta::between(
                    previous_media_intent
                        .displays
                        .iter()
                        .map(|entry| entry.display)
                        .collect(),
                    previous_media_intent
                        .displays
                        .iter()
                        .map(|entry| entry.display)
                        .collect(),
                ),
                media_intent: previous_media_intent,
            },
        );
    }

    state.aggregate_generation = state.aggregate_generation.saturating_add(1).max(1);
    state.media_intent = DisplayMediaIntent {
        logical_session_generation: state.logical_session_generation,
        aggregate_generation: state.aggregate_generation,
        displays,
    };
    let delta = DisplayDemandDelta::between(
        previous_media_intent
            .displays
            .iter()
            .map(|entry| entry.display)
            .collect(),
        state
            .media_intent
            .displays
            .iter()
            .map(|entry| entry.display)
            .collect(),
    );
    let effects = DisplayIntentEffects {
        changed: true,
        delta,
        media_intent: state.media_intent.clone(),
    };
    (state, effects)
}

fn aggregate_display_intents<'a>(intents: impl Iterator<Item = &'a [usize]>) -> Vec<usize> {
    let mut displays = Vec::new();
    for intent in intents {
        displays.extend_from_slice(intent);
    }
    displays.sort_unstable();
    displays.dedup();
    displays
}

fn aggregate_active_display_intents(handlers: &HashMap<SessionID, SessionHandler>) -> Vec<usize> {
    aggregate_display_intents(
        handlers
            .values()
            .filter(|handler| handler.event_stream.is_some())
            .map(|handler| handler.display_intent.displays.as_slice()),
    )
}

fn wire_display_indices(displays: &[usize]) -> Vec<i32> {
    displays
        .iter()
        .filter_map(|display| i32::try_from(*display).ok())
        .collect()
}

fn apply_display_intent_effects(session: &FlutterSession, effects: &DisplayIntentEffects) {
    if !effects.changed {
        return;
    }
    let added = wire_display_indices(&effects.delta.added);
    if !added.is_empty() {
        session.capture_displays(added, vec![], vec![]);
    }

    let removed = wire_display_indices(&effects.delta.removed);
    if !removed.is_empty() {
        session.capture_displays(vec![], removed, vec![]);
    }
    session.send(Data::DisplayIntent(effects.media_intent.clone()));
}

#[cfg(test)]
mod display_intent_tests {
    use super::{
        aggregate_display_intents, reduce_display_intent, DisplayDemandDelta,
        DisplayIntentReducerState, FlutterHandler, ViewDisplayIntent, ViewDisplayRenderBinding,
        ViewIntentEvent, ViewRenderPhase, VIEW_RENDER_LIVE_TIMEOUT,
    };
    use crate::flutter_ffi::SessionID;
    use crate::{client::RenderFrameContext, ui_session_interface::InvokeUiSession};
    use std::time::{Duration, Instant};

    fn set_view(
        state: DisplayIntentReducerState,
        view: u128,
        displays: &[usize],
    ) -> DisplayIntentReducerState {
        reduce_display_intent(
            state,
            ViewIntentEvent::Upsert {
                view_id: SessionID::from_u128(view),
                displays: displays.to_vec(),
                active: true,
            },
        )
        .0
    }

    #[test]
    fn aggregate_display_intents_is_deterministic_and_unique() {
        let first = [2, 0, 2];
        let second = [1, 2];
        let aggregate =
            aggregate_display_intents([first.as_slice(), second.as_slice()].into_iter());

        assert_eq!(aggregate, vec![0, 1, 2]);
    }

    #[test]
    fn expanding_display_demand_retains_existing_display() {
        let delta = DisplayDemandDelta::between(vec![0], vec![1, 0]);

        assert_eq!(delta.previous, vec![0]);
        assert_eq!(delta.current, vec![0, 1]);
        assert_eq!(delta.retained, vec![0]);
        assert_eq!(delta.added, vec![1]);
        assert!(delta.removed.is_empty());
    }

    #[test]
    fn releasing_one_view_removes_only_unshared_display() {
        let previous = aggregate_display_intents([[0, 1].as_slice(), [1].as_slice()].into_iter());
        let current = aggregate_display_intents([[1].as_slice()].into_iter());
        let delta = DisplayDemandDelta::between(previous, current);

        assert_eq!(delta.retained, vec![1]);
        assert!(delta.added.is_empty());
        assert_eq!(delta.removed, vec![0]);
    }

    #[test]
    fn attaching_or_releasing_shared_display_needs_no_host_change() {
        let one_view = aggregate_display_intents([[1].as_slice()].into_iter());
        let two_views = aggregate_display_intents([[1].as_slice(), [1].as_slice()].into_iter());

        let attach = DisplayDemandDelta::between(one_view.clone(), two_views.clone());
        assert_eq!(attach.retained, vec![1]);
        assert!(attach.added.is_empty());
        assert!(attach.removed.is_empty());

        let release = DisplayDemandDelta::between(two_views, one_view);
        assert_eq!(release.retained, vec![1]);
        assert!(release.added.is_empty());
        assert!(release.removed.is_empty());
    }

    #[test]
    fn wire_display_intent_ignores_invalid_and_duplicate_indices() {
        let mut intent = ViewDisplayIntent::default();
        intent.set_wire_displays(&[2, -1, 2, 0]);

        assert_eq!(intent.displays, vec![2, 0]);
        assert!(intent.initialized);
    }

    #[test]
    fn renderer_size_only_seeds_initial_intent_once() {
        let mut intent = ViewDisplayIntent::default();
        intent.seed_initial_display(1);
        intent.seed_initial_display(0);

        assert_eq!(intent.displays, vec![1]);
    }

    #[test]
    fn newer_aggregate_intent_adopts_retained_activation_work() {
        let state = set_view(DisplayIntentReducerState::default(), 1, &[0, 1]);
        let activation_b = state.media_intent.activation(1).unwrap().generation;
        let state = set_view(state, 1, &[0, 1, 2]);

        assert_eq!(
            state.media_intent.activation(1).unwrap().generation,
            activation_b
        );
        assert_eq!(state.media_intent.activation(2).unwrap().generation, 1);
        assert_eq!(state.aggregate_generation, 2);
    }

    #[test]
    fn duplicate_view_snapshot_is_idempotent() {
        let state = set_view(DisplayIntentReducerState::default(), 1, &[1, 0]);
        let generation = state.aggregate_generation;
        let (state, effects) = reduce_display_intent(
            state,
            ViewIntentEvent::Upsert {
                view_id: SessionID::from_u128(1),
                displays: vec![1, 0],
                active: true,
            },
        );

        assert!(!effects.changed);
        assert_eq!(state.aggregate_generation, generation);
        assert!(effects.delta.added.is_empty());
        assert!(effects.delta.removed.is_empty());
    }

    #[test]
    fn inactive_view_changes_do_not_version_the_effective_media_intent() {
        let state = set_view(DisplayIntentReducerState::default(), 1, &[0]);
        let aggregate_generation = state.aggregate_generation;
        let (state, effects) = reduce_display_intent(
            state,
            ViewIntentEvent::Upsert {
                view_id: SessionID::from_u128(2),
                displays: vec![1],
                active: false,
            },
        );

        assert!(!effects.changed);
        assert_eq!(state.aggregate_generation, aggregate_generation);
        assert_eq!(
            state
                .media_intent
                .displays
                .iter()
                .map(|activation| activation.display)
                .collect::<Vec<_>>(),
            vec![0]
        );
    }

    #[test]
    fn view_reorder_does_not_version_a_deterministically_equal_aggregate() {
        let state = set_view(DisplayIntentReducerState::default(), 1, &[0, 1]);
        let aggregate_generation = state.aggregate_generation;
        let (state, effects) = reduce_display_intent(
            state,
            ViewIntentEvent::Upsert {
                view_id: SessionID::from_u128(1),
                displays: vec![1, 0],
                active: true,
            },
        );

        assert!(!effects.changed);
        assert_eq!(state.aggregate_generation, aggregate_generation);
    }

    #[test]
    fn final_release_and_readd_changes_only_that_activation_generation() {
        let state = set_view(DisplayIntentReducerState::default(), 1, &[0, 1]);
        let activation_a = state.media_intent.activation(0).unwrap().generation;
        let activation_b = state.media_intent.activation(1).unwrap().generation;
        let state = set_view(state, 1, &[0]);
        let state = set_view(state, 1, &[0, 1]);

        assert_eq!(
            state.media_intent.activation(0).unwrap().generation,
            activation_a
        );
        assert!(state.media_intent.activation(1).unwrap().generation > activation_b);
    }

    #[test]
    fn aggregate_order_is_independent_of_view_insertion_order() {
        let first = set_view(
            set_view(DisplayIntentReducerState::default(), 2, &[2, 0]),
            1,
            &[1, 2],
        );
        let second = set_view(
            set_view(DisplayIntentReducerState::default(), 1, &[1, 2]),
            2,
            &[2, 0],
        );

        let first_displays = first
            .media_intent
            .displays
            .iter()
            .map(|entry| (entry.display, entry.view_count))
            .collect::<Vec<_>>();
        let second_displays = second
            .media_intent
            .displays
            .iter()
            .map(|entry| (entry.display, entry.view_count))
            .collect::<Vec<_>>();
        assert_eq!(first_displays, vec![(0, 1), (1, 1), (2, 2)]);
        assert_eq!(first_displays, second_displays);
    }

    #[test]
    fn closing_one_view_retains_shared_display_activation() {
        let state = set_view(
            set_view(DisplayIntentReducerState::default(), 1, &[0, 1]),
            2,
            &[1],
        );
        let activation_b = state.media_intent.activation(1).unwrap().generation;
        let (state, effects) = reduce_display_intent(
            state,
            ViewIntentEvent::Remove {
                view_id: SessionID::from_u128(1),
            },
        );

        assert_eq!(effects.delta.removed, vec![0]);
        assert_eq!(state.media_intent.activation(1).unwrap().view_count, 1);
        assert_eq!(
            state.media_intent.activation(1).unwrap().generation,
            activation_b
        );
    }

    fn render_context(
        connection_generation: u32,
        display_activation_generation: u64,
        stream_id: u64,
        frame_id: u64,
    ) -> RenderFrameContext {
        RenderFrameContext {
            connection_generation,
            display_activation_generation,
            stream_id,
            frame_id,
        }
    }

    #[test]
    fn decoded_frame_without_a_render_target_is_not_live() {
        let context = render_context(1, 1, 11, 1);
        let mut binding = ViewDisplayRenderBinding::new(context, 1);

        binding.observe(context, 1, false, false, Instant::now());

        assert_eq!(binding.phase, ViewRenderPhase::AwaitingTarget);
        assert_eq!(binding.submitted_frame_id, 0);
        assert!(binding.last_submission.is_none());
    }

    #[test]
    fn render_liveness_is_independent_for_each_view_binding() {
        let context = render_context(1, 1, 12, 4);
        let mut first_view = ViewDisplayRenderBinding::new(context, 3);
        let mut second_view = ViewDisplayRenderBinding::new(context, 8);
        let now = Instant::now();

        first_view.observe(context, 3, true, true, now);
        second_view.observe(context, 8, false, true, now);

        assert_eq!(first_view.phase, ViewRenderPhase::Live);
        assert_eq!(second_view.phase, ViewRenderPhase::Failed);
    }

    #[test]
    fn repeated_render_submissions_refresh_liveness_without_state_churn() {
        let first = render_context(1, 1, 13, 7);
        let second = render_context(1, 1, 13, 8);
        let mut binding = ViewDisplayRenderBinding::new(first, 2);
        let now = Instant::now();

        assert!(binding.observe(first, 2, true, true, now));
        assert!(!binding.observe(second, 2, true, true, now + Duration::from_millis(1),));
        assert_eq!(binding.phase, ViewRenderPhase::Live);
        assert_eq!(binding.submitted_frame_id, 8);
        assert!(
            !binding.mark_stale_if_due(now + VIEW_RENDER_LIVE_TIMEOUT - Duration::from_millis(1),)
        );
        assert!(
            binding.mark_stale_if_due(now + VIEW_RENDER_LIVE_TIMEOUT + Duration::from_millis(2),)
        );
        assert_eq!(binding.phase, ViewRenderPhase::Stale);
    }

    #[test]
    fn old_connection_and_activation_completions_are_rejected() {
        let handler = FlutterHandler::default();
        let effects = handler.reduce_view_intent(
            ViewIntentEvent::Upsert {
                view_id: SessionID::from_u128(1),
                displays: vec![0],
                active: true,
            },
            &[0],
        );
        let first_activation = effects.media_intent.activation(0).unwrap().generation;
        handler.begin_connection_runtime(5);
        let first_context = render_context(5, first_activation, 21, 1);
        assert!(handler.accepts_render_context(0, first_context));

        handler.begin_connection_runtime(6);
        assert!(!handler.accepts_render_context(0, first_context));
        assert!(handler.accepts_render_context(0, render_context(6, first_activation, 21, 1),));
        assert_eq!(
            handler
                .current_display_media_intent()
                .activation(0)
                .unwrap()
                .generation,
            first_activation
        );

        handler.reduce_view_intent(
            ViewIntentEvent::Remove {
                view_id: SessionID::from_u128(1),
            },
            &[],
        );
        let effects = handler.reduce_view_intent(
            ViewIntentEvent::Upsert {
                view_id: SessionID::from_u128(1),
                displays: vec![0],
                active: true,
            },
            &[0],
        );
        let replacement_activation = effects.media_intent.activation(0).unwrap().generation;
        assert!(replacement_activation > first_activation);
        assert!(!handler.accepts_render_context(0, render_context(6, first_activation, 21, 2),));
    }
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum RenderType {
    PixelBuffer,
    #[cfg(feature = "vram")]
    Texture,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ViewRenderPhase {
    AwaitingTarget,
    Live,
    Stale,
    Failed,
}

impl ViewRenderPhase {
    fn as_str(self) -> &'static str {
        match self {
            Self::AwaitingTarget => "awaiting-target",
            Self::Live => "live",
            Self::Stale => "stale",
            Self::Failed => "failed",
        }
    }
}

#[derive(Debug)]
struct ViewDisplayRenderBinding {
    connection_generation: u32,
    display_activation_generation: u64,
    render_target_generation: u64,
    stream_id: u64,
    submitted_frame_id: u64,
    last_submission: Option<Instant>,
    phase: ViewRenderPhase,
}

impl ViewDisplayRenderBinding {
    fn new(context: RenderFrameContext, render_target_generation: u64) -> Self {
        Self {
            connection_generation: context.connection_generation,
            display_activation_generation: context.display_activation_generation,
            render_target_generation,
            stream_id: context.stream_id,
            submitted_frame_id: 0,
            last_submission: None,
            phase: ViewRenderPhase::AwaitingTarget,
        }
    }

    fn observe(
        &mut self,
        context: RenderFrameContext,
        render_target_generation: u64,
        submitted: bool,
        target_exists: bool,
        now: Instant,
    ) -> bool {
        let dependency_changed = self.connection_generation != context.connection_generation
            || self.display_activation_generation != context.display_activation_generation
            || self.render_target_generation != render_target_generation
            || self.stream_id != context.stream_id;
        if dependency_changed {
            *self = Self::new(context, render_target_generation);
        }
        let previous_phase = self.phase;
        if submitted {
            self.submitted_frame_id = self.submitted_frame_id.max(context.frame_id);
            self.last_submission = Some(now);
            self.phase = ViewRenderPhase::Live;
        } else if target_exists {
            self.phase = ViewRenderPhase::Failed;
        } else {
            self.phase = ViewRenderPhase::AwaitingTarget;
        }
        previous_phase != self.phase || dependency_changed
    }

    fn mark_stale_if_due(&mut self, now: Instant) -> bool {
        if self.phase != ViewRenderPhase::Live
            || !self
                .last_submission
                .is_some_and(|last| now.saturating_duration_since(last) >= VIEW_RENDER_LIVE_TIMEOUT)
        {
            return false;
        }
        self.phase = ViewRenderPhase::Stale;
        true
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RenderTargetSubmission {
    Missing {
        generation: u64,
    },
    Rejected {
        generation: u64,
    },
    Submitted {
        generation: u64,
        render_type_changed: bool,
    },
}

impl RenderTargetSubmission {
    fn generation(self) -> u64 {
        match self {
            Self::Missing { generation }
            | Self::Rejected { generation }
            | Self::Submitted { generation, .. } => generation,
        }
    }

    fn submitted(self) -> bool {
        matches!(self, Self::Submitted { .. })
    }

    fn target_exists(self) -> bool {
        !matches!(self, Self::Missing { .. })
    }

    fn render_type_changed(self) -> bool {
        matches!(
            self,
            Self::Submitted {
                render_type_changed: true,
                ..
            }
        )
    }
}

#[derive(Clone)]
pub struct FlutterHandler {
    // ui session id -> display handler data
    session_handlers: Arc<RwLock<HashMap<SessionID, SessionHandler>>>,
    display_intent_reducer: Arc<RwLock<DisplayIntentReducerState>>,
    connection_generation: Arc<AtomicUsize>,
    display_rgbas: Arc<RwLock<HashMap<usize, RgbaData>>>,
    peer_info: Arc<RwLock<PeerInfo>>,
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    hooks: Arc<RwLock<HashMap<String, SessionHook>>>,
    use_texture_render: Arc<AtomicBool>,
}

impl Default for FlutterHandler {
    fn default() -> Self {
        Self {
            session_handlers: Default::default(),
            display_intent_reducer: Default::default(),
            connection_generation: Default::default(),
            display_rgbas: Default::default(),
            peer_info: Default::default(),
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            hooks: Default::default(),
            use_texture_render: Arc::new(
                AtomicBool::new(crate::ui_interface::use_texture_render()),
            ),
        }
    }
}

#[derive(Default, Clone)]
struct RgbaData {
    // SAFETY: [rgba] is guarded by [rgba_valid], and it's safe to reach [rgba] with `rgba_valid == true`.
    // We must check the `rgba_valid` before reading [rgba].
    data: Vec<u8>,
    valid: bool,
}

pub type FlutterRgbaRendererPluginOnRgba = unsafe extern "C" fn(
    texture_rgba: *mut c_void,
    buffer: *const u8,
    len: c_int,
    width: c_int,
    height: c_int,
    dst_rgba_stride: c_int,
);

#[cfg(feature = "vram")]
pub type FlutterGpuTextureRendererPluginCApiSetTexture =
    unsafe extern "C" fn(output: *mut c_void, texture: *mut c_void);

#[cfg(feature = "vram")]
pub type FlutterGpuTextureRendererPluginCApiGetAdapterLuid = unsafe extern "C" fn() -> i64;

struct DisplaySessionInfo {
    pixelbuffer_target: RenderTargetOwner,
    size: (usize, usize),
    #[cfg(feature = "vram")]
    gpu_target: RenderTargetOwner,
    notify_render_type: Option<RenderType>,
    render_target_generation: u64,
}

impl DisplaySessionInfo {
    fn with_size(width: usize, height: usize) -> Self {
        Self {
            pixelbuffer_target: RenderTargetOwner::default(),
            size: (width, height),
            #[cfg(feature = "vram")]
            gpu_target: RenderTargetOwner::default(),
            notify_render_type: None,
            render_target_generation: 1,
        }
    }
}

impl Default for DisplaySessionInfo {
    fn default() -> Self {
        Self::with_size(0, 0)
    }
}

// Video Texture Renderer in Flutter
#[derive(Clone)]
struct VideoRenderer {
    is_support_multi_ui_session: bool,
    map_display_sessions: Arc<RwLock<HashMap<usize, DisplaySessionInfo>>>,
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    on_rgba_func: Option<Symbol<'static, FlutterRgbaRendererPluginOnRgba>>,
    #[cfg(feature = "vram")]
    on_texture_func: Option<Symbol<'static, FlutterGpuTextureRendererPluginCApiSetTexture>>,
}

impl Default for VideoRenderer {
    fn default() -> Self {
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        let on_rgba_func = match &*TEXTURE_RGBA_RENDERER_PLUGIN {
            Ok(lib) => {
                let find_sym_res = unsafe {
                    lib.symbol::<FlutterRgbaRendererPluginOnRgba>("FlutterRgbaRendererPluginOnRgba")
                };
                match find_sym_res {
                    Ok(sym) => Some(sym),
                    Err(e) => {
                        log::error!("Failed to find symbol FlutterRgbaRendererPluginOnRgba, {e}");
                        None
                    }
                }
            }
            Err(e) => {
                log::error!("Failed to load texture rgba renderer plugin, {e}");
                None
            }
        };
        #[cfg(feature = "vram")]
        let on_texture_func = match &*TEXTURE_GPU_RENDERER_PLUGIN {
            Ok(lib) => {
                let find_sym_res = unsafe {
                    lib.symbol::<FlutterGpuTextureRendererPluginCApiSetTexture>(
                        "FlutterGpuTextureRendererPluginCApiSetTexture",
                    )
                };
                match find_sym_res {
                    Ok(sym) => Some(sym),
                    Err(e) => {
                        log::error!("Failed to find symbol FlutterGpuTextureRendererPluginCApiSetTexture, {e}");
                        None
                    }
                }
            }
            Err(e) => {
                log::error!("Failed to load texture gpu renderer plugin, {e}");
                None
            }
        };

        Self {
            map_display_sessions: Default::default(),
            is_support_multi_ui_session: false,
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            on_rgba_func,
            #[cfg(feature = "vram")]
            on_texture_func,
        }
    }
}

impl VideoRenderer {
    fn bump_target_generation(info: &mut DisplaySessionInfo) {
        info.render_target_generation = info.render_target_generation.saturating_add(1).max(1);
    }

    #[inline]
    fn set_size(&mut self, display: usize, width: usize, height: usize) {
        let mut sessions_lock = self.map_display_sessions.write().unwrap();
        if let Some(info) = sessions_lock.get_mut(&display) {
            if info.size != (width, height) {
                info.size = (width, height);
                info.notify_render_type = None;
                Self::bump_target_generation(info);
            }
        } else {
            sessions_lock.insert(display, DisplaySessionInfo::with_size(width, height));
        }
    }

    fn register_pixelbuffer_texture(&self, display: usize, ptr: usize) {
        let mut sessions_lock = self.map_display_sessions.write().unwrap();
        let info = sessions_lock.entry(display).or_default();
        if let Some(previous) = info.pixelbuffer_target.pointer() {
            if ptr != 0 && previous != ptr {
                log::warn!(
                    "replace legacy pixelbuffer render target {} with {}",
                    previous,
                    ptr
                );
            }
        }
        let previous = info.pixelbuffer_target.pointer();
        info.pixelbuffer_target.register_legacy(ptr);
        if info.pixelbuffer_target.pointer() != previous {
            info.notify_render_type = None;
            Self::bump_target_generation(info);
        }
    }

    fn register_owned_pixelbuffer_texture(&self, display: usize, ptr: usize, token: u64) {
        let mut sessions_lock = self.map_display_sessions.write().unwrap();
        let info = sessions_lock.entry(display).or_default();
        let previous = (
            info.pixelbuffer_target.pointer(),
            info.pixelbuffer_target.token(),
        );
        if info.pixelbuffer_target.register(ptr, token) {
            info.notify_render_type = None;
            if previous
                != (
                    info.pixelbuffer_target.pointer(),
                    info.pixelbuffer_target.token(),
                )
            {
                Self::bump_target_generation(info);
            }
        } else {
            log::debug!(
                "ignore stale pixelbuffer render target: display={}, token={}",
                display,
                token
            );
        }
    }

    fn unregister_owned_pixelbuffer_texture(&self, display: usize, token: u64) {
        let mut sessions_lock = self.map_display_sessions.write().unwrap();
        if let Some(info) = sessions_lock.get_mut(&display) {
            if info.pixelbuffer_target.unregister(token) {
                info.notify_render_type = None;
                Self::bump_target_generation(info);
            } else {
                log::debug!(
                    "ignore stale pixelbuffer unregister: display={}, token={}",
                    display,
                    token
                );
            }
        }
    }

    #[cfg(feature = "vram")]
    pub fn register_gpu_output(&self, display: usize, ptr: usize) {
        let mut sessions_lock = self.map_display_sessions.write().unwrap();
        let info = sessions_lock.entry(display).or_default();
        let previous = info.gpu_target.pointer();
        info.gpu_target.register_legacy(ptr);
        if info.gpu_target.pointer() != previous {
            info.notify_render_type = None;
            Self::bump_target_generation(info);
        }
    }

    #[cfg(feature = "vram")]
    pub fn register_owned_gpu_output(&self, display: usize, ptr: usize, token: u64) {
        let mut sessions_lock = self.map_display_sessions.write().unwrap();
        let info = sessions_lock.entry(display).or_default();
        let previous = (info.gpu_target.pointer(), info.gpu_target.token());
        if info.gpu_target.register(ptr, token) {
            info.notify_render_type = None;
            if previous != (info.gpu_target.pointer(), info.gpu_target.token()) {
                Self::bump_target_generation(info);
            }
        } else {
            log::debug!(
                "ignore stale GPU render target: display={}, token={}",
                display,
                token
            );
        }
    }

    #[cfg(feature = "vram")]
    pub fn unregister_owned_gpu_output(&self, display: usize, token: u64) {
        let mut sessions_lock = self.map_display_sessions.write().unwrap();
        if let Some(info) = sessions_lock.get_mut(&display) {
            if info.gpu_target.unregister(token) {
                info.notify_render_type = None;
                Self::bump_target_generation(info);
            } else {
                log::debug!(
                    "ignore stale GPU unregister: display={}, token={}",
                    display,
                    token
                );
            }
        }
    }

    fn pixelbuffer_display(
        &self,
        sessions: &HashMap<usize, DisplaySessionInfo>,
        requested_display: usize,
    ) -> Option<usize> {
        if self.is_support_multi_ui_session {
            return sessions
                .get(&requested_display)
                .and_then(|info| info.pixelbuffer_target.pointer())
                .map(|_| requested_display);
        }
        if sessions
            .get(&requested_display)
            .and_then(|info| info.pixelbuffer_target.pointer())
            .is_some()
        {
            return Some(requested_display);
        }
        sessions
            .iter()
            .filter_map(|(display, info)| {
                info.pixelbuffer_target
                    .pointer()
                    .map(|_| (info.pixelbuffer_target.token().unwrap_or(0), *display))
            })
            .max()
            .map(|(_, display)| display)
    }

    #[cfg(feature = "vram")]
    fn gpu_display(
        &self,
        sessions: &HashMap<usize, DisplaySessionInfo>,
        requested_display: usize,
    ) -> Option<usize> {
        if self.is_support_multi_ui_session {
            return sessions
                .get(&requested_display)
                .and_then(|info| info.gpu_target.pointer())
                .map(|_| requested_display);
        }
        if sessions
            .get(&requested_display)
            .and_then(|info| info.gpu_target.pointer())
            .is_some()
        {
            return Some(requested_display);
        }
        sessions
            .iter()
            .filter_map(|(display, info)| {
                info.gpu_target
                    .pointer()
                    .map(|_| (info.gpu_target.token().unwrap_or(0), *display))
            })
            .max()
            .map(|(_, display)| display)
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    pub fn on_rgba(&self, display: usize, rgba: &scrap::ImageRgb) -> RenderTargetSubmission {
        let mut write_lock = self.map_display_sessions.write().unwrap();
        let Some(target_display) = self.pixelbuffer_display(&write_lock, display) else {
            return RenderTargetSubmission::Missing { generation: 0 };
        };
        let Some(info) = write_lock.get_mut(&target_display) else {
            return RenderTargetSubmission::Missing { generation: 0 };
        };
        let Some(texture_rgba_ptr) = info.pixelbuffer_target.pointer() else {
            return RenderTargetSubmission::Missing {
                generation: info.render_target_generation,
            };
        };

        if info.size.0 != rgba.w || info.size.1 != rgba.h {
            log::error!(
                "width/height mismatch: ({},{}) != ({},{})",
                info.size.0,
                info.size.1,
                rgba.w,
                rgba.h
            );
            // Peer info's handling is async and may be late than video frame's handling
            // Allow peer info not set, but not allow wrong width/height for correct local cursor position
            if info.size != (0, 0) {
                return RenderTargetSubmission::Rejected {
                    generation: info.render_target_generation,
                };
            }
        }
        let Some(func) = &self.on_rgba_func else {
            return RenderTargetSubmission::Rejected {
                generation: info.render_target_generation,
            };
        };
        unsafe {
            func(
                texture_rgba_ptr as _,
                rgba.raw.as_ptr() as _,
                rgba.raw.len() as _,
                rgba.w as _,
                rgba.h as _,
                rgba.align() as _,
            )
        };
        let render_type_changed = info.notify_render_type != Some(RenderType::PixelBuffer);
        if render_type_changed {
            info.notify_render_type = Some(RenderType::PixelBuffer);
        }
        RenderTargetSubmission::Submitted {
            generation: info.render_target_generation,
            render_type_changed,
        }
    }

    #[cfg(feature = "vram")]
    pub fn on_texture(&self, display: usize, texture: *mut c_void) -> RenderTargetSubmission {
        let mut write_lock = self.map_display_sessions.write().unwrap();
        let Some(target_display) = self.gpu_display(&write_lock, display) else {
            return RenderTargetSubmission::Missing { generation: 0 };
        };
        let Some(info) = write_lock.get_mut(&target_display) else {
            return RenderTargetSubmission::Missing { generation: 0 };
        };
        let Some(gpu_output_ptr) = info.gpu_target.pointer() else {
            return RenderTargetSubmission::Missing {
                generation: info.render_target_generation,
            };
        };
        let Some(func) = &self.on_texture_func else {
            return RenderTargetSubmission::Rejected {
                generation: info.render_target_generation,
            };
        };
        unsafe { func(gpu_output_ptr as _, texture) };
        let render_type_changed = info.notify_render_type != Some(RenderType::Texture);
        if render_type_changed {
            info.notify_render_type = Some(RenderType::Texture);
        }
        RenderTargetSubmission::Submitted {
            generation: info.render_target_generation,
            render_type_changed,
        }
    }

    pub fn reset_all_display_render_type(&self) {
        let mut write_lock = self.map_display_sessions.write().unwrap();
        write_lock
            .values_mut()
            .map(|v| v.notify_render_type = None)
            .count();
    }
}

impl SessionHandler {
    pub fn on_waiting_for_image_dialog_show(&self) {
        self.renderer.reset_all_display_render_type();
        #[cfg(all(target_os = "android", feature = "mediacodec"))]
        self.texture_notified.write().unwrap().clear();
        // rgba array render will notify every frame
    }

    fn record_render_outcome(
        &mut self,
        display: usize,
        context: RenderFrameContext,
        render_target_generation: u64,
        submitted: bool,
        target_exists: bool,
    ) -> RenderFrameOutcome {
        let now = Instant::now();
        let binding = self
            .render_bindings
            .entry(display)
            .or_insert_with(|| ViewDisplayRenderBinding::new(context, render_target_generation));
        let changed = binding.observe(
            context,
            render_target_generation,
            submitted,
            target_exists,
            now,
        );
        let phase = binding.phase;
        let submitted_frame_id = binding.submitted_frame_id;
        if changed {
            emit_render_binding_state(
                &self.event_stream,
                display,
                context,
                render_target_generation,
                submitted_frame_id,
                phase,
            );
        }
        if submitted {
            RenderFrameOutcome::submitted()
        } else {
            RenderFrameOutcome::rejected()
        }
    }
}

fn emit_render_binding_state(
    event_stream: &Option<StreamSink<EventToUI>>,
    display: usize,
    context: RenderFrameContext,
    render_target_generation: u64,
    submitted_frame_id: u64,
    phase: ViewRenderPhase,
) {
    let Some(event_stream) = event_stream else {
        return;
    };
    event_stream.add(EventToUI::Event(
        json!({
            "name": "display_render_state",
            "display": display,
            "state": phase.as_str(),
            "connection_generation": context.connection_generation,
            "display_activation_generation": context.display_activation_generation,
            "render_target_generation": render_target_generation,
            "stream_id": context.stream_id,
            "submitted_frame_id": submitted_frame_id,
            "presentation_confirmed": false,
        })
        .to_string(),
    ));
}

impl FlutterHandler {
    fn accepts_render_context(&self, display: usize, context: RenderFrameContext) -> bool {
        self.connection_generation.load(Ordering::Acquire) == context.connection_generation as usize
            && self
                .display_intent_reducer
                .read()
                .unwrap()
                .media_intent
                .activation(display)
                .is_some_and(|activation| {
                    activation.generation == context.display_activation_generation
                })
    }

    fn reduce_view_intent(
        &self,
        event: ViewIntentEvent,
        legacy_current: &[usize],
    ) -> DisplayIntentEffects {
        let mut reducer = self.display_intent_reducer.write().unwrap();
        let (next, effects) = reduce_display_intent(reducer.clone(), event);
        let reduced_current = effects
            .media_intent
            .displays
            .iter()
            .map(|entry| entry.display)
            .collect::<Vec<_>>();
        if reduced_current != legacy_current {
            log::error!(
                "display intent shadow mismatch: legacy={legacy_current:?}, reducer={reduced_current:?}, aggregate_generation={}",
                effects.media_intent.aggregate_generation
            );
            debug_assert_eq!(reduced_current, legacy_current);
        }
        *reducer = next;
        effects
    }

    fn current_display_media_intent(&self) -> DisplayMediaIntent {
        self.display_intent_reducer
            .read()
            .unwrap()
            .media_intent
            .clone()
    }

    /// Push an event to all the event queues.
    /// An event is stored as json in the event queues.
    ///
    /// # Arguments
    ///
    /// * `name` - The name of the event.
    /// * `event` - Fields of the event content.
    pub fn push_event<V>(&self, name: &str, event: &[(&str, V)], excludes: &[&SessionID])
    where
        V: Sized + Serialize + Clone,
    {
        self.push_event_(name, event, &[], excludes);
    }

    pub fn push_event_to<V>(&self, name: &str, event: &[(&str, V)], include: &[&SessionID])
    where
        V: Sized + Serialize + Clone,
    {
        self.push_event_(name, event, include, &[]);
    }

    pub fn push_event_<V>(
        &self,
        name: &str,
        event: &[(&str, V)],
        includes: &[&SessionID],
        excludes: &[&SessionID],
    ) where
        V: Sized + Serialize + Clone,
    {
        let mut h: HashMap<&str, serde_json::Value> =
            event.iter().map(|(k, v)| (*k, json!(*v))).collect();
        debug_assert!(h.get("name").is_none());
        h.insert("name", json!(name));
        let out = serde_json::ser::to_string(&h).unwrap_or("".to_owned());
        for (sid, session) in self.session_handlers.read().unwrap().iter() {
            let mut push = false;
            if includes.is_empty() {
                if !excludes.contains(&sid) {
                    push = true;
                }
            } else {
                if includes.contains(&sid) {
                    push = true;
                }
            }
            if push {
                if let Some(stream) = &session.event_stream {
                    stream.add(EventToUI::Event(out.clone()));
                }
            }
        }
    }

    fn make_displays_msg(displays: &Vec<DisplayInfo>) -> String {
        let mut msg_vec = Vec::new();
        for ref d in displays.iter() {
            let mut h: HashMap<&str, i32> = Default::default();
            h.insert("x", d.x);
            h.insert("y", d.y);
            h.insert("width", d.width);
            h.insert("height", d.height);
            h.insert("cursor_embedded", if d.cursor_embedded { 1 } else { 0 });
            if let Some(original_resolution) = d.original_resolution.as_ref() {
                h.insert("original_width", original_resolution.width);
                h.insert("original_height", original_resolution.height);
            }
            // Don't convert scale (x 100) to i32 directly.
            // (d.scale * 100.0f64) as i32 may produces inaccuracies.
            //
            // Example: GNOME Wayland with Fractional Scaling enabled:
            // - Physical resolution: 2560x1600
            // - Logical resolution: 1074x1065
            // - Scale factor: 150%
            // Passing physical dimensions and scale factor prevents accurate logical resolution calculation
            // since 2560/1.5 = 1706.666... (rounded to 1706.67) and 1600/1.5 = 1066.666... (rounded to 1066.67)
            // h.insert("scale", (d.scale * 100.0f64) as i32);

            // Send scaled_width for accurate logical scale calculation.
            if d.scale > 0.0 {
                let scaled_width = (d.width as f64 / d.scale).round() as i32;
                h.insert("scaled_width", scaled_width);
            }
            msg_vec.push(h);
        }
        serde_json::ser::to_string(&msg_vec).unwrap_or("".to_owned())
    }

    #[cfg(feature = "plugin_framework")]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    pub(crate) fn add_session_hook(&self, key: String, hook: SessionHook) -> bool {
        let mut hooks = self.hooks.write().unwrap();
        if hooks.contains_key(&key) {
            // Already has the hook with this key.
            return false;
        }
        let _ = hooks.insert(key, hook);
        true
    }

    #[cfg(feature = "plugin_framework")]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    pub(crate) fn remove_session_hook(&self, key: &String) -> bool {
        let mut hooks = self.hooks.write().unwrap();
        if !hooks.contains_key(key) {
            // The hook with this key does not found.
            return false;
        }
        let _ = hooks.remove(key);
        true
    }

    pub fn update_use_texture_render(&self) {
        self.use_texture_render
            .store(crate::ui_interface::use_texture_render(), Ordering::Relaxed);
        self.display_rgbas.write().unwrap().clear();
    }
}

impl InvokeUiSession for FlutterHandler {
    fn set_cursor_data(&self, cd: CursorData) {
        let colors = hbb_common::compress::decompress(&cd.colors);
        self.push_event(
            "cursor_data",
            &[
                ("id", &cd.id.to_string()),
                ("hotx", &cd.hotx.to_string()),
                ("hoty", &cd.hoty.to_string()),
                ("width", &cd.width.to_string()),
                ("height", &cd.height.to_string()),
                (
                    "colors",
                    &serde_json::ser::to_string(&colors).unwrap_or("".to_owned()),
                ),
            ],
            &[],
        );
    }

    fn set_cursor_id(&self, id: String) {
        self.push_event("cursor_id", &[("id", &id.to_string())], &[]);
    }

    fn set_cursor_position(&self, cp: CursorPosition) {
        self.push_event(
            "cursor_position",
            &[("x", &cp.x.to_string()), ("y", &cp.y.to_string())],
            &[],
        );
    }

    /// unused in flutter, use switch_display or set_peer_info
    fn set_display(&self, _x: i32, _y: i32, _w: i32, _h: i32, _cursor_embedded: bool, _scale: f64) {
    }

    fn update_privacy_mode(&self) {
        self.push_event::<&str>("update_privacy_mode", &[], &[]);
    }

    fn set_permission(&self, name: &str, value: bool) {
        self.push_event("permission", &[(name, &value.to_string())], &[]);
    }

    // unused in flutter
    fn close_success(&self) {}

    fn update_quality_status(&self, status: QualityStatus) {
        const NULL: String = String::new();
        self.push_event(
            "update_quality_status",
            &[
                ("speed", &status.speed.map_or(NULL, |it| it)),
                (
                    "fps",
                    &serde_json::ser::to_string(&status.fps).unwrap_or(NULL.to_owned()),
                ),
                ("delay", &status.delay.map_or(NULL, |it| it.to_string())),
                (
                    "target_bitrate",
                    &status.target_bitrate.map_or(NULL, |it| it.to_string()),
                ),
                (
                    "codec_format",
                    &status.codec_format.map_or(NULL, |it| it.to_string()),
                ),
                ("chroma", &status.chroma.map_or(NULL, |it| it.to_string())),
                (
                    "connection_type",
                    &status.connection_type.map_or(NULL, |it| it.to_string()),
                ),
                (
                    "transport_mtu",
                    &status.transport_mtu.map_or(NULL, |it| it.to_string()),
                ),
                (
                    "transport_rtt_ms",
                    &status.transport_rtt_ms.map_or(NULL, |it| it.to_string()),
                ),
                (
                    "transport_lost_packets",
                    &status
                        .transport_lost_packets
                        .map_or(NULL, |it| it.to_string()),
                ),
                (
                    "datagram_payload",
                    &status.datagram_payload.map_or(NULL, |it| it.to_string()),
                ),
                (
                    "negotiated_datagram_payload",
                    &status
                        .negotiated_datagram_payload
                        .map_or(NULL, |it| it.to_string()),
                ),
                ("quic_protocol", &status.quic_protocol.map_or(NULL, |it| it)),
                (
                    "quic_video_transport",
                    &status.quic_video_transport.map_or(NULL, |it| it),
                ),
                (
                    "quic_reassembly_drops",
                    &status
                        .quic_reassembly_drops
                        .map_or(NULL, |it| it.to_string()),
                ),
                (
                    "quic_reassembly_reasons",
                    &status.quic_reassembly_reasons.map_or(NULL, |it| it),
                ),
                (
                    "quic_reassembly_frame",
                    &status.quic_reassembly_frame.map_or(NULL, |it| it),
                ),
                (
                    "quic_reassembly_timing",
                    &status.quic_reassembly_timing.map_or(NULL, |it| it),
                ),
                (
                    "quic_keyframe_requests",
                    &status
                        .quic_keyframe_requests
                        .map_or(NULL, |it| it.to_string()),
                ),
                (
                    "quic_keyframe_barrier",
                    &status.quic_keyframe_barrier.map_or(NULL, |it| it),
                ),
                (
                    "quic_receiver_recovery",
                    &status.quic_receiver_recovery.map_or(NULL, |it| it),
                ),
                (
                    "quic_sender_recovery",
                    &status.quic_sender_recovery.map_or(NULL, |it| it),
                ),
                (
                    "quic_sender_admission",
                    &status.quic_sender_admission.map_or(NULL, |it| it),
                ),
                (
                    "quic_sender_frame",
                    &status.quic_sender_frame.map_or(NULL, |it| it),
                ),
                (
                    "quic_sender_percentiles",
                    &status.quic_sender_percentiles.map_or(NULL, |it| it),
                ),
                (
                    "quic_sender_space",
                    &status.quic_sender_space.map_or(NULL, |it| it),
                ),
                (
                    "quic_disposable_drops",
                    &status.quic_disposable_drops.map_or(NULL, |it| it),
                ),
                (
                    "quic_video_queue_target_ms",
                    &status
                        .quic_video_queue_target_ms
                        .map_or(NULL, |it| it.to_string()),
                ),
                ("decoder", &status.decoder.map_or(NULL, |it| it)),
                ("renderer", &status.renderer.map_or(NULL, |it| it)),
                (
                    "capture_backend",
                    &status.capture_backend.map_or(NULL, |it| it),
                ),
                ("capture_frame", &status.capture_frame.map_or(NULL, |it| it)),
                (
                    "encoder_backend",
                    &status.encoder_backend.map_or(NULL, |it| it),
                ),
                ("encoder_input", &status.encoder_input.map_or(NULL, |it| it)),
                (
                    "decode_fps",
                    &serde_json::ser::to_string(&status.decode_fps).unwrap_or(NULL.to_owned()),
                ),
                (
                    "video_queue",
                    &serde_json::ser::to_string(&status.video_queue).unwrap_or(NULL.to_owned()),
                ),
                (
                    "frame_resolution",
                    &serde_json::ser::to_string(&status.frame_resolution)
                        .unwrap_or(NULL.to_owned()),
                ),
                (
                    "video_threads",
                    &status.video_threads.map_or(NULL, |it| it.to_string()),
                ),
                (
                    "texture_render",
                    &status.texture_render.map_or(NULL, |it| it.to_string()),
                ),
                ("direct", &status.direct.map_or(NULL, |it| it.to_string())),
                ("fps_mode", &status.fps_mode.map_or(NULL, |it| it)),
                (
                    "auto_fps",
                    &status.auto_fps.map_or(NULL, |it| it.to_string()),
                ),
                (
                    "video_progress",
                    &if status.video_progress.is_empty() {
                        NULL
                    } else {
                        serde_json::ser::to_string(&status.video_progress)
                            .unwrap_or(NULL.to_owned())
                    },
                ),
                (
                    "video_dropped",
                    &if status.video_dropped.is_empty() {
                        NULL
                    } else {
                        serde_json::ser::to_string(&status.video_dropped).unwrap_or(NULL.to_owned())
                    },
                ),
                (
                    "video_decode_time_us",
                    &if status.video_decode_time_us.is_empty() {
                        NULL
                    } else {
                        serde_json::ser::to_string(&status.video_decode_time_us)
                            .unwrap_or(NULL.to_owned())
                    },
                ),
                (
                    "video_render_submit_time_us",
                    &if status.video_render_submit_time_us.is_empty() {
                        NULL
                    } else {
                        serde_json::ser::to_string(&status.video_render_submit_time_us)
                            .unwrap_or(NULL.to_owned())
                    },
                ),
                (
                    "video_feedback_queue",
                    &if status.video_feedback_queue.is_empty() {
                        NULL
                    } else {
                        serde_json::ser::to_string(&status.video_feedback_queue)
                            .unwrap_or(NULL.to_owned())
                    },
                ),
                (
                    "display_refresh_millihz",
                    &if status.display_refresh_millihz.is_empty() {
                        NULL
                    } else {
                        serde_json::ser::to_string(&status.display_refresh_millihz)
                            .unwrap_or(NULL.to_owned())
                    },
                ),
                (
                    "video_delivery_phase",
                    &status.video_delivery_phase.map_or(NULL, |it| it),
                ),
                (
                    "video_recovery_count",
                    &status
                        .video_recovery_count
                        .map_or(NULL, |it| it.to_string()),
                ),
                (
                    "video_stall_ms",
                    &status.video_stall_ms.map_or(NULL, |it| it.to_string()),
                ),
                (
                    "requested_video_profile",
                    &status.requested_video_profile.map_or(NULL, |it| it),
                ),
                (
                    "effective_video_profile",
                    &status.effective_video_profile.map_or(NULL, |it| it),
                ),
                (
                    "movie_target_fps",
                    &status.movie_target_fps.map_or(NULL, |it| it.to_string()),
                ),
                (
                    "movie_pacing_fps",
                    &status.movie_pacing_fps.map_or(NULL, |it| it.to_string()),
                ),
                (
                    "movie_host_pipeline_p95_us",
                    &status
                        .movie_host_pipeline_p95_us
                        .map_or(NULL, |it| it.to_string()),
                ),
                (
                    "movie_fallback_reason",
                    &status.movie_fallback_reason.map_or(NULL, |it| it),
                ),
                (
                    "movie_playout_delay_ms",
                    &status
                        .movie_playout_delay_ms
                        .map_or(NULL, |it| it.to_string()),
                ),
            ],
            &[],
        );
    }

    fn set_connection_type(&self, is_secured: bool, direct: bool, stream_type: &str) {
        self.push_event(
            "connection_ready",
            &[
                ("secure", &is_secured.to_string()),
                ("direct", &direct.to_string()),
                ("stream_type", &stream_type.to_string()),
            ],
            &[],
        );
    }

    fn set_fingerprint(&self, fingerprint: String) {
        self.push_event("fingerprint", &[("fingerprint", &fingerprint)], &[]);
    }

    fn job_error(&self, id: i32, err: String, file_num: i32) {
        self.push_event(
            "job_error",
            &[
                ("id", &id.to_string()),
                ("err", &err),
                ("file_num", &file_num.to_string()),
            ],
            &[],
        );
    }

    fn job_done(&self, id: i32, file_num: i32) {
        self.push_event(
            "job_done",
            &[("id", &id.to_string()), ("file_num", &file_num.to_string())],
            &[],
        );
    }

    // unused in flutter
    fn clear_all_jobs(&self) {}

    fn load_last_job(&self, _cnt: i32, job_json: &str, _auto_start: bool) {
        self.push_event("load_last_job", &[("value", job_json)], &[]);
    }

    fn update_folder_files(
        &self,
        id: i32,
        entries: &Vec<FileEntry>,
        path: String,
        #[allow(unused_variables)] is_local: bool,
        only_count: bool,
    ) {
        // TODO opt
        if only_count {
            self.push_event(
                "update_folder_files",
                &[("info", &make_fd_flutter(id, entries, only_count))],
                &[],
            );
        } else {
            self.push_event(
                "file_dir",
                &[
                    ("is_local", "false"),
                    ("value", &crate::common::make_fd_to_json(id, path, entries)),
                ],
                &[],
            );
        }
    }

    fn update_empty_dirs(&self, res: ReadEmptyDirsResponse) {
        self.push_event(
            "empty_dirs",
            &[
                ("is_local", "false"),
                (
                    "value",
                    &crate::common::make_empty_dirs_response_to_json(&res),
                ),
            ],
            &[],
        );
    }

    // unused in flutter
    fn update_transfer_list(&self) {}

    // unused in flutter // TEST flutter
    fn confirm_delete_files(&self, _id: i32, _i: i32, _name: String) {}

    fn override_file_confirm(
        &self,
        id: i32,
        file_num: i32,
        to: String,
        is_upload: bool,
        is_identical: bool,
    ) {
        self.push_event(
            "override_file_confirm",
            &[
                ("id", &id.to_string()),
                ("file_num", &file_num.to_string()),
                ("read_path", &to),
                ("is_upload", &is_upload.to_string()),
                ("is_identical", &is_identical.to_string()),
            ],
            &[],
        );
    }

    fn job_progress(&self, id: i32, file_num: i32, speed: f64, finished_size: f64) {
        self.push_event(
            "job_progress",
            &[
                ("id", &id.to_string()),
                ("file_num", &file_num.to_string()),
                ("speed", &speed.to_string()),
                ("finished_size", &finished_size.to_string()),
            ],
            &[],
        );
    }

    // unused in flutter
    fn adapt_size(&self) {}

    #[inline]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    fn on_rgba(
        &self,
        context: RenderFrameContext,
        display: usize,
        rgba: &mut scrap::ImageRgb,
    ) -> RenderFrameOutcome {
        if !self.accepts_render_context(display, context) {
            return RenderFrameOutcome::default();
        }
        let use_texture_render = self.use_texture_render.load(Ordering::Relaxed);
        let mut outcome =
            self.on_rgba_flutter_texture_render(context, use_texture_render, display, rgba);
        if !use_texture_render {
            outcome.merge(self.on_rgba_soft_render(context, display, rgba));
        }
        outcome
    }

    #[inline]
    #[cfg(any(target_os = "android", target_os = "ios"))]
    fn on_rgba(
        &self,
        context: RenderFrameContext,
        display: usize,
        rgba: &mut scrap::ImageRgb,
    ) -> RenderFrameOutcome {
        if !self.accepts_render_context(display, context) {
            return RenderFrameOutcome::default();
        }
        self.on_rgba_soft_render(context, display, rgba)
    }

    fn display_media_intent(&self) -> Option<DisplayMediaIntent> {
        Some(self.current_display_media_intent())
    }

    fn begin_connection_runtime(&self, connection_generation: u32) {
        let previous = self
            .connection_generation
            .swap(connection_generation as usize, Ordering::AcqRel);
        if previous == connection_generation as usize {
            return;
        }
        let mut handlers = self.session_handlers.write().unwrap();
        for handler in handlers.values_mut() {
            let event_stream = &handler.event_stream;
            let render_bindings = &mut handler.render_bindings;
            for (display, binding) in render_bindings.iter_mut() {
                if binding.phase == ViewRenderPhase::Live {
                    binding.phase = ViewRenderPhase::Stale;
                    emit_render_binding_state(
                        event_stream,
                        *display,
                        RenderFrameContext {
                            connection_generation,
                            display_activation_generation: binding.display_activation_generation,
                            stream_id: binding.stream_id,
                            frame_id: binding.submitted_frame_id,
                        },
                        binding.render_target_generation,
                        binding.submitted_frame_id,
                        binding.phase,
                    );
                }
            }
        }
    }

    fn tick_render_liveness(&self) {
        let now = Instant::now();
        let mut handlers = self.session_handlers.write().unwrap();
        for handler in handlers.values_mut() {
            let event_stream = &handler.event_stream;
            let render_bindings = &mut handler.render_bindings;
            for (display, binding) in render_bindings.iter_mut() {
                if binding.mark_stale_if_due(now) {
                    emit_render_binding_state(
                        event_stream,
                        *display,
                        RenderFrameContext {
                            connection_generation: binding.connection_generation,
                            display_activation_generation: binding.display_activation_generation,
                            stream_id: binding.stream_id,
                            frame_id: binding.submitted_frame_id,
                        },
                        binding.render_target_generation,
                        binding.submitted_frame_id,
                        binding.phase,
                    );
                }
            }
        }
    }

    #[inline]
    #[cfg(all(
        feature = "vram",
        not(all(target_os = "android", feature = "mediacodec"))
    ))]
    fn on_texture(
        &self,
        context: RenderFrameContext,
        display: usize,
        texture: *mut c_void,
    ) -> RenderFrameOutcome {
        if !self.use_texture_render.load(Ordering::Relaxed) {
            return RenderFrameOutcome::default();
        }
        if !self.accepts_render_context(display, context) {
            return RenderFrameOutcome::default();
        }
        let mut outcome = RenderFrameOutcome::default();
        for session in self.session_handlers.write().unwrap().values_mut() {
            if session.event_stream.is_none() || !session.display_intent.displays.contains(&display)
            {
                continue;
            }
            let submission = session.renderer.on_texture(display, texture);
            if submission.render_type_changed() {
                if let Some(stream) = &session.event_stream {
                    stream.add(EventToUI::Texture(display, true));
                }
            }
            outcome.merge(session.record_render_outcome(
                display,
                context,
                submission.generation(),
                submission.submitted(),
                submission.target_exists(),
            ));
        }
        outcome
    }

    #[inline]
    #[cfg(all(target_os = "android", feature = "mediacodec"))]
    fn on_texture(
        &self,
        context: RenderFrameContext,
        display: usize,
        _texture: *mut c_void,
    ) -> RenderFrameOutcome {
        if !self.use_texture_render.load(Ordering::Relaxed) {
            return RenderFrameOutcome::default();
        }
        if !self.accepts_render_context(display, context) {
            return RenderFrameOutcome::default();
        }
        let mut outcome = RenderFrameOutcome::default();
        for session in self.session_handlers.write().unwrap().values_mut() {
            if session.event_stream.is_none() || !session.display_intent.displays.contains(&display)
            {
                continue;
            }
            if session.texture_notified.write().unwrap().insert(display) {
                if let Some(stream) = &session.event_stream {
                    stream.add(EventToUI::Texture(display, true));
                }
            }
            outcome.merge(session.record_render_outcome(
                display,
                context,
                session.event_stream_generation,
                true,
                true,
            ));
        }
        outcome
    }

    fn set_peer_info(&self, pi: &PeerInfo) {
        let displays = Self::make_displays_msg(&pi.displays);
        let mut features: HashMap<&str, bool> = Default::default();
        for ref f in pi.features.iter() {
            features.insert("privacy_mode", f.privacy_mode);
            if let Some(keyboard) = f.keyboard.as_ref() {
                features.insert(
                    "keyboard_v2_committed_text",
                    keyboard.protocol_version
                        >= hbb_common::keyboard::KEYBOARD_INPUT_PROTOCOL_VERSION
                        && keyboard.committed_text,
                );
                features.insert(
                    "keyboard_v2_physical_key",
                    keyboard.protocol_version
                        >= hbb_common::keyboard::KEYBOARD_INPUT_PROTOCOL_VERSION
                        && keyboard.physical_key,
                );
                features.insert(
                    "keyboard_v2_layout_aware_text",
                    keyboard.protocol_version
                        >= hbb_common::keyboard::KEYBOARD_INPUT_PROTOCOL_VERSION
                        && keyboard.layout_aware_text,
                );
            }
        }
        // compatible with 1.1.9
        if get_version_number(&pi.version) < get_version_number("1.2.0") {
            features.insert("privacy_mode", false);
        }
        let features = serde_json::ser::to_string(&features).unwrap_or("".to_owned());
        let resolutions = serialize_resolutions(&pi.resolutions.resolutions);
        *self.peer_info.write().unwrap() = pi.clone();
        if let Ok(current_display) = usize::try_from(pi.current_display) {
            let uninitialized = self
                .session_handlers
                .read()
                .unwrap()
                .iter()
                .filter_map(|(session_id, handler)| {
                    (handler.event_stream.is_some() && !handler.display_intent.initialized)
                        .then_some(*session_id)
                })
                .collect::<Vec<_>>();
            for session_id in uninitialized {
                let (event, current) = {
                    let mut handlers = self.session_handlers.write().unwrap();
                    let Some(handler) = handlers.get_mut(&session_id) else {
                        continue;
                    };
                    if !handler.display_intent.seed_initial_display(current_display) {
                        continue;
                    }
                    let event = ViewIntentEvent::Upsert {
                        view_id: session_id,
                        displays: handler.display_intent.displays.clone(),
                        active: true,
                    };
                    let current = aggregate_active_display_intents(&handlers);
                    (event, current)
                };
                self.reduce_view_intent(event, &current);
            }
        }
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        let is_support_multi_ui_session = crate::common::is_support_multi_ui_session(&pi.version);
        #[cfg(any(target_os = "android", target_os = "ios"))]
        let is_support_multi_ui_session = false;
        self.session_handlers
            .write()
            .unwrap()
            .values_mut()
            .for_each(|h| {
                h.renderer.is_support_multi_ui_session = is_support_multi_ui_session;
            });
        self.push_event(
            "peer_info",
            &[
                ("username", &pi.username),
                ("hostname", &pi.hostname),
                ("platform", &pi.platform),
                ("sas_enabled", &pi.sas_enabled.to_string()),
                ("displays", &displays),
                ("version", &pi.version),
                ("features", &features),
                ("current_display", &pi.current_display.to_string()),
                ("resolutions", &resolutions),
                ("platform_additions", &pi.platform_additions),
            ],
            &[],
        );
    }

    fn set_displays(&self, displays: &Vec<DisplayInfo>) {
        self.peer_info.write().unwrap().displays = displays.clone();
        self.push_event(
            "sync_peer_info",
            &[("displays", &Self::make_displays_msg(displays))],
            &[],
        );
    }

    fn set_platform_additions(&self, data: &str) {
        self.push_event(
            "sync_platform_additions",
            &[("platform_additions", &data)],
            &[],
        )
    }

    fn set_multiple_windows_session(&self, sessions: Vec<WindowsSession>) {
        let mut msg_vec = Vec::new();
        let mut sessions = sessions;
        for d in sessions.drain(..) {
            let mut h: HashMap<&str, String> = Default::default();
            h.insert("sid", d.sid.to_string());
            h.insert("name", d.name);
            msg_vec.push(h);
        }
        self.push_event(
            "set_multiple_windows_session",
            &[(
                "windows_sessions",
                &serde_json::ser::to_string(&msg_vec).unwrap_or("".to_owned()),
            )],
            &[],
        );
    }

    fn is_multi_ui_session(&self) -> bool {
        self.session_handlers.read().unwrap().len() > 1
    }

    fn set_current_display(&self, disp_idx: i32) {
        if self.is_multi_ui_session() {
            return;
        }
        self.push_event(
            "follow_current_display",
            &[("display_idx", &disp_idx.to_string())],
            &[],
        );
    }

    fn on_connected(&self, _conn_type: ConnType) {}

    fn msgbox(&self, msgtype: &str, title: &str, text: &str, link: &str, retry: bool) {
        let has_retry = if retry { "true" } else { "" };
        self.push_event(
            "msgbox",
            &[
                ("type", msgtype),
                ("title", title),
                ("text", text),
                ("link", link),
                ("hasRetry", has_retry),
            ],
            &[],
        );
    }

    fn cancel_msgbox(&self, tag: &str) {
        self.push_event("cancel_msgbox", &[("tag", tag)], &[]);
    }

    fn new_message(&self, msg: String) {
        self.push_event("chat_client_mode", &[("text", &msg)], &[]);
    }

    fn switch_display(&self, display: &SwitchDisplay) {
        let resolutions = serialize_resolutions(&display.resolutions.resolutions);
        self.push_event(
            "switch_display",
            &[
                ("display", &display.display.to_string()),
                ("x", &display.x.to_string()),
                ("y", &display.y.to_string()),
                ("width", &display.width.to_string()),
                ("height", &display.height.to_string()),
                (
                    "cursor_embedded",
                    &{
                        if display.cursor_embedded {
                            1
                        } else {
                            0
                        }
                    }
                    .to_string(),
                ),
                ("resolutions", &resolutions),
                (
                    "original_width",
                    &display.original_resolution.width.to_string(),
                ),
                (
                    "original_height",
                    &display.original_resolution.height.to_string(),
                ),
            ],
            &[],
        );
    }

    fn update_block_input_state(&self, on: bool) {
        self.push_event(
            "update_block_input_state",
            &[("input_state", if on { "on" } else { "off" })],
            &[],
        );
    }

    #[cfg(any(target_os = "android", target_os = "ios"))]
    fn clipboard(&self, content: String) {
        self.push_event("clipboard", &[("content", &content)], &[]);
    }

    fn switch_back(&self, peer_id: &str) {
        self.push_event("switch_back", &[("peer_id", peer_id)], &[]);
    }

    fn portable_service_running(&self, running: bool) {
        self.push_event(
            "portable_service_running",
            &[("running", running.to_string().as_str())],
            &[],
        );
    }

    fn on_voice_call_started(&self) {
        self.push_event::<&str>("on_voice_call_started", &[], &[]);
    }

    fn on_voice_call_closed(&self, reason: &str) {
        let _res = self.push_event("on_voice_call_closed", &[("reason", reason)], &[]);
    }

    fn on_voice_call_waiting(&self) {
        self.push_event::<&str>("on_voice_call_waiting", &[], &[]);
    }

    fn on_voice_call_incoming(&self) {
        self.push_event::<&str>("on_voice_call_incoming", &[], &[]);
    }

    #[inline]
    fn get_rgba(&self, _display: usize) -> *const u8 {
        if let Some(rgba_data) = self.display_rgbas.read().unwrap().get(&_display) {
            if rgba_data.valid {
                return rgba_data.data.as_ptr();
            }
        }
        std::ptr::null_mut()
    }

    #[inline]
    fn next_rgba(&self, _display: usize) {
        if let Some(rgba_data) = self.display_rgbas.write().unwrap().get_mut(&_display) {
            rgba_data.valid = false;
        }
    }

    fn update_record_status(&self, start: bool) {
        self.push_event("record_status", &[("start", &start.to_string())], &[]);
    }

    fn printer_request(&self, id: i32, path: String) {
        self.push_event(
            "printer_request",
            &[("id", json!(id)), ("path", json!(path))],
            &[],
        );
    }

    fn handle_screenshot_resp(&self, sid: String, msg: String) {
        match SessionID::from_str(&sid) {
            Ok(sid) => self.push_event_to("screenshot", &[("msg", json!(msg))], &[&sid]),
            Err(e) => {
                // Unreachable!
                log::error!("Failed to parse sid \"{}\", {}", sid, e);
            }
        }
    }

    fn handle_terminal_response(&self, response: TerminalResponse) {
        use hbb_common::message_proto::terminal_response::Union;

        match response.union {
            Some(Union::Opened(opened)) => {
                let mut event_data: Vec<(&str, serde_json::Value)> = vec![
                    ("type", json!("opened")),
                    ("terminal_id", json!(opened.terminal_id)),
                    ("success", json!(opened.success)),
                    ("message", json!(&opened.message)),
                    ("pid", json!(opened.pid)),
                    ("service_id", json!(&opened.service_id)),
                ];
                if !opened.persistent_sessions.is_empty() {
                    event_data.push(("persistent_sessions", json!(opened.persistent_sessions)));
                }
                self.push_event_("terminal_response", &event_data, &[], &[]);
            }
            Some(Union::Data(data)) => {
                // Decompress data if needed
                let output_data = if data.compressed {
                    hbb_common::compress::decompress(&data.data)
                } else {
                    data.data.to_vec()
                };

                let encoded = crate::encode64(&output_data);
                let event_data: Vec<(&str, serde_json::Value)> = vec![
                    ("type", json!("data")),
                    ("terminal_id", json!(data.terminal_id)),
                    ("data", json!(&encoded)),
                ];
                self.push_event_("terminal_response", &event_data, &[], &[]);
            }
            Some(Union::Closed(closed)) => {
                let event_data: Vec<(&str, serde_json::Value)> = vec![
                    ("type", json!("closed")),
                    ("terminal_id", json!(closed.terminal_id)),
                    ("exit_code", json!(closed.exit_code)),
                ];
                self.push_event_("terminal_response", &event_data, &[], &[]);
            }
            Some(Union::Error(error)) => {
                let event_data: Vec<(&str, serde_json::Value)> = vec![
                    ("type", json!("error")),
                    ("terminal_id", json!(error.terminal_id)),
                    ("message", json!(&error.message)),
                ];
                self.push_event_("terminal_response", &event_data, &[], &[]);
            }
            None => {}
            Some(_) => {
                log::warn!("Unhandled terminal response type");
            }
        }
    }
}

impl FlutterHandler {
    #[inline]
    fn on_rgba_soft_render(
        &self,
        context: RenderFrameContext,
        display: usize,
        rgba: &mut scrap::ImageRgb,
    ) -> RenderFrameOutcome {
        // Give a chance for plugins or etc to hook a rgba data.
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        for (key, hook) in self.hooks.read().unwrap().iter() {
            match hook {
                SessionHook::OnSessionRgba(cb) => {
                    cb(key.to_owned(), rgba);
                }
            }
        }
        // If the current rgba is not fetched by flutter, i.e., is valid.
        // We give up sending a new event to flutter.
        let mut rgba_write_lock = self.display_rgbas.write().unwrap();
        if let Some(rgba_data) = rgba_write_lock.get_mut(&display) {
            if rgba_data.valid {
                return RenderFrameOutcome::default();
            } else {
                rgba_data.valid = true;
            }
            // Return the rgba buffer to the video handler for reusing allocated rgba buffer.
            std::mem::swap::<Vec<u8>>(&mut rgba.raw, &mut rgba_data.data);
        } else {
            let mut rgba_data = RgbaData::default();
            std::mem::swap::<Vec<u8>>(&mut rgba.raw, &mut rgba_data.data);
            rgba_data.valid = true;
            rgba_write_lock.insert(display, rgba_data);
        }
        drop(rgba_write_lock);

        let mut is_sent = false;
        let mut outcome = RenderFrameOutcome::default();
        let mut handlers = self.session_handlers.write().unwrap();
        let is_multi_sessions = handlers
            .values()
            .filter(|handler| handler.event_stream.is_some())
            .count()
            > 1;
        for h in handlers.values_mut() {
            #[cfg(all(target_os = "android", feature = "mediacodec"))]
            h.texture_notified.write().unwrap().remove(&display);
            // The soft renderer does not support multi-displays session for now.
            if h.display_intent.displays.len() > 1 {
                continue;
            }
            // If there're multiple ui sessions, we only notify the ui session that has the display.
            if is_multi_sessions && !h.display_intent.displays.contains(&display) {
                continue;
            }
            if h.event_stream.is_some() && h.display_intent.displays.contains(&display) {
                let submitted = h
                    .event_stream
                    .as_ref()
                    .is_some_and(|stream| stream.add(EventToUI::Rgba(display)));
                let render_target_generation = h.event_stream_generation;
                outcome.merge(h.record_render_outcome(
                    display,
                    context,
                    render_target_generation,
                    submitted,
                    true,
                ));
                is_sent |= submitted;
            }
        }
        // We need `is_sent` here. Because we use texture render for multi-displays session.
        //
        // Eg. We have two windows, one is display 1, the other is displays 0&1.
        // When image of display 0 is received, we will not send the event.
        //
        // 1. "display 1" will not send the event.
        // 2. "displays 0&1" will not send the event. Because it uses texutre render for now.
        if !is_sent {
            if let Some(rgba_data) = self.display_rgbas.write().unwrap().get_mut(&display) {
                rgba_data.valid = false;
            }
        }
        outcome
    }

    #[inline]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    fn on_rgba_flutter_texture_render(
        &self,
        context: RenderFrameContext,
        use_texture_render: bool,
        display: usize,
        rgba: &mut scrap::ImageRgb,
    ) -> RenderFrameOutcome {
        let mut outcome = RenderFrameOutcome::default();
        for session in self.session_handlers.write().unwrap().values_mut() {
            if session.event_stream.is_none()
                || !session.display_intent.displays.contains(&display)
                || (!use_texture_render && session.display_intent.displays.len() <= 1)
            {
                continue;
            }
            let submission = session.renderer.on_rgba(display, rgba);
            if submission.render_type_changed() {
                if let Some(stream) = &session.event_stream {
                    stream.add(EventToUI::Texture(display, false));
                }
            }
            outcome.merge(session.record_render_outcome(
                display,
                context,
                submission.generation(),
                submission.submitted(),
                submission.target_exists(),
            ));
        }
        outcome
    }
}

// This function is only used for the default connection session.
pub fn session_add_existed(
    peer_id: String,
    session_id: SessionID,
    displays: Vec<i32>,
    is_view_camera: bool,
) -> ResultType<()> {
    let conn_type = if is_view_camera {
        ConnType::VIEW_CAMERA
    } else {
        ConnType::DEFAULT_CONN
    };
    sessions::insert_peer_session_id(peer_id, conn_type, session_id, displays);
    Ok(())
}

/// Create a new remote session with the given id.
///
/// # Arguments
///
/// * `id` - The identifier of the remote session with prefix. Regex: [\w]*[\_]*[\d]+
/// * `is_file_transfer` - If the session is used for file transfer.
/// * `is_view_camera` - If the session is used for view camera.
/// * `is_port_forward` - If the session is used for port forward.
pub fn session_add(
    session_id: &SessionID,
    id: &str,
    is_file_transfer: bool,
    is_view_camera: bool,
    is_port_forward: bool,
    is_rdp: bool,
    is_terminal: bool,
    switch_uuid: &str,
    force_relay: bool,
    password: String,
    is_shared_password: bool,
    conn_token: Option<String>,
) -> ResultType<FlutterSession> {
    let conn_type = if is_file_transfer {
        ConnType::FILE_TRANSFER
    } else if is_view_camera {
        ConnType::VIEW_CAMERA
    } else if is_terminal {
        ConnType::TERMINAL
    } else if is_port_forward {
        if is_rdp {
            ConnType::RDP
        } else {
            ConnType::PORT_FORWARD
        }
    } else {
        ConnType::DEFAULT_CONN
    };

    // to-do: check the same id session.
    if let Some(session) = sessions::get_session_by_session_id(&session_id) {
        if session.lc.read().unwrap().conn_type != conn_type {
            bail!("same session id is found with different conn type?");
        }
        // The same session is added before?
        bail!("same session id is found");
    }
    log::info!("session-add stage=session-id-available");

    LocalConfig::set_remote_id(&id);
    log::info!("session-add stage=remote-id-saved");

    let mut preset_password = password.clone();
    let shared_password = if is_shared_password {
        // To achieve a flexible password application order, we don't treat shared password as a preset password.
        preset_password = Default::default();
        Some(password)
    } else {
        None
    };

    let session: Session<FlutterHandler> = Session {
        password: preset_password,
        server_keyboard_enabled: Arc::new(RwLock::new(true)),
        server_file_transfer_enabled: Arc::new(RwLock::new(true)),
        server_clipboard_enabled: Arc::new(RwLock::new(true)),
        reconnect_count: Arc::new(AtomicUsize::new(0)),
        ..Default::default()
    };

    let switch_uuid = if switch_uuid.is_empty() {
        None
    } else {
        Some(switch_uuid.to_string())
    };

    session.lc.write().unwrap().initialize(
        id.to_owned(),
        conn_type,
        switch_uuid,
        force_relay,
        get_adapter_luid(),
        shared_password,
        conn_token,
    );
    log::info!("session-add stage=login-config-initialized");

    let session = Arc::new(session.clone());
    sessions::insert_session(session_id.to_owned(), conn_type, session.clone());
    log::info!("session-add stage=session-inserted");

    Ok(session)
}

/// start a session with the given id.
///
/// # Arguments
///
/// * `id` - The identifier of the remote session with prefix. Regex: [\w]*[\_]*[\d]+
/// * `events2ui` - The events channel to ui.
fn session_start_with_display_intent(
    session_id: &SessionID,
    id: &str,
    event_stream: StreamSink<EventToUI>,
    displays: Option<&[i32]>,
) -> ResultType<(FlutterSession, DisplayIntentEffects)> {
    // is_connected is used to indicate whether to start a peer connection. For two cases:
    // 1. "Move tab to new window"
    // 2. multi ui session within the same peer connection.
    let mut is_connected = false;
    let mut started = None;
    for s in sessions::get_sessions() {
        let mut handlers = s.session_handlers.write().unwrap();
        if let Some(h) = handlers.get_mut(session_id) {
            is_connected = h.event_stream.is_some();
            try_send_close_event(&h.event_stream);
            if let Some(displays) = displays {
                h.display_intent.set_wire_displays(displays);
            }
            h.render_bindings
                .retain(|display, _| h.display_intent.displays.contains(display));
            h.event_stream_generation = h.event_stream_generation.saturating_add(1).max(1);
            h.event_stream = Some(event_stream);
            let event = ViewIntentEvent::Upsert {
                view_id: *session_id,
                displays: h.display_intent.displays.clone(),
                active: true,
            };
            let current = aggregate_active_display_intents(&handlers);
            let is_first_ui_session = handlers.len() == 1;
            let effects = s.ui_handler.reduce_view_intent(event, &current);
            drop(handlers);
            started = Some((s, is_first_ui_session, effects));
            break;
        }
    }
    let Some((session, is_first_ui_session, display_effects)) = started else {
        bail!(
            "No session with peer id {}, session id: {}",
            id,
            session_id.to_string()
        );
    };

    if !is_connected && is_first_ui_session {
        log::info!(
            "Session {} start, use texture render: {}",
            id,
            session.use_texture_render.load(Ordering::Relaxed)
        );
        let session_for_io = (*session).clone();
        std::thread::spawn(move || {
            let round = session_for_io
                .connection_round_state
                .lock()
                .unwrap()
                .new_round();
            io_loop(session_for_io, round);
        });
    }
    Ok((session, display_effects))
}

pub fn session_start_(
    session_id: &SessionID,
    id: &str,
    event_stream: StreamSink<EventToUI>,
) -> ResultType<()> {
    let (session, display_effects) =
        session_start_with_display_intent(session_id, id, event_stream, None)?;
    apply_display_intent_effects(&session, &display_effects);
    Ok(())
}

pub fn session_start_with_displays_(
    session_id: &SessionID,
    id: &str,
    event_stream: StreamSink<EventToUI>,
    displays: &[i32],
) -> ResultType<()> {
    let (session, display_effects) =
        session_start_with_display_intent(session_id, id, event_stream, Some(displays))?;
    // A newly added subscription is synchronized by the host video service. Retained
    // subscriptions must not be refreshed merely because another UI view attached.
    apply_display_intent_effects(&session, &display_effects);
    Ok(())
}

#[inline]
fn try_send_close_event(event_stream: &Option<StreamSink<EventToUI>>) {
    if let Some(stream) = &event_stream {
        stream.add(EventToUI::Event("close".to_owned()));
        // The application marker is not the FRB stream terminator. Without
        // this, Dart's async* subscription can wait forever on a quiet port.
        stream.close();
    }
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod event_stream_close_tests {
    use super::*;
    use flutter_rust_bridge::{
        ffi::io::ffi::{DartCObject, DartCObjectType},
        rust2dart::Rust2Dart,
        store_dart_post_cobject,
    };
    use std::cell::RefCell;

    const TEST_PORT: i64 = -137;
    thread_local! {
        static ACTIONS: RefCell<Vec<i32>> = RefCell::new(Vec::new());
    }

    unsafe extern "C" fn record_post(port: i64, message: *mut DartCObject) -> bool {
        if port != TEST_PORT || message.is_null() {
            return false;
        }
        // Read only the bridge envelope tag; no application payload is logged.
        let message = &*message;
        if message.ty != DartCObjectType::DartArray {
            return false;
        }
        let array = message.value.as_array;
        if array.length == 0 || array.values.is_null() || (*array.values).is_null() {
            return false;
        }
        let action = &**array.values;
        if action.ty != DartCObjectType::DartInt32 {
            return false;
        }
        ACTIONS.with(|actions| actions.borrow_mut().push(action.value.as_int32));
        true
    }

    #[test]
    fn application_close_is_followed_by_bridge_stream_termination() {
        unsafe { store_dart_post_cobject(record_post) };
        ACTIONS.with(|actions| actions.borrow_mut().clear());
        let stream = StreamSink::new(Rust2Dart::new(TEST_PORT));
        try_send_close_event(&Some(stream));
        ACTIONS.with(|actions| assert_eq!(*actions.borrow(), [0, 2]));
        try_send_close_event(&None);
        ACTIONS.with(|actions| assert_eq!(*actions.borrow(), [0, 2]));
    }
}

#[cfg(not(target_os = "ios"))]
fn refresh_clipboard_channels() -> bool {
    for session in sessions::get_sessions()
        .into_iter()
        .filter(|session| session.is_default() && session.is_connection_alive())
    {
        let text = session.is_text_clipboard_required();
        #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
        let file = session.is_file_clipboard_required();
        #[cfg(not(any(target_os = "windows", feature = "unix-file-copy-paste")))]
        let file = false;
        Client::update_clipboard_channel(&session.get_id(), session.connection_round(), text, file);
    }
    Client::clipboard_required(false)
}

#[cfg(not(target_os = "ios"))]
pub fn update_text_clipboard_required() {
    #[cfg(target_os = "android")]
    {
        let is_required = refresh_clipboard_channels();
        let _ = scrap::android::ffi::call_clipboard_manager_enable_client_clipboard(is_required);
    }
    #[cfg(not(target_os = "android"))]
    refresh_clipboard_channels();
}

#[cfg(feature = "unix-file-copy-paste")]
pub fn update_file_clipboard_required() {
    refresh_clipboard_channels();
}

#[cfg(not(target_os = "ios"))]
pub fn send_clipboard_msg(msg: Message, _is_file: bool) {
    // Remote-origin clipboard writes carry the RustAdmin owner marker and are
    // consumed by the platform adapter. Only external local snapshots reach
    // this fan-out boundary.
    let recipients = Client::clipboard_local_recipients(_is_file);
    for s in sessions::get_sessions() {
        if !recipients.contains(&(s.get_id(), s.connection_round())) {
            continue;
        }
        #[cfg(feature = "unix-file-copy-paste")]
        if _is_file {
            if crate::is_support_file_copy_paste_num(s.lc.read().unwrap().version) {
                s.send(Data::Message(msg.clone()));
            }
            continue;
        }
        // Check if the client supports multi clipboards.
        if let Some(message::Union::MultiClipboards(multi_clipboards)) = &msg.union {
            let version = s.ui_handler.peer_info.read().unwrap().version.clone();
            let platform = s.ui_handler.peer_info.read().unwrap().platform.clone();
            if let Some(msg_out) = crate::clipboard::get_msg_if_not_support_multi_clip(
                &version,
                &platform,
                multi_clipboards,
            ) {
                s.send(Data::Message(msg_out));
                continue;
            }
        }
        s.send(Data::Message(msg.clone()));
    }
}

#[cfg(not(target_os = "ios"))]
pub fn send_debug_msg(msg: Message) {
    for s in sessions::get_sessions() {
        s.send(Data::Message(msg.clone()));
    }
}

// Server Side
#[cfg(not(any(target_os = "ios")))]
pub mod connection_manager {
    use std::collections::HashMap;

    #[cfg(any(target_os = "android"))]
    use hbb_common::log;
    #[cfg(any(target_os = "android"))]
    use scrap::android::call_main_service_set_by_name;
    use serde_json::json;

    use crate::ui_cm_interface::InvokeUiCM;

    use super::GLOBAL_EVENT_STREAM;

    #[derive(Clone)]
    struct FlutterHandler {}

    impl InvokeUiCM for FlutterHandler {
        //TODO port_forward
        fn add_connection(&self, client: &crate::ui_cm_interface::Client) {
            let client_json = serde_json::to_string(&client).unwrap_or("".into());
            // send to Android service, active notification no matter UI is shown or not.
            #[cfg(target_os = "android")]
            if let Err(e) =
                call_main_service_set_by_name("add_connection", Some(&client_json), None)
            {
                log::debug!("call_main_service_set_by_name fail,{}", e);
            }
            // send to UI, refresh widget
            self.push_event("add_connection", &[("client", &client_json)]);
        }

        fn remove_connection(&self, id: i32, close: bool) {
            self.push_event(
                "on_client_remove",
                &[("id", &id.to_string()), ("close", &close.to_string())],
            );
        }

        fn new_message(&self, id: i32, text: String) {
            self.push_event(
                "chat_server_mode",
                &[("id", &id.to_string()), ("text", &text)],
            );
        }

        fn permission_update(&self, id: i32, name: String, enabled: bool) {
            self.push_event(
                "permission_update",
                &[
                    ("id", &id.to_string()),
                    ("permission_name", &name),
                    ("enabled", &enabled.to_string()),
                ],
            );
        }

        fn permission_request(&self, id: i32, request_id: u64, name: String, enabled: bool) {
            self.push_event(
                "permission_request",
                &[
                    ("id", &id.to_string()),
                    ("request_id", &request_id.to_string()),
                    ("permission_name", &name),
                    ("enabled", &enabled.to_string()),
                ],
            );
        }

        fn change_theme(&self, dark: String) {
            self.push_event("theme", &[("dark", &dark)]);
        }

        fn change_language(&self) {
            self.push_event::<&str>("language", &[]);
        }

        fn show_elevation(&self, show: bool) {
            self.push_event("show_elevation", &[("show", &show.to_string())]);
        }

        fn update_voice_call_state(&self, client: &crate::ui_cm_interface::Client) {
            let client_json = serde_json::to_string(&client).unwrap_or("".into());
            // send to Android service, active notification no matter UI is shown or not.
            #[cfg(target_os = "android")]
            if let Err(e) =
                call_main_service_set_by_name("update_voice_call_state", Some(&client_json), None)
            {
                log::debug!("call_main_service_set_by_name fail,{}", e);
            }
            self.push_event("update_voice_call_state", &[("client", &client_json)]);
        }

        fn file_transfer_log(&self, action: &str, log: &str) {
            self.push_event("cm_file_transfer_log", &[(action, log)]);
        }
    }

    impl FlutterHandler {
        fn push_event<V>(&self, name: &str, event: &[(&str, V)])
        where
            V: Sized + serde::Serialize + Clone,
        {
            let mut h: HashMap<&str, serde_json::Value> =
                event.iter().map(|(k, v)| (*k, json!(*v))).collect();
            debug_assert!(h.get("name").is_none());
            h.insert("name", json!(name));

            if let Some(s) = GLOBAL_EVENT_STREAM.read().unwrap().get(super::APP_TYPE_CM) {
                s.add(serde_json::ser::to_string(&h).unwrap_or("".to_owned()));
            } else {
                println!(
                    "Push event {} failed. No {} event stream found.",
                    name,
                    super::APP_TYPE_CM
                );
            };
        }
    }

    #[inline]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    pub fn start_cm_no_ui() {
        start_listen_ipc(false);
    }

    #[inline]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    fn start_listen_ipc_thread() {
        start_listen_ipc(true);
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    fn start_listen_ipc(new_thread: bool) {
        use crate::ui_cm_interface::{start_ipc, ConnectionManager};

        #[cfg(target_os = "linux")]
        std::thread::spawn(crate::ipc::start_pa);

        let cm = ConnectionManager {
            ui_handler: FlutterHandler {},
        };
        if new_thread {
            std::thread::spawn(move || start_ipc(cm));
        } else {
            start_ipc(cm);
        }
    }

    #[inline]
    pub fn cm_init() {
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        start_listen_ipc_thread();
    }

    #[cfg(target_os = "android")]
    use hbb_common::tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};

    #[cfg(target_os = "android")]
    pub fn start_channel(
        rx: UnboundedReceiver<crate::ipc::Data>,
        tx: UnboundedSender<crate::ipc::Data>,
    ) {
        use crate::ui_cm_interface::start_listen;
        let cm = crate::ui_cm_interface::ConnectionManager {
            ui_handler: FlutterHandler {},
        };
        std::thread::spawn(move || start_listen(cm, rx, tx));
    }
}

pub fn make_fd_flutter(id: i32, entries: &Vec<FileEntry>, only_count: bool) -> String {
    let mut m = serde_json::Map::new();
    m.insert("id".into(), json!(id));
    let mut a = vec![];
    let mut n: u64 = 0;
    for entry in entries {
        n += entry.size;
        if only_count {
            continue;
        }
        let mut e = serde_json::Map::new();
        e.insert("name".into(), json!(entry.name.to_owned()));
        let tmp = entry.entry_type.value();
        e.insert("type".into(), json!(if tmp == 0 { 1 } else { tmp }));
        e.insert("time".into(), json!(entry.modified_time as f64));
        e.insert("size".into(), json!(entry.size as f64));
        a.push(e);
    }
    if only_count {
        m.insert("num_entries".into(), json!(entries.len() as i32));
    } else {
        m.insert("entries".into(), json!(a));
    }
    m.insert("total_size".into(), json!(n as f64));
    serde_json::to_string(&m).unwrap_or("".into())
}

pub fn get_cur_session_id() -> SessionID {
    CUR_SESSION_ID.read().unwrap().clone()
}

pub fn get_cur_peer_id() -> String {
    sessions::get_peer_id_by_session_id(&get_cur_session_id(), ConnType::DEFAULT_CONN)
        .unwrap_or("".to_string())
}

pub fn set_cur_session_id(session_id: SessionID) {
    if get_cur_session_id() != session_id {
        *CUR_SESSION_ID.write().unwrap() = session_id;
    }
}

#[inline]
fn serialize_resolutions(resolutions: &Vec<Resolution>) -> String {
    #[derive(Debug, serde::Serialize)]
    struct ResolutionSerde {
        width: i32,
        height: i32,
    }

    let mut v = vec![];
    resolutions
        .iter()
        .map(|r| {
            v.push(ResolutionSerde {
                width: r.width,
                height: r.height,
            })
        })
        .count();
    serde_json::ser::to_string(&v).unwrap_or("".to_string())
}

fn char_to_session_id(c: *const char) -> ResultType<SessionID> {
    if c.is_null() {
        bail!("Session id ptr is null");
    }
    let cstr = unsafe { std::ffi::CStr::from_ptr(c as _) };
    let str = cstr.to_str()?;
    SessionID::from_str(str).map_err(|e| anyhow!("{:?}", e))
}

pub fn session_get_rgba_size(session_id: SessionID, display: usize) -> usize {
    if let Some(session) = sessions::get_session_by_session_id(&session_id) {
        return session
            .display_rgbas
            .read()
            .unwrap()
            .get(&display)
            .map_or(0, |rgba| rgba.data.len());
    }
    0
}

#[no_mangle]
pub extern "C" fn session_get_rgba(session_uuid_str: *const char, display: usize) -> *const u8 {
    if let Ok(session_id) = char_to_session_id(session_uuid_str) {
        if let Some(s) = sessions::get_session_by_session_id(&session_id) {
            return s.ui_handler.get_rgba(display);
        }
    }

    std::ptr::null()
}

pub fn session_next_rgba(session_id: SessionID, display: usize) {
    if let Some(s) = sessions::get_session_by_session_id(&session_id) {
        return s.ui_handler.next_rgba(display);
    }
}

#[inline]
pub fn session_set_size(session_id: SessionID, display: usize, width: usize, height: usize) {
    for s in sessions::get_sessions() {
        let effects = {
            let mut handlers = s.ui_handler.session_handlers.write().unwrap();
            let Some(h) = handlers.get_mut(&session_id) else {
                continue;
            };
            // The first UI session has no explicit display intent until its initial
            // renderer is sized. Seed it once; later target setup must not expand intent.
            let intent_changed = h.display_intent.seed_initial_display(display);
            h.renderer.set_size(display, width, height);
            if intent_changed {
                let event = ViewIntentEvent::Upsert {
                    view_id: session_id,
                    displays: h.display_intent.displays.clone(),
                    active: h.event_stream.is_some(),
                };
                let current = aggregate_active_display_intents(&handlers);
                Some(s.ui_handler.reduce_view_intent(event, &current))
            } else {
                None
            }
        };
        if let Some(effects) = effects {
            apply_display_intent_effects(&s, &effects);
        }
        break;
    }
}

#[inline]
pub fn session_register_pixelbuffer_texture(session_id: SessionID, display: usize, ptr: usize) {
    for s in sessions::get_sessions() {
        if let Some(h) = s
            .ui_handler
            .session_handlers
            .read()
            .unwrap()
            .get(&session_id)
        {
            h.renderer.register_pixelbuffer_texture(display, ptr);
            break;
        }
    }
}

fn with_session_renderer(session_id: &SessionID, callback: impl FnOnce(&VideoRenderer)) {
    for session in sessions::get_sessions() {
        if let Some(handler) = session
            .ui_handler
            .session_handlers
            .read()
            .unwrap()
            .get(session_id)
        {
            callback(&handler.renderer);
            break;
        }
    }
}

#[inline]
pub fn session_register_pixelbuffer_render_target(
    session_id: SessionID,
    display: usize,
    ptr: usize,
    token: u64,
) {
    with_session_renderer(&session_id, |renderer| {
        renderer.register_owned_pixelbuffer_texture(display, ptr, token)
    });
}

#[inline]
pub fn session_unregister_pixelbuffer_render_target(
    session_id: SessionID,
    display: usize,
    token: u64,
) {
    with_session_renderer(&session_id, |renderer| {
        renderer.unregister_owned_pixelbuffer_texture(display, token)
    });
}

#[inline]
pub fn session_register_gpu_texture(_session_id: SessionID, _display: usize, _output_ptr: usize) {
    #[cfg(feature = "vram")]
    for s in sessions::get_sessions() {
        if let Some(h) = s
            .ui_handler
            .session_handlers
            .read()
            .unwrap()
            .get(&_session_id)
        {
            h.renderer.register_gpu_output(_display, _output_ptr);
            break;
        }
    }
}

#[inline]
pub fn session_register_gpu_render_target(
    _session_id: SessionID,
    _display: usize,
    _output_ptr: usize,
    _token: u64,
) {
    #[cfg(feature = "vram")]
    with_session_renderer(&_session_id, |renderer| {
        renderer.register_owned_gpu_output(_display, _output_ptr, _token)
    });
}

#[inline]
pub fn session_unregister_gpu_render_target(_session_id: SessionID, _display: usize, _token: u64) {
    #[cfg(feature = "vram")]
    with_session_renderer(&_session_id, |renderer| {
        renderer.unregister_owned_gpu_output(_display, _token)
    });
}

#[inline]
#[cfg(not(feature = "vram"))]
pub fn get_adapter_luid() -> Option<i64> {
    None
}

#[cfg(feature = "vram")]
pub fn get_adapter_luid() -> Option<i64> {
    if !crate::ui_interface::use_texture_render() {
        return None;
    }
    let get_adapter_luid_func = match &*TEXTURE_GPU_RENDERER_PLUGIN {
        Ok(lib) => {
            let find_sym_res = unsafe {
                lib.symbol::<FlutterGpuTextureRendererPluginCApiGetAdapterLuid>(
                    "FlutterGpuTextureRendererPluginCApiGetAdapterLuid",
                )
            };
            match find_sym_res {
                Ok(sym) => Some(sym),
                Err(e) => {
                    log::error!("Failed to find symbol FlutterGpuTextureRendererPluginCApiGetAdapterLuid, {e}");
                    None
                }
            }
        }
        Err(e) => {
            log::error!("Failed to load texture gpu renderer plugin, {e}");
            None
        }
    };
    let adapter_luid = match get_adapter_luid_func {
        Some(get_adapter_luid_func) => unsafe { Some(get_adapter_luid_func()) },
        None => Default::default(),
    };
    return adapter_luid;
}

#[inline]
pub fn push_session_event(session_id: &SessionID, name: &str, event: Vec<(&str, &str)>) {
    if let Some(s) = sessions::get_session_by_session_id(session_id) {
        s.push_event(name, &event, &[]);
    }
}

#[inline]
pub fn push_global_event(channel: &str, event: String) -> Option<bool> {
    Some(GLOBAL_EVENT_STREAM.read().unwrap().get(channel)?.add(event))
}

#[inline]
pub fn get_global_event_channels() -> Vec<String> {
    GLOBAL_EVENT_STREAM
        .read()
        .unwrap()
        .keys()
        .cloned()
        .collect()
}

pub fn start_global_event_stream(s: StreamSink<String>, app_type: String) -> ResultType<()> {
    let app_type_values = app_type.split(",").collect::<Vec<&str>>();
    let mut lock = GLOBAL_EVENT_STREAM.write().unwrap();
    if !lock.contains_key(app_type_values[0]) {
        lock.insert(app_type_values[0].to_string(), s);
    } else {
        if let Some(_) = lock.insert(app_type.clone(), s) {
            log::warn!(
                "Global event stream of type {} is started before, but now removed",
                app_type
            );
        }
    }
    Ok(())
}

pub fn stop_global_event_stream(app_type: String) {
    let _ = GLOBAL_EVENT_STREAM.write().unwrap().remove(&app_type);
}

#[inline]
fn session_send_touch_scale(
    session_id: SessionID,
    v: &serde_json::Value,
    alt: bool,
    ctrl: bool,
    shift: bool,
    command: bool,
) {
    match v.get("v").and_then(|s| s.as_i64()) {
        Some(scale) => {
            if let Some(session) = sessions::get_session_by_session_id(&session_id) {
                session.send_touch_scale(scale as _, alt, ctrl, shift, command);
            }
        }
        None => {}
    }
}

#[inline]
fn session_send_touch_pan(
    session_id: SessionID,
    v: &serde_json::Value,
    pan_event: &str,
    alt: bool,
    ctrl: bool,
    shift: bool,
    command: bool,
) {
    match v.get("v") {
        Some(v) => match (
            v.get("x").and_then(|x| x.as_i64()),
            v.get("y").and_then(|y| y.as_i64()),
        ) {
            (Some(x), Some(y)) => {
                if let Some(session) = sessions::get_session_by_session_id(&session_id) {
                    session
                        .send_touch_pan_event(pan_event, x as _, y as _, alt, ctrl, shift, command);
                }
            }
            _ => {}
        },
        _ => {}
    }
}

fn session_send_touch_event(
    session_id: SessionID,
    v: &serde_json::Value,
    alt: bool,
    ctrl: bool,
    shift: bool,
    command: bool,
) {
    match v.get("t").and_then(|t| t.as_str()) {
        Some("scale") => session_send_touch_scale(session_id, v, alt, ctrl, shift, command),
        Some(pan_event) => {
            session_send_touch_pan(session_id, v, pan_event, alt, ctrl, shift, command)
        }
        _ => {}
    }
}

pub fn session_send_pointer(session_id: SessionID, msg: String) {
    if let Ok(m) = serde_json::from_str::<HashMap<String, serde_json::Value>>(&msg) {
        let alt = m.get("alt").is_some();
        let ctrl = m.get("ctrl").is_some();
        let shift = m.get("shift").is_some();
        let command = m.get("command").is_some();
        match (m.get("k"), m.get("v")) {
            (Some(k), Some(v)) => match k.as_str() {
                Some("touch") => session_send_touch_event(session_id, v, alt, ctrl, shift, command),
                _ => {}
            },
            _ => {}
        }
    }
}

#[inline]
pub fn session_on_waiting_for_image_dialog_show(session_id: SessionID) {
    for s in sessions::get_sessions() {
        if let Some(h) = s.session_handlers.write().unwrap().get_mut(&session_id) {
            h.on_waiting_for_image_dialog_show();
        }
    }
}

/// Hooks for session.
#[derive(Clone)]
pub enum SessionHook {
    OnSessionRgba(fn(String, &mut scrap::ImageRgb)),
}

#[inline]
pub fn get_cur_session() -> Option<FlutterSession> {
    sessions::get_session_by_session_id(&*CUR_SESSION_ID.read().unwrap())
}

#[inline]
pub fn try_sync_peer_option(
    session: &FlutterSession,
    cur_id: &SessionID,
    key: &str,
    _value: Option<serde_json::Value>,
) {
    let mut event = Vec::new();
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    if key == "view-only" {
        event = vec![
            ("k", json!(key.to_string())),
            ("v", json!(session.lc.read().unwrap().view_only.v)),
        ];
    }
    if ["keyboard_mode", "input_source"].contains(&key) {
        event = vec![("k", json!(key.to_string())), ("v", json!(""))];
    }
    if !event.is_empty() {
        session.push_event("sync_peer_option", &event, &[cur_id]);
    }
}

pub(super) fn session_update_virtual_display(session: &FlutterSession, index: i32, on: bool) {
    let virtual_display_key = "virtual-display";
    let displays = session.get_option(virtual_display_key.to_owned());
    if !on {
        if index == -1 {
            if !displays.is_empty() {
                session.set_option(virtual_display_key.to_owned(), "".to_owned());
            }
        } else {
            let mut vdisplays = displays.split(',').collect::<Vec<_>>();
            let len = vdisplays.len();
            if index == 0 {
                // 0 means we can't toggle the virtual display by index.
                vdisplays.remove(vdisplays.len() - 1);
            } else {
                if let Some(i) = vdisplays.iter().position(|&x| x == index.to_string()) {
                    vdisplays.remove(i);
                }
            }
            if vdisplays.len() != len {
                session.set_option(
                    virtual_display_key.to_owned(),
                    vdisplays.join(",").to_owned(),
                );
            }
        }
    } else {
        let mut vdisplays = displays
            .split(',')
            .map(|x| x.to_string())
            .collect::<Vec<_>>();
        let len = vdisplays.len();
        if index == 0 {
            vdisplays.push(index.to_string());
        } else {
            if !vdisplays.iter().any(|x| *x == index.to_string()) {
                vdisplays.push(index.to_string());
            }
        }
        if vdisplays.len() != len {
            session.set_option(
                virtual_display_key.to_owned(),
                vdisplays.join(",").to_owned(),
            );
        }
    }
}

// sessions mod is used to avoid the big lock of sessions' map.
pub mod sessions {

    use super::*;

    lazy_static::lazy_static! {
        // peer -> peer session, peer session -> ui sessions
        static ref SESSIONS: RwLock<HashMap<(String, ConnType), FlutterSession>> = Default::default();
    }

    #[inline]
    pub fn get_session_count(peer_id: String, conn_type: ConnType) -> usize {
        SESSIONS
            .read()
            .unwrap()
            .get(&(peer_id, conn_type))
            .map(|s| s.ui_handler.session_handlers.read().unwrap().len())
            .unwrap_or(0)
    }

    #[inline]
    pub fn get_peer_id_by_session_id(id: &SessionID, conn_type: ConnType) -> Option<String> {
        SESSIONS
            .read()
            .unwrap()
            .iter()
            .find_map(|((peer_id, t), s)| {
                if *t == conn_type
                    && s.ui_handler
                        .session_handlers
                        .read()
                        .unwrap()
                        .contains_key(id)
                {
                    Some(peer_id.clone())
                } else {
                    None
                }
            })
    }

    #[inline]
    pub fn get_session_by_session_id(id: &SessionID) -> Option<FlutterSession> {
        SESSIONS
            .read()
            .unwrap()
            .values()
            .find(|s| {
                s.ui_handler
                    .session_handlers
                    .read()
                    .unwrap()
                    .contains_key(id)
            })
            .cloned()
    }

    #[inline]
    pub fn get_session_by_peer_id(peer_id: String, conn_type: ConnType) -> Option<FlutterSession> {
        SESSIONS.read().unwrap().get(&(peer_id, conn_type)).cloned()
    }

    #[inline]
    pub fn remove_session_by_session_id(id: &SessionID) -> Option<FlutterSession> {
        remove_session_with_notifier(id, |handler| try_send_close_event(&handler.event_stream))
    }

    fn remove_session_with_notifier(
        id: &SessionID,
        notify: impl FnOnce(&SessionHandler),
    ) -> Option<FlutterSession> {
        let mut remove_peer_key = None;
        let mut display_reconcile = None;
        let mut removed_handler = None;
        let removed_session = {
            let mut sessions = SESSIONS.write().unwrap();
            for (peer_key, s) in sessions.iter_mut() {
                let mut handlers = s.ui_handler.session_handlers.write().unwrap();
                if let Some(handler) = handlers.remove(id) {
                    removed_handler = Some(handler);
                    if handlers.is_empty() {
                        remove_peer_key = Some(peer_key.clone());
                    } else {
                        let current = aggregate_active_display_intents(&handlers);
                        let effects = s
                            .ui_handler
                            .reduce_view_intent(ViewIntentEvent::Remove { view_id: *id }, &current);
                        display_reconcile = Some((s.clone(), effects));
                    }
                    break;
                }
            }
            remove_peer_key
                .as_ref()
                .and_then(|peer_key| sessions.remove(peer_key))
        };

        // Notify through the detached handler while its sink is still alive.
        // This is required even when other views keep the peer session alive.
        if let Some(handler) = removed_handler {
            notify(&handler);
        }

        if let Some((session, display_effects)) = display_reconcile {
            apply_display_intent_effects(&session, &display_effects);
        }

        let session = removed_session?;
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        update_session_count_to_server();
        Some(session)
    }

    /// Check if removing a session by session_id would result in removing the entire peer.
    ///
    /// Returns:
    /// - `true`: The session exists and removing it would leave the peer with no other sessions,
    ///           so the entire peer would be removed (equivalent to `remove_session_by_session_id` returning `Some`)
    /// - `false`: The session doesn't exist, or it exists but the peer has other sessions,
    ///            so the peer would not be removed (equivalent to `remove_session_by_session_id` returning `None`)
    #[inline]
    pub fn would_remove_peer_by_session_id(id: &SessionID) -> bool {
        for (_peer_key, s) in SESSIONS.read().unwrap().iter() {
            let read_lock = s.ui_handler.session_handlers.read().unwrap();
            if read_lock.contains_key(id) {
                // Found the session, check if it's the only one for this peer
                return read_lock.len() == 1;
            }
        }
        // Session not found
        false
    }

    #[cfg(test)]
    mod close_tests {
        use super::*;

        #[test]
        fn removed_views_are_notified_once_including_the_last_view() {
            let first = SessionID::new_v4();
            let second = SessionID::new_v4();
            let peer_key = (format!("close-test-{first}"), ConnType::DEFAULT_CONN);
            let session: FlutterSession = Arc::new(Session::default());
            {
                let mut handlers = session.ui_handler.session_handlers.write().unwrap();
                for (id, display) in [(first, 0), (second, 1)] {
                    let mut handler = SessionHandler::default();
                    handler.display_intent.set_wire_displays(&[display]);
                    handler.event_stream = Some(StreamSink::new(
                        flutter_rust_bridge::rust2dart::Rust2Dart::new(-138),
                    ));
                    handlers.insert(id, handler);
                    let current = aggregate_active_display_intents(&handlers);
                    session.ui_handler.reduce_view_intent(
                        ViewIntentEvent::Upsert {
                            view_id: id,
                            displays: vec![display as usize],
                            active: true,
                        },
                        &current,
                    );
                }
            }
            let retained_activation = session
                .ui_handler
                .current_display_media_intent()
                .activation(1)
                .unwrap()
                .clone();
            SESSIONS
                .write()
                .unwrap()
                .insert(peer_key.clone(), session.clone());
            let mut notifications = Vec::new();

            assert!(remove_session_with_notifier(&first, |handler| {
                assert!(!session
                    .ui_handler
                    .session_handlers
                    .read()
                    .unwrap()
                    .contains_key(&first));
                notifications.push(handler.display_intent.displays.clone());
            })
            .is_none());
            assert!(get_session_by_session_id(&second).is_some());
            assert_eq!(
                session.ui_handler.current_display_media_intent().displays,
                vec![retained_activation]
            );
            assert!(remove_session_with_notifier(&first, |_| {
                panic!("duplicate removal notified a closed view");
            })
            .is_none());

            let last = remove_session_with_notifier(&second, |handler| {
                assert!(!SESSIONS.read().unwrap().contains_key(&peer_key));
                notifications.push(handler.display_intent.displays.clone());
            })
            .unwrap();
            assert!(Arc::ptr_eq(&last, &session));
            assert_eq!(notifications, vec![vec![0], vec![1]]);
            assert!(get_session_by_session_id(&second).is_none());
        }
    }

    pub fn session_switch_display(is_desktop: bool, session_id: SessionID, value: Vec<i32>) {
        for s in SESSIONS.read().unwrap().values() {
            let update = {
                let mut handlers = s.ui_handler.session_handlers.write().unwrap();
                let Some(handler) = handlers.get_mut(&session_id) else {
                    continue;
                };
                let is_active = handler.event_stream.is_some();
                handler.display_intent.set_wire_displays(&value);
                handler
                    .render_bindings
                    .retain(|display, _| handler.display_intent.displays.contains(display));
                let event = ViewIntentEvent::Upsert {
                    view_id: session_id,
                    displays: handler.display_intent.displays.clone(),
                    active: is_active,
                };
                let current = aggregate_active_display_intents(&handlers);
                let active_ui_sessions = handlers
                    .values()
                    .filter(|handler| handler.event_stream.is_some())
                    .count();
                (
                    s.ui_handler.reduce_view_intent(event, &current),
                    active_ui_sessions,
                    is_active,
                )
            };

            let (display_effects, active_ui_sessions, is_active) = update;
            if !is_active || !display_effects.changed {
                break;
            }
            let legacy_single_display =
                display_effects.delta.current.len() == 1 && active_ui_sessions == 1;

            if legacy_single_display {
                let display = display_effects.delta.current[0];
                let Ok(display_wire) = i32::try_from(display) else {
                    break;
                };
                // Preserve the established one-view replacement behavior. Multi-view
                // updates below are declarative and must not reset another view's decoder.
                s.switch_display(display_wire);
                s.next_rgba(display);
                if is_desktop {
                    s.capture_displays(
                        vec![],
                        vec![],
                        wire_display_indices(&display_effects.delta.current),
                    );
                } else {
                    s.capture_displays(vec![], vec![], vec![display_wire]);
                }

                #[cfg(not(any(target_os = "android", target_os = "ios")))]
                if crate::common::is_support_multi_ui_session(
                    &s.ui_handler.peer_info.read().unwrap().version,
                ) {
                    s.refresh_video(display_wire);
                }
                s.send(Data::DisplayIntent(display_effects.media_intent.clone()));
            } else if is_desktop {
                apply_display_intent_effects(s, &display_effects);
            } else {
                s.capture_displays(
                    vec![],
                    vec![],
                    wire_display_indices(&display_effects.delta.current),
                );
                s.send(Data::DisplayIntent(display_effects.media_intent.clone()));
            }
            break;
        }
    }

    #[inline]
    pub fn insert_session(session_id: SessionID, conn_type: ConnType, session: FlutterSession) {
        let session = {
            let mut sessions = SESSIONS.write().unwrap();
            sessions
                .entry((session.get_id(), conn_type))
                .or_insert(session)
                .clone()
        };
        let current = {
            let mut handlers = session.ui_handler.session_handlers.write().unwrap();
            handlers.insert(session_id, Default::default());
            aggregate_active_display_intents(&handlers)
        };
        session.ui_handler.reduce_view_intent(
            ViewIntentEvent::Upsert {
                view_id: session_id,
                displays: Vec::new(),
                active: false,
            },
            &current,
        );
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        update_session_count_to_server();
    }

    #[inline]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    fn update_session_count_to_server() {
        crate::ipc::update_controlling_session_count(SESSIONS.read().unwrap().len()).ok();
    }

    #[inline]
    pub fn insert_peer_session_id(
        peer_id: String,
        conn_type: ConnType,
        session_id: SessionID,
        displays: Vec<i32>,
    ) -> bool {
        if let Some(s) = SESSIONS.read().unwrap().get(&(peer_id, conn_type)) {
            let mut h = SessionHandler::default();
            h.display_intent.set_wire_displays(&displays);
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            let is_support_multi_ui_session = crate::common::is_support_multi_ui_session(
                &s.ui_handler.peer_info.read().unwrap().version,
            );
            #[cfg(any(target_os = "android", target_os = "ios"))]
            let is_support_multi_ui_session = false;
            h.renderer.is_support_multi_ui_session = is_support_multi_ui_session;
            let current = {
                let mut handlers = s.ui_handler.session_handlers.write().unwrap();
                handlers.insert(session_id, h);
                aggregate_active_display_intents(&handlers)
            };
            s.ui_handler.reduce_view_intent(
                ViewIntentEvent::Upsert {
                    view_id: session_id,
                    displays: displays
                        .iter()
                        .filter_map(|display| usize::try_from(*display).ok())
                        .collect(),
                    active: false,
                },
                &current,
            );
            // If the session is a single display session, it may be a software rgba rendered display.
            // If this is the second time the display is opened, the old valid flag may be true.
            if displays.len() == 1 {
                s.ui_handler.next_rgba(displays[0] as usize);
            }
            true
        } else {
            false
        }
    }

    #[inline]
    pub fn get_sessions() -> Vec<FlutterSession> {
        SESSIONS.read().unwrap().values().cloned().collect()
    }

    #[inline]
    #[cfg(not(target_os = "ios"))]
    pub fn has_sessions_running(conn_type: ConnType) -> bool {
        SESSIONS.read().unwrap().iter().any(|((_, r#type), s)| {
            *r#type == conn_type && s.session_handlers.read().unwrap().len() != 0
        })
    }
}

pub(super) mod async_tasks {
    use hbb_common::{bail, tokio, ResultType};
    use std::{
        collections::HashMap,
        sync::{
            mpsc::{sync_channel, SyncSender},
            Arc, Mutex,
        },
    };

    type TxQueryOnlines = SyncSender<Vec<String>>;
    lazy_static::lazy_static! {
        static ref TX_QUERY_ONLINES: Arc<Mutex<Option<TxQueryOnlines>>> = Default::default();
    }

    #[inline]
    pub fn start_flutter_async_runner() {
        std::thread::spawn(start_flutter_async_runner_);
    }

    #[allow(dead_code)]
    pub fn stop_flutter_async_runner() {
        let _ = TX_QUERY_ONLINES.lock().unwrap().take();
    }

    #[tokio::main(flavor = "current_thread")]
    async fn start_flutter_async_runner_() {
        // Only one task is allowed to run at the same time.
        let (tx_onlines, rx_onlines) = sync_channel::<Vec<String>>(1);
        TX_QUERY_ONLINES.lock().unwrap().replace(tx_onlines);

        loop {
            match rx_onlines.recv() {
                Ok(ids) => {
                    crate::client::peer_online::query_online_states(ids, handle_query_onlines).await
                }
                _ => {
                    // unreachable!
                    break;
                }
            }
        }
    }

    pub fn query_onlines(ids: Vec<String>) -> ResultType<()> {
        if let Some(tx) = TX_QUERY_ONLINES.lock().unwrap().as_ref() {
            // Ignore if the channel is full.
            let _ = tx.try_send(ids)?;
        } else {
            bail!("No tx_query_onlines");
        }
        Ok(())
    }

    fn handle_query_onlines(onlines: Vec<String>, offlines: Vec<String>) {
        let data = HashMap::from([
            ("name", "callback_query_onlines".to_owned()),
            ("onlines", onlines.join(",")),
            ("offlines", offlines.join(",")),
        ]);
        let _res = super::push_global_event(
            super::APP_TYPE_MAIN,
            serde_json::ser::to_string(&data).unwrap_or("".to_owned()),
        );
    }
}
