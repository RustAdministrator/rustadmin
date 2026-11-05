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

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Both => "both",
            Self::LocalToRemote => "local-to-remote",
            Self::RemoteToLocal => "remote-to-local",
            Self::Off => "off",
        }
    }
}

/// The direction in force for a viewer session: the session's own setting if it
/// has one, otherwise the local configuration, otherwise the global option. An
/// empty value means "not set at this level"; a set but unknown value is `Off`.
pub(crate) fn resolve_clipboard_direction(
    session: &str,
    local: &str,
    global: &str,
) -> ClipboardDirectionPolicy {
    for value in [session, local, global] {
        if !value.trim().is_empty() {
            return ClipboardDirectionPolicy::from_option_value(value);
        }
    }
    ClipboardDirectionPolicy::Both
}

#[cfg(test)]
mod clipboard_direction_resolution_tests {
    use super::*;
    use ClipboardDirectionPolicy::*;

    #[test]
    fn the_narrowest_level_that_is_set_decides() {
        // Nothing set anywhere: both directions.
        assert_eq!(resolve_clipboard_direction("", "", ""), Both);
        // Global only.
        assert_eq!(
            resolve_clipboard_direction("", "", "local-to-remote"),
            LocalToRemote
        );
        // Local configuration beats the global option.
        assert_eq!(
            resolve_clipboard_direction("", "off", "local-to-remote"),
            Off
        );
        // The session beats both, including to widen: this is a per-session
        // decision the user took on purpose.
        assert_eq!(
            resolve_clipboard_direction("both", "off", "remote-to-local"),
            Both
        );
        assert_eq!(
            resolve_clipboard_direction("remote-to-local", "both", "both"),
            RemoteToLocal
        );
    }

    #[test]
    fn whitespace_is_unset_and_unknown_values_close_the_clipboard() {
        assert_eq!(resolve_clipboard_direction("  ", "", "send"), LocalToRemote);
        assert_eq!(resolve_clipboard_direction("sideways", "both", "both"), Off);
    }
}
