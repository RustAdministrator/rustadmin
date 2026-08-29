import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/quality_monitor_window.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('detached quality monitor snapshot round-trips bounded data', () {
    final source = QualityMonitorData()
      ..speed = '42KB/s'
      ..codecFormat = 'H265'
      ..quicReassemblyDrops = '3'
      ..movieFallbackReason = 'x' * 2000;

    final encoded = qualityMonitorDataToWindowJson(source);
    final decoded = qualityMonitorDataFromWindowJson(encoded);

    expect(decoded.speed, source.speed);
    expect(decoded.codecFormat, source.codecFormat);
    expect(decoded.quicReassemblyDrops, source.quicReassemblyDrops);
    expect(decoded.movieFallbackReason, hasLength(1024));
  });

  test('detached model applies only normalized display state', () {
    final model = QualityMonitorModel.detached();
    addTearDown(model.dispose);

    model.applyDetachedSnapshot(
      details: 'invalid',
      data: QualityMonitorData()..fps = '60',
    );

    expect(model.show, isTrue);
    expect(model.position, kQualityMonitorPositionDetached);
    expect(model.details, kQualityMonitorDetailsBasic);
    expect(model.data.fps, '60');
  });
}
