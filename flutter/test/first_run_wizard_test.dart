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
                  localPairingPassphrase: '',
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
    await tester.enterText(find.byType(TextField), 'vpn-only');
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
    expect(result!.localPairingPassphrase, 'vpn-only');
    expect(result!.showOnNextStart, isFalse);
  });

  testWidgets('skip returns the current settings unchanged', (tester) async {
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
                  localPairingPassphrase: 'already-set',
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
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.directAccessEnabled, isFalse);
    expect(result!.lanDiscoveryMode, kLanDiscoveryModeStandard);
    expect(result!.localPairingPassphrase, 'already-set');
    expect(result!.showOnNextStart, isTrue);
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
                  localPairingPassphrase: 'stored-local-pairing',
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
    expect(result!.localPairingPassphrase, 'stored-local-pairing');
  });
}
