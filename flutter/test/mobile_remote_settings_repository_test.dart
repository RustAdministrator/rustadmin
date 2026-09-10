import 'dart:async';

import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/common/remote_toolbar_settings.dart';
import 'package:flutter_hbb/mobile/mobile_remote_settings_repository.dart';
import 'package:flutter_hbb/mobile/widgets/remote_session_controls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retired mode write cannot start or update a compatibility mirror', () async {
    var current = false;
    final primary = Completer<void>();
    final writes = <String>[];
    final repository = MobileRemoteSettingsRepository(
      readUserDefault: (_) => '',
      readLocal: (_) => '',
      readPeer: (_) async => '',
      writePeer: (key, value) async {
        writes.add('$key=$value');
        await primary.future;
      },
    );
    await repository.storeKeyboardInputMode('physical', isCurrent: () => current);
    expect(writes, isEmpty);
    current = true;
    final write = repository.storeKeyboardInputMode('text', isCurrent: () => current);
    expect(writes, ['$kOptionKeyboardInputModeV2=text']);
    current = false;
    primary.complete();
    await write;
    expect(writes, ['$kOptionKeyboardInputModeV2=text']);
  });

  test('explicit new mode overrides every legacy physical flag in the snapshot', () async {
    for (final mode in ['auto', 'text', 'physical', 'PHYSICAL', 'future-mode']) {
      for (final legacy in ['', 'Y', 'N', 'n']) {
        final repository = MobileRemoteSettingsRepository(
          readUserDefault: (_) => '',
          readLocal: (_) => '',
          readPeer: (key) async => switch (key) {
            kOptionKeyboardInputModeV2 => mode,
            kOptionMobilePhysicalKeyInput => legacy,
            _ => '',
          },
        );
        final settings = await repository.readSession();
        final expected = mode == 'future-mode' ? 'auto' : mode.toLowerCase();
        expect(settings.keyboardInputMode, expected);
        expect(settings.physicalKeyInput, expected != 'text');
      }
    }
  });

  test('new mode writes its legacy mirror and old toggle is an explicit choice', () async {
    final peer = <String, String>{};
    final repository = MobileRemoteSettingsRepository(
      readUserDefault: (_) => '',
      readLocal: (_) => '',
      readPeer: (key) async => peer[key] ?? '',
      writePeer: (key, value) async { peer[key] = value; },
    );
    await repository.storeKeyboardInputMode('physical');
    expect(peer[kOptionKeyboardInputModeV2], 'physical');
    expect(peer[kOptionMobilePhysicalKeyInput], 'Y');
    await repository.storePhysicalKeyInput(false);
    expect(peer[kOptionKeyboardInputModeV2], 'text');
    expect(peer[kOptionMobilePhysicalKeyInput], 'N');
    await repository.storePhysicalKeyInput(true);
    expect(peer[kOptionKeyboardInputModeV2], 'auto');
    expect(peer[kOptionMobilePhysicalKeyInput], 'Y');
  });

  test('registry keys are unique within each legal scope', () {
    expect(MobileRemoteSettingsRegistry.hasUniqueScopedKeys(), isTrue);
    expect(
      MobileRemoteSettingsRegistry.toolbarPlacement.scope,
      SettingScope.appLocal,
    );
    expect(
      MobileRemoteSettingsRegistry.toolbarOverlapDefault.scope,
      SettingScope.userDefault,
    );
    expect(
      MobileRemoteSettingsRegistry.toolbarOverlapPeer.scope,
      SettingScope.peer,
    );
  });

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
    await repository.storeTouchMode(false);
    await repository.storeTextureRender(true);
    await repository.storeCursorInertia(600);

    expect(writes, [
      (kOptionMobileRemoteToolbarPlacement, placement.storedValue),
      (kOptionTouchMode, 'N'),
      (kOptionTextureRender, 'Y'),
      (kOptionMobileCursorInertiaDurationMs, '600'),
    ]);
  });
}
