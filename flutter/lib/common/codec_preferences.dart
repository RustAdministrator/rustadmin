class CodecChoice {
  const CodecChoice(
    this.value,
    this.label,
    this.capability, {
    this.requestCapability,
    this.optionalSoftware = false,
  });
  final String value;
  final String label;
  final String? capability;
  final String? requestCapability;
  final bool optionalSoftware;

  bool enabled(Map<String, dynamic> capabilities) =>
      (capability == null || capabilities[capability] == true) &&
      // Defaults have no remote host yet; a live session supplies this flag.
      (requestCapability == null || capabilities[requestCapability] != false);

  bool visible(Map<String, dynamic> capabilities) =>
      !optionalSoftware ||
      (capabilities['local-$capability'] ?? capabilities[capability]) == true;
}

const encoderCodecChoices = [
  CodecChoice('auto', 'Auto', null),
  CodecChoice('vp8', 'VP8 SW', 'encVp8'),
  CodecChoice('vp9', 'VP9 SW', 'encVp9'),
  CodecChoice('av1', 'AV1 Auto', 'encAv1'),
  CodecChoice('av1-hw', 'AV1 HW', 'encAv1Hw'),
  CodecChoice('av1-sw', 'AV1 SW', 'encAv1Sw'),
  CodecChoice('h264-sw', 'H264 SW', 'encH264Sw', optionalSoftware: true),
  CodecChoice('h264', 'H264 HW', 'encH264Hw'),
  CodecChoice('h264-hq', 'H264 HQ HW', 'encH264Hq'),
  CodecChoice('h265-sw', 'H265 SW', 'encH265Sw', optionalSoftware: true),
  CodecChoice('h265', 'H265 HW', 'encH265Hw'),
  CodecChoice('h265-hq', 'H265 HQ HW', 'encH265Hq'),
];

String normalizeEncoderPreference(String value) => switch (value) {
  'h264-hw' => 'h264',
  'h265-hw' => 'h265',
  _ =>
    encoderCodecChoices.any((choice) => choice.value == value) ? value : 'auto',
};

// Settings explicitly label local hardware; the toolbar retains its short
// H264/H265 labels and the independent remote HQ request aliases.
String decoderSettingsLabel(CodecChoice choice) => switch (choice.value) {
  'h264' || 'h264-hq' || 'h265' || 'h265-hq' => '${choice.label} HW',
  _ => choice.label,
};

const decoderCodecChoices = [
  CodecChoice('auto', 'Auto', null),
  CodecChoice('vp8', 'VP8 SW', 'vp8'),
  CodecChoice('vp9', 'VP9 SW', 'vp9'),
  CodecChoice('av1', 'AV1 Auto', 'av1'),
  CodecChoice('av1-hw', 'AV1 HW', 'av1Hw'),
  CodecChoice('av1-sw', 'AV1 SW', 'av1Sw'),
  CodecChoice('h264-sw', 'H264 SW', 'h264Sw', optionalSoftware: true),
  CodecChoice(
    'h264-hq-sw',
    'H264 HQ SW',
    'h264Sw',
    requestCapability: 'requestH264Hq',
    optionalSoftware: true,
  ),
  CodecChoice('h264', 'H264', 'h264Hw'),
  CodecChoice(
    'h264-hq',
    'H264 HQ',
    'h264Hw',
    requestCapability: 'requestH264Hq',
  ),
  CodecChoice('h265-sw', 'H265 SW', 'h265Sw', optionalSoftware: true),
  CodecChoice(
    'h265-hq-sw',
    'H265 HQ SW',
    'h265Sw',
    requestCapability: 'requestH265Hq',
    optionalSoftware: true,
  ),
  CodecChoice('h265', 'H265', 'h265Hw'),
  CodecChoice(
    'h265-hq',
    'H265 HQ',
    'h265Hw',
    requestCapability: 'requestH265Hq',
  ),
];

String normalizeDecoderPreference(String value) => switch (value) {
  'h264-hw' => 'h264',
  'h265-hw' => 'h265',
  _ =>
    decoderCodecChoices.any((choice) => choice.value == value) ? value : 'auto',
};

Iterable<CodecChoice> visibleDecoderCodecChoices(
  Map<String, dynamic> capabilities, {
  String? selected,
}) => decoderCodecChoices.where(
  (choice) => choice.visible(capabilities) || choice.value == selected,
);

const encoderCodecPreferenceKey = 'encoder-codec-preference';
