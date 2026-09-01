import '../consts.dart';
import '../common/remote_toolbar_settings.dart';
import '../models/platform_model.dart';
import '../generated_bridge.dart'
    if (dart.library.html) '../web/bridge.dart';
import 'widgets/remote_session_controls.dart';

typedef OptionReader = String Function(String key);
typedef PeerOptionReader = Future<String> Function(String key);
typedef OptionWriter = Future<void> Function(String key, String value);

class LocalSetting<T> implements SettingDefinition<T> {
  const LocalSetting({
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

class PeerSetting<T> implements SettingDefinition<T> {
  const PeerSetting({
    required this.key,
    required this.codec,
    this.inheritWhenEmpty = false,
    this.applyMode = SettingApplyMode.live,
  });

  @override
  final String key;
  @override
  final SettingCodec<T> codec;
  final bool inheritWhenEmpty;
  @override
  final SettingApplyMode applyMode;
  @override
  SettingScope get scope => SettingScope.peer;
}

class _PlacementCodec
    implements SettingCodec<MobileRemoteToolbarPlacementSettings> {
  const _PlacementCodec();

  @override
  MobileRemoteToolbarPlacementSettings decode(String raw) =>
      MobileRemoteToolbarPlacementSettings.fromStored(raw);

  @override
  String encode(MobileRemoteToolbarPlacementSettings value) =>
      value.storedValue;
}

class _PhysicalInputCodec implements SettingCodec<bool> {
  const _PhysicalInputCodec();

  @override
  bool decode(String raw) => mobileVmPhysicalInputEnabled(raw);

  @override
  String encode(bool value) => mobileVmPhysicalInputOption(value);
}

class _KeyboardInputModeCodec implements SettingCodec<String> {
  const _KeyboardInputModeCodec();

  @override
  String decode(String raw) => switch (raw.toLowerCase()) {
    kKeyboardInputModeAuto => kKeyboardInputModeAuto,
    kKeyboardInputModeText => kKeyboardInputModeText,
    kKeyboardInputModePhysical => kKeyboardInputModePhysical,
    _ => '',
  };

  @override
  String encode(String value) => decode(value);
}

abstract final class MobileRemoteSettingsRegistry {
  static const _toolbarOverlapCodec = IntRangeCodec(
    defaultValue: kDefaultMobileRemoteToolbarOverlapOpacityPercent,
    min: kMinMobileRemoteToolbarOverlapOpacityPercent,
    max: kMaxMobileRemoteToolbarOverlapOpacityPercent,
  );
  static const _cursorInertiaCodec = IntRangeCodec(
    defaultValue: kDefaultMobileCursorInertiaDurationMs,
    min: kMinMobileCursorInertiaDurationMs,
    max: kMaxMobileCursorInertiaDurationMs,
  );
  static const toolbarOverlapDefault = UserDefaultSetting<int>(
    key: kOptionMobileRemoteToolbarOverlapOpacityPercent,
    codec: _toolbarOverlapCodec,
    applyMode: SettingApplyMode.nextSession,
  );
  static const cursorInertiaDefault = UserDefaultSetting<int>(
    key: kOptionMobileCursorInertiaDurationMs,
    codec: _cursorInertiaCodec,
    applyMode: SettingApplyMode.nextSession,
  );
  static const toolbarPlacement =
      LocalSetting<MobileRemoteToolbarPlacementSettings>(
        key: kOptionMobileRemoteToolbarPlacement,
        codec: _PlacementCodec(),
      );
  static const touchMode = LocalSetting<bool>(
    key: kOptionTouchMode,
    codec: BoolOptionCodec(falseValue: 'N'),
  );
  static const textureRender = LocalSetting<bool>(
    key: kOptionTextureRender,
    codec: BoolOptionCodec(falseValue: 'N'),
  );
  static const toolbarOverlapPeer = PeerSetting<int>(
    key: kOptionMobileRemoteToolbarOverlapOpacityPercent,
    codec: _toolbarOverlapCodec,
    inheritWhenEmpty: true,
  );
  static const cursorInertiaPeer = PeerSetting<int>(
    key: kOptionMobileCursorInertiaDurationMs,
    codec: _cursorInertiaCodec,
    inheritWhenEmpty: true,
  );
  static const physicalKeyInput = PeerSetting<bool>(
    key: kOptionMobilePhysicalKeyInput,
    codec: _PhysicalInputCodec(),
  );
  static const keyboardInputMode = PeerSetting<String>(
    key: kOptionKeyboardInputModeV2,
    codec: _KeyboardInputModeCodec(),
  );

  static const all = <SettingDefinition<dynamic>>[
    toolbarOverlapDefault,
    cursorInertiaDefault,
    toolbarPlacement,
    touchMode,
    textureRender,
    toolbarOverlapPeer,
    cursorInertiaPeer,
    physicalKeyInput,
    keyboardInputMode,
  ];

  static bool hasUniqueScopedKeys() =>
      all.map((setting) => (setting.scope, setting.key)).toSet().length ==
      all.length;
}

class MobileRemoteSettingsSnapshot {
  const MobileRemoteSettingsSnapshot({
    required this.toolbarTransparency,
    required this.toolbarPlacement,
    required this.cursorInertia,
    required this.physicalKeyInput,
    required this.keyboardInputMode,
  });

  final MobileRemoteToolbarTransparencySettings toolbarTransparency;
  final MobileRemoteToolbarPlacementSettings toolbarPlacement;
  final MobileCursorInertiaSettings cursorInertia;
  final bool physicalKeyInput;
  final String keyboardInputMode;
}

class MobileRemoteSettingsRepository {
  factory MobileRemoteSettingsRepository.forSession(SessionID sessionId) =>
      MobileRemoteSettingsRepository(
        readUserDefault: (key) => bind.mainGetUserDefaultOption(key: key),
        readLocal: (key) => bind.mainGetLocalOption(key: key),
        readPeer: (key) => bind.sessionGetPeerOption(
          sessionId: sessionId,
          name: key,
        ),
        writeLocal: (key, value) =>
            bind.mainSetLocalOption(key: key, value: value),
        writePeer: (key, value) => bind.sessionPeerOption(
          sessionId: sessionId,
          name: key,
          value: value,
        ),
      );

  factory MobileRemoteSettingsRepository({
    required OptionReader readUserDefault,
    required OptionReader readLocal,
    required PeerOptionReader readPeer,
    OptionWriter? writeLocal,
    OptionWriter? writePeer,
  }) => MobileRemoteSettingsRepository._(
    readUserDefault,
    readLocal,
    readPeer,
    writeLocal,
    writePeer,
  );

  const MobileRemoteSettingsRepository._(
    this._readUserDefaultRaw,
    this._readLocalRaw,
    this._readPeerRaw,
    this._writeLocal,
    this._writePeer,
  );

  final OptionReader _readUserDefaultRaw;
  final OptionReader _readLocalRaw;
  final PeerOptionReader _readPeerRaw;
  final OptionWriter? _writeLocal;
  final OptionWriter? _writePeer;

  T _readUserDefault<T>(UserDefaultSetting<T> setting) =>
      setting.codec.decode(_readUserDefaultRaw(setting.key));

  T _readLocal<T>(LocalSetting<T> setting) =>
      setting.codec.decode(_readLocalRaw(setting.key));

  Future<T?> _readPeer<T>(PeerSetting<T> setting) async {
    final raw = await _readPeerRaw(setting.key);
    if (raw.isEmpty && setting.inheritWhenEmpty) return null;
    return setting.codec.decode(raw);
  }

  MobileRemoteSettingsSnapshot readDefaults() {
    const physicalKeyInput = true;
    return MobileRemoteSettingsSnapshot(
      toolbarTransparency: MobileRemoteToolbarTransparencySettings.fromStored(
        overlapOpacityPercent: _readUserDefault(
          MobileRemoteSettingsRegistry.toolbarOverlapDefault,
        ).toString(),
      ),
      toolbarPlacement: _readLocal(
        MobileRemoteSettingsRegistry.toolbarPlacement,
      ),
      cursorInertia: MobileCursorInertiaSettings.fromStored(
        _readUserDefault(
          MobileRemoteSettingsRegistry.cursorInertiaDefault,
        ).toString(),
      ),
      physicalKeyInput: physicalKeyInput,
      keyboardInputMode: mobileKeyboardInputV2Mode(
        '',
        mobileVmPhysicalInputOption(physicalKeyInput),
      ),
    );
  }

  Future<MobileRemoteSettingsSnapshot> readSession() async {
    final defaults = readDefaults();
    final toolbarOverlap = await _readPeer(
      MobileRemoteSettingsRegistry.toolbarOverlapPeer,
    );
    final cursorInertia = await _readPeer(
      MobileRemoteSettingsRegistry.cursorInertiaPeer,
    );
    final physicalKeyInput =
        await _readPeer(MobileRemoteSettingsRegistry.physicalKeyInput) ?? true;
    final keyboardInputMode =
        await _readPeer(MobileRemoteSettingsRegistry.keyboardInputMode) ?? '';
    return MobileRemoteSettingsSnapshot(
      toolbarTransparency: MobileRemoteToolbarTransparencySettings.fromStored(
        overlapOpacityPercent:
            (toolbarOverlap ??
                    defaults.toolbarTransparency.overlapOpacityPercent)
                .toString(),
        fallback: defaults.toolbarTransparency,
      ),
      toolbarPlacement: defaults.toolbarPlacement,
      cursorInertia: MobileCursorInertiaSettings.fromStored(
        (cursorInertia ?? defaults.cursorInertia.durationMs).toString(),
        fallback: defaults.cursorInertia,
      ),
      physicalKeyInput: physicalKeyInput,
      keyboardInputMode: mobileKeyboardInputV2Mode(
        keyboardInputMode,
        mobileVmPhysicalInputOption(physicalKeyInput),
      ),
    );
  }

  Future<void> storePlacement(
    MobileRemoteToolbarPlacementSettings settings,
  ) async {
    final writer = _writeLocal;
    if (writer != null) {
      final setting = MobileRemoteSettingsRegistry.toolbarPlacement;
      await writer(setting.key, setting.codec.encode(settings));
    }
  }

  Future<void> _storeLocal<T>(LocalSetting<T> setting, T value) async {
    final writer = _writeLocal;
    if (writer != null) await writer(setting.key, setting.codec.encode(value));
  }

  Future<void> storeTouchMode(bool value) =>
      _storeLocal(MobileRemoteSettingsRegistry.touchMode, value);

  Future<void> storeTextureRender(bool value) =>
      _storeLocal(MobileRemoteSettingsRegistry.textureRender, value);

  Future<void> _storePeer<T>(PeerSetting<T> setting, T value) async {
    final writer = _writePeer;
    if (writer != null) await writer(setting.key, setting.codec.encode(value));
  }

  Future<void> storeToolbarOverlap(int value) =>
      _storePeer(MobileRemoteSettingsRegistry.toolbarOverlapPeer, value);

  Future<void> storeCursorInertia(int value) =>
      _storePeer(MobileRemoteSettingsRegistry.cursorInertiaPeer, value);

  Future<void> storePhysicalKeyInput(bool value) =>
      _storePeer(MobileRemoteSettingsRegistry.physicalKeyInput, value);

  Future<void> storeKeyboardInputMode(String value) =>
      _storePeer(MobileRemoteSettingsRegistry.keyboardInputMode, value);
}

class MobileRemoteDefaultsRepository {
  const MobileRemoteDefaultsRepository(this._userDefaults);

  final UserDefaultSettingsRepository _userDefaults;

  T read<T>(UserDefaultSetting<T> setting) => _userDefaults.read(setting);

  Future<void> write<T>(UserDefaultSetting<T> setting, T value) =>
      _userDefaults.write(setting, value);

  Stream<String> watch() {
    final keys = {
      MobileRemoteSettingsRegistry.toolbarOverlapDefault.key,
      MobileRemoteSettingsRegistry.cursorInertiaDefault.key,
    };
    return _userDefaults.changes.where(keys.contains);
  }
}

final mobileRemoteDefaults = MobileRemoteDefaultsRepository(
  remoteUserDefaultSettings,
);

class MobileRemoteLocalSettingsRepository {
  const MobileRemoteLocalSettingsRepository(this._readRaw, this._writeRaw);

  final OptionReader _readRaw;
  final OptionWriter _writeRaw;

  T read<T>(LocalSetting<T> setting) =>
      setting.codec.decode(_readRaw(setting.key));

  Future<void> write<T>(LocalSetting<T> setting, T value) =>
      _writeRaw(setting.key, setting.codec.encode(value));
}

final mobileRemoteLocalSettings = MobileRemoteLocalSettingsRepository(
  (key) => bind.mainGetLocalOption(key: key),
  (key, value) => bind.mainSetLocalOption(key: key, value: value),
);
