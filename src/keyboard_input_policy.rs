pub(crate) const OPTION_MOBILE_PHYSICAL_KEY_INPUT: &str = "mobile-physical-key-input";
pub(crate) const OPTION_KEYBOARD_INPUT_MODE_V2: &str = "keyboard-input-mode-v2";
const KEYBOARD_INPUT_MODE_AUTO: &str = "auto";
const KEYBOARD_INPUT_MODE_TEXT: &str = "text";
const KEYBOARD_INPUT_MODE_PHYSICAL: &str = "physical";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum KeyboardInputPreference {
    Auto,
    Text,
    Physical,
}

impl KeyboardInputPreference {
    pub(crate) fn from_options(mode: &str, legacy_physical_key_input: &str) -> Self {
        match mode.to_ascii_lowercase().as_str() {
            KEYBOARD_INPUT_MODE_TEXT => Self::Text,
            KEYBOARD_INPUT_MODE_PHYSICAL => Self::Physical,
            KEYBOARD_INPUT_MODE_AUTO => Self::Auto,
            "" if legacy_physical_key_input.eq_ignore_ascii_case("N") => Self::Text,
            _ => Self::Auto,
        }
    }

    pub(crate) fn migration_value(mode: &str, legacy: &str) -> Option<&'static str> {
        if !mode.is_empty() {
            return None;
        }
        if legacy.eq_ignore_ascii_case("N") {
            Some(KEYBOARD_INPUT_MODE_TEXT)
        } else if legacy.eq_ignore_ascii_case("Y") {
            Some(KEYBOARD_INPUT_MODE_AUTO)
        } else {
            None
        }
    }

    pub(crate) fn physical_keys_enabled(self, is_mobile: bool) -> bool {
        is_mobile && self != Self::Text
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_mode_wins_over_legacy_flags() {
        for (mode, expected) in [
            ("auto", KeyboardInputPreference::Auto),
            ("text", KeyboardInputPreference::Text),
            ("physical", KeyboardInputPreference::Physical),
            ("PHYSICAL", KeyboardInputPreference::Physical),
            ("future-mode", KeyboardInputPreference::Auto),
        ] {
            for legacy in ["", "Y", "N", "n", "invalid"] {
                let preference = KeyboardInputPreference::from_options(mode, legacy);
                assert_eq!(preference, expected);
                assert_eq!(
                    preference.physical_keys_enabled(true),
                    expected != KeyboardInputPreference::Text
                );
                assert!(!preference.physical_keys_enabled(false));
            }
        }
    }

    #[test]
    fn absent_mode_retains_legacy_opt_out_and_default() {
        for (legacy, expected) in [
            ("", KeyboardInputPreference::Auto),
            ("Y", KeyboardInputPreference::Auto),
            ("N", KeyboardInputPreference::Text),
            ("n", KeyboardInputPreference::Text),
            ("invalid", KeyboardInputPreference::Auto),
        ] {
            assert_eq!(KeyboardInputPreference::from_options("", legacy), expected);
        }
    }

    #[test]
    fn migration_requires_an_absent_mode_and_a_recognized_legacy_flag() {
        for mode in ["auto", "text", "physical", "PHYSICAL", "future-mode"] {
            for legacy in ["", "Y", "N", "n"] {
                assert_eq!(KeyboardInputPreference::migration_value(mode, legacy), None);
            }
        }
        for legacy in ["N", "n"] {
            assert_eq!(
                KeyboardInputPreference::migration_value("", legacy),
                Some("text")
            );
        }
        for legacy in ["Y", "y"] {
            assert_eq!(
                KeyboardInputPreference::migration_value("", legacy),
                Some("auto")
            );
        }
        assert_eq!(KeyboardInputPreference::migration_value("", ""), None);
        assert_eq!(
            KeyboardInputPreference::migration_value("", "invalid"),
            None
        );
    }

    #[test]
    fn migration_preserves_resolution_and_is_idempotent() {
        for legacy in ["N", "n", "Y", "y"] {
            let migrated = KeyboardInputPreference::migration_value("", legacy).unwrap();
            assert_eq!(
                KeyboardInputPreference::from_options("", legacy),
                KeyboardInputPreference::from_options(migrated, legacy)
            );
            assert_eq!(
                KeyboardInputPreference::migration_value(migrated, legacy),
                None
            );
        }
    }
}
