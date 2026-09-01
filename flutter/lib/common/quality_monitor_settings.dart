import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/consts.dart';

import 'remote_toolbar_settings.dart';

abstract final class QualityMonitorSettingsRegistry {
  static const opacity = UserDefaultSetting<int>(
    key: kOptionQualityMonitorInactiveOpacityPercent,
    codec: IntRangeCodec(
      defaultValue: kDefaultQualityMonitorInactiveOpacityPercent,
      min: kMinQualityMonitorInactiveOpacityPercent,
      max: kMaxQualityMonitorInactiveOpacityPercent,
    ),
  );
  static const delay = UserDefaultSetting<int>(
    key: kOptionQualityMonitorDimDelayMs,
    codec: IntRangeCodec(
      defaultValue: kDefaultQualityMonitorDimDelayMs,
      min: kMinQualityMonitorDimDelayMs,
      max: kMaxQualityMonitorDimDelayMs,
    ),
  );
  static const duration = UserDefaultSetting<int>(
    key: kOptionQualityMonitorDimDurationMs,
    codec: IntRangeCodec(
      defaultValue: kDefaultQualityMonitorDimDurationMs,
      min: kMinQualityMonitorDimDurationMs,
      max: kMaxQualityMonitorDimDurationMs,
    ),
  );

  static const all = <UserDefaultSetting<dynamic>>[opacity, delay, duration];
}

@immutable
class QualityMonitorFadeSettings {
  const QualityMonitorFadeSettings({
    required this.opacity,
    required this.delay,
    required this.duration,
  });

  static const defaults = QualityMonitorFadeSettings(
    opacity: kDefaultQualityMonitorInactiveOpacityPercent / 100.0,
    delay: Duration(milliseconds: kDefaultQualityMonitorDimDelayMs),
    duration: Duration(milliseconds: kDefaultQualityMonitorDimDurationMs),
  );

  final double opacity;
  final Duration delay;
  final Duration duration;

  int get opacityPercent => (opacity * 100).round();
  int get delayMs => delay.inMilliseconds;
  int get durationMs => duration.inMilliseconds;
  bool get enabled => opacityPercent < kMaxQualityMonitorInactiveOpacityPercent;

  factory QualityMonitorFadeSettings.fromStored({
    required String opacityPercent,
    required String delayMs,
    required String durationMs,
    QualityMonitorFadeSettings fallback = defaults,
  }) {
    return QualityMonitorFadeSettings(
      opacity:
          _normalized(
            opacityPercent,
            fallback.opacityPercent,
            kMinQualityMonitorInactiveOpacityPercent,
            kMaxQualityMonitorInactiveOpacityPercent,
          ) /
          100.0,
      delay: Duration(
        milliseconds: _normalized(
          delayMs,
          fallback.delayMs,
          kMinQualityMonitorDimDelayMs,
          kMaxQualityMonitorDimDelayMs,
        ),
      ),
      duration: Duration(
        milliseconds: _normalized(
          durationMs,
          fallback.durationMs,
          kMinQualityMonitorDimDurationMs,
          kMaxQualityMonitorDimDurationMs,
        ),
      ),
    );
  }

  factory QualityMonitorFadeSettings.fromUserDefaults() {
    return qualityMonitorSettings.read();
  }

  QualityMonitorFadeSettings copyWith({
    int? opacityPercent,
    int? delayMs,
    int? durationMs,
  }) {
    return QualityMonitorFadeSettings(
      opacity:
          (opacityPercent ?? this.opacityPercent).clamp(
            kMinQualityMonitorInactiveOpacityPercent,
            kMaxQualityMonitorInactiveOpacityPercent,
          ) /
          100.0,
      delay: Duration(
        milliseconds: (delayMs ?? this.delayMs)
            .clamp(kMinQualityMonitorDimDelayMs, kMaxQualityMonitorDimDelayMs)
            .toInt(),
      ),
      duration: Duration(
        milliseconds: (durationMs ?? this.durationMs)
            .clamp(
              kMinQualityMonitorDimDurationMs,
              kMaxQualityMonitorDimDurationMs,
            )
            .toInt(),
      ),
    );
  }

  static int _normalized(String raw, int fallback, int min, int max) {
    return (int.tryParse(raw) ?? fallback).clamp(min, max).toInt();
  }

  @override
  bool operator ==(Object other) {
    return other is QualityMonitorFadeSettings &&
        opacity == other.opacity &&
        delay == other.delay &&
        duration == other.duration;
  }

  @override
  int get hashCode => Object.hash(opacity, delay, duration);
}

class QualityMonitorSettingsRepository {
  const QualityMonitorSettingsRepository(this._userDefaults);

  final UserDefaultSettingsRepository _userDefaults;
  static final _keys = QualityMonitorSettingsRegistry.all
      .map((setting) => setting.key)
      .toSet();

  QualityMonitorFadeSettings read() => QualityMonitorFadeSettings(
    opacity: _userDefaults.read(QualityMonitorSettingsRegistry.opacity) / 100,
    delay: Duration(
      milliseconds: _userDefaults.read(QualityMonitorSettingsRegistry.delay),
    ),
    duration: Duration(
      milliseconds: _userDefaults.read(QualityMonitorSettingsRegistry.duration),
    ),
  );

  Stream<QualityMonitorFadeSettings> watch() =>
      _userDefaults.changes.where(_keys.contains).map((_) => read()).distinct();

  Future<void> write(QualityMonitorFadeSettings settings) async {
    await _userDefaults.write(
      QualityMonitorSettingsRegistry.opacity,
      settings.opacityPercent,
    );
    await _userDefaults.write(
      QualityMonitorSettingsRegistry.delay,
      settings.delayMs,
    );
    await _userDefaults.write(
      QualityMonitorSettingsRegistry.duration,
      settings.durationMs,
    );
  }
}

final qualityMonitorSettings = QualityMonitorSettingsRepository(
  remoteUserDefaultSettings,
);
