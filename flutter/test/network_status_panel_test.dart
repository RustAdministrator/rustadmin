import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/connection_page.dart';

Widget buildTestApp(Widget child) {
  return MaterialApp(
    theme: MyTheme.lightTheme,
    home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(16), child: child)),
  );
}

void main() {
  test('colorForNetworkMode maps known modes to expected colors', () {
    expect(colorForNetworkMode('local_only'), const Color(0xFF2E8B57));
    expect(colorForNetworkMode('private_server'), const Color(0xFF2F65BA));
    expect(colorForNetworkMode('public_server'), const Color(0xFFF39C12));
    expect(colorForNetworkMode('not_configured'), Colors.grey);
    expect(colorForNetworkMode('unexpected'), Colors.grey);
  });

  testWidgets(
      'renders local-only panel with collapsible trust and direct access details',
      (tester) async {
    await tester.pumpWidget(buildTestApp(
      const NetworkStatusPanelBody(
        mode: 'local_only',
        label: 'Local Only',
        detail: '',
        trustPhrase: 'amber river solar mint dune cedar',
        directEndpoints: ['192.168.1.25:21118', '10.8.0.5:21118'],
        pairingRequired: true,
        lanDiscoveryLabel: 'Trusted Peers Only',
      ),
    ));

    expect(find.text('Local Only'), findsOneWidget);
    expect(find.text('LAN discovery: Trusted Peers Only'), findsOneWidget);
    expect(find.text('Trust phrase'), findsOneWidget);
    expect(find.text('Direct access'), findsOneWidget);
    expect(find.text('amber river solar mint dune cedar'), findsNothing);
    expect(find.text('Local pairing passphrase: Required'), findsNothing);
    expect(find.text('192.168.1.25:21118, 10.8.0.5:21118'), findsNothing);
    expect(find.textContaining('Endpoint:'), findsNothing);
    expect(find.byIcon(Icons.copy_rounded), findsNothing);

    await tester.tap(find.text('Trust phrase'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direct access'));
    await tester.pumpAndSettle();

    expect(find.text('amber river solar mint dune cedar'), findsOneWidget);
    expect(find.text('Local pairing passphrase: Required'), findsOneWidget);
    expect(find.text('192.168.1.25:21118, 10.8.0.5:21118'), findsOneWidget);
    expect(find.byIcon(Icons.copy_rounded), findsNWidgets(2));
  });

  testWidgets('renders private-server panel without local-only extras',
      (tester) async {
    await tester.pumpWidget(buildTestApp(
      const NetworkStatusPanelBody(
        mode: 'private_server',
        label: 'Private Server',
        detail: 'hbbs.example.local:21116',
        trustPhrase: '',
        directEndpoints: [],
        pairingRequired: false,
        lanDiscoveryLabel: 'Off',
      ),
    ));

    expect(find.text('Private Server'), findsOneWidget);
    expect(find.text('LAN discovery: Off'), findsOneWidget);
    expect(find.text('Endpoint: hbbs.example.local:21116'), findsOneWidget);
    expect(find.textContaining('Trust phrase:'), findsNothing);
    expect(find.textContaining('Pairing passphrase:'), findsNothing);
    expect(find.textContaining('Direct access:'), findsNothing);
    expect(find.byIcon(Icons.copy_rounded), findsNothing);
  });

  testWidgets('renders offline panel with minimal status only', (tester) async {
    await tester.pumpWidget(buildTestApp(
      const NetworkStatusPanelBody(
        mode: 'not_configured',
        label: 'Offline',
        detail: '',
        trustPhrase: '',
        directEndpoints: [],
        pairingRequired: false,
        lanDiscoveryLabel: 'Off',
      ),
    ));

    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('LAN discovery: Off'), findsOneWidget);
    expect(find.textContaining('Trust phrase:'), findsNothing);
    expect(find.textContaining('Pairing passphrase:'), findsNothing);
    expect(find.textContaining('Direct access:'), findsNothing);
    expect(find.textContaining('Endpoint:'), findsNothing);
  });
}
