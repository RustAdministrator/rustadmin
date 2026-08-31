import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/mobile_remote_settings_repository.dart';
import 'package:flutter_hbb/mobile/widgets/remote_session_controls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('session values override defaults while empty values inherit', () async {
    final userDefaults = <String, String>{
      kOptionMobileRemoteToolbarOverlapOpacityPercent: '40',
      kOptionMobileCursorInertiaDurationMs: '700',
    };
    final peer = <String, String>{
      kOptionMobileRemoteToolbarOverlapOpacityPercent: '80',
      kOptionMobileCursorInertiaDurationMs: '',
      kOptionMobilePhysicalKeyInput: 'N',
      kOptionKeyboardInputModeV2: '',
    };
    final repository = MobileRemoteSettingsRepository(
      readUserDefault: (key) => userDefaults[key] ?? '',
      readLocal: (_) => '',
      readPeer: (key) async => peer[key] ?? '',
    );

    final settings = await repository.readSession();

    expect(settings.toolbarTransparency.overlapOpacityPercent, 80);
    expect(settings.cursorInertia.durationMs, 700);
    expect(settings.physicalKeyInput, isFalse);
    expect(settings.keyboardInputMode, kKeyboardInputModeText);
  });

  test('invalid stored values are normalized by their typed codecs', () async {
    final repository = MobileRemoteSettingsRepository(
      readUserDefault: (_) => 'invalid',
      readLocal: (_) => 'vertical,2,-1',
      readPeer: (_) async => 'invalid',
    );

    final settings = await repository.readSession();

    expect(
      settings.toolbarTransparency,
      MobileRemoteToolbarTransparencySettings.defaults,
    );
    expect(settings.cursorInertia, MobileCursorInertiaSettings.defaults);
    expect(settings.toolbarPlacement.axis, MobileRemoteToolbarAxis.vertical);
    expect(settings.toolbarPlacement.horizontalPosition, 1);
    expect(settings.toolbarPlacement.verticalPosition, 0);
    expect(settings.physicalKeyInput, isTrue);
    expect(settings.keyboardInputMode, kKeyboardInputModeAuto);
  });

  test('writes keep the existing option keys and serialized values', () async {
    final writes = <(String, String)>[];
    final repository = MobileRemoteSettingsRepository(
      readUserDefault: (_) => '',
      readLocal: (_) => '',
      readPeer: (_) async => '',
      writeLocal: (key, value) async => writes.add((key, value)),
      writePeer: (key, value) async => writes.add((key, value)),
    );
    const placement = MobileRemoteToolbarPlacementSettings(
      axis: MobileRemoteToolbarAxis.vertical,
      horizontalPosition: 0.25,
      verticalPosition: 0.75,
    );

    await repository.storePlacement(placement);
    await repository.storePeerOption(
      kOptionMobileCursorInertiaDurationMs,
      '600',
    );

    expect(writes, [
      (kOptionMobileRemoteToolbarPlacement, placement.storedValue),
      (kOptionMobileCursorInertiaDurationMs, '600'),
    ]);
  });
}
