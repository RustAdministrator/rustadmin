import 'dart:async';

import 'package:flutter_hbb/common/quality_monitor_settings.dart';
import 'package:flutter_hbb/common/remote_display_settings.dart';
import 'package:flutter_hbb/common/remote_toolbar_settings.dart';
import 'package:flutter_hbb/common/session_peer_settings.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/mobile_remote_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all domain setting definitions have unique scoped keys', () {
    final definitions = <SettingDefinition<dynamic>>[
      ...RemoteToolbarSettingsRegistry.all,
      ...QualityMonitorSettingsRegistry.all,
      ...RemoteDisplaySettingsRegistry.all,
      ...MobileRemoteSettingsRegistry.all,
      ...SessionPeerSettingsRegistry.all,
      ...RemoteAppLocalSettingsRegistry.all,
      ...LiveSessionSettingsRegistry.all,
    ];
    final scopedKeys = definitions
        .map((setting) => (setting.scope, setting.key))
        .toSet();

    expect(scopedKeys, hasLength(definitions.length));
    for (final setting in definitions) {
      final value = setting.codec.decode('');
      expect(
        setting.codec.decode(setting.codec.encode(value)),
        value,
        reason: '${setting.scope.name}:${setting.key}',
      );
    }
  });

  test(
    'display codecs normalize legacy values and preserve false encoding',
    () {
      expect(
        RemoteDisplaySettingsRegistry.imageQuality.codec.decode('unknown'),
        'balanced',
      );
      expect(
        RemoteDisplaySettingsRegistry.codecPreference.codec.decode('h265-hq'),
        'h265-hq',
      );
      expect(RemoteDisplaySettingsRegistry.customFps.codec.decode('999'), 120);
      expect(
        RemoteDisplaySettingsRegistry.enableFileCopyPaste.codec.encode(false),
        'N',
      );
      expect(
        RemoteDisplaySettingsRegistry.showRemoteCursor.codec.encode(false),
        '',
      );
      expect(
        RemoteDisplaySettingsRegistry.viewStyle.applyMode,
        SettingApplyMode.nextSession,
      );
      expect(
        RemoteDisplaySettingsRegistry.showMonitorsToolbar.applyMode,
        SettingApplyMode.live,
      );
      expect(
        QualityMonitorSettingsRegistry.opacity.applyMode,
        SettingApplyMode.live,
      );
      expect(
        MobileRemoteSettingsRegistry.cursorInertiaDefault.applyMode,
        SettingApplyMode.nextSession,
      );
      expect(
        MobileRemoteSettingsRegistry.cursorInertiaPeer.applyMode,
        SettingApplyMode.live,
      );
      expect(
        SessionPeerSettingsRegistry.codecPreference.scope,
        SettingScope.peer,
      );
      expect(
        RemoteAppLocalSettingsRegistry.textureRender.scope,
        SettingScope.appLocal,
      );
      expect(
        RemoteAppLocalSettingsRegistry.virtualMouseScale.codec.decode('99'),
        1.8,
      );
      expect(
        RemoteAppLocalSettingsRegistry.virtualMouseScale.codec.decode('bad'),
        1,
      );
      expect(
        RemoteAppLocalSettingsRegistry.showVirtualMouse.codec.encode(false),
        'N',
      );
      expect(
        LiveSessionSettingsRegistry.showQualityMonitor.scope,
        SettingScope.liveSession,
      );
      expect(
        LiveSessionSettingsRegistry.showQualityMonitor.applyMode,
        SettingApplyMode.live,
      );
    },
  );

  test('display repository publishes persisted cross-window changes', () async {
    final storage = <String, String>{};
    final defaults = UserDefaultSettingsRepository(
      (key) => storage[key] ?? '',
      (key, value) async => storage[key] = value,
    );
    final repository = RemoteDisplaySettingsRepository(defaults);
    final changed = Completer<bool>();
    final subscription = repository
        .watch(RemoteDisplaySettingsRegistry.showMonitorsToolbar)
        .listen((value) {
          if (!changed.isCompleted) changed.complete(value);
        });

    await repository.write(
      RemoteDisplaySettingsRegistry.showMonitorsToolbar,
      true,
    );

    expect(await changed.future, isTrue);
    expect(storage[RemoteDisplaySettingsRegistry.showMonitorsToolbar.key], 'Y');
    await subscription.cancel();
    await defaults.dispose();
  });

  test('live repository emits only registered legacy commands', () async {
    final commands = <String>[];
    final repository = LiveSessionSettingsRepository(
      readSync: (key) => key == 'show-quality-monitor',
      read: (key) async => key == kOptionTerminalPersistent,
      write: (command) async => commands.add(command),
    );

    expect(
      repository.readSync(LiveSessionSettingsRegistry.showQualityMonitor),
      isTrue,
    );
    expect(
      await repository.read(LiveSessionSettingsRegistry.terminalPersistent),
      isTrue,
    );
    await repository.toggle(LiveSessionSettingsRegistry.showRemoteCursor);
    await repository.setBlockInput(true);
    await repository.setBlockInput(false);
    await repository.setClipboardDirection(kClipboardDirectionLocalToRemote);
    await repository.setClipboardDirection('invalid');

    expect(commands, [
      'show-remote-cursor',
      'block-input',
      'unblock-input',
      '$kSessionToggleClipboardDirectionPrefix'
          '$kClipboardDirectionLocalToRemote',
      '$kSessionToggleClipboardDirectionPrefix$kClipboardDirectionOff',
    ]);

    final unsettled = LiveSessionSettingsRepository(
      readSync: (_) => false,
      read: (_) async => null,
      write: (_) async {},
    );
    expect(
      await unsettled.toggleAndRead(
        LiveSessionSettingsRegistry.showMyCursor,
        fallback: true,
      ),
      isTrue,
    );
  });
}
