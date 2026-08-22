use hbb_common::{
    message_proto::option_message::VideoProfile as WireVideoProfile, protobuf::EnumOrUnknown,
};

pub(crate) const MOVIE_DEFAULT_TARGET_FPS: u32 = 60;
pub(crate) const MOVIE_PLAYOUT_DELAY_MS: u32 = 50;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum VideoProfile {
    #[default]
    Standard,
    Movie,
}

impl VideoProfile {
    pub(crate) fn from_config(value: &str) -> Self {
        match value.trim().to_ascii_lowercase().as_str() {
            "movie" => Self::Movie,
            _ => Self::Standard,
        }
    }

    pub(crate) fn config_value(self) -> &'static str {
        match self {
            Self::Standard => "standard",
            Self::Movie => "movie",
        }
    }

    pub(crate) fn wire_value(self) -> WireVideoProfile {
        match self {
            Self::Standard => WireVideoProfile::VideoProfileStandard,
            Self::Movie => WireVideoProfile::VideoProfileMovie,
        }
    }

    pub(crate) fn from_wire_update(value: EnumOrUnknown<WireVideoProfile>) -> Option<Self> {
        match value.enum_value() {
            Ok(WireVideoProfile::VideoProfileNotSet) => None,
            Ok(WireVideoProfile::VideoProfileStandard) => Some(Self::Standard),
            Ok(WireVideoProfile::VideoProfileMovie) => Some(Self::Movie),
            Err(_) => Some(Self::Standard),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum EffectiveMovieMode {
    #[default]
    Off,
    Full,
    ViewerOnly,
    CompatibilityTransport,
    MixedSubscribers,
    UnsupportedPeer,
}

impl EffectiveMovieMode {
    pub(crate) fn for_request(profile: VideoProfile, full_supported: bool) -> Self {
        match (profile, full_supported) {
            (VideoProfile::Standard, _) => Self::Off,
            (VideoProfile::Movie, true) => Self::Full,
            (VideoProfile::Movie, false) => Self::UnsupportedPeer,
        }
    }

    pub(crate) fn for_viewer(
        profile: VideoProfile,
        host_supported: bool,
        full_transport: bool,
    ) -> Self {
        match (profile, host_supported, full_transport) {
            (VideoProfile::Standard, _, _) => Self::Off,
            (VideoProfile::Movie, false, _) => Self::UnsupportedPeer,
            (VideoProfile::Movie, true, true) => Self::Full,
            (VideoProfile::Movie, true, false) => Self::CompatibilityTransport,
        }
    }

    pub(crate) fn profile_label(self) -> &'static str {
        match self {
            Self::Off => "standard",
            Self::Full => "movie-full",
            Self::ViewerOnly => "movie-viewer-only",
            Self::CompatibilityTransport => "movie-compatibility-transport",
            Self::MixedSubscribers => "standard",
            Self::UnsupportedPeer => "standard",
        }
    }

    pub(crate) fn fallback_reason(self) -> &'static str {
        match self {
            Self::Off | Self::Full => "none",
            Self::ViewerOnly => "host-pacing-unavailable",
            Self::CompatibilityTransport => "transport-unsupported",
            Self::MixedSubscribers => "mixed-subscribers",
            Self::UnsupportedPeer => "host-unsupported",
        }
    }
}

pub(crate) fn viewer_full_movie_mode(
    profile: VideoProfile,
    host_supported: bool,
    full_transport: bool,
) -> bool {
    EffectiveMovieMode::for_viewer(profile, host_supported, full_transport)
        == EffectiveMovieMode::Full
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_and_wire_profiles_normalize_safely() {
        assert_eq!(VideoProfile::from_config("movie"), VideoProfile::Movie);
        assert_eq!(
            VideoProfile::from_config("unsupported"),
            VideoProfile::Standard
        );
        assert_eq!(
            VideoProfile::from_wire_update(WireVideoProfile::VideoProfileNotSet.into()),
            None
        );
        assert_eq!(
            VideoProfile::from_wire_update(WireVideoProfile::VideoProfileStandard.into()),
            Some(VideoProfile::Standard)
        );
        assert_eq!(
            VideoProfile::from_wire_update(WireVideoProfile::VideoProfileMovie.into()),
            Some(VideoProfile::Movie)
        );
        assert_eq!(
            VideoProfile::from_wire_update(EnumOrUnknown::from_i32(99)),
            Some(VideoProfile::Standard)
        );
    }

    #[test]
    fn effective_mode_reports_truthful_fallbacks() {
        assert_eq!(
            EffectiveMovieMode::for_request(VideoProfile::Standard, true),
            EffectiveMovieMode::Off
        );
        assert_eq!(
            EffectiveMovieMode::for_request(VideoProfile::Movie, false),
            EffectiveMovieMode::UnsupportedPeer
        );
        assert_eq!(
            EffectiveMovieMode::for_request(VideoProfile::Movie, true),
            EffectiveMovieMode::Full
        );
        assert_eq!(
            EffectiveMovieMode::for_viewer(VideoProfile::Movie, true, false),
            EffectiveMovieMode::CompatibilityTransport
        );
        assert_eq!(
            EffectiveMovieMode::UnsupportedPeer.fallback_reason(),
            "host-unsupported"
        );
        assert_eq!(
            EffectiveMovieMode::ViewerOnly.profile_label(),
            "movie-viewer-only"
        );
        assert_eq!(
            EffectiveMovieMode::CompatibilityTransport.fallback_reason(),
            "transport-unsupported"
        );
        assert_eq!(
            EffectiveMovieMode::MixedSubscribers.fallback_reason(),
            "mixed-subscribers"
        );
        assert!(!viewer_full_movie_mode(VideoProfile::Movie, false, true));
        assert!(!viewer_full_movie_mode(VideoProfile::Movie, true, false));
        assert!(viewer_full_movie_mode(VideoProfile::Movie, true, true));
    }
}
