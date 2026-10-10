import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/first_run_wizard.dart';

Widget buildTestApp(Widget child) {
  return MaterialApp(
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('wizard advances, updates settings, and returns finish result',
      (tester) async {
    FirstRunWizardSettings? result;

    await tester.pumpWidget(buildTestApp(
      Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () async {
              result = await showFirstRunWizardDialog(
                context: context,
                initialSettings: const FirstRunWizardSettings(
                  directAccessEnabled: true,
                  lanDiscoveryMode: kLanDiscoveryModeOff,
                  localPairingPassphraseConfigured: false,
                  showOnNextStart: true,
                ),
                directAccessFixed: false,
                lanDiscoveryFixed: false,
                localPairingFixed: false,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to RustAdmin'), findsOneWidget);
    expect(find.text('Show on next start'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    expect(find.text('Enable direct local/VPN access'), findsOneWidget);
    final trustedPeersOnly = find.byWidgetPredicate(
      (widget) =>
          widget is RadioListTile<String> &&
          widget.value == kLanDiscoveryModeTrustedPeersOnly,
    );
    await tester.ensureVisible(trustedPeersOnly);
    await tester.tap(trustedPeersOnly);
    await tester.pumpAndSettle();
    // Typed verbatim: leading and trailing spaces are part of a passphrase.
    await tester.enterText(find.byType(TextField), ' vpn only ');
    await tester.ensureVisible(find.text('Show on next start'));
    await tester.tap(find.text('Show on next start'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    expect(find.text('Ready to apply'), findsOneWidget);
    expect(find.text('Trusted peers only'), findsOneWidget);
    expect(find.text('Configured'), findsOneWidget);

    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.directAccessEnabled, isTrue);
    expect(result!.lanDiscoveryMode, kLanDiscoveryModeTrustedPeersOnly);
    expect(result!.newLocalPairingPassphrase, ' vpn only ');
    expect(result!.clearLocalPairingPassphrase, isFalse);
    expect(result!.showOnNextStart, isFalse);
  });

  testWidgets('welcome page requires moving through setup', (tester) async {
    FirstRunWizardSettings? result;

    await tester.pumpWidget(buildTestApp(
      Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () async {
              result = await showFirstRunWizardDialog(
                context: context,
                initialSettings: const FirstRunWizardSettings(
                  directAccessEnabled: false,
                  lanDiscoveryMode: kLanDiscoveryModeStandard,
                  localPairingPassphraseConfigured: true,
                  showOnNextStart: true,
                ),
                directAccessFixed: false,
                lanDiscoveryFixed: false,
                localPairingFixed: false,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to RustAdmin'), findsOneWidget);
    expect(find.text('Skip'), findsNothing);
    expect(find.text('Back'), findsNothing);
    expect(find.text('Next'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('How connections work'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to RustAdmin'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('local pairing passphrase depends on direct access',
      (tester) async {
    FirstRunWizardSettings? result;

    await tester.pumpWidget(buildTestApp(
      Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () async {
              result = await showFirstRunWizardDialog(
                context: context,
                initialSettings: const FirstRunWizardSettings(
                  directAccessEnabled: false,
                  lanDiscoveryMode: kLanDiscoveryModeOff,
                  localPairingPassphraseConfigured: true,
                  showOnNextStart: true,
                ),
                directAccessFixed: false,
                lanDiscoveryFixed: false,
                localPairingFixed: false,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
    expect(
      find.text('Enable direct local/VPN access to require local pairing.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    expect(find.text('Ready to apply'), findsOneWidget);
    expect(find.text('Configured'), findsOneWidget);

    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.directAccessEnabled, isFalse);
    // Nothing typed: the stored passphrase is left alone.
    expect(result!.localPairingPassphraseConfigured, isTrue);
    expect(result!.newLocalPairingPassphrase, isEmpty);
    expect(result!.clearLocalPairingPassphrase, isFalse);
  });

  Future<FirstRunWizardSettings?> openOnQuickSetup(
    WidgetTester tester, {
    required bool configured,
    int maxPassphraseLength = 128,
  }) async {
    FirstRunWizardSettings? result;
    await tester.pumpWidget(buildTestApp(
      Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () async {
              result = await showFirstRunWizardDialog(
                context: context,
                initialSettings: FirstRunWizardSettings(
                  directAccessEnabled: true,
                  lanDiscoveryMode: kLanDiscoveryModeOff,
                  localPairingPassphraseConfigured: configured,
                  showOnNextStart: true,
                ),
                directAccessFixed: false,
                lanDiscoveryFixed: false,
                localPairingFixed: false,
                maxPassphraseLength: maxPassphraseLength,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('the stored passphrase is never put in the field',
      (tester) async {
    await openOnQuickSetup(tester, configured: true, maxPassphraseLength: 64);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(field.maxLength, 64);
    expect(find.text('Leave empty to keep the current one'), findsOneWidget);
  });

  testWidgets('typing replaces and the clear button removes the passphrase',
      (tester) async {
    FirstRunWizardSettings? result;
    await tester.pumpWidget(buildTestApp(
      Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () async {
              result = await showFirstRunWizardDialog(
                context: context,
                initialSettings: const FirstRunWizardSettings(
                  directAccessEnabled: true,
                  lanDiscoveryMode: kLanDiscoveryModeOff,
                  localPairingPassphraseConfigured: true,
                  showOnNextStart: true,
                ),
                directAccessFixed: false,
                lanDiscoveryFixed: false,
                localPairingFixed: false,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'new secret');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Will be replaced'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();

    final clear = find.byTooltip('Remove the passphrase');
    await tester.ensureVisible(clear);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Will be removed'), findsOneWidget);

    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(result!.clearLocalPairingPassphrase, isTrue);
    expect(result!.newLocalPairingPassphrase, isEmpty);
  });

  group('firstRunWizardChanges', () {
    const initial = FirstRunWizardSettings(
      directAccessEnabled: true,
      lanDiscoveryMode: kLanDiscoveryModeOff,
      localPairingPassphraseConfigured: true,
      showOnNextStart: true,
    );

    List<FirstRunWizardChange> plan(
      FirstRunWizardSettings result, {
      bool directFixed = false,
      bool pairingFixed = false,
      FirstRunWizardSettings base = initial,
    }) =>
        firstRunWizardChanges(
          initial: base,
          result: result,
          directAccessFixed: directFixed,
          localPairingFixed: pairingFixed,
        );

    test('an untouched wizard writes nothing', () {
      expect(plan(initial), isEmpty);
    });

    test('a typed passphrase replaces, an empty field keeps', () {
      expect(
        plan(initial.copyWith(newLocalPairingPassphrase: ' a b ')),
        [
          const FirstRunWizardChange(
              kOptionDirectAccessPairingPassphrase, ' a b ')
        ],
      );
      expect(plan(initial.copyWith(newLocalPairingPassphrase: '')), isEmpty);
    });

    test('clearing removes only a passphrase that is set', () {
      expect(
        plan(initial.copyWith(clearLocalPairingPassphrase: true)),
        [const FirstRunWizardChange(kOptionDirectAccessPairingPassphrase, '')],
      );
      const none = FirstRunWizardSettings(
        directAccessEnabled: true,
        lanDiscoveryMode: kLanDiscoveryModeOff,
        localPairingPassphraseConfigured: false,
        showOnNextStart: true,
      );
      expect(
        plan(none.copyWith(clearLocalPairingPassphrase: true), base: none),
        isEmpty,
      );
    });

    test('the access scope is written only when it changes and is not fixed',
        () {
      expect(
        plan(initial.copyWith(directAccessScope: kDirectAccessScopeLocal))
            .map((c) => '${c.key}=${c.value}'),
        ['$kOptionDirectAccessScope=$kDirectAccessScopeLocal'],
      );
      // Empty and "any" are the same scope: no write.
      expect(plan(initial.copyWith(directAccessScope: '')), isEmpty);
      expect(
        firstRunWizardChanges(
          initial: initial,
          result: initial.copyWith(directAccessScope: kDirectAccessScopeLocal),
          directAccessFixed: false,
          localPairingFixed: false,
          directScopeFixed: true,
        ),
        isEmpty,
      );
    });

    test('settings managed by the deployment are never written', () {
      final edited = initial.copyWith(
        directAccessEnabled: false,
        newLocalPairingPassphrase: 'x',
      );
      expect(plan(edited, directFixed: true, pairingFixed: true), isEmpty);
      expect(
        plan(edited, pairingFixed: true).map((c) => c.key),
        [kOptionDirectServer],
      );
    });
  });

  group('applyFirstRunWizardResult', () {
    const initial = FirstRunWizardSettings(
      directAccessEnabled: true,
      lanDiscoveryMode: kLanDiscoveryModeOff,
      localPairingPassphraseConfigured: false,
      showOnNextStart: true,
    );

    Future<_FakePlatform> run(
      FirstRunWizardSettings result, {
      bool allowed = true,
      bool disabled = false,
    }) async {
      final platform = _FakePlatform(allowed: allowed, disabled: disabled);
      await applyFirstRunWizardResult(
        initial: initial,
        result: result,
        directAccessFixed: false,
        lanDiscoveryFixed: false,
        localPairingFixed: false,
        platform: platform,
      );
      return platform;
    }

    final edited = initial.copyWith(
      directAccessEnabled: false,
      lanDiscoveryMode: kLanDiscoveryModeStandard,
      newLocalPairingPassphrase: 'secret',
      showOnNextStart: false,
    );

    test('writes after the unlock and records the preference', () async {
      final platform = await run(edited);
      expect(platform.accessRequests, 1);
      expect(platform.written.map((e) => e.key), [
        kOptionDirectServer,
        kOptionDirectAccessPairingPassphrase,
      ]);
      expect(platform.lanMode, kLanDiscoveryModeStandard);
      expect(platform.showOnNextStart, isFalse);
    });

    test('a refused unlock writes no setting', () async {
      final platform = await run(edited, allowed: false);
      expect(platform.accessRequests, 1);
      expect(platform.written, isEmpty);
      expect(platform.lanMode, isNull);
      expect(platform.showOnNextStart, isFalse);
    });

    test('disabled settings are never written or even asked about',
        () async {
      final platform = await run(edited, disabled: true);
      expect(platform.accessRequests, 0);
      expect(platform.written, isEmpty);
      expect(platform.lanMode, isNull);
    });

    test('an untouched wizard asks for no unlock', () async {
      final platform = await run(initial);
      expect(platform.accessRequests, 0);
      expect(platform.written, isEmpty);
    });
  });
}

class _FakePlatform implements FirstRunWizardPlatform {
  _FakePlatform({required this.allowed, required this.disabled});

  final bool allowed;
  final bool disabled;
  int accessRequests = 0;
  final written = <FirstRunWizardChange>[];
  String? lanMode;
  bool? showOnNextStart;

  @override
  Future<bool> requestWriteAccess() async {
    accessRequests++;
    return allowed;
  }

  @override
  bool settingsDisabled() => disabled;

  @override
  Future<void> writeOption(String key, String value) async =>
      written.add(FirstRunWizardChange(key, value));

  @override
  Future<void> writeLanDiscoveryMode(String mode) async => lanMode = mode;

  @override
  Future<void> writeShowOnNextStart(bool show) async => showOnNextStart = show;
}
