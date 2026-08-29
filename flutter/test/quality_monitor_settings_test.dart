import 'package:flutter_hbb/common/quality_monitor_settings.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quality monitor fading is disabled by default', () {
    expect(QualityMonitorFadeSettings.defaults.opacityPercent, 100);
    expect(QualityMonitorFadeSettings.defaults.enabled, isFalse);
    expect(QualityMonitorFadeSettings.defaults.delayMs,
        kDefaultQualityMonitorDimDelayMs);
    expect(QualityMonitorFadeSettings.defaults.durationMs,
        kDefaultQualityMonitorDimDurationMs);
  });

  test('stored quality monitor settings clamp independently', () {
    final settings = QualityMonitorFadeSettings.fromStored(
      opacityPercent: '5',
      delayMs: '9000',
      durationMs: '750',
    );

    expect(settings.opacityPercent, kMinQualityMonitorInactiveOpacityPercent);
    expect(settings.delayMs, kMaxQualityMonitorDimDelayMs);
    expect(settings.durationMs, 750);
    expect(settings.enabled, isTrue);

    final disabled = settings.copyWith(opacityPercent: 100);
    expect(disabled.enabled, isFalse);
    expect(disabled.delayMs, settings.delayMs);
    expect(disabled.durationMs, settings.durationMs);
  });
}
