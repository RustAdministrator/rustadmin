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

#[cfg(test)]
mod tests {
    use super::*;

    fn mapped(target: HidTarget, usage: u32) -> Option<u32> {
        keycode_from_usb_hid(target, usage, |_| panic!("unexpected fallback"))
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
