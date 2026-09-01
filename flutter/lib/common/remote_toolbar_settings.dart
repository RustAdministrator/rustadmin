import 'dart:async';

import '../consts.dart';
import '../models/platform_model.dart';

abstract interface class SettingCodec<T> {
  T decode(String raw);
  String encode(T value);
}

enum SettingScope { appLocal, userDefault, peer, liveSession }

enum SettingApplyMode { live, nextSession, restartRequired }

abstract interface class SettingDefinition<T> {
  String get key;
  SettingCodec<T> get codec;
  SettingScope get scope;
  SettingApplyMode get applyMode;
}

class IntRangeCodec implements SettingCodec<int> {
  const IntRangeCodec({
    required this.defaultValue,
    required this.min,
    required this.max,
  });

  final int defaultValue;
  final int min;
  final int max;

  @override
  int decode(String raw) =>
      (int.tryParse(raw) ?? defaultValue).clamp(min, max).toInt();

  @override
  String encode(int value) => value.clamp(min, max).toInt().toString();
}

class DoubleRangeCodec implements SettingCodec<double> {
  const DoubleRangeCodec({
    required this.defaultValue,
    required this.min,
    required this.max,
  });

  final double defaultValue;
  final double min;
  final double max;

  @override
  double decode(String raw) =>
      (double.tryParse(raw) ?? defaultValue).clamp(min, max).toDouble();

  @override
  String encode(double value) => value.clamp(min, max).toString();
}

class BoolOptionCodec implements SettingCodec<bool> {
  const BoolOptionCodec({this.defaultValue = false, this.falseValue = ''});

  final bool defaultValue;
  final String falseValue;

  @override
  bool decode(String raw) => raw.isEmpty ? defaultValue : raw == 'Y';

  @override
  String encode(bool value) => value ? 'Y' : falseValue;
}

class AllowedStringCodec implements SettingCodec<String> {
  const AllowedStringCodec({
    required this.defaultValue,
    required this.allowedValues,
  });

  final String defaultValue;
  final Set<String> allowedValues;

  @override
  String decode(String raw) => allowedValues.contains(raw) ? raw : defaultValue;

  @override
  String encode(String value) => decode(value);
}

class UserDefaultSetting<T> implements SettingDefinition<T> {
  const UserDefaultSetting({
    required this.key,
    required this.codec,
    this.applyMode = SettingApplyMode.live,
  });

  @override
  final String key;
  @override
  final SettingCodec<T> codec;
  @override
  final SettingApplyMode applyMode;
  @override
  SettingScope get scope => SettingScope.userDefault;
}

abstract final class RemoteToolbarSettingsRegistry {
  static const revealZone = UserDefaultSetting<int>(
    key: kOptionRemoteToolbarRevealZonePx,
    codec: IntRangeCodec(
      defaultValue: kDefaultRemoteToolbarRevealZonePx,
      min: kMinRemoteToolbarRevealZonePx,
      max: kMaxRemoteToolbarRevealZonePx,
    ),
  );
  static const hideDelay = UserDefaultSetting<int>(
    key: kOptionRemoteToolbarHideDelayMs,
    codec: IntRangeCodec(
      defaultValue: kDefaultRemoteToolbarHideDelayMs,
      min: kMinRemoteToolbarHideDelayMs,
      max: kMaxRemoteToolbarHideDelayMs,
    ),
  );
  static const pinnedOpacity = UserDefaultSetting<int>(
    key: kOptionRemoteToolbarPinnedOpacityPercent,
    codec: IntRangeCodec(
      defaultValue: kDefaultRemoteToolbarPinnedOpacityPercent,
      min: kMinRemoteToolbarPinnedOpacityPercent,
      max: kMaxRemoteToolbarPinnedOpacityPercent,
    ),
  );
  static const pinnedDimDelay = UserDefaultSetting<int>(
    key: kOptionRemoteToolbarPinnedDimDelayMs,
    codec: IntRangeCodec(
      defaultValue: kDefaultRemoteToolbarPinnedDimDelayMs,
      min: kMinRemoteToolbarPinnedDimDelayMs,
      max: kMaxRemoteToolbarPinnedDimDelayMs,
    ),
  );
  static const pinnedDimDuration = UserDefaultSetting<int>(
    key: kOptionRemoteToolbarPinnedDimDurationMs,
    codec: IntRangeCodec(
      defaultValue: kDefaultRemoteToolbarPinnedDimDurationMs,
      min: kMinRemoteToolbarPinnedDimDurationMs,
      max: kMaxRemoteToolbarPinnedDimDurationMs,
    ),
  );
  static const scrollStyle = UserDefaultSetting<String>(
    key: kOptionScrollStyle,
    codec: AllowedStringCodec(
      defaultValue: kRemoteScrollStyleAuto,
      allowedValues: {
        kRemoteScrollStyleAuto,
        kRemoteScrollStyleBar,
        kRemoteScrollStyleEdge,
        kRemoteScrollStyleEdgeAcceleration,
      },
    ),
  );
  static const edgeThickness = UserDefaultSetting<int>(
    key: kOptionEdgeScrollEdgeThickness,
    codec: IntRangeCodec(
      defaultValue: kDefaultEdgeScrollEdgeThickness,
      min: kMinEdgeScrollEdgeThickness,
      max: kMaxEdgeScrollEdgeThickness,
    ),
  );
  static const trackpadSpeed = UserDefaultSetting<int>(
    key: kKeyTrackpadSpeed,
    codec: IntRangeCodec(
      defaultValue: kDefaultTrackpadSpeed,
      min: kMinTrackpadSpeed,
      max: kMaxTrackpadSpeed,
    ),
  );

  static const all = <UserDefaultSetting<dynamic>>[
    revealZone,
    hideDelay,
    pinnedOpacity,
    pinnedDimDelay,
    pinnedDimDuration,
    scrollStyle,
    edgeThickness,
    trackpadSpeed,
  ];

  static bool hasUniqueKeys() =>
      all.map((setting) => setting.key).toSet().length == all.length;
}

typedef UserDefaultReader = String Function(String key);
typedef UserDefaultWriter = Future<void> Function(String key, String value);

class UserDefaultSettingsRepository {
  UserDefaultSettingsRepository(this._readRaw, this._writeRaw);

  final UserDefaultReader _readRaw;
  final UserDefaultWriter _writeRaw;
  final _changes = StreamController<String>.broadcast(sync: true);

  Stream<String> get changes => _changes.stream;

  T read<T>(UserDefaultSetting<T> setting) =>
      setting.codec.decode(_readRaw(setting.key));

  Future<void> write<T>(UserDefaultSetting<T> setting, T value) async {
    await _writeRaw(setting.key, setting.codec.encode(value));
    notifyExternal(setting.key);
  }

  void notifyExternal(String key) {
    if (!_changes.isClosed) _changes.add(key);
  }

  Future<void> dispose() => _changes.close();
}

class RemoteToolbarSettingsSnapshot {
  const RemoteToolbarSettingsSnapshot({
    required this.revealZonePx,
    required this.hideDelayMs,
    required this.pinnedOpacityPercent,
    required this.pinnedDimDelayMs,
    required this.pinnedDimDurationMs,
    required this.scrollStyle,
    required this.edgeThickness,
    required this.trackpadSpeed,
  });

  final int revealZonePx;
  final int hideDelayMs;
  final int pinnedOpacityPercent;
  final int pinnedDimDelayMs;
  final int pinnedDimDurationMs;
  final String scrollStyle;
  final int edgeThickness;
  final int trackpadSpeed;

  double get pinnedOpacity => pinnedOpacityPercent / 100.0;

  @override
  bool operator ==(Object other) =>
      other is RemoteToolbarSettingsSnapshot &&
      other.revealZonePx == revealZonePx &&
      other.hideDelayMs == hideDelayMs &&
      other.pinnedOpacityPercent == pinnedOpacityPercent &&
      other.pinnedDimDelayMs == pinnedDimDelayMs &&
      other.pinnedDimDurationMs == pinnedDimDurationMs &&
      other.scrollStyle == scrollStyle &&
      other.edgeThickness == edgeThickness &&
      other.trackpadSpeed == trackpadSpeed;

  @override
  int get hashCode => Object.hash(
    revealZonePx,
    hideDelayMs,
    pinnedOpacityPercent,
    pinnedDimDelayMs,
    pinnedDimDurationMs,
    scrollStyle,
    edgeThickness,
    trackpadSpeed,
  );
}

class RemoteToolbarSettingsRepository {
  const RemoteToolbarSettingsRepository(this.userDefaults);

  final UserDefaultSettingsRepository userDefaults;
  static final _keys = RemoteToolbarSettingsRegistry.all
      .map((setting) => setting.key)
      .toSet();

  RemoteToolbarSettingsSnapshot read() => RemoteToolbarSettingsSnapshot(
    revealZonePx: userDefaults.read(RemoteToolbarSettingsRegistry.revealZone),
    hideDelayMs: userDefaults.read(RemoteToolbarSettingsRegistry.hideDelay),
    pinnedOpacityPercent: userDefaults.read(
      RemoteToolbarSettingsRegistry.pinnedOpacity,
    ),
    pinnedDimDelayMs: userDefaults.read(
      RemoteToolbarSettingsRegistry.pinnedDimDelay,
    ),
    pinnedDimDurationMs: userDefaults.read(
      RemoteToolbarSettingsRegistry.pinnedDimDuration,
    ),
    scrollStyle: userDefaults.read(RemoteToolbarSettingsRegistry.scrollStyle),
    edgeThickness: userDefaults.read(
      RemoteToolbarSettingsRegistry.edgeThickness,
    ),
    trackpadSpeed: userDefaults.read(
      RemoteToolbarSettingsRegistry.trackpadSpeed,
    ),
  );

  Stream<RemoteToolbarSettingsSnapshot> watch() =>
      userDefaults.changes.where(_keys.contains).map((_) => read()).distinct();

  Future<void> write<T>(UserDefaultSetting<T> setting, T value) =>
      userDefaults.write(setting, value);
}

final remoteUserDefaultSettings = UserDefaultSettingsRepository(
  (key) => bind.mainGetUserDefaultOption(key: key),
  (key, value) => bind.mainSetUserDefaultOption(key: key, value: value),
);

final remoteToolbarSettings = RemoteToolbarSettingsRepository(
  remoteUserDefaultSettings,
);
