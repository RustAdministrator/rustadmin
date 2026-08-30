import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';

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
      opacity: _normalized(
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
    return QualityMonitorFadeSettings.fromStored(
      opacityPercent: bind.mainGetUserDefaultOption(
        key: kOptionQualityMonitorInactiveOpacityPercent,
      ),
      delayMs: bind.mainGetUserDefaultOption(
        key: kOptionQualityMonitorDimDelayMs,
      ),
      durationMs: bind.mainGetUserDefaultOption(
        key: kOptionQualityMonitorDimDurationMs,
      ),
    );
  }

  QualityMonitorFadeSettings copyWith({
    int? opacityPercent,
    int? delayMs,
    int? durationMs,
  }) {
    return QualityMonitorFadeSettings(
      opacity: (opacityPercent ?? this.opacityPercent)
              .clamp(
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
        milliseconds: (durationMs ?? this.durationMs).clamp(
          kMinQualityMonitorDimDurationMs,
          kMaxQualityMonitorDimDurationMs,
        ).toInt(),
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
