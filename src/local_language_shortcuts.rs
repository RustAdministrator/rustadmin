pub(crate) const OPTION_LOCAL_LANGUAGE_SHORTCUTS: &str = "local-language-shortcuts";

const LOCAL_LANGUAGE_SHORTCUTS_AUTO: &str = "auto";
const LOCAL_LANGUAGE_SHORTCUTS_ENABLED: &str = "enabled";
const LOCAL_LANGUAGE_SHORTCUTS_DISABLED: &str = "disabled";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum LocalLanguageShortcutPreference {
    Auto,
    Enabled,
    Disabled,
}

impl LocalLanguageShortcutPreference {
    pub(crate) fn from_option(value: &str) -> Self {
        if value.eq_ignore_ascii_case(LOCAL_LANGUAGE_SHORTCUTS_ENABLED) {
            Self::Enabled
        } else if value.eq_ignore_ascii_case(LOCAL_LANGUAGE_SHORTCUTS_DISABLED) {
            Self::Disabled
        } else if value.eq_ignore_ascii_case(LOCAL_LANGUAGE_SHORTCUTS_AUTO) {
            Self::Auto
        } else {
            Self::Auto
        }
    }
}

pub(crate) fn resolve(
    peer: LocalLanguageShortcutPreference,
    global: LocalLanguageShortcutPreference,
    is_map: bool,
    is_windows: bool,
) -> bool {
    if !is_windows {
        return false;
    }
    let preference = match peer {
        LocalLanguageShortcutPreference::Auto => global,
        explicit => explicit,
    };
    match preference {
        LocalLanguageShortcutPreference::Auto => is_map,
        LocalLanguageShortcutPreference::Enabled => true,
        LocalLanguageShortcutPreference::Disabled => false,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum LanguageSwitch {
    Language,
    Layout,
    AllForward,
    AllBackward,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct HotkeySettings {
    pub(crate) alt_shift: Option<LanguageSwitch>,
    pub(crate) ctrl_shift: Option<LanguageSwitch>,
}

impl Default for HotkeySettings {
    fn default() -> Self {
        Self {
            alt_shift: None,
            ctrl_shift: None,
        }
    }
}

const MOD_ALT: u8 = 1 << 0;
const MOD_ALT_GR: u8 = 1 << 1;
const MOD_CONTROL_LEFT: u8 = 1 << 2;
const MOD_CONTROL_RIGHT: u8 = 1 << 3;
const MOD_SHIFT_LEFT: u8 = 1 << 4;
const MOD_SHIFT_RIGHT: u8 = 1 << 5;
const MOD_META_LEFT: u8 = 1 << 6;
const MOD_META_RIGHT: u8 = 1 << 7;
const MOD_CONTROL: u8 = MOD_CONTROL_LEFT | MOD_CONTROL_RIGHT;
const MOD_SHIFT: u8 = MOD_SHIFT_LEFT | MOD_SHIFT_RIGHT;
const MOD_META: u8 = MOD_META_LEFT | MOD_META_RIGHT;

const MAX_OTHER_KEYS: usize = 16;

#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct LocalLanguageShortcutState {
    modifiers: u8,
    other_keys: [Option<rdev::Key>; MAX_OTHER_KEYS],
    // Once the bounded ledger overflows, release events cannot prove which
    // untracked key was released. Keep the recognizer fail-closed until an
    // explicit reset clears this latch.
    other_key_overflow: bool,
    chord_dirty: bool,
    chord_decided: bool,
}

impl LocalLanguageShortcutState {
    pub(crate) fn reset(&mut self) {
        *self = Self::default();
    }

    pub(crate) fn process(
        &mut self,
        key: rdev::Key,
        down: bool,
        settings: HotkeySettings,
    ) -> Option<LanguageSwitch> {
        if let Some(bit) = modifier_bit(key) {
            return self.process_modifier(key, bit, down, settings);
        }

        if key == rdev::Key::Space {
            return self.process_space(down);
        }

        if down {
            self.track_other_key_down(key);
            if self.modifiers != 0 {
                self.chord_dirty = true;
            }
        } else {
            self.track_other_key_up(key);
        }
        self.reset_if_idle();
        None
    }

    fn process_modifier(
        &mut self,
        key: rdev::Key,
        bit: u8,
        down: bool,
        settings: HotkeySettings,
    ) -> Option<LanguageSwitch> {
        if down {
            if self.modifiers & bit != 0 {
                return None;
            }
            self.modifiers |= bit;
            if !valid_modifier_prefix(self.modifiers) {
                self.chord_dirty = true;
            }
            // Re-pressing the second member starts a fresh clean chord while
            // the first modifier remains held. A dirty application chord must
            // still be fully released before language switching is admitted.
            if self.chord_decided
                && !self.chord_dirty
                && !self.other_keys_down()
                && self.release_is_shortcut_member(key)
            {
                self.chord_decided = false;
            }
            return None;
        }

        if self.modifiers & bit == 0 {
            return None;
        }

        let action = if !self.chord_decided {
            self.release_action(key, settings)
        } else {
            None
        };
        if self.release_is_shortcut_member(key) {
            self.chord_decided = true;
        }
        self.modifiers &= !bit;
        self.reset_if_idle();
        action
    }

    fn process_space(&mut self, down: bool) -> Option<LanguageSwitch> {
        if !down {
            self.track_other_key_up(rdev::Key::Space);
            self.reset_if_idle();
            return None;
        }

        if self.is_other_key_down(rdev::Key::Space) {
            return None;
        }

        // Win+Space is a direct local cycle. It never opens the operating-system
        // input-language chooser and never relies on synthetic key delivery.
        let action = if self.can_switch_with_win_space() {
            if self.modifiers & MOD_SHIFT != 0 {
                Some(LanguageSwitch::AllBackward)
            } else {
                Some(LanguageSwitch::AllForward)
            }
        } else {
            None
        };
        self.track_other_key_down(rdev::Key::Space);
        if self.modifiers != 0 && action.is_none() {
            self.chord_dirty = true;
        }
        action
    }

    fn release_action(&self, key: rdev::Key, settings: HotkeySettings) -> Option<LanguageSwitch> {
        if self.chord_dirty || self.other_keys_down() {
            return None;
        }

        if is_alt_shift_release(self.modifiers, key) {
            return settings.alt_shift;
        }
        if is_control_shift_release(self.modifiers, key) {
            return settings.ctrl_shift;
        }
        None
    }

    fn release_is_shortcut_member(&self, key: rdev::Key) -> bool {
        is_alt_shift_release(self.modifiers, key) || is_control_shift_release(self.modifiers, key)
    }

    fn can_switch_with_win_space(&self) -> bool {
        if self.chord_dirty || self.other_keys_down() {
            return false;
        }
        if self.modifiers & MOD_META == 0
            || self.modifiers & (MOD_ALT | MOD_ALT_GR | MOD_CONTROL) != 0
        {
            return false;
        }
        let meta_count = (self.modifiers & MOD_META).count_ones();
        let shift_count = (self.modifiers & MOD_SHIFT).count_ones();
        meta_count == 1 && shift_count <= 1
    }

    fn track_other_key_down(&mut self, key: rdev::Key) {
        if self.is_other_key_down(key) {
            return;
        }
        for slot in &mut self.other_keys {
            if slot.is_none() {
                *slot = Some(key);
                return;
            }
        }
        self.other_key_overflow = true;
    }

    fn track_other_key_up(&mut self, key: rdev::Key) {
        for slot in &mut self.other_keys {
            if *slot == Some(key) {
                *slot = None;
                return;
            }
        }
        // An untracked release cannot establish that the released key was one
        // of the keys omitted after the bounded ledger filled. Leave the
        // fail-closed latch set until an explicit state reset.
    }

    fn is_other_key_down(&self, key: rdev::Key) -> bool {
        self.other_keys.iter().any(|slot| *slot == Some(key))
    }

    fn other_keys_down(&self) -> bool {
        self.other_key_overflow || self.other_keys.iter().any(Option::is_some)
    }

    fn reset_if_idle(&mut self) {
        if self.modifiers == 0 && !self.other_keys_down() {
            self.chord_dirty = false;
            self.chord_decided = false;
        }
    }
}

fn modifier_bit(key: rdev::Key) -> Option<u8> {
    match key {
        rdev::Key::Alt => Some(MOD_ALT),
        rdev::Key::AltGr => Some(MOD_ALT_GR),
        rdev::Key::ControlLeft => Some(MOD_CONTROL_LEFT),
        rdev::Key::ControlRight => Some(MOD_CONTROL_RIGHT),
        rdev::Key::ShiftLeft => Some(MOD_SHIFT_LEFT),
        rdev::Key::ShiftRight => Some(MOD_SHIFT_RIGHT),
        rdev::Key::MetaLeft => Some(MOD_META_LEFT),
        rdev::Key::MetaRight => Some(MOD_META_RIGHT),
        _ => None,
    }
}

fn valid_modifier_prefix(modifiers: u8) -> bool {
    let control_count = (modifiers & MOD_CONTROL).count_ones();
    let shift_count = (modifiers & MOD_SHIFT).count_ones();
    let meta_count = (modifiers & MOD_META).count_ones();
    if control_count > 1 || shift_count > 1 || meta_count > 1 {
        return false;
    }

    if modifiers & MOD_ALT_GR != 0 {
        return modifiers == MOD_ALT_GR;
    }

    let non_shift = modifiers & (MOD_ALT | MOD_CONTROL | MOD_META);
    non_shift.count_ones() <= 1
}

fn is_alt_shift_release(modifiers: u8, key: rdev::Key) -> bool {
    matches!(
        key,
        rdev::Key::Alt | rdev::Key::ShiftLeft | rdev::Key::ShiftRight
    ) && modifiers & MOD_ALT != 0
        && modifiers & MOD_ALT_GR == 0
        && modifiers & (MOD_CONTROL | MOD_META) == 0
        && (modifiers & MOD_SHIFT).count_ones() == 1
}

fn is_control_shift_release(modifiers: u8, key: rdev::Key) -> bool {
    matches!(
        key,
        rdev::Key::ControlLeft
            | rdev::Key::ControlRight
            | rdev::Key::ShiftLeft
            | rdev::Key::ShiftRight
    ) && modifiers & MOD_CONTROL != 0
        && modifiers & (MOD_ALT | MOD_ALT_GR | MOD_META) == 0
        && (modifiers & MOD_CONTROL).count_ones() == 1
        && (modifiers & MOD_SHIFT).count_ones() == 1
}

pub(crate) const MAX_LOCAL_LANGUAGE_LAYOUTS: usize = 64;

pub(crate) fn select_layout_index(
    action: LanguageSwitch,
    current_index: usize,
    layout_handles: &[usize; MAX_LOCAL_LANGUAGE_LAYOUTS],
    language_ids: &[u16; MAX_LOCAL_LANGUAGE_LAYOUTS],
    count: usize,
) -> Option<usize> {
    if count == 0 || count > MAX_LOCAL_LANGUAGE_LAYOUTS || current_index >= count {
        return None;
    }

    let current_handle = layout_handles[current_index];
    let current_language = language_ids[current_index];
    let backward = matches!(action, LanguageSwitch::AllBackward);
    for offset in 1..count {
        let candidate = if backward {
            (current_index + count - offset) % count
        } else {
            (current_index + offset) % count
        };
        let matches_group = match action {
            LanguageSwitch::Language => language_ids[candidate] != current_language,
            LanguageSwitch::Layout => language_ids[candidate] == current_language,
            LanguageSwitch::AllForward | LanguageSwitch::AllBackward => true,
        };
        if matches_group && layout_handles[candidate] != current_handle {
            return Some(candidate);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(
        state: &mut LocalLanguageShortcutState,
        key: rdev::Key,
        down: bool,
        settings: HotkeySettings,
    ) -> Option<LanguageSwitch> {
        state.process(key, down, settings)
    }

    fn alt_shift_settings(action: LanguageSwitch) -> HotkeySettings {
        HotkeySettings {
            alt_shift: Some(action),
            ctrl_shift: None,
        }
    }

    fn ctrl_shift_settings(action: LanguageSwitch) -> HotkeySettings {
        HotkeySettings {
            alt_shift: None,
            ctrl_shift: Some(action),
        }
    }

    #[test]
    fn option_parser_and_policy_are_fail_closed() {
        assert_eq!(
            LocalLanguageShortcutPreference::from_option("auto"),
            LocalLanguageShortcutPreference::Auto
        );
        assert_eq!(
            LocalLanguageShortcutPreference::from_option("ENABLED"),
            LocalLanguageShortcutPreference::Enabled
        );
        assert_eq!(
            LocalLanguageShortcutPreference::from_option("disabled"),
            LocalLanguageShortcutPreference::Disabled
        );
        assert_eq!(
            LocalLanguageShortcutPreference::from_option("future-value"),
            LocalLanguageShortcutPreference::Auto
        );

        let preferences = [
            LocalLanguageShortcutPreference::Auto,
            LocalLanguageShortcutPreference::Enabled,
            LocalLanguageShortcutPreference::Disabled,
        ];
        for peer in preferences {
            for global in preferences {
                assert!(!resolve(peer, global, true, false));
            }
        }
        assert!(resolve(
            LocalLanguageShortcutPreference::Auto,
            LocalLanguageShortcutPreference::Auto,
            true,
            true
        ));
        assert!(!resolve(
            LocalLanguageShortcutPreference::Auto,
            LocalLanguageShortcutPreference::Auto,
            false,
            true
        ));
        assert!(resolve(
            LocalLanguageShortcutPreference::Auto,
            LocalLanguageShortcutPreference::Enabled,
            false,
            true
        ));
        assert!(!resolve(
            LocalLanguageShortcutPreference::Auto,
            LocalLanguageShortcutPreference::Disabled,
            true,
            true
        ));
        assert!(resolve(
            LocalLanguageShortcutPreference::Enabled,
            LocalLanguageShortcutPreference::Disabled,
            false,
            true
        ));
        assert!(!resolve(
            LocalLanguageShortcutPreference::Disabled,
            LocalLanguageShortcutPreference::Enabled,
            true,
            true
        ));
    }

    #[test]
    fn alt_shift_accepts_each_side_and_releases_once() {
        for shift in [rdev::Key::ShiftLeft, rdev::Key::ShiftRight] {
            for release_first in [rdev::Key::Alt, shift] {
                let release_second = if release_first == rdev::Key::Alt {
                    shift
                } else {
                    rdev::Key::Alt
                };
                let mut state = LocalLanguageShortcutState::default();
                let settings = alt_shift_settings(LanguageSwitch::Language);
                assert_eq!(process(&mut state, rdev::Key::Alt, true, settings), None);
                assert_eq!(process(&mut state, shift, true, settings), None);
                assert_eq!(
                    process(&mut state, release_first, false, settings),
                    Some(LanguageSwitch::Language)
                );
                assert_eq!(process(&mut state, release_second, false, settings), None);
                assert_eq!(process(&mut state, release_second, false, settings), None);
            }
        }
    }

    #[test]
    fn control_shift_accepts_each_side_and_releases_once() {
        for control in [rdev::Key::ControlLeft, rdev::Key::ControlRight] {
            for shift in [rdev::Key::ShiftLeft, rdev::Key::ShiftRight] {
                let mut state = LocalLanguageShortcutState::default();
                let settings = ctrl_shift_settings(LanguageSwitch::Layout);
                assert_eq!(process(&mut state, control, true, settings), None);
                assert_eq!(process(&mut state, shift, true, settings), None);
                assert_eq!(
                    process(&mut state, shift, false, settings),
                    Some(LanguageSwitch::Layout)
                );
                assert_eq!(process(&mut state, control, false, settings), None);
            }
        }
    }

    #[test]
    fn holding_first_modifier_allows_distinct_clean_chords() {
        for (first, second, settings, expected) in [
            (
                rdev::Key::Alt,
                rdev::Key::ShiftLeft,
                alt_shift_settings(LanguageSwitch::Language),
                LanguageSwitch::Language,
            ),
            (
                rdev::Key::ShiftRight,
                rdev::Key::Alt,
                alt_shift_settings(LanguageSwitch::Language),
                LanguageSwitch::Language,
            ),
            (
                rdev::Key::ControlRight,
                rdev::Key::ShiftRight,
                ctrl_shift_settings(LanguageSwitch::Layout),
                LanguageSwitch::Layout,
            ),
            (
                rdev::Key::ShiftLeft,
                rdev::Key::ControlLeft,
                ctrl_shift_settings(LanguageSwitch::Layout),
                LanguageSwitch::Layout,
            ),
        ] {
            let mut state = LocalLanguageShortcutState::default();
            assert_eq!(state.process(first, true, settings), None);
            for _ in 0..3 {
                assert_eq!(state.process(second, true, settings), None);
                assert_eq!(state.process(second, true, settings), None);
                assert_eq!(state.process(second, false, settings), Some(expected));
                assert_eq!(state.process(second, false, settings), None);
            }
            assert_eq!(state.process(first, false, settings), None);
        }
    }

    #[test]
    fn dirty_chords_do_not_switch_and_repeats_do_not_retrigger() {
        let settings = alt_shift_settings(LanguageSwitch::Language);
        let mut state = LocalLanguageShortcutState::default();
        assert_eq!(process(&mut state, rdev::Key::Alt, true, settings), None);
        assert_eq!(
            process(&mut state, rdev::Key::ShiftLeft, true, settings),
            None
        );
        assert_eq!(process(&mut state, rdev::Key::KeyA, true, settings), None);
        assert_eq!(process(&mut state, rdev::Key::KeyA, true, settings), None);
        assert_eq!(process(&mut state, rdev::Key::KeyA, false, settings), None);
        assert_eq!(
            process(&mut state, rdev::Key::ShiftLeft, false, settings),
            None
        );
        assert_eq!(process(&mut state, rdev::Key::Alt, false, settings), None);

        let mut state = LocalLanguageShortcutState::default();
        assert_eq!(process(&mut state, rdev::Key::Alt, true, settings), None);
        assert_eq!(process(&mut state, rdev::Key::Alt, true, settings), None);
        assert_eq!(
            process(&mut state, rdev::Key::ShiftLeft, true, settings),
            None
        );
        assert_eq!(
            process(&mut state, rdev::Key::ShiftLeft, false, settings),
            Some(LanguageSwitch::Language)
        );
        assert_eq!(
            process(&mut state, rdev::Key::ShiftLeft, false, settings),
            None
        );
        assert_eq!(process(&mut state, rdev::Key::Alt, false, settings), None);

        for _ in 0..2 {
            assert_eq!(process(&mut state, rdev::Key::Alt, true, settings), None);
            assert_eq!(
                process(&mut state, rdev::Key::ShiftLeft, true, settings),
                None
            );
            assert_eq!(
                process(&mut state, rdev::Key::ShiftLeft, false, settings),
                Some(LanguageSwitch::Language)
            );
            assert_eq!(process(&mut state, rdev::Key::Alt, false, settings), None);
        }
    }

    #[test]
    fn right_alt_and_extra_modifiers_are_rejected() {
        let settings = alt_shift_settings(LanguageSwitch::Language);
        for extra in [
            rdev::Key::AltGr,
            rdev::Key::ControlLeft,
            rdev::Key::MetaLeft,
        ] {
            let mut state = LocalLanguageShortcutState::default();
            assert_eq!(process(&mut state, rdev::Key::Alt, true, settings), None);
            assert_eq!(
                process(&mut state, rdev::Key::ShiftLeft, true, settings),
                None
            );
            assert_eq!(process(&mut state, extra, true, settings), None);
            assert_eq!(process(&mut state, extra, false, settings), None);
            assert_eq!(
                process(&mut state, rdev::Key::ShiftLeft, false, settings),
                None
            );
            assert_eq!(process(&mut state, rdev::Key::Alt, false, settings), None);
        }
    }

    #[test]
    fn win_space_cycles_directly_and_is_independent_of_registry_settings() {
        let disabled = HotkeySettings::default();
        let mut state = LocalLanguageShortcutState::default();
        assert_eq!(
            process(&mut state, rdev::Key::MetaLeft, true, disabled),
            None
        );
        assert_eq!(
            process(&mut state, rdev::Key::Space, true, disabled),
            Some(LanguageSwitch::AllForward)
        );
        assert_eq!(process(&mut state, rdev::Key::Space, true, disabled), None);
        assert_eq!(process(&mut state, rdev::Key::Space, false, disabled), None);
        assert_eq!(
            process(&mut state, rdev::Key::MetaLeft, false, disabled),
            None
        );

        assert_eq!(
            process(&mut state, rdev::Key::ShiftRight, true, disabled),
            None
        );
        assert_eq!(
            process(&mut state, rdev::Key::MetaRight, true, disabled),
            None
        );
        assert_eq!(
            process(&mut state, rdev::Key::Space, true, disabled),
            Some(LanguageSwitch::AllBackward)
        );
        assert_eq!(process(&mut state, rdev::Key::Space, false, disabled), None);
        assert_eq!(
            process(&mut state, rdev::Key::MetaRight, false, disabled),
            None
        );
        assert_eq!(
            process(&mut state, rdev::Key::ShiftRight, false, disabled),
            None
        );
    }

    #[test]
    fn win_space_can_repeat_after_each_space_release() {
        let mut state = LocalLanguageShortcutState::default();
        let settings = HotkeySettings::default();
        assert_eq!(
            process(&mut state, rdev::Key::MetaLeft, true, settings),
            None
        );
        for _ in 0..3 {
            assert_eq!(
                process(&mut state, rdev::Key::Space, true, settings),
                Some(LanguageSwitch::AllForward)
            );
            assert_eq!(process(&mut state, rdev::Key::Space, false, settings), None);
        }
        assert_eq!(
            process(&mut state, rdev::Key::MetaLeft, false, settings),
            None
        );
    }

    #[test]
    fn reset_clears_dirty_chord_and_disabled_alt_shift_stays_disabled() {
        let mut state = LocalLanguageShortcutState::default();
        let settings = alt_shift_settings(LanguageSwitch::Language);
        assert_eq!(process(&mut state, rdev::Key::Alt, true, settings), None);
        assert_eq!(
            process(&mut state, rdev::Key::ShiftLeft, true, settings),
            None
        );
        assert_eq!(process(&mut state, rdev::Key::KeyB, true, settings), None);
        state.reset();
        assert_eq!(process(&mut state, rdev::Key::Alt, true, settings), None);
        assert_eq!(
            process(&mut state, rdev::Key::ShiftLeft, true, settings),
            None
        );
        assert_eq!(
            process(&mut state, rdev::Key::Alt, false, settings),
            Some(LanguageSwitch::Language)
        );
        assert_eq!(
            process(&mut state, rdev::Key::ShiftLeft, false, settings),
            None
        );

        let mut state = LocalLanguageShortcutState::default();
        let disabled = HotkeySettings::default();
        assert_eq!(process(&mut state, rdev::Key::Alt, true, disabled), None);
        assert_eq!(
            process(&mut state, rdev::Key::ShiftLeft, true, disabled),
            None
        );
        assert_eq!(
            process(&mut state, rdev::Key::ShiftLeft, false, disabled),
            None
        );
        assert_eq!(process(&mut state, rdev::Key::Alt, false, disabled), None);
    }

    #[test]
    fn layout_selection_groups_languages_and_rejects_bad_bounds() {
        let mut handles = [0_usize; MAX_LOCAL_LANGUAGE_LAYOUTS];
        handles[..5].copy_from_slice(&[11, 12, 13, 14, 15]);
        let mut languages = [0_u16; MAX_LOCAL_LANGUAGE_LAYOUTS];
        languages[..5].copy_from_slice(&[0x0409, 0x0411, 0x0411, 0x0804, 0x0804]);
        assert_eq!(
            select_layout_index(LanguageSwitch::Language, 0, &handles, &languages, 5),
            Some(1)
        );
        assert_eq!(
            select_layout_index(LanguageSwitch::Layout, 1, &handles, &languages, 5),
            Some(2)
        );
        assert_eq!(
            select_layout_index(LanguageSwitch::Layout, 2, &handles, &languages, 5),
            Some(1)
        );
        assert_eq!(
            select_layout_index(LanguageSwitch::AllBackward, 0, &handles, &languages, 5),
            Some(4)
        );
        assert_eq!(
            select_layout_index(LanguageSwitch::Language, 3, &handles, &languages, 5),
            Some(0)
        );
        assert_eq!(
            select_layout_index(LanguageSwitch::Layout, 0, &handles, &languages, 1),
            None
        );
        assert_eq!(
            select_layout_index(
                LanguageSwitch::AllForward,
                0,
                &handles,
                &languages,
                MAX_LOCAL_LANGUAGE_LAYOUTS + 1
            ),
            None
        );
        assert_eq!(
            select_layout_index(LanguageSwitch::AllForward, 5, &handles, &languages, 5),
            None
        );
    }

    #[test]
    fn bounded_other_key_overflow_fails_closed_until_reset() {
        let settings = alt_shift_settings(LanguageSwitch::Language);
        let mut state = LocalLanguageShortcutState::default();
        for index in 0..(MAX_OTHER_KEYS + 2) {
            assert_eq!(
                process(&mut state, rdev::Key::Unknown(index as u32), true, settings),
                None
            );
        }
        for _ in 0..3 {
            assert_eq!(
                process(
                    &mut state,
                    rdev::Key::Unknown(MAX_OTHER_KEYS as u32),
                    true,
                    settings
                ),
                None
            );
        }
        for index in 0..(MAX_OTHER_KEYS + 2) {
            assert_eq!(
                process(
                    &mut state,
                    rdev::Key::Unknown(index as u32),
                    false,
                    settings
                ),
                None
            );
        }
        assert!(state.other_keys_down());
        state.reset();
        assert_eq!(process(&mut state, rdev::Key::Alt, true, settings), None);
        assert_eq!(
            process(&mut state, rdev::Key::ShiftLeft, true, settings),
            None
        );
        assert_eq!(
            process(&mut state, rdev::Key::Alt, false, settings),
            Some(LanguageSwitch::Language)
        );
    }
}
