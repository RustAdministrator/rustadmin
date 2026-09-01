import '../consts.dart';
import 'package:uuid/uuid.dart';
import '../models/platform_model.dart';
import 'remote_toolbar_settings.dart';

class PeerOptionSetting<T> implements SettingDefinition<T> {
  const PeerOptionSetting({
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
  SettingScope get scope => SettingScope.peer;
}

class AppLocalSetting<T> implements SettingDefinition<T> {
  const AppLocalSetting({
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
  SettingScope get scope => SettingScope.appLocal;
}

class LiveSessionToggleSetting implements SettingDefinition<bool> {
  const LiveSessionToggleSetting(this.key);

  @override
  final String key;
  @override
  SettingCodec<bool> get codec => const BoolOptionCodec();
  @override
  SettingApplyMode get applyMode => SettingApplyMode.live;
  @override
  SettingScope get scope => SettingScope.liveSession;
}

class _CaptureBackendCodec implements SettingCodec<String> {
  const _CaptureBackendCodec();

  @override
  String decode(String raw) => switch (raw) {
    'dxgi' => 'dxgi',
    'wgc' => 'wgc',
    'winmag' => 'winmag',
    'gdi' => 'gdi',
    _ => 'auto',
  };

  @override
  String encode(String value) => decode(value) == 'auto' ? '' : decode(value);
}

class _QualityPositionCodec implements SettingCodec<String> {
  const _QualityPositionCodec();

  @override
  String decode(String raw) => normalizeQualityMonitorPosition(raw);

  @override
  String encode(String value) => decode(value);
}

class _QualityDetailsCodec implements SettingCodec<String> {
  const _QualityDetailsCodec();

  @override
  String decode(String raw) => normalizeQualityMonitorDetails(raw);

  @override
  String encode(String value) => decode(value);
}

class _StoredStringCodec implements SettingCodec<String> {
  const _StoredStringCodec({this.maxLength = 4096});

  final int maxLength;

  @override
  String decode(String raw) => raw.length <= maxLength ? raw : '';

  @override
  String encode(String value) => decode(value);
}

class _PresenceBoolCodec implements SettingCodec<bool> {
  const _PresenceBoolCodec();

  @override
  bool decode(String raw) => raw.isNotEmpty;

  @override
  String encode(bool value) => value ? 'Y' : '';
}

class _SignedFpsCodec implements SettingCodec<double> {
  const _SignedFpsCodec();

  @override
  double decode(String raw) =>
      (double.tryParse(raw)?.abs() ?? kDefaultFps).clamp(5, 120).toDouble();

  @override
  String encode(double value) => value.abs().clamp(5, 120).toString();
}

abstract final class SessionPeerSettingsRegistry {
  static const codecPreference = PeerOptionSetting<String>(
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
  );
  static const videoProfile = PeerOptionSetting<String>(
    key: kOptionVideoProfile,
    codec: AllowedStringCodec(
      defaultValue: kVideoProfileStandard,
      allowedValues: {kVideoProfileStandard, kVideoProfileMovie},
    ),
  );
  static const captureBackend = PeerOptionSetting<String>(
    key: kOptionCaptureBackend,
    codec: _CaptureBackendCodec(),
  );
  static const qualityMonitorPosition = PeerOptionSetting<String>(
    key: kOptionQualityMonitorPosition,
    codec: _QualityPositionCodec(),
  );
  static const qualityMonitorDetails = PeerOptionSetting<String>(
    key: kOptionQualityMonitorDetails,
    codec: _QualityDetailsCodec(),
  );
  static const qualityMonitorFloatingPosition = PeerOptionSetting<String>(
    key: kOptionQualityMonitorFloatingPosition,
    codec: _StoredStringCodec(),
  );
  static const qualityMonitorFloatingSize = PeerOptionSetting<String>(
    key: kOptionQualityMonitorFloatingSize,
    codec: _StoredStringCodec(),
  );
  static const toolbarOrientation = PeerOptionSetting<String>(
    key: 'remote-menubar-orientation',
    codec: AllowedStringCodec(
      defaultValue: 'horizontal',
      allowedValues: {'horizontal', 'vertical'},
    ),
  );
  static const toolbarDragX = PeerOptionSetting<double>(
    key: 'remote-menubar-drag-x',
    codec: DoubleRangeCodec(defaultValue: 0.5, min: 0, max: 1),
  );
  static const toolbarDragY = PeerOptionSetting<double>(
    key: 'remote-menubar-drag-y',
    codec: DoubleRangeCodec(defaultValue: 0, min: 0, max: 1),
  );
  static const customFps = PeerOptionSetting<double>(
    key: kOptionCustomFps,
    codec: _SignedFpsCodec(),
  );
  static const customFpsMode = PeerOptionSetting<String>(
    key: kOptionCustomFpsMode,
    codec: AllowedStringCodec(
      defaultValue: kCustomFpsModeAdaptive,
      allowedValues: {kCustomFpsModeAdaptive, kCustomFpsModeFixed},
    ),
  );
  static const clipboardDirection = PeerOptionSetting<String>(
    key: kOptionClipboardDirection,
    codec: _StoredStringCodec(),
  );
  static const legacyTouchMode = PeerOptionSetting<String>(
    key: kOptionTouchMode,
    codec: _StoredStringCodec(),
  );
  static const privacyModeImplementation = PeerOptionSetting<String>(
    key: 'privacy-mode-impl-key',
    codec: _StoredStringCodec(),
  );
  static const osUsername = PeerOptionSetting<String>(
    key: 'os-username',
    codec: _StoredStringCodec(),
  );
  static const osPassword = PeerOptionSetting<String>(
    key: 'os-password',
    codec: _StoredStringCodec(),
  );
  static const autoLogin = PeerOptionSetting<bool>(
    key: 'auto-login',
    codec: BoolOptionCodec(),
  );
  static const localDirectory = PeerOptionSetting<String>(
    key: 'local_dir',
    codec: _StoredStringCodec(maxLength: 32768),
  );
  static const remoteDirectory = PeerOptionSetting<String>(
    key: 'remote_dir',
    codec: _StoredStringCodec(maxLength: 32768),
  );
  static const localShowHidden = PeerOptionSetting<bool>(
    key: 'local_show_hidden',
    codec: _PresenceBoolCodec(),
  );
  static const remoteShowHidden = PeerOptionSetting<bool>(
    key: 'remote_show_hidden',
    codec: _PresenceBoolCodec(),
  );

  static const all = <PeerOptionSetting<dynamic>>[
    codecPreference,
    videoProfile,
    captureBackend,
    qualityMonitorPosition,
    qualityMonitorDetails,
    qualityMonitorFloatingPosition,
    qualityMonitorFloatingSize,
    toolbarOrientation,
    toolbarDragX,
    toolbarDragY,
    customFps,
    customFpsMode,
    clipboardDirection,
    legacyTouchMode,
    privacyModeImplementation,
    osUsername,
    osPassword,
    autoLogin,
    localDirectory,
    remoteDirectory,
    localShowHidden,
    remoteShowHidden,
  ];
}

abstract final class RemoteAppLocalSettingsRegistry {
  static const clipboardDirection = AppLocalSetting<String>(
    key: kOptionClipboardDirection,
    codec: _StoredStringCodec(),
  );
  static const toolbarDragLeft = AppLocalSetting<double>(
    key: kOptionRemoteMenubarDragLeft,
    codec: DoubleRangeCodec(defaultValue: 0, min: 0, max: 1),
  );
  static const toolbarDragRight = AppLocalSetting<double>(
    key: kOptionRemoteMenubarDragRight,
    codec: DoubleRangeCodec(defaultValue: 1, min: 0, max: 1),
  );
  static const touchMode = AppLocalSetting<bool>(
    key: kOptionTouchMode,
    codec: BoolOptionCodec(falseValue: 'N'),
  );
  static const textureRender = AppLocalSetting<bool>(
    key: kOptionTextureRender,
    codec: BoolOptionCodec(falseValue: 'N'),
  );
  static const showVirtualMouse = AppLocalSetting<bool>(
    key: kOptionShowVirtualMouse,
    codec: BoolOptionCodec(falseValue: 'N'),
  );
  static const virtualMouseScale = AppLocalSetting<double>(
    key: kOptionVirtualMouseScale,
    codec: DoubleRangeCodec(defaultValue: 1, min: 0.8, max: 1.8),
  );
  static const showVirtualJoystick = AppLocalSetting<bool>(
    key: kOptionShowVirtualJoystick,
    codec: BoolOptionCodec(falseValue: 'N'),
  );

  static const all = <AppLocalSetting<dynamic>>[
    clipboardDirection,
    toolbarDragLeft,
    toolbarDragRight,
    touchMode,
    textureRender,
    showVirtualMouse,
    virtualMouseScale,
    showVirtualJoystick,
  ];
}

abstract final class LiveSessionSettingsRegistry {
  static const collapseToolbar = LiveSessionToggleSetting(
    kOptionCollapseToolbar,
  );
  static const hideToolbar = LiveSessionToggleSetting(kOptionHideToolbar);
  static const showRemoteCursor = LiveSessionToggleSetting(
    'show-remote-cursor',
  );
  static const followRemoteCursor = LiveSessionToggleSetting(
    'follow-remote-cursor',
  );
  static const followRemoteWindow = LiveSessionToggleSetting(
    'follow-remote-window',
  );
  static const zoomCursor = LiveSessionToggleSetting(kOptionZoomCursor);
  static const disableAudio = LiveSessionToggleSetting('disable-audio');
  static const enableFileCopyPaste = LiveSessionToggleSetting(
    kOptionEnableFileCopyPaste,
  );
  static const disableClipboard = LiveSessionToggleSetting('disable-clipboard');
  static const lockAfterSessionEnd = LiveSessionToggleSetting(
    'lock-after-session-end',
  );
  static const trueColor444 = LiveSessionToggleSetting(kOptionI444);
  static const viewOnly = LiveSessionToggleSetting(kOptionToggleViewOnly);
  static const showMyCursor = LiveSessionToggleSetting(
    kOptionToggleShowMyCursor,
  );
  static const showQualityMonitor = LiveSessionToggleSetting(
    'show-quality-monitor',
  );
  static const privacyMode = LiveSessionToggleSetting('privacy-mode');
  static const swapControlCommand = LiveSessionToggleSetting('allow_swap_key');
  static const swapMouseButtons = LiveSessionToggleSetting(
    kOptionSwapLeftRightMouse,
  );
  static const terminalPersistent = LiveSessionToggleSetting(
    kOptionTerminalPersistent,
  );

  static const all = <LiveSessionToggleSetting>[
    collapseToolbar,
    hideToolbar,
    showRemoteCursor,
    followRemoteCursor,
    followRemoteWindow,
    zoomCursor,
    disableAudio,
    enableFileCopyPaste,
    disableClipboard,
    lockAfterSessionEnd,
    trueColor444,
    viewOnly,
    showMyCursor,
    showQualityMonitor,
    privacyMode,
    swapControlCommand,
    swapMouseButtons,
    terminalPersistent,
  ];
}

class SessionPeerSettingsRepository {
  const SessionPeerSettingsRepository._(this.sessionId);

  factory SessionPeerSettingsRepository.forSession(UuidValue sessionId) =>
      SessionPeerSettingsRepository._(sessionId);

  final UuidValue sessionId;

  Future<String> readRaw<T>(PeerOptionSetting<T> setting) async =>
      await bind.sessionGetOption(sessionId: sessionId, arg: setting.key) ?? '';

  Future<String> readPeerRaw<T>(PeerOptionSetting<T> setting) =>
      bind.sessionGetPeerOption(sessionId: sessionId, name: setting.key);

  Future<T> read<T>(PeerOptionSetting<T> setting) async =>
      setting.codec.decode(await readRaw(setting));

  Future<T> readPeer<T>(PeerOptionSetting<T> setting) async =>
      setting.codec.decode(await readPeerRaw(setting));

  Future<void> write<T>(PeerOptionSetting<T> setting, T value) =>
      bind.sessionPeerOption(
        sessionId: sessionId,
        name: setting.key,
        value: setting.codec.encode(value),
      );
}

class RemoteAppLocalSettingsRepository {
  const RemoteAppLocalSettingsRepository();

  String readRaw<T>(AppLocalSetting<T> setting) =>
      bind.mainGetLocalOption(key: setting.key);

  T read<T>(AppLocalSetting<T> setting) =>
      setting.codec.decode(readRaw(setting));

  Future<void> write<T>(AppLocalSetting<T> setting, T value) => bind
      .mainSetLocalOption(key: setting.key, value: setting.codec.encode(value));
}

typedef LiveToggleSyncReader = bool Function(String key);
typedef LiveToggleReader = Future<bool?> Function(String key);
typedef LiveToggleWriter = Future<void> Function(String command);

class LiveSessionSettingsRepository {
  factory LiveSessionSettingsRepository({
    required LiveToggleSyncReader readSync,
    required LiveToggleReader read,
    required LiveToggleWriter write,
  }) => LiveSessionSettingsRepository._(readSync, read, write);

  const LiveSessionSettingsRepository._(
    this._readSync,
    this._read,
    this._write,
  );

  factory LiveSessionSettingsRepository.forSession(UuidValue sessionId) =>
      LiveSessionSettingsRepository(
        readSync: (key) =>
            bind.sessionGetToggleOptionSync(sessionId: sessionId, arg: key),
        read: (key) =>
            bind.sessionGetToggleOption(sessionId: sessionId, arg: key),
        write: (command) =>
            bind.sessionToggleOption(sessionId: sessionId, value: command),
      );

  final LiveToggleSyncReader _readSync;
  final LiveToggleReader _read;
  final LiveToggleWriter _write;

  bool readSync(LiveSessionToggleSetting setting) => _readSync(setting.key);

  Future<bool> read(
    LiveSessionToggleSetting setting, {
    bool fallback = false,
  }) async => await _read(setting.key) ?? fallback;

  Future<void> toggle(LiveSessionToggleSetting setting) => _write(setting.key);

  Future<bool> toggleAndRead(
    LiveSessionToggleSetting setting, {
    bool? fallback,
  }) async {
    await toggle(setting);
    return await _read(setting.key) ?? fallback ?? readSync(setting);
  }

  Future<void> setBlockInput(bool blocked) =>
      _write(blocked ? 'block-input' : 'unblock-input');

  Future<void> setClipboardDirection(String policy) {
    final normalized = switch (policy) {
      kClipboardDirectionBoth => kClipboardDirectionBoth,
      kClipboardDirectionLocalToRemote => kClipboardDirectionLocalToRemote,
      kClipboardDirectionRemoteToLocal => kClipboardDirectionRemoteToLocal,
      _ => kClipboardDirectionOff,
    };
    return _write('$kSessionToggleClipboardDirectionPrefix$normalized');
  }
}

const remoteAppLocalSettings = RemoteAppLocalSettingsRepository();
