#[cfg(windows)]
use std::mem::{size_of, size_of_val};

use hbb_common::message_proto::DisplayInfo;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InputDesktopClassification {
    Default,
    NonDefault,
    Unknown,
}

impl InputDesktopClassification {
    // Only a positively identified Default desktop permits ordinary capture.
    // Query failures must not tear down a working privileged capture helper.
    pub const fn requires_secure_capture(self) -> bool {
        !matches!(self, Self::Default)
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::NonDefault => "non_default",
            Self::Unknown => "unknown",
        }
    }
}

pub(crate) fn select_focus_display(
    input_desktop: InputDesktopClassification,
    foreground_display: Option<usize>,
    displays: &[DisplayInfo],
) -> Option<usize> {
    if foreground_display.is_some() {
        return foreground_display;
    }

    if input_desktop == InputDesktopClassification::NonDefault {
        primary_display_index(displays)
    } else {
        None
    }
}

fn primary_display_index(displays: &[DisplayInfo]) -> Option<usize> {
    displays
        .iter()
        .position(|display| contains_point(display, 0, 0))
}

fn contains_point(display: &DisplayInfo, x: i32, y: i32) -> bool {
    let x = i64::from(x);
    let y = i64::from(y);
    let left = i64::from(display.x);
    let top = i64::from(display.y);
    let right = left + i64::from(display.width);
    let bottom = top + i64::from(display.height);
    x >= left && x < right && y >= top && y < bottom
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CaptureDesktopState {
    pub prelogin: bool,
    pub locked: bool,
    pub desktop_changed: bool,
    pub logon_ui: bool,
    pub input_desktop: InputDesktopClassification,
}

impl CaptureDesktopState {
    pub const fn new(
        prelogin: bool,
        locked: bool,
        desktop_changed: bool,
        logon_ui: bool,
        input_desktop: InputDesktopClassification,
    ) -> Self {
        Self {
            prelogin,
            locked,
            desktop_changed,
            logon_ui,
            input_desktop,
        }
    }

    pub const fn requires_secure_capture(self) -> bool {
        self.prelogin
            || self.locked
            || self.desktop_changed
            || self.logon_ui
            || self.input_desktop.requires_secure_capture()
    }

    // Thread attachment can differ between monitors and becomes current after
    // rebinding to UAC. It must not change their shared helper generation.
    pub const fn persistent_secure_identity(self) -> bool {
        self.prelogin
            || self.locked
            || self.logon_ui
            || self.input_desktop.requires_secure_capture()
    }

    pub const fn allows_interactive_capture(self) -> bool {
        !self.requires_secure_capture()
    }
}

const DEFAULT_DESKTOP_NAME: &[u16] = &[
    b'D' as u16,
    b'e' as u16,
    b'f' as u16,
    b'a' as u16,
    b'u' as u16,
    b'l' as u16,
    b't' as u16,
];

pub fn classify_input_desktop_name(name: &[u16]) -> InputDesktopClassification {
    let Some(name_end) = name.iter().position(|character| *character == 0) else {
        return InputDesktopClassification::Unknown;
    };
    if name_end == 0 {
        return InputDesktopClassification::Unknown;
    }
    if name[..name_end].len() == DEFAULT_DESKTOP_NAME.len()
        && name[..name_end]
            .iter()
            .zip(DEFAULT_DESKTOP_NAME)
            .all(|(actual, expected)| ascii_lowercase(*actual) == ascii_lowercase(*expected))
    {
        InputDesktopClassification::Default
    } else {
        InputDesktopClassification::NonDefault
    }
}

const fn ascii_lowercase(character: u16) -> u16 {
    if character >= b'A' as u16 && character <= b'Z' as u16 {
        character + (b'a' - b'A') as u16
    } else {
        character
    }
}

#[cfg(windows)]
const INPUT_DESKTOP_NAME_CAPACITY: usize = 256;

#[cfg(windows)]
struct InputDesktopHandle(winapi::shared::windef::HDESK);

#[cfg(windows)]
impl Drop for InputDesktopHandle {
    fn drop(&mut self) {
        // SAFETY: this handle is the one returned by OpenInputDesktop below and
        // remains owned by this guard until CloseDesktop consumes that ownership.
        unsafe {
            let _ = winapi::um::winuser::CloseDesktop(self.0);
        }
    }
}

#[cfg(windows)]
pub fn input_desktop_classification() -> InputDesktopClassification {
    use winapi::{
        shared::minwindef::{DWORD, FALSE},
        um::winuser::{GetUserObjectInformationW, OpenInputDesktop, DESKTOP_READOBJECTS, UOI_NAME},
    };

    // The returned desktop handle is query-owned. Request only the read access
    // needed for UOI_NAME; never switch to or close the calling thread's desktop.
    let desktop = unsafe {
        // SAFETY: the flags are constant Win32 inputs; OpenInputDesktop returns
        // either a new HDESK owned by this query or a null handle on failure.
        OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS)
    };
    if desktop.is_null() {
        return InputDesktopClassification::Unknown;
    }
    let desktop = InputDesktopHandle(desktop);

    // UOI_NAME reports the required byte count through `needed`. The fixed
    // stack buffer avoids allocation on capture-state checks; a failed,
    // truncated, malformed, or empty result stays conservative.
    let mut name = [0u16; INPUT_DESKTOP_NAME_CAPACITY];
    let mut needed: DWORD = 0;
    let ok = unsafe {
        // SAFETY: `desktop.0` is a valid query-owned HDESK, `name` is writable
        // stack storage, its byte length matches the supplied DWORD, and
        // `needed` is a valid out pointer for the duration of this call.
        GetUserObjectInformationW(
            desktop.0.cast(),
            UOI_NAME as i32,
            name.as_mut_ptr().cast(),
            size_of_val(&name) as DWORD,
            &mut needed,
        )
    };
    if ok == FALSE || needed == 0 || needed as usize > size_of_val(&name) {
        return InputDesktopClassification::Unknown;
    }
    if needed as usize % size_of::<u16>() != 0 {
        return InputDesktopClassification::Unknown;
    }
    classify_input_desktop_name(&name[..needed as usize / size_of::<u16>()])
}

#[cfg(test)]
mod tests {
    use super::{classify_input_desktop_name, select_focus_display, InputDesktopClassification};
    use hbb_common::message_proto::DisplayInfo;

    #[test]
    fn classifies_only_a_complete_default_name_as_default() {
        use InputDesktopClassification::{Default, NonDefault};
        for (name, expected) in [
            ("Default", Default),
            ("default", Default),
            ("DeFaUlT", Default),
            ("Winlogon", NonDefault),
            ("Screen-saver", NonDefault),
            ("DefaultSuffix", NonDefault),
        ] {
            let mut wide_name: Vec<u16> = name.encode_utf16().collect();
            wide_name.push(0);
            assert_eq!(classify_input_desktop_name(&wide_name), expected, "{name}");
        }
    }

    #[test]
    fn rejects_unknown_or_truncated_names_conservatively() {
        assert_eq!(
            classify_input_desktop_name(&[]),
            InputDesktopClassification::Unknown
        );
        assert_eq!(
            classify_input_desktop_name(&[0]),
            InputDesktopClassification::Unknown
        );
        assert_eq!(
            classify_input_desktop_name(&[
                'D' as u16, 'e' as u16, 'f' as u16, 'a' as u16, 'u' as u16, 'l' as u16, 't' as u16
            ]),
            InputDesktopClassification::Unknown
        );
    }

    #[test]
    fn non_default_fallback_uses_primary_origin_in_display_order() {
        let displays = [
            DisplayInfo {
                x: -1920,
                y: 0,
                width: 1920,
                height: 1080,
                ..Default::default()
            },
            DisplayInfo {
                x: 0,
                y: 0,
                width: 2560,
                height: 1440,
                ..Default::default()
            },
        ];

        assert_eq!(
            select_focus_display(InputDesktopClassification::NonDefault, None, &displays),
            Some(1)
        );
    }

    #[test]
    fn default_and_unknown_missing_foreground_do_not_fallback() {
        let displays = [DisplayInfo {
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            ..Default::default()
        }];

        for input_desktop in [
            InputDesktopClassification::Default,
            InputDesktopClassification::Unknown,
        ] {
            assert_eq!(select_focus_display(input_desktop, None, &displays), None);
        }
    }

    #[test]
    fn actual_foreground_display_wins_over_non_default_fallback() {
        let displays = [DisplayInfo::default()];

        assert_eq!(
            select_focus_display(InputDesktopClassification::NonDefault, Some(0), &displays),
            Some(0)
        );
    }
}
