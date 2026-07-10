import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/model.dart';

void main() {
  test('quality monitor identifies NVENC p5 H264 and H265 as HQ', () {
    final data = QualityMonitorData()
      ..encoderBackend = 'Hardware NVIDIA NVENC p5 via FFmpeg';

    data.codecFormat = 'H264';
    expect(data.codecLabel, 'H264 HQ');

    data.codecFormat = 'H265';
    expect(data.codecLabel, 'H265 HQ');
  });

  test('quality monitor does not infer HQ from codec or backend alone', () {
    final data = QualityMonitorData()..codecFormat = 'H265';
    expect(data.codecLabel, 'H265');

    data.encoderBackend = 'Hardware NVIDIA NVENC via FFmpeg';
    expect(data.codecLabel, 'H265');

    data.encoderBackend = 'Hardware NVIDIA NVENC p5 via FFmpeg';
    data.codecFormat = 'AV1';
    expect(data.codecLabel, 'AV1');
  });
}
