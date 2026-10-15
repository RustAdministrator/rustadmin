use crate::local_language_shortcuts::{
    select_layout_index, HotkeySettings, LanguageSwitch, MAX_LOCAL_LANGUAGE_LAYOUTS,
};
use std::{mem, ptr};
use winapi::{
    ctypes::c_int,
    shared::{minwindef::*, windef::HWND},
    um::{
        processthreadsapi::GetCurrentProcessId,
        winuser::{
            GetForegroundWindow, GetGUIThreadInfo, GetKeyboardLayout, GetKeyboardLayoutList,
            GetWindowThreadProcessId, PostMessageW, GUITHREADINFO, WM_INPUTLANGCHANGEREQUEST,
        },
    },
};
use winreg::{enums::*, RegKey};

const KEYBOARD_LAYOUT_TOGGLE: &str = "Keyboard Layout\\Toggle";
const LANGUAGE_HOTKEY_VALUE: &str = "Language Hotkey";
const LAYOUT_HOTKEY_VALUE: &str = "Layout Hotkey";
const FALLBACK_HOTKEY_VALUE: &str = "Hotkey";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RegistryHotkeyValue {
    Missing,
    Invalid,
    Code(u32),
}

pub(crate) fn load_hotkey_settings() -> HotkeySettings {
    let current_user = RegKey::predef(HKEY_CURRENT_USER);
    let Ok(toggle) = current_user.open_subkey(KEYBOARD_LAYOUT_TOGGLE) else {
        return HotkeySettings::default();
    };

    let language_code = match read_registry_hotkey(&toggle, LANGUAGE_HOTKEY_VALUE) {
        RegistryHotkeyValue::Code(code) => Some(code),
        RegistryHotkeyValue::Invalid => None,
        RegistryHotkeyValue::Missing => {
            match read_registry_hotkey(&toggle, FALLBACK_HOTKEY_VALUE) {
                RegistryHotkeyValue::Code(code) => Some(code),
                RegistryHotkeyValue::Missing | RegistryHotkeyValue::Invalid => None,
            }
        }
    };
    let layout_code = match read_registry_hotkey(&toggle, LAYOUT_HOTKEY_VALUE) {
        RegistryHotkeyValue::Code(code) => Some(code),
        RegistryHotkeyValue::Missing | RegistryHotkeyValue::Invalid => None,
    };

    let mut settings = HotkeySettings::default();
    assign_hotkey(&mut settings, language_code, LanguageSwitch::Language);
    assign_hotkey(&mut settings, layout_code, LanguageSwitch::Layout);
    settings
}

fn read_registry_hotkey(toggle: &RegKey, name: &str) -> RegistryHotkeyValue {
    let value = match toggle.get_raw_value(name) {
        Ok(value) => value,
        Err(_) => return RegistryHotkeyValue::Missing,
    };

    if value.vtype == REG_DWORD && value.bytes.len() >= mem::size_of::<u32>() {
        let mut bytes = [0_u8; mem::size_of::<u32>()];
        bytes.copy_from_slice(&value.bytes[..mem::size_of::<u32>()]);
        return RegistryHotkeyValue::Code(u32::from_le_bytes(bytes));
    }

    if matches!(value.vtype, REG_SZ | REG_EXPAND_SZ) {
        if let Ok(text) = toggle.get_value::<String, _>(name) {
            if let Ok(code) = text.trim().parse::<u32>() {
                return RegistryHotkeyValue::Code(code);
            }
        }
    }
    RegistryHotkeyValue::Invalid
}

fn action_for_registry_code(code: Option<u32>, action: LanguageSwitch) -> Option<LanguageSwitch> {
    match code {
        Some(1) | Some(2) => Some(action),
        Some(3) | None => None,
        Some(_) => None,
    }
}

fn assign_hotkey(settings: &mut HotkeySettings, code: Option<u32>, action: LanguageSwitch) {
    let Some(action) = action_for_registry_code(code, action) else {
        return;
    };
    let slot = match code {
        Some(1) => &mut settings.alt_shift,
        Some(2) => &mut settings.ctrl_shift,
        _ => return,
    };
    if slot.is_none() {
        *slot = Some(action);
    } else if *slot != Some(action) {
        // Two registry entries targeting one physical chord are ambiguous.
        // Leave that chord disabled instead of choosing an implicit winner.
        *slot = None;
    }
}

pub(crate) fn foreground_window_id() -> Option<isize> {
    let (foreground, _) = validated_foreground_window()?;
    Some(foreground as isize)
}

pub(crate) fn request_switch_for_window(expected: isize, action: LanguageSwitch) -> bool {
    let (foreground, foreground_thread) = match validated_foreground_window() {
        Some(value) if value.0 as isize == expected => value,
        _ => return false,
    };
    let current_process_id = unsafe {
        // SAFETY: GetCurrentProcessId has no pointer arguments or preconditions.
        GetCurrentProcessId()
    };
    let target = focused_target(foreground, foreground_thread, current_process_id);

    if foreground_window_id() != Some(expected) {
        return false;
    }

    let target_thread = unsafe {
        // SAFETY: `target` is either the validated foreground HWND or a focus HWND
        // returned for its GUI thread and is passed with a valid output pointer.
        GetWindowThreadProcessId(target, ptr::null_mut())
    };
    if target_thread == 0 {
        return false;
    }
    let current_layout = unsafe {
        // SAFETY: `target_thread` is the nonzero thread id returned above.
        GetKeyboardLayout(target_thread)
    };
    if current_layout.is_null() {
        return false;
    }

    let (layouts, count) = match loaded_layouts() {
        Some(value) => value,
        None => return false,
    };
    let mut current_index = None;
    let mut layout_handles = [0_usize; MAX_LOCAL_LANGUAGE_LAYOUTS];
    let mut language_ids = [0_u16; MAX_LOCAL_LANGUAGE_LAYOUTS];
    for index in 0..count {
        let layout = layouts[index];
        layout_handles[index] = layout as usize;
        language_ids[index] = layout as usize as u16;
        if layout == current_layout {
            current_index = Some(index);
        }
    }
    let Some(current_index) = current_index else {
        return false;
    };
    let Some(next_index) =
        select_layout_index(action, current_index, &layout_handles, &language_ids, count)
    else {
        return false;
    };
    let next_layout = layouts[next_index];
    if next_layout.is_null() {
        return false;
    }

    let (latest_foreground, _) = match validated_foreground_window() {
        Some(value) if value.0 as isize == expected => value,
        _ => return false,
    };
    if latest_foreground != foreground {
        return false;
    }
    let mut target_process_id = 0;
    let target_thread = unsafe {
        // SAFETY: `target` is a non-null HWND selected from the validated process.
        GetWindowThreadProcessId(target, &mut target_process_id)
    };
    if target_thread == 0 || target_process_id != current_process_id {
        return false;
    }
    let posted = unsafe {
        // SAFETY: `target` belongs to the current process, `next_layout` is an
        // explicit non-null HKL from the bounded list, and the message carries
        // that HKL in LPARAM. No input is synthesized or activated here.
        PostMessageW(target, WM_INPUTLANGCHANGEREQUEST, 0, next_layout as LPARAM)
    };
    posted != FALSE
}

fn validated_foreground_window() -> Option<(HWND, DWORD)> {
    let foreground = unsafe {
        // SAFETY: GetForegroundWindow returns a process-independent HWND and
        // requires no caller-owned memory.
        GetForegroundWindow()
    };
    if foreground.is_null() {
        return None;
    }

    let mut process_id = 0;
    let thread_id = unsafe {
        // SAFETY: `foreground` is non-null and `process_id` is valid stack storage.
        GetWindowThreadProcessId(foreground, &mut process_id)
    };
    if thread_id == 0 {
        return None;
    }
    let current_process_id = unsafe {
        // SAFETY: GetCurrentProcessId has no pointer arguments or preconditions.
        GetCurrentProcessId()
    };
    if process_id != current_process_id {
        return None;
    }
    Some((foreground, thread_id))
}

fn focused_target(foreground: HWND, foreground_thread: DWORD, current_process_id: DWORD) -> HWND {
    let mut gui_info: GUITHREADINFO = unsafe {
        // SAFETY: GUITHREADINFO is a plain Win32 output structure. It is zeroed
        // before its required cbSize field is initialized.
        mem::zeroed()
    };
    gui_info.cbSize = mem::size_of::<GUITHREADINFO>() as DWORD;
    let got_info = unsafe {
        // SAFETY: `foreground_thread` is nonzero and `gui_info` is valid writable
        // storage for the documented output structure.
        GetGUIThreadInfo(foreground_thread, &mut gui_info)
    };
    if got_info == FALSE || gui_info.hwndFocus.is_null() {
        return foreground;
    }

    let mut focus_process_id = 0;
    let focus_thread = unsafe {
        // SAFETY: `hwndFocus` is returned by GetGUIThreadInfo and the output
        // process id points to valid stack storage.
        GetWindowThreadProcessId(gui_info.hwndFocus, &mut focus_process_id)
    };
    if focus_thread != 0 && focus_process_id == current_process_id {
        gui_info.hwndFocus
    } else {
        foreground
    }
}

fn loaded_layouts() -> Option<(
    [winapi::shared::minwindef::HKL; MAX_LOCAL_LANGUAGE_LAYOUTS],
    usize,
)> {
    let required = unsafe {
        // SAFETY: A zero capacity and null output pointer are the documented
        // count-query form of GetKeyboardLayoutList.
        GetKeyboardLayoutList(0, ptr::null_mut())
    };
    if required <= 0 || required as usize > MAX_LOCAL_LANGUAGE_LAYOUTS {
        return None;
    }

    let mut layouts = [ptr::null_mut(); MAX_LOCAL_LANGUAGE_LAYOUTS];
    let copied = unsafe {
        // SAFETY: `layouts` has exactly MAX_LOCAL_LANGUAGE_LAYOUTS writable HKL
        // slots and `required` was checked to fit that fixed bound.
        GetKeyboardLayoutList(required as c_int, layouts.as_mut_ptr())
    };
    if copied != required {
        return None;
    }
    let count = copied as usize;
    if layouts[..count].iter().any(|layout| layout.is_null()) {
        return None;
    }
    Some((layouts, count))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_codes_are_explicit_and_fail_closed() {
        assert_eq!(
            action_for_registry_code(Some(1), LanguageSwitch::Language),
            Some(LanguageSwitch::Language)
        );
        assert_eq!(
            action_for_registry_code(Some(2), LanguageSwitch::Layout),
            Some(LanguageSwitch::Layout)
        );
        assert_eq!(
            action_for_registry_code(Some(3), LanguageSwitch::Language),
            None
        );
        assert_eq!(
            action_for_registry_code(Some(99), LanguageSwitch::Layout),
            None
        );
        assert_eq!(
            action_for_registry_code(None, LanguageSwitch::Language),
            None
        );
    }
}
