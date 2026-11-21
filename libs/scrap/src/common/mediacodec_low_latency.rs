//! Low latency from an Android hardware decoder: what is asked for beyond the standard key.
//!
//! The `low-latency` format key of Android 11 makes a decoder emit a frame without holding it
//! back, but only a decoder that lists the feature honours it. One that does not keeps the
//! last frame until the next one is handed in: the picture is a frame behind, the last frame
//! of a burst is not shown until the next packet, and the viewer cannot report a keyframe as
//! decoded while nothing follows it. For such decoders the chip makers have keys of their own.
//!
//! Only the choice is here, so that it is tested on every platform; the format is put
//! together where the decoder is configured.

/// What is known about one hardware decoder of the device, from the system's codec list.
#[derive(Clone, Copy, Debug)]
pub struct HardwareDecoder<'a> {
    pub name: &'a str,
    pub mime_type: &'a str,
    /// Whether the decoder lists the low-latency feature; `None` before Android 11.
    pub low_latency: Option<bool>,
}

/// One key of a decoder format, and its value.
pub type FormatKey = (&'static str, i32);

/// Qualcomm: output in the order of decoding. A remote screen has no frames to reorder.
const QUALCOMM_PICTURE_ORDER: FormatKey = ("vendor.qti-ext-dec-picture-order.enable", 1);
/// Qualcomm: the decoder's own low-latency mode.
const QUALCOMM_LOW_LATENCY: FormatKey = ("vendor.qti-ext-dec-low-latency.enable", 1);
/// Both first; the low-latency mode alone for a decoder that refuses the pair.
const QUALCOMM_ATTEMPTS: &[&[FormatKey]] = &[
    &[QUALCOMM_PICTURE_ORDER, QUALCOMM_LOW_LATENCY],
    &[QUALCOMM_LOW_LATENCY],
];
/// How the names of Qualcomm's decoders begin, in lower case.
const QUALCOMM_PREFIXES: [&str; 2] = ["c2.qti", "omx.qcom"];

/// The sets of vendor keys to try, in this order, when the decoder for `mime_type` is
/// configured. The caller tries the format without any of them last.
///
/// The system prefers the first decoder of its list for a type, and so does this. Nothing is
/// returned when that decoder lists the standard feature (the standard key is then enough),
/// when its maker is not one whose keys are known, or when the list has no decoder for the
/// type.
pub fn vendor_key_attempts(
    decoders: &[HardwareDecoder],
    mime_type: &str,
) -> &'static [&'static [FormatKey]] {
    let Some(decoder) = decoders
        .iter()
        .find(|decoder| decoder.mime_type == mime_type)
    else {
        return &[];
    };
    if decoder.low_latency == Some(true) {
        return &[];
    }
    let name = decoder.name.to_ascii_lowercase();
    if QUALCOMM_PREFIXES
        .iter()
        .any(|prefix| name.starts_with(prefix))
    {
        return QUALCOMM_ATTEMPTS;
    }
    &[]
}

#[cfg(test)]
mod tests {
    use super::*;

    const AVC: &str = "video/avc";
    const HEVC: &str = "video/hevc";

    fn decoder<'a>(
        name: &'a str,
        mime_type: &'a str,
        low_latency: Option<bool>,
    ) -> HardwareDecoder<'a> {
        HardwareDecoder {
            name,
            mime_type,
            low_latency,
        }
    }

    fn names(attempts: &[&[FormatKey]]) -> Vec<Vec<&'static str>> {
        attempts
            .iter()
            .map(|keys| keys.iter().map(|(key, _)| *key).collect())
            .collect()
    }

    /// The phone of the session of 2026-11-21: a Qualcomm decoder that does not list the
    /// low-latency feature. Both keys are tried, then the low-latency mode alone.
    #[test]
    fn qualcomm_decoder_without_the_standard_feature_gets_its_makers_keys() {
        let decoders = [decoder("c2.qti.avc.decoder", AVC, Some(false))];
        let attempts = vendor_key_attempts(&decoders, AVC);
        assert_eq!(
            names(attempts),
            vec![
                vec![
                    "vendor.qti-ext-dec-picture-order.enable",
                    "vendor.qti-ext-dec-low-latency.enable"
                ],
                vec!["vendor.qti-ext-dec-low-latency.enable"],
            ]
        );
        assert!(attempts
            .iter()
            .flat_map(|keys| keys.iter())
            .all(|(_, value)| *value == 1));
    }

    #[test]
    fn decoder_before_android_11_and_the_older_name_form_count_too() {
        let decoders = [decoder("OMX.qcom.video.decoder.avc", AVC, None)];
        assert_eq!(vendor_key_attempts(&decoders, AVC).len(), 2);
    }

    /// A decoder that lists the feature honours the standard key: nothing else is asked.
    #[test]
    fn decoder_with_the_standard_feature_gets_no_vendor_keys() {
        let decoders = [decoder("c2.qti.avc.decoder", AVC, Some(true))];
        assert!(vendor_key_attempts(&decoders, AVC).is_empty());
    }

    #[test]
    fn decoder_of_an_unknown_maker_gets_no_vendor_keys() {
        let decoders = [
            decoder("c2.exynos.h264.decoder", AVC, Some(false)),
            decoder("c2.mtk.hevc.decoder", HEVC, None),
        ];
        assert!(vendor_key_attempts(&decoders, AVC).is_empty());
        assert!(vendor_key_attempts(&decoders, HEVC).is_empty());
        assert!(vendor_key_attempts(&[], AVC).is_empty());
    }

    /// Each type is decided by its own decoder, and by the first one the system lists for it.
    #[test]
    fn first_decoder_of_the_type_decides() {
        let decoders = [
            decoder("c2.qti.hevc.decoder", HEVC, Some(false)),
            decoder("c2.other.avc.decoder", AVC, Some(false)),
            decoder("c2.qti.avc.decoder", AVC, Some(false)),
        ];
        assert_eq!(vendor_key_attempts(&decoders, HEVC).len(), 2);
        assert!(vendor_key_attempts(&decoders, AVC).is_empty());
    }
}
