import 'dart:async';

import 'package:flutter_hbb/common/quality_monitor_settings.dart';
import 'package:flutter_hbb/common/remote_toolbar_settings.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quality monitor fading is disabled by default', () {
    expect(QualityMonitorFadeSettings.defaults.opacityPercent, 100);
    expect(QualityMonitorFadeSettings.defaults.enabled, isFalse);
    expect(
      QualityMonitorFadeSettings.defaults.delayMs,
      kDefaultQualityMonitorDimDelayMs,
    );
    expect(
      QualityMonitorFadeSettings.defaults.durationMs,
      kDefaultQualityMonitorDimDurationMs,
    );
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

  test('quality monitor registry is unique and codecs round-trip', () {
    final keys = QualityMonitorSettingsRegistry.all
        .map((setting) => setting.key)
        .toList();
    expect(keys.toSet(), hasLength(keys.length));
    for (final setting in QualityMonitorSettingsRegistry.all) {
      final value = setting.codec.decode('');
      expect(setting.codec.decode(setting.codec.encode(value)), value);
    }
  });

  test('repository publishes external changes without polling', () async {
    final storage = <String, String>{
      kOptionQualityMonitorInactiveOpacityPercent: '100',
      kOptionQualityMonitorDimDelayMs: '1000',
      kOptionQualityMonitorDimDurationMs: '3000',
    };
    final defaults = UserDefaultSettingsRepository(
      (key) => storage[key] ?? '',
      (key, value) async => storage[key] = value,
    );
    final repository = QualityMonitorSettingsRepository(defaults);
    final changed = Completer<QualityMonitorFadeSettings>();
    final subscription = repository.watch().listen((settings) {
      if (!changed.isCompleted) changed.complete(settings);
    });

    storage[kOptionQualityMonitorInactiveOpacityPercent] = '40';
    defaults.notifyExternal(kOptionQualityMonitorInactiveOpacityPercent);

    expect((await changed.future).opacityPercent, 40);
    await subscription.cancel();
    await defaults.dispose();
  });
}
