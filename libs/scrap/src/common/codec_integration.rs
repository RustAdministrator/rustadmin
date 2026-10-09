pub const VERIFY_CODEC_INTEGRATION_ARG: &str = "--verify-codec-integration";
pub const CODEC_INTEGRATION_REPORT_KIND: &str = "rustadmin-codec-integration";
pub const CODEC_INTEGRATION_REPORT_VERSION: u32 = 2;
pub const PRIVATE_CODEC_WARNING: &str = "This build includes optional software H.264/H.265 implementations. Under RustAdmin's distribution policy it is intended for private/custom use and is not approved for public distribution. Review applicable implementation licenses and patent obligations.";

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum CodecFormat {
    VP8,
    VP9,
    AV1,
    H264,
    H265,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct LinkedCodec {
    pub name: String,
    pub format: CodecFormat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CodecCheckStatus {
    Validated,
    NotBuilt,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct CodecCheck {
    pub name: String,
    pub format: CodecFormat,
    pub status: CodecCheckStatus,
    pub detail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct CodecIntegrationReport {
    pub report_kind: &'static str,
    pub report_version: u32,
    pub hwcodec_enabled: bool,
    pub passed: bool,
    // Registry inventory for RustAdmin's known FFmpeg implementations. These
    // entries do NOT claim that hardware is usable on the build machine.
    pub registered_encoders: Vec<LinkedCodec>,
    pub registered_decoders: Vec<LinkedCodec>,
    pub core_roundtrips: Vec<CodecCheck>,
    pub optional_software_decoders: Vec<CodecCheck>,
    pub warnings: Vec<String>,
}

impl CodecIntegrationReport {
    fn from_checks(
        hwcodec_enabled: bool,
        registered_encoders: Vec<LinkedCodec>,
        registered_decoders: Vec<LinkedCodec>,
        core_roundtrips: Vec<CodecCheck>,
        optional_software_decoders: Vec<CodecCheck>,
    ) -> Self {
        let core_ok = [CodecFormat::VP8, CodecFormat::VP9, CodecFormat::AV1]
            .iter()
            .all(|format| {
                core_roundtrips
                    .iter()
                    .any(|c| c.format == *format && c.status == CodecCheckStatus::Validated)
            });
        let passed = core_ok
            && core_roundtrips
                .iter()
                .all(|c| c.status == CodecCheckStatus::Validated)
            && optional_software_decoders
                .iter()
                .all(|c| c.status != CodecCheckStatus::Failed);
        let software_h26x = registered_encoders.iter().any(|c| {
            matches!(
                c.name.as_str(),
                "libx264" | "libx264rgb" | "libx265" | "libopenh264" | "libkvazaar"
            )
        }) || registered_decoders
            .iter()
            .any(|c| matches!(c.name.as_str(), "h264" | "hevc" | "libopenh264"));
        Self {
            report_kind: CODEC_INTEGRATION_REPORT_KIND,
            report_version: CODEC_INTEGRATION_REPORT_VERSION,
            hwcodec_enabled,
            passed,
            registered_encoders,
            registered_decoders,
            core_roundtrips,
            optional_software_decoders,
            warnings: if software_h26x {
                vec![PRIVATE_CODEC_WARNING.to_owned()]
            } else {
                Vec::new()
            },
        }
    }
}

fn check(name: &str, format: CodecFormat, result: Result<(), String>) -> CodecCheck {
    CodecCheck {
        name: name.to_owned(),
        format,
        status: if result.is_ok() {
            CodecCheckStatus::Validated
        } else {
            CodecCheckStatus::Failed
        },
        detail: result.err(),
    }
}

// Small real encode/decode roundtrips validate the linked baseline libraries
// without querying user preferences, service caches or GPU drivers.
fn core_roundtrip(format: CodecFormat) -> hbb_common::ResultType<()> {
    use crate::{
        aom::{AomDecoder, AomEncoder, AomEncoderConfig},
        codec::{EncoderApi, EncoderCfg},
        vpxcodec::{VpxDecoder, VpxDecoderConfig, VpxEncoder, VpxEncoderConfig, VpxVideoCodecId},
        GoogleImage,
    };
    use hbb_common::anyhow::{bail, ensure};
    let (width, height) = (64usize, 64usize);
    let input = vec![128u8; width * height * 3 / 2];
    let mut decoded = 0;
    match format {
        CodecFormat::VP8 | CodecFormat::VP9 => {
            let codec = if format == CodecFormat::VP8 {
                VpxVideoCodecId::VP8
            } else {
                VpxVideoCodecId::VP9
            };
            let mut encoder = VpxEncoder::new(
                EncoderCfg::VPX(VpxEncoderConfig {
                    width: width as _,
                    height: height as _,
                    quality: 1.0,
                    fps: 30,
                    codec,
                    keyframe_interval: None,
                }),
                false,
            )?;
            let mut decoder = VpxDecoder::new(VpxDecoderConfig { codec })?;
            for packet in encoder.encode(0, &input, 1)? {
                for image in decoder.decode(packet.data)? {
                    ensure!(
                        image.width() == width && image.height() == height,
                        "decoded dimensions differ"
                    );
                    decoded += 1;
                }
            }
            for packet in encoder.flush()? {
                for image in decoder.decode(packet.data)? {
                    ensure!(
                        image.width() == width && image.height() == height,
                        "decoded dimensions differ"
                    );
                    decoded += 1;
                }
            }
        }
        CodecFormat::AV1 => {
            let mut encoder = AomEncoder::new(
                EncoderCfg::AOM(AomEncoderConfig {
                    width: width as _,
                    height: height as _,
                    quality: 1.0,
                    fps: 30,
                    keyframe_interval: None,
                }),
                false,
            )?;
            let mut decoder = AomDecoder::new()?;
            for packet in encoder.encode(0, &input, 1)? {
                for image in decoder.decode(packet.data)? {
                    ensure!(
                        image.width() == width && image.height() == height,
                        "decoded dimensions differ"
                    );
                    decoded += 1;
                }
            }
        }
        _ => bail!("not a core codec"),
    }
    ensure!(decoded > 0, "no decoded frame");
    Ok(())
}

#[cfg(feature = "hwcodec")]
fn registered_codecs(encoder: bool) -> Vec<LinkedCodec> {
    use CodecFormat::*;
    let mut codecs = Vec::new();
    for (prefix, format) in [("h264", H264), ("hevc", H265), ("av1", AV1)] {
        let suffixes: &[&str] = if encoder {
            &[
                "nvenc",
                "amf",
                "qsv",
                "vaapi",
                "videotoolbox",
                "mediacodec",
                "mf",
            ]
        } else {
            &["cuvid", "qsv", "mediacodec"]
        };
        for suffix in suffixes {
            let name = format!("{prefix}_{suffix}");
            if hwcodec::ffmpeg::codec_registered(&name, encoder) {
                codecs.push(LinkedCodec { name, format });
            }
        }
        if !encoder && hwcodec::ffmpeg::codec_registered(prefix, false) {
            codecs.push(LinkedCodec {
                name: prefix.to_owned(),
                format,
            });
        }
    }
    let software: &[(&str, CodecFormat)] = if encoder {
        &[
            ("libx264", H264),
            ("libx264rgb", H264),
            ("libx265", H265),
            ("libopenh264", H264),
            ("libkvazaar", H265),
        ]
    } else {
        &[("libopenh264", H264)]
    };
    for &(name, format) in software {
        if hwcodec::ffmpeg::codec_registered(name, encoder) {
            codecs.push(LinkedCodec {
                name: name.to_owned(),
                format,
            });
        }
    }
    codecs
}

#[cfg(any(feature = "hwcodec", test))]
fn optional_decoder_check(
    name: &str,
    format: CodecFormat,
    registered: bool,
    usable: bool,
) -> CodecCheck {
    if !registered {
        CodecCheck {
            name: name.to_owned(),
            format,
            status: CodecCheckStatus::NotBuilt,
            detail: None,
        }
    } else {
        check(
            name,
            format,
            if usable {
                Ok(())
            } else {
                Err("Registered decoder failed the real-frame probe".to_owned())
            },
        )
    }
}

pub fn verify() -> CodecIntegrationReport {
    let core = [
        ("libvpx-vp8", CodecFormat::VP8),
        ("libvpx-vp9", CodecFormat::VP9),
        ("libaom-av1", CodecFormat::AV1),
    ]
    .iter()
    .copied()
    .map(|(name, format)| {
        check(
            name,
            format,
            core_roundtrip(format).map_err(|e| e.to_string()),
        )
    })
    .collect();
    #[cfg(feature = "hwcodec")]
    {
        let encoders = registered_codecs(true);
        let decoders = registered_codecs(false);
        let usable = hwcodec::ffmpeg_ram::decode::Decoder::available_software_decoders();
        let optional = [("h264", CodecFormat::H264), ("hevc", CodecFormat::H265)]
            .iter()
            .copied()
            .map(|(name, format)| {
                optional_decoder_check(
                    name,
                    format,
                    decoders.iter().any(|c| c.name == name),
                    usable.iter().any(|c| c.name == name),
                )
            })
            .collect();
        CodecIntegrationReport::from_checks(true, encoders, decoders, core, optional)
    }
    #[cfg(not(feature = "hwcodec"))]
    CodecIntegrationReport::from_checks(false, Vec::new(), Vec::new(), core, Vec::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn core() -> Vec<CodecCheck> {
        [CodecFormat::VP8, CodecFormat::VP9, CodecFormat::AV1]
            .iter()
            .copied()
            .map(|format| check("core", format, Ok(())))
            .collect()
    }

    #[test]
    fn hardware_only_build_does_not_require_software_h26x() {
        let report = CodecIntegrationReport::from_checks(
            true,
            Vec::new(),
            vec![LinkedCodec {
                name: "h264_cuvid".into(),
                format: CodecFormat::H264,
            }],
            core(),
            vec![
                optional_decoder_check("h264", CodecFormat::H264, false, false),
                optional_decoder_check("hevc", CodecFormat::H265, false, false),
            ],
        );
        assert!(report.passed);
        assert!(report.warnings.is_empty());
        assert_eq!(
            report.optional_software_decoders[0].status,
            CodecCheckStatus::NotBuilt
        );
    }

    #[test]
    fn broken_present_optional_decoder_fails() {
        let report = CodecIntegrationReport::from_checks(
            true,
            Vec::new(),
            Vec::new(),
            core(),
            vec![optional_decoder_check(
                "hevc",
                CodecFormat::H265,
                true,
                false,
            )],
        );
        assert!(!report.passed);
    }

    #[test]
    fn software_only_build_and_headless_hwcodec_build_pass_core_checks() {
        for hwcodec in [false, true] {
            assert!(
                CodecIntegrationReport::from_checks(
                    hwcodec,
                    Vec::new(),
                    Vec::new(),
                    core(),
                    Vec::new()
                )
                .passed
            );
        }
    }

    #[test]
    fn missing_or_failed_core_codec_fails() {
        let mut checks = core();
        checks.pop();
        assert!(
            !CodecIntegrationReport::from_checks(true, Vec::new(), Vec::new(), checks, Vec::new())
                .passed
        );
        let mut checks = core();
        checks[0].status = CodecCheckStatus::Failed;
        assert!(
            !CodecIntegrationReport::from_checks(true, Vec::new(), Vec::new(), checks, Vec::new())
                .passed
        );
    }

    #[test]
    fn linked_software_encoder_or_decoder_emits_private_build_warning() {
        for encoder in [false, true] {
            let codec = LinkedCodec {
                name: if encoder { "libx264" } else { "h264" }.into(),
                format: CodecFormat::H264,
            };
            let (encoders, decoders) = if encoder {
                (vec![codec], Vec::new())
            } else {
                (Vec::new(), vec![codec])
            };
            let report =
                CodecIntegrationReport::from_checks(true, encoders, decoders, core(), Vec::new());
            assert!(report.passed);
            assert_eq!(report.warnings, [PRIVATE_CODEC_WARNING]);
            let json = hbb_common::serde_json::to_value(report).unwrap();
            assert_eq!(json["report_version"], 2);
            assert!(json.get("missing_expected_decoders").is_none());
        }
    }

    #[test]
    fn linked_core_codecs_encode_and_decode_a_real_frame() {
        for format in [CodecFormat::VP8, CodecFormat::VP9, CodecFormat::AV1] {
            core_roundtrip(format).unwrap();
        }
    }
}
