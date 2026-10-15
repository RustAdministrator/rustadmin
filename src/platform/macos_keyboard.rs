#![cfg(target_os = "macos")]

use core_graphics::{
    event::{CGEvent, CGEventFlags, CGKeyCode, EventField},
    event_source::CGEventSource,
};
use foreign_types::ForeignType;
use hbb_common::{keyboard::macos_keyboard_type, message_proto::KeyboardFamily};

// These are the Carbon OSType values for the physical layouts declared in the
// installed SDK's HIToolbox/Keyboards.h. OSType is a four-byte big-endian code.
const K_KEYBOARD_JIS: u32 = u32::from_be_bytes(*b"JIS ");
const K_KEYBOARD_ANSI: u32 = u32::from_be_bytes(*b"ANSI");
const K_KEYBOARD_ISO: u32 = u32::from_be_bytes(*b"ISO ");

#[allow(improper_ctypes, non_snake_case)]
#[link(name = "Carbon", kind = "framework")]
extern "C" {
    fn LMGetKbdType() -> u8;
    fn KBGetLayoutType(keyboard_type: i16) -> u32;
}

#[allow(improper_ctypes, non_snake_case)]
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventSourceSetKeyboardType(
        source: core_graphics::sys::CGEventSourceRef,
        keyboard_type: u32,
    );
}

/// Set the keyboard type used while CoreGraphics constructs an event.
fn set_source_keyboard_type(source: &CGEventSource, keyboard_type: u32) {
    // SAFETY: `source.as_ptr()` is the live `CGEventSourceRef` owned by the
    // caller. CoreGraphics accepts that opaque pointer and the `u32` matches
    // its `CGEventSourceKeyboardType` parameter. The source remains alive for
    // the duration of this call.
    unsafe { CGEventSourceSetKeyboardType(source.as_ptr(), keyboard_type) };
}

fn family_for_layout_type(layout_type: u32) -> KeyboardFamily {
    match layout_type {
        K_KEYBOARD_ANSI => KeyboardFamily::Ansi,
        K_KEYBOARD_ISO => KeyboardFamily::Iso,
        K_KEYBOARD_JIS => KeyboardFamily::Jis,
        _ => KeyboardFamily::Unknown,
    }
}

/// Carbon's hardware queries are confined to the native main thread. The
/// session owner caches the result; this module owns no keyboard-family state.
pub(crate) fn detected_keyboard_family() -> KeyboardFamily {
    fn query() -> KeyboardFamily {
        // SAFETY: These pointer-free declarations match the SDK's UInt8,
        // SInt16 and OSType signatures, and run exclusively on the main thread.
        let keyboard_type = unsafe { LMGetKbdType() };
        let layout_type = unsafe { KBGetLayoutType(i16::from(keyboard_type)) };
        family_for_layout_type(layout_type)
    }
    // SAFETY: pthread_main_np is a pointer-free thread identity query.
    if unsafe { hbb_common::libc::pthread_main_np() } != 0 {
        query()
    } else {
        let mut family = KeyboardFamily::Unknown;
        dispatch::Queue::main().exec_sync(|| family = query());
        family
    }
}

#[allow(non_upper_case_globals)]
fn apply_key_up_flag_workaround(event: &CGEvent, code: CGKeyCode) {
    let flags_to_clear = match code {
        // Keep this list aligned with rdev f9b60b1's macOS workaround_fn.
        rdev::kVK_F1
        | rdev::kVK_F2
        | rdev::kVK_F3
        | rdev::kVK_F4
        | rdev::kVK_F5
        | rdev::kVK_F6
        | rdev::kVK_F7
        | rdev::kVK_F8
        | rdev::kVK_F9
        | rdev::kVK_F10
        | rdev::kVK_F11
        | rdev::kVK_F12
        | rdev::kVK_F13
        | rdev::kVK_F14
        | rdev::kVK_F15
        | rdev::kVK_F16
        | rdev::kVK_F17
        | rdev::kVK_F18
        | rdev::kVK_F19
        | rdev::kVK_ANSI_KeypadClear
        | rdev::kVK_ForwardDelete
        | rdev::kVK_Home
        | rdev::kVK_End
        | rdev::kVK_PageDown
        | rdev::kVK_PageUp
        | 129
        | 130
        | 131
        | 144
        | 145 => CGEventFlags::CGEventFlagSecondaryFn,
        rdev::kVK_UpArrow | rdev::kVK_DownArrow | rdev::kVK_LeftArrow | rdev::kVK_RightArrow => {
            CGEventFlags::CGEventFlagSecondaryFn | CGEventFlags::CGEventFlagNumericPad
        }
        rdev::kVK_Help => CGEventFlags::CGEventFlagSecondaryFn | CGEventFlags::CGEventFlagHelp,
        _ => return,
    };

    event.set_flags(event.get_flags() & !flags_to_clear);
}

/// Construct a physical keyboard event without posting it.
///
/// For a known family, configure the caller-owned source before construction;
/// the input owner supplies one source per family, so this source-local change
/// cannot overwrite another family's source. Unknown preserves CoreGraphics'
/// baseline source. The key-up flag cleanup matches the pinned rdev macOS
/// behavior; key-down flags are untouched.
pub(crate) fn new_physical_key_event(
    source: CGEventSource,
    code: u16,
    down: bool,
    family: KeyboardFamily,
) -> Result<CGEvent, ()> {
    if let Some(keyboard_type) = macos_keyboard_type(family) {
        set_source_keyboard_type(&source, keyboard_type);
    }

    let event = CGEvent::new_keyboard_event(source, code, down)?;

    if !down {
        apply_key_up_flag_workaround(&event, code);
    }

    event.set_integer_value_field(
        EventField::EVENT_SOURCE_USER_DATA,
        enigo::ENIGO_INPUT_EXTRA_VALUE,
    );
    Ok(event)
}

#[cfg(test)]
mod tests {
    use super::*;
    use core_graphics::{
        event::CGEventType,
        event_source::{CGEventSource, CGEventSourceStateID},
    };

    const UNICODE_BUFFER_LENGTH: usize = 32;

    #[allow(non_snake_case)]
    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGEventKeyboardGetUnicodeString(
            event: core_graphics::sys::CGEventRef,
            max_string_length: libc::c_ulong,
            actual_string_length: *mut libc::c_ulong,
            unicode_string: *mut u16,
        );
    }

    fn unicode_payload(event: &CGEvent) -> String {
        let mut buffer = [0_u16; UNICODE_BUFFER_LENGTH];
        let mut actual_string_length = 0;
        // SAFETY: `event.as_ptr()` refers to the live event for this call;
        // `buffer` has the advertised bounded capacity and the output count
        // points to writable storage of the exact CoreGraphics type.
        unsafe {
            CGEventKeyboardGetUnicodeString(
                event.as_ptr(),
                buffer.len() as libc::c_ulong,
                &mut actual_string_length,
                buffer.as_mut_ptr(),
            );
        }
        let actual_string_length = usize::try_from(actual_string_length)
            .expect("CoreGraphics Unicode length should fit in usize");
        assert!(actual_string_length <= buffer.len());
        String::from_utf16(&buffer[..actual_string_length])
            .expect("CoreGraphics should return valid UTF-16")
    }

    fn native_reference_event(source: CGEventSource, code: u16, family: KeyboardFamily) -> CGEvent {
        let keyboard_type = macos_keyboard_type(family)
            .expect("native reference is only used for a known keyboard family");
        set_source_keyboard_type(&source, keyboard_type);
        CGEvent::new_keyboard_event(source, code, true)
            .expect("CoreGraphics keyboard event should be constructible")
    }

    fn event_with_event_only_keyboard_type(code: u16, family: KeyboardFamily) -> CGEvent {
        let source_keyboard_type = macos_keyboard_type(KeyboardFamily::Ansi)
            .expect("event-only baseline requires the ANSI keyboard type");
        let event_keyboard_type = macos_keyboard_type(family)
            .expect("event-only regression is only used for a known keyboard family");
        let source = new_combined_source();
        set_source_keyboard_type(&source, source_keyboard_type);
        let event = CGEvent::new_keyboard_event(source, code, true)
            .expect("CoreGraphics keyboard event should be constructible");
        event.set_integer_value_field(
            EventField::KEYBOARD_EVENT_KEYBOARD_TYPE,
            i64::from(event_keyboard_type),
        );
        event
    }

    #[test]
    fn carbon_family_values_are_distinct_from_cg_keyboard_types() {
        assert_eq!(
            family_for_layout_type(K_KEYBOARD_ANSI),
            KeyboardFamily::Ansi
        );
        assert_eq!(family_for_layout_type(K_KEYBOARD_ISO), KeyboardFamily::Iso);
        assert_eq!(family_for_layout_type(K_KEYBOARD_JIS), KeyboardFamily::Jis);
        assert_eq!(family_for_layout_type(42), KeyboardFamily::Unknown);
    }

    #[test]
    fn combined_session_source_and_privacy_marker_are_preserved() {
        let source = CGEventSource::new(CGEventSourceStateID::CombinedSessionState).unwrap();
        let event = new_physical_key_event(source, 94, true, KeyboardFamily::Jis).unwrap();
        assert_eq!(
            event.get_integer_value_field(EventField::EVENT_SOURCE_STATE_ID),
            0
        );
        assert_eq!(
            event.get_integer_value_field(EventField::EVENT_SOURCE_USER_DATA),
            enigo::ENIGO_INPUT_EXTRA_VALUE
        );
    }

    fn new_source() -> CGEventSource {
        CGEventSource::new(CGEventSourceStateID::HIDSystemState)
            .expect("CoreGraphics HID event source should be constructible")
    }

    fn new_combined_source() -> CGEventSource {
        CGEventSource::new(CGEventSourceStateID::CombinedSessionState)
            .expect("CoreGraphics combined-session event source should be constructible")
    }

    #[test]
    fn maps_carbon_physical_layout_types() {
        assert_eq!(
            family_for_layout_type(K_KEYBOARD_ANSI),
            KeyboardFamily::Ansi
        );
        assert_eq!(family_for_layout_type(K_KEYBOARD_ISO), KeyboardFamily::Iso);
        assert_eq!(family_for_layout_type(K_KEYBOARD_JIS), KeyboardFamily::Jis);
        assert_eq!(family_for_layout_type(0), KeyboardFamily::Unknown);
    }

    #[test]
    fn creates_tagged_physical_events_for_each_known_family() {
        let code = 0x18;
        for (family, keyboard_type) in [
            (KeyboardFamily::Ansi, 40),
            (KeyboardFamily::Iso, 41),
            (KeyboardFamily::Jis, 42),
        ] {
            for down in [true, false] {
                let event = new_physical_key_event(new_source(), code, down, family)
                    .expect("CoreGraphics keyboard event should be constructible");
                let expected_event_type = if down {
                    CGEventType::KeyDown
                } else {
                    CGEventType::KeyUp
                };
                assert_eq!(event.get_type() as u32, expected_event_type as u32);
                assert_eq!(
                    event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE),
                    i64::from(code)
                );
                assert_eq!(
                    event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYBOARD_TYPE),
                    i64::from(keyboard_type)
                );
                assert_eq!(
                    event.get_integer_value_field(EventField::EVENT_SOURCE_USER_DATA),
                    enigo::ENIGO_INPUT_EXTRA_VALUE
                );
            }
        }
    }

    #[test]
    fn source_keyboard_type_controls_native_unicode_payload() {
        for (family, code) in [
            (KeyboardFamily::Ansi, 24),
            (KeyboardFamily::Iso, 24),
            (KeyboardFamily::Jis, 24),
            (KeyboardFamily::Ansi, 94),
            (KeyboardFamily::Iso, 94),
            (KeyboardFamily::Jis, 94),
        ] {
            let event = new_physical_key_event(new_combined_source(), code, true, family)
                .expect("CoreGraphics keyboard event should be constructible");
            let reference = native_reference_event(new_combined_source(), code, family);

            assert_eq!(unicode_payload(&event), unicode_payload(&reference));
            assert_eq!(
                event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYBOARD_TYPE),
                i64::from(
                    macos_keyboard_type(family)
                        .expect("native payload test uses a known keyboard family"),
                )
            );
        }
    }

    #[test]
    fn event_only_keyboard_type_preserves_ansi_source_payload() {
        let jis_keyboard_type = macos_keyboard_type(KeyboardFamily::Jis)
            .expect("event-only regression requires the JIS keyboard type");
        for code in [24, 94] {
            let event = event_with_event_only_keyboard_type(code, KeyboardFamily::Jis);
            let reference =
                native_reference_event(new_combined_source(), code, KeyboardFamily::Ansi);

            assert_eq!(
                event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYBOARD_TYPE),
                i64::from(jis_keyboard_type)
            );
            assert_eq!(unicode_payload(&event), unicode_payload(&reference));
        }
    }

    #[test]
    fn independent_family_sources_retain_interleaved_payloads() {
        let jis_source = new_combined_source();
        let ansi_source = new_combined_source();
        let cases = [
            (KeyboardFamily::Jis, 94),
            (KeyboardFamily::Ansi, 24),
            (KeyboardFamily::Jis, 24),
            (KeyboardFamily::Ansi, 24),
            (KeyboardFamily::Jis, 94),
        ];

        let expected_payloads: Vec<String> = cases
            .iter()
            .map(|&(family, code)| {
                let reference = native_reference_event(new_combined_source(), code, family);
                unicode_payload(&reference)
            })
            .collect();

        let mut events = Vec::with_capacity(cases.len());
        for &(family, code) in &cases {
            let source = match family {
                KeyboardFamily::Ansi => &ansi_source,
                KeyboardFamily::Jis => &jis_source,
                _ => unreachable!("interleave cases only use ANSI and JIS sources"),
            };
            let event = new_physical_key_event((*source).clone(), code, true, family)
                .expect("CoreGraphics keyboard event should be constructible");
            events.push((event, family, code));
        }

        for ((event, family, code), expected_payload) in events.into_iter().zip(expected_payloads) {
            assert_eq!(
                event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE),
                i64::from(code)
            );
            assert_eq!(
                event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYBOARD_TYPE),
                i64::from(
                    macos_keyboard_type(family)
                        .expect("interleave cases use known keyboard families"),
                )
            );
            assert_eq!(unicode_payload(&event), expected_payload);
        }
    }

    #[test]
    fn unknown_family_preserves_core_graphics_keyboard_type_baseline() {
        let code = 0x18;
        let baseline = CGEvent::new_keyboard_event(new_source(), code, true)
            .expect("CoreGraphics keyboard event should be constructible")
            .get_integer_value_field(EventField::KEYBOARD_EVENT_KEYBOARD_TYPE);
        let event = new_physical_key_event(new_source(), code, true, KeyboardFamily::Unknown)
            .expect("CoreGraphics keyboard event should be constructible");

        assert_eq!(
            event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYBOARD_TYPE),
            baseline
        );
    }

    #[test]
    #[allow(non_upper_case_globals)]
    fn key_up_flag_workaround_clears_rdev_fn_bits() {
        let cases = [
            (rdev::kVK_F11, CGEventFlags::CGEventFlagSecondaryFn),
            (
                rdev::kVK_LeftArrow,
                CGEventFlags::CGEventFlagSecondaryFn | CGEventFlags::CGEventFlagNumericPad,
            ),
            (
                rdev::kVK_Help,
                CGEventFlags::CGEventFlagSecondaryFn | CGEventFlags::CGEventFlagHelp,
            ),
        ];
        let preserved = CGEventFlags::CGEventFlagCommand;

        for (code, workaround_flags) in cases {
            let event = CGEvent::new_keyboard_event(new_source(), code, false)
                .expect("CoreGraphics keyboard event should be constructible");
            event.set_flags(workaround_flags | preserved);
            apply_key_up_flag_workaround(&event, code);
            assert_eq!(event.get_flags(), preserved);
        }
    }
}
