pub const VERIFY_CODEC_INTEGRATION_ARG: &str = "--verify-codec-integration";
pub const CODEC_INTEGRATION_REPORT_KIND: &str = "rustadmin-codec-integration";
pub const CODEC_INTEGRATION_REPORT_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum CodecFormat {
    H264,
    H265,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct ExpectedCodec {
    pub name: &'static str,
    pub format: CodecFormat,
}

pub const EXPECTED_NATIVE_DECODERS: [ExpectedCodec; 2] = [
    ExpectedCodec {
        name: "h264",
        format: CodecFormat::H264,
    },
    ExpectedCodec {
        name: "hevc",
        format: CodecFormat::H265,
    },
];

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct LinkedDecoder {
    pub name: String,
    pub format: CodecFormat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum CodecCheckStatus {
    #[serde(rename = "validated")]
    Validated,
    #[serde(rename = "missing_or_sample_decode_failed")]
    MissingOrSampleDecodeFailed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct CodecCheck {
    pub expected: ExpectedCodec,
    pub status: CodecCheckStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct CodecIntegrationReport {
    pub report_kind: &'static str,
    pub report_version: u32,
    pub hwcodec_enabled: bool,
    pub passed: bool,
    pub linked_decoders: Vec<LinkedDecoder>,
    pub checks: Vec<CodecCheck>,
    pub missing_expected_decoders: Vec<ExpectedCodec>,
}

impl CodecIntegrationReport {
    pub fn from_linked_decoders(
        hwcodec_enabled: bool,
        linked_decoders: Vec<LinkedDecoder>,
    ) -> Self {
        let mut checks = Vec::with_capacity(EXPECTED_NATIVE_DECODERS.len());
        let mut missing_expected_decoders = Vec::with_capacity(EXPECTED_NATIVE_DECODERS.len());

        for expected in EXPECTED_NATIVE_DECODERS {
            let validated = linked_decoders
                .iter()
                .any(|actual| actual.name == expected.name && actual.format == expected.format);
            let status = if validated {
                CodecCheckStatus::Validated
            } else {
                missing_expected_decoders.push(expected);
                CodecCheckStatus::MissingOrSampleDecodeFailed
            };
            checks.push(CodecCheck { expected, status });
        }
        let passed = hwcodec_enabled && missing_expected_decoders.is_empty();

        Self {
            report_kind: CODEC_INTEGRATION_REPORT_KIND,
            report_version: CODEC_INTEGRATION_REPORT_VERSION,
            hwcodec_enabled,
            passed,
            linked_decoders,
            checks,
            missing_expected_decoders,
        }
    }
}

pub fn verify() -> CodecIntegrationReport {
    #[cfg(feature = "hwcodec")]
    {
        use hwcodec::{common::DataFormat, ffmpeg_ram::decode::Decoder};

        let linked_decoders = Decoder::available_software_decoders()
            .into_iter()
            .filter_map(|decoder| {
                let format = match decoder.format {
                    DataFormat::H264 => CodecFormat::H264,
                    DataFormat::H265 => CodecFormat::H265,
                    _ => return None,
                };
                Some(LinkedDecoder {
                    name: decoder.name,
                    format,
                })
            })
            .collect();
        return CodecIntegrationReport::from_linked_decoders(true, linked_decoders);
    }

    #[cfg(not(feature = "hwcodec"))]
    CodecIntegrationReport::from_linked_decoders(false, Vec::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decoder(name: &str, format: CodecFormat) -> LinkedDecoder {
        LinkedDecoder {
            name: name.to_owned(),
            format,
        }
    }

    #[test]
    fn valid_report_contains_both_native_decoders() {
        let report = CodecIntegrationReport::from_linked_decoders(
            true,
            vec![
                decoder("h264", CodecFormat::H264),
                decoder("hevc", CodecFormat::H265),
            ],
        );

        assert_eq!(report.report_kind, CODEC_INTEGRATION_REPORT_KIND);
        assert_eq!(report.report_version, CODEC_INTEGRATION_REPORT_VERSION);
        assert!(report.passed);
        assert!(report.missing_expected_decoders.is_empty());
        assert!(report
            .checks
            .iter()
            .all(|check| check.status == CodecCheckStatus::Validated));
    }

    #[test]
    fn valid_report_serializes_the_versioned_json_contract() {
        let report = CodecIntegrationReport::from_linked_decoders(
            true,
            vec![
                decoder("h264", CodecFormat::H264),
                decoder("hevc", CodecFormat::H265),
            ],
        );
        let json = hbb_common::serde_json::to_value(&report).expect("report must serialize");

        assert_eq!(json["report_kind"], CODEC_INTEGRATION_REPORT_KIND);
        assert_eq!(json["report_version"], CODEC_INTEGRATION_REPORT_VERSION);
        assert_eq!(json["hwcodec_enabled"], true);
        assert_eq!(json["passed"], true);
        assert_eq!(json["checks"][0]["expected"]["name"], "h264");
        assert_eq!(json["checks"][0]["expected"]["format"], "H264");
        assert_eq!(json["checks"][0]["status"], "validated");
        assert_eq!(json["checks"][1]["expected"]["name"], "hevc");
        assert_eq!(json["checks"][1]["expected"]["format"], "H265");
        assert_eq!(json["checks"][1]["status"], "validated");
        assert!(json["missing_expected_decoders"]
            .as_array()
            .map_or(false, |values| values.is_empty()));
    }

    #[test]
    fn report_fails_closed_when_hwcodec_is_not_enabled() {
        let report = CodecIntegrationReport::from_linked_decoders(
            false,
            vec![
                decoder("h264", CodecFormat::H264),
                decoder("hevc", CodecFormat::H265),
            ],
        );

        assert!(!report.passed);
        assert!(report.missing_expected_decoders.is_empty());
    }

    #[test]
    fn missing_h264_is_reported_with_expected_format() {
        let report = CodecIntegrationReport::from_linked_decoders(
            true,
            vec![decoder("hevc", CodecFormat::H265)],
        );

        assert!(!report.passed);
        assert_eq!(
            report.missing_expected_decoders,
            vec![EXPECTED_NATIVE_DECODERS[0]]
        );
        assert_eq!(report.checks[0].expected, EXPECTED_NATIVE_DECODERS[0]);
        assert_eq!(
            report.checks[0].status,
            CodecCheckStatus::MissingOrSampleDecodeFailed
        );
    }

    #[test]
    fn missing_hevc_is_reported_with_expected_format() {
        let report = CodecIntegrationReport::from_linked_decoders(
            true,
            vec![decoder("h264", CodecFormat::H264)],
        );

        assert!(!report.passed);
        assert_eq!(
            report.missing_expected_decoders,
            vec![EXPECTED_NATIVE_DECODERS[1]]
        );
        assert_eq!(report.checks[1].expected, EXPECTED_NATIVE_DECODERS[1]);
        assert_eq!(
            report.checks[1].status,
            CodecCheckStatus::MissingOrSampleDecodeFailed
        );
    }

    #[test]
    fn native_decoder_names_and_formats_must_match_exactly() {
        let report = CodecIntegrationReport::from_linked_decoders(
            true,
            vec![
                decoder("libx264", CodecFormat::H264),
                decoder("h264_cuvid", CodecFormat::H264),
                decoder("h264", CodecFormat::H265),
                decoder("h264", CodecFormat::H264),
            ],
        );

        assert!(!report.passed);
        assert_eq!(
            report.missing_expected_decoders,
            vec![EXPECTED_NATIVE_DECODERS[1]]
        );
    }
}
