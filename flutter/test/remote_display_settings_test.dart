import 'dart:async';

import 'package:flutter_hbb/common/quality_monitor_settings.dart';
import 'package:flutter_hbb/common/remote_display_settings.dart';
import 'package:flutter_hbb/common/remote_toolbar_settings.dart';
import 'package:flutter_hbb/mobile/mobile_remote_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all domain setting definitions have unique scoped keys', () {
    final definitions = <SettingDefinition<dynamic>>[
      ...RemoteToolbarSettingsRegistry.all,
      ...QualityMonitorSettingsRegistry.all,
      ...RemoteDisplaySettingsRegistry.all,
      ...MobileRemoteSettingsRegistry.all,
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
}
