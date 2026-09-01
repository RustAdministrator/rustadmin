import '../consts.dart';
import '../common/remote_toolbar_settings.dart';
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
  );
  static const cursorInertiaDefault = UserDefaultSetting<int>(
    key: kOptionMobileCursorInertiaDurationMs,
    codec: _cursorInertiaCodec,
  );
  static const toolbarPlacement =
      LocalSetting<MobileRemoteToolbarPlacementSettings>(
        key: kOptionMobileRemoteToolbarPlacement,
        codec: _PlacementCodec(),
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
  const MobileRemoteSettingsRepository({
    required this.readUserDefault,
    required this.readLocal,
    required this.readPeer,
    this.writeLocal,
    this.writePeer,
  });

  final OptionReader readUserDefault;
  final OptionReader readLocal;
  final PeerOptionReader readPeer;
  final OptionWriter? writeLocal;
  final OptionWriter? writePeer;

  T _readUserDefault<T>(UserDefaultSetting<T> setting) =>
      setting.codec.decode(readUserDefault(setting.key));

  T _readLocal<T>(LocalSetting<T> setting) =>
      setting.codec.decode(readLocal(setting.key));

  Future<T?> _readPeer<T>(PeerSetting<T> setting) async {
    final raw = await readPeer(setting.key);
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
    final writer = writeLocal;
    if (writer != null) {
      final setting = MobileRemoteSettingsRegistry.toolbarPlacement;
      await writer(setting.key, setting.codec.encode(settings));
    }
  }

  Future<void> _storePeer<T>(PeerSetting<T> setting, T value) async {
    final writer = writePeer;
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
