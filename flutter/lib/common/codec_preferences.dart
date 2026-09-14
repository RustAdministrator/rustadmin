class CodecChoice {
  const CodecChoice(this.value, this.label, this.capability);
  final String value;
  final String label;
  final String? capability;

  bool enabled(Map<String, dynamic> capabilities) =>
      capability == null || capabilities[capability] == true;
}

const encoderCodecChoices = [
  CodecChoice('auto', 'Auto', null),
  CodecChoice('vp8', 'VP8', 'encVp8'),
  CodecChoice('vp9', 'VP9', 'encVp9'),
  CodecChoice('av1', 'AV1', 'encAv1'),
  CodecChoice('h264', 'H264', 'encH264'),
  CodecChoice('h264-hq', 'H264 HQ', 'encH264Hq'),
  CodecChoice('h265', 'H265', 'encH265'),
  CodecChoice('h265-hq', 'H265 HQ', 'encH265Hq'),
];

const decoderCodecChoices = [
  CodecChoice('auto', 'Auto', null),
  CodecChoice('vp8', 'VP8 SW', 'vp8'),
  CodecChoice('vp9', 'VP9 SW', 'vp9'),
  CodecChoice('av1', 'AV1 Auto', 'av1'),
  CodecChoice('av1-hw', 'AV1 HW', 'av1Hw'),
  CodecChoice('av1-sw', 'AV1 SW', 'av1Sw'),
  CodecChoice('h264', 'H264 Auto', 'h264'),
  CodecChoice('h264-hw', 'H264 HW', 'h264Hw'),
  CodecChoice('h264-sw', 'H264 SW', 'h264Sw'),
  CodecChoice('h265', 'H265 Auto', 'h265'),
  CodecChoice('h265-hw', 'H265 HW', 'h265Hw'),
  CodecChoice('h265-sw', 'H265 SW', 'h265Sw'),
];

String normalizeDecoderPreference(String value) => switch (value) {
  'h264-hq' => 'h264',
  'h265-hq' => 'h265',
  _ =>
    decoderCodecChoices.any((choice) => choice.value == value) ? value : 'auto',
};

const encoderCodecPreferenceKey = 'encoder-codec-preference';
