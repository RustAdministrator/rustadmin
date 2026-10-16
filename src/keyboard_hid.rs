use hbb_common::message_proto::KeyboardFamily;

pub(crate) const OPTION_KEYBOARD_FAMILY: &str = "physical-keyboard-family";

#[derive(Clone, Copy)]
pub(crate) enum HidTarget {
    Windows,
    Linux,
    MacOs,
}

// Columns: Windows set-1 scan, Linux Xorg keycode (evdev + 8), macOS virtual key.
// None is an explicit lack of a native mapping, not permission to reinterpret
// a JIS conversion key as Korean LANG1/LANG2 through rdev's historical names.
// Sources and compatibility boundaries are listed in KEYBOARD_INPUT_V2.md.
const SPECIAL_KEYCODES: &[(u32, [Option<u32>; 3])] = &[
    (0x67, [Some(0x59), Some(125), Some(0x51)]),
    (0x85, [Some(0x7e), Some(129), Some(0x5f)]),
    (0x86, [None, None, None]),
    (0x87, [Some(0x73), Some(97), Some(0x5e)]),
    (0x88, [Some(0x70), Some(101), None]),
    (0x89, [Some(0x7d), Some(132), Some(0x5d)]),
    (0x8a, [Some(0x79), Some(100), None]),
    (0x8b, [Some(0x7b), Some(102), None]),
    (0x8c, [Some(0x5c), Some(103), None]),
    (0x90, [Some(0xf2), Some(130), Some(0x68)]),
    (0x91, [Some(0xf1), Some(131), Some(0x66)]),
    (0x92, [Some(0x78), Some(98), None]),
    (0x93, [Some(0x77), Some(99), None]),
    (0x94, [Some(0x76), Some(93), None]),
];

pub(crate) fn keycode_from_usb_hid(
    target: HidTarget,
    usage: u32,
    fallback: impl FnOnce(u32) -> Option<u32>,
) -> Option<u32> {
    match SPECIAL_KEYCODES.iter().find(|row| row.0 == usage) {
        Some((_, codes)) => codes[target as usize],
        None => fallback(usage),
    }
}

#[inline]
pub(crate) fn is_macos_platform(platform: &str) -> bool {
    platform.eq_ignore_ascii_case("macos") || platform.eq_ignore_ascii_case("mac os")
}

/// The sole HID-to-native mapping used by V2 and legacy Map transport.
/// Family describes physical geometry, independently of language or IME.
pub(crate) fn keycode_for_peer(platform: &str, usage: u32, family: KeyboardFamily) -> Option<u32> {
    if platform.eq_ignore_ascii_case("windows") {
        keycode_from_usb_hid(HidTarget::Windows, usage, |usage| {
            rdev::usb_hid_code_to_win_scancode(usage).map(|code| code as u32)
        })
    } else if platform.eq_ignore_ascii_case("linux") {
        keycode_from_usb_hid(HidTarget::Linux, usage, |usage| {
            rdev::usb_hid_code_to_linux_code(usage).map(|code| code as u32)
        })
    } else if is_macos_platform(platform) {
        keycode_from_usb_hid(HidTarget::MacOs, usage, |usage| {
            let code = if family == KeyboardFamily::Iso {
                rdev::usb_hid_code_to_macos_iso_code(usage)
            } else {
                rdev::usb_hid_code_to_macos_code(usage)
            };
            code.map(|code| code as u32)
        })
    } else if platform.eq_ignore_ascii_case("android") {
        rdev::usb_hid_code_to_android_key_code(usage).map(|code| code as u32)
    } else {
        None
    }
}

/// Explicit missing native mappings must not fall back to rdev's historical
/// language-key aliases. Ordinary unknown usages can retain the raw-code path.
pub(crate) fn explicitly_unmapped(platform: &str, usage: u32) -> bool {
    let column = if platform.eq_ignore_ascii_case("windows") {
        0
    } else if platform.eq_ignore_ascii_case("linux") {
        1
    } else if is_macos_platform(platform) {
        2
    } else {
        return false;
    };
    SPECIAL_KEYCODES
        .iter()
        .any(|row| row.0 == usage && row.1[column].is_none())
}

/// Normalize native hardware positions without using characters or language.
/// Consult the same compatibility table in reverse before rdev's named keys,
/// whose historical PC conversion-key aliases do not match USB LANG usages.
pub(crate) fn usage_from_native(
    target: HidTarget,
    mut code: u32,
    family: KeyboardFamily,
) -> Option<u32> {
    if matches!(target, HidTarget::MacOs) && family == KeyboardFamily::Iso {
        code = match code {
            10 => 50,
            50 => 10,
            _ => code,
        };
    }
    if let Some((usage, _)) = SPECIAL_KEYCODES
        .iter()
        .find(|row| row.1[target as usize] == Some(code))
    {
        return Some(*usage);
    }
    let key = match target {
        HidTarget::Windows => rdev::win_key_from_scancode(code),
        HidTarget::Linux => rdev::linux_key_from_code(code),
        HidTarget::MacOs => rdev::macos_key_from_code(u16::try_from(code).ok()?.into()),
    };
    if matches!(key, rdev::Key::Unknown(_) | rdev::Key::RawKey(_)) {
        return None;
    }
    rdev::usb_hid_keycode_from_key(key).filter(|usage| valid_usage(*usage))
}

pub(crate) fn valid_usage(usage: u32) -> bool {
    (hbb_common::keyboard::MIN_USB_HID_KEYBOARD_USAGE
        ..=hbb_common::keyboard::MAX_USB_HID_KEYBOARD_USAGE)
        .contains(&usage)
}

pub(crate) fn detected_keyboard_family() -> KeyboardFamily {
    #[cfg(target_os = "macos")]
    {
        return crate::platform::macos_keyboard::detected_keyboard_family();
    }
    #[cfg(target_os = "windows")]
    {
        // GetKeyboardType(0) is a read-only Win32 query with no pointer inputs.
        // Type 7 identifies Japanese hardware; other types do not distinguish
        // ANSI from ISO reliably, so leave them to the saved override.
        return if unsafe { winapi::um::winuser::GetKeyboardType(0) } == 7 {
            KeyboardFamily::Jis
        } else {
            KeyboardFamily::Unknown
        };
    }
    #[allow(unreachable_code)]
    KeyboardFamily::Unknown
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mapped(target: HidTarget, usage: u32) -> Option<u32> {
        keycode_from_usb_hid(target, usage, |_| panic!("unexpected fallback"))
    }

    #[test]
    fn jis_punctuation_has_one_mapping_for_all_physical_transports() {
        for (usage, windows, macos) in [(0x2e, 0x0d, 24), (0x87, 0x73, 94), (0x89, 0x7d, 93)] {
            assert_eq!(
                keycode_for_peer("Windows", usage, KeyboardFamily::Jis),
                Some(windows)
            );
            for platform in ["macos", "macOS", "Mac OS", "MAC OS"] {
                assert_eq!(
                    keycode_for_peer(platform, usage, KeyboardFamily::Jis),
                    Some(macos)
                );
            }
        }
        for platform in ["macos", "macOS", "Mac OS", "MAC OS"] {
            assert_eq!(keycode_for_peer(platform, 0x8a, KeyboardFamily::Jis), None);
            assert_eq!(keycode_for_peer(platform, 0x8b, KeyboardFamily::Jis), None);
            assert!(explicitly_unmapped(platform, 0x8a));
            assert!(explicitly_unmapped(platform, 0x8b));
            assert!(!explicitly_unmapped(platform, 0xa0));
        }
        assert!(valid_usage(0x87));
        assert!(!valid_usage(0));
        assert!(!explicitly_unmapped("Windows", 0x8a));
        assert_eq!(
            keycode_for_peer("Solaris", 0x04, KeyboardFamily::Ansi),
            None
        );
        assert!(!explicitly_unmapped("Solaris", 0x8a));
    }

    #[test]
    fn native_positions_recover_hid_without_language_or_unknown_code_aliases() {
        for (scan, usage) in [
            (0x0d, 0x2e),
            (0x73, 0x87),
            (0x7d, 0x89),
            (0x70, 0x88),
            (0x79, 0x8a),
            (0x7b, 0x8b),
            (0xf2, 0x90),
        ] {
            assert_eq!(
                usage_from_native(HidTarget::Windows, scan, KeyboardFamily::Jis),
                Some(usage)
            );
        }
        for (code, usage) in [(24, 0x2e), (94, 0x87), (93, 0x89), (104, 0x90), (102, 0x91)] {
            assert_eq!(
                usage_from_native(HidTarget::MacOs, code, KeyboardFamily::Jis),
                Some(usage)
            );
        }
        assert_eq!(
            usage_from_native(HidTarget::MacOs, 10, KeyboardFamily::Iso),
            Some(0x35)
        );
        assert_eq!(
            usage_from_native(HidTarget::MacOs, 50, KeyboardFamily::Iso),
            Some(0x64)
        );
        assert_eq!(
            usage_from_native(HidTarget::MacOs, 0xffff, KeyboardFamily::Ansi),
            None
        );
        assert_eq!(
            usage_from_native(HidTarget::Windows, 0xffff, KeyboardFamily::Jis),
            None
        );
    }

    #[test]
    fn macos_rejects_codes_that_do_not_fit_the_native_keycode_alias() {
        for (code, expected_usage) in [(24, Some(0x2e)), (0x10018, None), (u32::MAX, None)] {
            assert_eq!(
                usage_from_native(HidTarget::MacOs, code, KeyboardFamily::Jis),
                expected_usage
            );
        }
    }

    #[test]
    fn windows_keeps_jis_conversion_separate_from_korean_language_keys() {
        for (usage, scan) in [
            (0x67, 0x59),
            (0x85, 0x7e),
            (0x87, 0x73),
            (0x88, 0x70),
            (0x89, 0x7d),
            (0x8a, 0x79),
            (0x8b, 0x7b),
            (0x8c, 0x5c),
            (0x90, 0xf2),
            (0x91, 0xf1),
            (0x92, 0x78),
            (0x93, 0x77),
            (0x94, 0x76),
        ] {
            assert_eq!(mapped(HidTarget::Windows, usage), Some(scan));
        }
    }

    #[test]
    fn linux_uses_evdev_mapping_with_exactly_one_xorg_offset() {
        for (usage, evdev) in [
            (0x67, 117),
            (0x85, 121),
            (0x87, 89),
            (0x88, 93),
            (0x89, 124),
            (0x8a, 92),
            (0x8b, 94),
            (0x8c, 95),
            (0x90, 122),
            (0x91, 123),
            (0x92, 90),
            (0x93, 91),
            (0x94, 85),
        ] {
            assert_eq!(mapped(HidTarget::Linux, usage), Some(evdev + 8));
        }
    }

    #[test]
    fn macos_uses_apple_kana_eisu_without_aliasing_henkan_muhenkan() {
        for (usage, code) in [
            (0x67, 0x51),
            (0x85, 0x5f),
            (0x87, 0x5e),
            (0x89, 0x5d),
            (0x90, 0x68),
            (0x91, 0x66),
        ] {
            assert_eq!(mapped(HidTarget::MacOs, usage), Some(code));
        }
        for usage in [0x88, 0x8a, 0x8b, 0x8c, 0x92, 0x93, 0x94] {
            assert_eq!(mapped(HidTarget::MacOs, usage), None);
        }
    }

    #[test]
    fn as400_equal_is_not_ordinary_keypad_equal() {
        for target in [HidTarget::Windows, HidTarget::Linux, HidTarget::MacOs] {
            assert_eq!(mapped(target, 0x86), None);
            assert!(mapped(target, 0x67).is_some());
        }
    }

    #[test]
    fn ordinary_keys_keep_the_existing_platform_and_iso_fallback() {
        for usage in [0x04, 0x28, 0x2a, 0x64, 0xe0, 0xe7] {
            assert_eq!(
                keycode_from_usb_hid(HidTarget::MacOs, usage, |received| {
                    assert_eq!(received, usage);
                    Some(1234)
                }),
                Some(1234)
            );
        }
        assert_eq!(
            keycode_from_usb_hid(HidTarget::Linux, 0xffff, |_| None),
            None
        );
    }
}
