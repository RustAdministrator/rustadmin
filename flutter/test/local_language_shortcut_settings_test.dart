import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/session_peer_settings.dart';
import 'package:flutter_hbb/common/widgets/local_language_shortcut_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'local language shortcut registries share the bounded wire contract',
    () {
      final global = RemoteAppLocalSettingsRegistry.localLanguageShortcuts;
      final peer = SessionPeerSettingsRegistry.localLanguageShortcuts;

      expect(global.key, 'local-language-shortcuts');
      expect(peer.key, global.key);
      for (final value in [
        kLocalLanguageShortcutsAuto,
        kLocalLanguageShortcutsEnabled,
        kLocalLanguageShortcutsDisabled,
      ]) {
        expect(global.codec.decode(global.codec.encode(value)), value);
        expect(peer.codec.decode(peer.codec.encode(value)), value);
      }
      expect(global.codec.decode(''), kLocalLanguageShortcutsAuto);
      expect(global.codec.decode('unexpected'), kLocalLanguageShortcutsAuto);
      expect(global.codec.encode('unexpected'), kLocalLanguageShortcutsAuto);
      expect(
        localLanguageShortcutOptionDescription(
          kLocalLanguageShortcutsAuto,
          peerOverride: true,
        ),
        'Follow the global setting.',
      );
    },
  );

  testWidgets('global control explains scope and writes the selected mode', (
    tester,
  ) async {
    var stored = kLocalLanguageShortcutsAuto;
    final writes = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocalLanguageShortcutSettings(
            readValue: () => stored,
            writeValue: (value) async {
              writes.add(value);
              stored = value;
            },
          ),
        ),
      ),
    );

    expect(find.text('Local language shortcuts'), findsOneWidget);
    expect(find.text(localLanguageShortcutGlobalExplanation), findsOneWidget);
    expect(
      find.byKey(const ValueKey('local-language-shortcut-auto')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
          .groupValue,
      kLocalLanguageShortcutsAuto,
    );

    await tester.tap(
      find.byKey(const ValueKey('local-language-shortcut-enabled')),
    );
    await tester.pumpAndSettle();

    expect(writes, [kLocalLanguageShortcutsEnabled]);
    expect(stored, kLocalLanguageShortcutsEnabled);
    expect(
      tester
          .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
          .groupValue,
      kLocalLanguageShortcutsEnabled,
    );
  });
}
