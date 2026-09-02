import 'package:flutter/foundation.dart';

import '../consts.dart';
import 'remote_toolbar_settings.dart';

class _DefaultViewStyleCodec implements SettingCodec<String> {
  const _DefaultViewStyleCodec();

  @override
  String decode(String raw) => switch (raw) {
    kRemoteViewStyleOriginal => kRemoteViewStyleOriginal,
    kRemoteViewStyleAdaptive => kRemoteViewStyleAdaptive,
    _ =>
      defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS
          ? kRemoteViewStyleAdaptive
          : kRemoteViewStyleOriginal,
  };

  @override
  String encode(String value) => decode(value);
}

class UserDefaultToggleSetting extends UserDefaultSetting<bool> {
  const UserDefaultToggleSetting({
    required this.label,
    required super.key,
    required super.codec,
    super.applyMode = SettingApplyMode.nextSession,
  });

  final String label;
}

abstract final class RemoteDisplaySettingsRegistry {
  static const viewStyle = UserDefaultSetting<String>(
    key: kOptionViewStyle,
    codec: _DefaultViewStyleCodec(),
    applyMode: SettingApplyMode.nextSession,
  );
  static const imageQuality = UserDefaultSetting<String>(
    key: kOptionImageQuality,
    codec: AllowedStringCodec(
      defaultValue: kRemoteImageQualityBalanced,
      allowedValues: {
        kRemoteImageQualityBest,
        kRemoteImageQualityBalanced,
        kRemoteImageQualityLow,
        kRemoteImageQualityCustom,
      },
    ),
    applyMode: SettingApplyMode.nextSession,
  );
  static const codecPreference = UserDefaultSetting<String>(
    key: kOptionCodecPreference,
    codec: AllowedStringCodec(
      defaultValue: 'auto',
      allowedValues: {
        'auto',
        'vp8',
        'vp9',
        'av1',
        'av1-hw',
        'h264',
        'h264-hq',
        'h265',
        'h265-hq',
      },
    ),
    applyMode: SettingApplyMode.nextSession,
  );
  static const customImageQuality = UserDefaultSetting<double>(
    key: 'custom_image_quality',
    codec: DoubleRangeCodec(defaultValue: kDefaultQuality, min: 10, max: 4095),
    applyMode: SettingApplyMode.nextSession,
  );
  static const customFps = UserDefaultSetting<double>(
    key: kOptionCustomFps,
    codec: DoubleRangeCodec(defaultValue: kDefaultFps, min: 5, max: 120),
    applyMode: SettingApplyMode.nextSession,
  );
  static const customFpsMode = UserDefaultSetting<String>(
    key: kOptionCustomFpsMode,
    codec: AllowedStringCodec(
      defaultValue: kCustomFpsModeAdaptive,
      allowedValues: {kCustomFpsModeAdaptive, kCustomFpsModeFixed},
    ),
    applyMode: SettingApplyMode.nextSession,
  );

  static const viewOnly = UserDefaultToggleSetting(
    label: 'View Mode',
    key: kOptionViewOnly,
    codec: BoolOptionCodec(),
  );
  static const showMonitorsToolbar = UserDefaultToggleSetting(
    label: 'show_monitors_tip',
    key: kKeyShowMonitorsToolbar,
    codec: BoolOptionCodec(),
    applyMode: SettingApplyMode.live,
  );
  static const collapseToolbar = UserDefaultToggleSetting(
    label: 'Collapse toolbar',
    key: kOptionCollapseToolbar,
    codec: BoolOptionCodec(),
  );
  static const showRemoteCursor = UserDefaultToggleSetting(
    label: 'Show remote cursor',
    key: kOptionShowRemoteCursor,
    codec: BoolOptionCodec(),
  );
  static const followRemoteCursor = UserDefaultToggleSetting(
    label: 'Follow remote cursor',
    key: kOptionFollowRemoteCursor,
    codec: BoolOptionCodec(),
  );
  static const followRemoteWindow = UserDefaultToggleSetting(
    label: 'Follow remote window focus',
    key: kOptionFollowRemoteWindow,
    codec: BoolOptionCodec(),
  );
  static const zoomCursor = UserDefaultToggleSetting(
    label: 'Zoom cursor',
    key: kOptionZoomCursor,
    codec: BoolOptionCodec(),
  );
  static const showQualityMonitor = UserDefaultToggleSetting(
    label: 'Show quality monitor',
    key: kOptionShowQualityMonitor,
    codec: BoolOptionCodec(),
  );
  static const disableAudio = UserDefaultToggleSetting(
    label: 'Mute',
    key: kOptionDisableAudio,
    codec: BoolOptionCodec(),
  );
  static const enableFileCopyPaste = UserDefaultToggleSetting(
    label: 'Enable file copy and paste',
    key: kOptionEnableFileCopyPaste,
    codec: BoolOptionCodec(defaultValue: true, falseValue: 'N'),
  );
  static const disableClipboard = UserDefaultToggleSetting(
    label: 'Disable clipboard',
    key: kOptionDisableClipboard,
    codec: BoolOptionCodec(),
  );
  static const lockAfterSessionEnd = UserDefaultToggleSetting(
    label: 'Lock after session end',
    key: kOptionLockAfterSessionEnd,
    codec: BoolOptionCodec(),
  );
  static const privacyMode = UserDefaultToggleSetting(
    label: 'Privacy mode',
    key: kOptionPrivacyMode,
    codec: BoolOptionCodec(),
  );
  static const i444 = UserDefaultToggleSetting(
    label: 'True color (4:4:4)',
    key: kOptionI444,
    codec: BoolOptionCodec(),
  );
  static const reverseMouseWheel = UserDefaultToggleSetting(
    label: 'Reverse mouse wheel',
    key: kKeyReverseMouseWheel,
    codec: BoolOptionCodec(),
    applyMode: SettingApplyMode.live,
  );
  static const swapMouseButtons = UserDefaultToggleSetting(
    label: 'swap-left-right-mouse',
    key: kOptionSwapLeftRightMouse,
    codec: BoolOptionCodec(),
  );
  static const displaysAsWindows = UserDefaultToggleSetting(
    label: 'Show displays as individual windows',
    key: kKeyShowDisplaysAsIndividualWindows,
    codec: BoolOptionCodec(),
  );
  static const useAllDisplays = UserDefaultToggleSetting(
    label: 'Use all my displays for the remote session',
    key: kKeyUseAllMyDisplaysForTheRemoteSession,
    codec: BoolOptionCodec(),
  );
  static const terminalPersistent = UserDefaultToggleSetting(
    label: 'Keep terminal sessions on disconnect',
    key: kOptionTerminalPersistent,
    codec: BoolOptionCodec(),
  );

  static const toggles = <UserDefaultToggleSetting>[
    viewOnly,
    showMonitorsToolbar,
    collapseToolbar,
    showRemoteCursor,
    followRemoteCursor,
    followRemoteWindow,
    zoomCursor,
    showQualityMonitor,
    disableAudio,
    enableFileCopyPaste,
    disableClipboard,
    lockAfterSessionEnd,
    privacyMode,
    i444,
    reverseMouseWheel,
    swapMouseButtons,
    displaysAsWindows,
    useAllDisplays,
    terminalPersistent,
  ];

  static const all = <UserDefaultSetting<dynamic>>[
    viewStyle,
    imageQuality,
    codecPreference,
    customImageQuality,
    customFps,
    customFpsMode,
    ...toggles,
  ];

  static List<UserDefaultToggleSetting> visibleToggles({
    required bool desktop,
    required bool webDesktop,
  }) => [
    viewOnly,
    showMonitorsToolbar,
    if (desktop || webDesktop) collapseToolbar,
    showRemoteCursor,
    followRemoteCursor,
    followRemoteWindow,
    if (desktop || webDesktop) zoomCursor,
    showQualityMonitor,
    disableAudio,
    if (desktop) enableFileCopyPaste,
    disableClipboard,
    lockAfterSessionEnd,
    privacyMode,
    i444,
    reverseMouseWheel,
    swapMouseButtons,
    if (desktop) displaysAsWindows,
    if (desktop) useAllDisplays,
    terminalPersistent,
  ];
}

class RemoteDisplaySettingsRepository {
  const RemoteDisplaySettingsRepository(this._userDefaults);

  final UserDefaultSettingsRepository _userDefaults;

  T read<T>(UserDefaultSetting<T> setting) => _userDefaults.read(setting);

  Future<void> write<T>(UserDefaultSetting<T> setting, T value) =>
      _userDefaults.write(setting, value);

  Stream<T> watch<T>(UserDefaultSetting<T> setting) => _userDefaults.changes
      .where((key) => key == setting.key)
      .map((_) => read(setting))
      .distinct();

  Stream<String> watchKeys(Iterable<UserDefaultSetting<dynamic>> settings) {
    final keys = settings.map((setting) => setting.key).toSet();
    return _userDefaults.changes.where(keys.contains);
  }
}

final remoteDisplaySettings = RemoteDisplaySettingsRepository(
  remoteUserDefaultSettings,
);
