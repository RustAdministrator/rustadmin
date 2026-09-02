import 'dart:async';

import 'package:flutter_hbb/common/remote_toolbar_settings.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registry keys are unique and codecs normalize legacy values', () {
    expect(RemoteToolbarSettingsRegistry.hasUniqueKeys(), isTrue);
    for (final setting in RemoteToolbarSettingsRegistry.all) {
      final normalized = setting.codec.decode('');
      expect(
        setting.codec.decode(setting.codec.encode(normalized)),
        normalized,
        reason: setting.key,
      );
    }
    expect(
      RemoteToolbarSettingsRegistry.revealZone.codec.decode('invalid'),
      kDefaultRemoteToolbarRevealZonePx,
    );
    expect(
      RemoteToolbarSettingsRegistry.revealZone.codec.decode('9999'),
      kMaxRemoteToolbarRevealZonePx,
    );
    expect(
      RemoteToolbarSettingsRegistry.scrollStyle.codec.decode('unknown'),
      kRemoteScrollStyleAuto,
    );
  });

  test('typed writes clamp values and publish after persistence', () async {
    final storage = <String, String>{};
    final events = <String>[];
    final repository = UserDefaultSettingsRepository(
      (key) => storage[key] ?? '',
      (key, value) async {
        expect(events, isEmpty);
        storage[key] = value;
      },
    );
    final subscription = repository.changes.listen(events.add);

    await repository.write(RemoteToolbarSettingsRegistry.revealZone, 9999);

    expect(storage[kOptionRemoteToolbarRevealZonePx], '160');
    expect(events, [kOptionRemoteToolbarRevealZonePx]);
    await subscription.cancel();
    await repository.dispose();
  });

  test('external notification re-reads shared cross-window storage', () async {
    final storage = <String, String>{kOptionRemoteToolbarHideDelayMs: '300'};
    final mainRepository = UserDefaultSettingsRepository(
      (key) => storage[key] ?? '',
      (key, value) async => storage[key] = value,
    );
    final remoteRepository = UserDefaultSettingsRepository(
      (key) => storage[key] ?? '',
      (key, value) async => storage[key] = value,
    );
    final remoteToolbar = RemoteToolbarSettingsRepository(remoteRepository);
    final changed = Completer<RemoteToolbarSettingsSnapshot>();
    final subscription = remoteToolbar.watch().listen((snapshot) {
      if (!changed.isCompleted) changed.complete(snapshot);
    });

    await mainRepository.write(RemoteToolbarSettingsRegistry.hideDelay, 725);
    remoteRepository.notifyExternal(kOptionRemoteToolbarHideDelayMs);

    expect((await changed.future).hideDelayMs, 725);
    await subscription.cancel();
    await mainRepository.dispose();
    await remoteRepository.dispose();
  });

  test('unregistered changes do not rebuild toolbar snapshots', () async {
    final repository = UserDefaultSettingsRepository(
      (_) => '',
      (_, __) async {},
    );
    final snapshots = <RemoteToolbarSettingsSnapshot>[];
    final subscription = RemoteToolbarSettingsRepository(
      repository,
    ).watch().listen(snapshots.add);

    repository.notifyExternal('unrelated-option');
    await Future<void>.delayed(Duration.zero);

    expect(snapshots, isEmpty);
    await subscription.cancel();
    await repository.dispose();
  });

  test('duplicate registered notifications publish one snapshot', () async {
    final repository = UserDefaultSettingsRepository(
      (key) => key == kOptionRemoteToolbarHideDelayMs ? '600' : '',
      (_, __) async {},
    );
    final snapshots = <RemoteToolbarSettingsSnapshot>[];
    final subscription = RemoteToolbarSettingsRepository(
      repository,
    ).watch().listen(snapshots.add);

    repository.notifyExternal(kOptionRemoteToolbarHideDelayMs);
    repository.notifyExternal(kOptionRemoteToolbarHideDelayMs);
    await Future<void>.delayed(Duration.zero);

    expect(snapshots, hasLength(1));
    expect(snapshots.single.hideDelayMs, 600);
    await subscription.cancel();
    await repository.dispose();
  });
}
