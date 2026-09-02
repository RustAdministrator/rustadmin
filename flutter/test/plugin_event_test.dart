import 'package:flutter_hbb/models/session_event.dart';
import 'package:flutter_hbb/plugin/manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => pluginManager.plugins.clear());

  test('typed plugin catalog and install status update the manager', () {
    final value = SessionPluginCatalogValue(
      sourceName: 'local',
      sourceUrl: '',
      sourceDescription: '',
      id: 'plugin',
      name: 'Plugin',
      version: '2',
      description: '',
      author: 'Author',
      home: '',
      license: 'MIT',
      source: '',
      lastReleased: DateTime.utc(2026),
      published: DateTime.utc(2026),
      installedVersion: '',
      invalidReason: '',
    );

    pluginManager.handleCatalogEvent(PluginCatalogSessionEvent([value]));
    expect(pluginManager.plugins.single.meta.id, 'plugin');
    expect(pluginManager.plugins.single.installed, isFalse);

    pluginManager.handleInstallStatusEvent(
      const PluginInstallStatusSessionEvent(
        id: 'plugin',
        message: 'finished',
        install: true,
      ),
    );
    expect(pluginManager.plugins.single.installedVersion, '2');
  });
}
