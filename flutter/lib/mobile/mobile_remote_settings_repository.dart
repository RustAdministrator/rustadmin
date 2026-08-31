import '../consts.dart';
import 'widgets/remote_session_controls.dart';

typedef OptionReader = String Function(String key);
typedef PeerOptionReader = Future<String> Function(String key);
typedef OptionWriter = Future<void> Function(String key, String value);

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

  MobileRemoteSettingsSnapshot readDefaults() {
    const physicalKeyInput = true;
    return MobileRemoteSettingsSnapshot(
      toolbarTransparency: MobileRemoteToolbarTransparencySettings.fromStored(
        overlapOpacityPercent: readUserDefault(
          kOptionMobileRemoteToolbarOverlapOpacityPercent,
        ),
      ),
      toolbarPlacement: MobileRemoteToolbarPlacementSettings.fromStored(
        readLocal(kOptionMobileRemoteToolbarPlacement),
      ),
      cursorInertia: MobileCursorInertiaSettings.fromStored(
        readUserDefault(kOptionMobileCursorInertiaDurationMs),
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
    final stored = await Future.wait([
      readPeer(kOptionMobileRemoteToolbarOverlapOpacityPercent),
      readPeer(kOptionMobileCursorInertiaDurationMs),
      readPeer(kOptionMobilePhysicalKeyInput),
      readPeer(kOptionKeyboardInputModeV2),
    ]);
    final physicalKeyInput = mobileVmPhysicalInputEnabled(stored[2]);
    return MobileRemoteSettingsSnapshot(
      toolbarTransparency: MobileRemoteToolbarTransparencySettings.fromStored(
        overlapOpacityPercent: stored[0].isEmpty
            ? defaults.toolbarTransparency.overlapOpacityPercent.toString()
            : stored[0],
        fallback: defaults.toolbarTransparency,
      ),
      toolbarPlacement: defaults.toolbarPlacement,
      cursorInertia: MobileCursorInertiaSettings.fromStored(
        stored[1].isEmpty
            ? defaults.cursorInertia.durationMs.toString()
            : stored[1],
        fallback: defaults.cursorInertia,
      ),
      physicalKeyInput: physicalKeyInput,
      keyboardInputMode: mobileKeyboardInputV2Mode(
        stored[3],
        mobileVmPhysicalInputOption(physicalKeyInput),
      ),
    );
  }

  Future<void> storePlacement(
    MobileRemoteToolbarPlacementSettings settings,
  ) async {
    final writer = writeLocal;
    if (writer != null) {
      await writer(kOptionMobileRemoteToolbarPlacement, settings.storedValue);
    }
  }

  Future<void> storePeerOption(String key, String value) async {
    final writer = writePeer;
    if (writer != null) await writer(key, value);
  }
}
