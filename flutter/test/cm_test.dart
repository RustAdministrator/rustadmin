import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/server_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/models/session_event.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:image/image.dart' as img2;
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:window_manager/window_manager.dart';

const _windowManagerChannel = MethodChannel('window_manager');

final testClients = [
  Client(0, true, false, false, 'UserAAAAAA', '123123123', true, false, false)
    ..disconnected = true,
  Client(1, true, false, false, 'UserBBBBB', '221123123', true, false, false)
    ..disconnected = true,
  Client(2, true, false, false, 'UserC', '331123123', true, false, false)
    ..disconnected = true,
  Client(3, true, false, false, 'UserDDDDDDDDDDDd', '441123123', true, false,
      false)
    ..disconnected = true,
];

SessionClientValue _sessionClient(Client client) => SessionClientValue(
      id: client.id,
      authorized: client.authorized,
      isFileTransfer: client.isFileTransfer,
      isViewCamera: client.isViewCamera,
      isTerminal: client.isTerminal,
      portForward: client.portForward,
      name: client.name,
      avatar: client.avatar,
      peerId: client.peerId,
      keyboard: client.keyboard,
      clipboard: client.clipboard,
      audio: client.audio,
      file: client.file,
      restart: client.restart,
      recording: client.recording,
      blockInput: client.blockInput,
      disconnected: client.disconnected,
      fromSwitch: client.fromSwitch,
      inVoiceCall: client.inVoiceCall,
      incomingVoiceCall: client.incomingVoiceCall,
    );

bool _testShouldBlockRustAdminGuiForActiveSessions = false;
String _testRemoteModifyControlPermission = '';
String _testKnownHostsJson = '';
List<PeerSecurityEntry> _testKnownHostsV2 = const [];

class _TestRustadminImpl implements Rustadmin {
  String _mainGetCommon(String key) {
    if (key == 'should-block-rustadmin-gui-for-active-sessions') {
      return _testShouldBlockRustAdminGuiForActiveSessions ? 'true' : 'false';
    }
    if (key == 'is-remote-modify-enabled-by-control-permissions') {
      return _testRemoteModifyControlPermission;
    }
    return '';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #translate:
        return invocation.namedArguments[#name] as String;
      case #mainGetLocalOption:
        final key = invocation.namedArguments[#key] as String;
        return key == kOptionAllowRemoteCmModification ? 'Y' : '';
      case #mainGetOptionSync:
      case #mainGetOptionsSync:
      case #mainGetPeerOptionSync:
      case #mainGetBuildinOption:
      case #mainGetCommonSync:
      case #mainGetAppNameSync:
      case #mainUriPrefixSync:
      case #getLocalFlutterOption:
        if (invocation.memberName == #mainGetCommonSync) {
          final key = invocation.namedArguments[#key] as String;
          return _mainGetCommon(key);
        }
        return '';
      case #mainGetCommon:
        final key = invocation.namedArguments[#key] as String;
        return Future<String>.value(_mainGetCommon(key));
      case #mainGetOption:
        final key = invocation.namedArguments[#key] as String;
        if (key == kOptionAccessMode) {
          return Future<String>.value('full');
        }
        if (key == kOptionAllowRemoteConfigModification) {
          return Future<String>.value('Y');
        }
        return Future<String>.value('');
      case #mainListPeerSecurityEntries:
        return Future<String>.value(_testKnownHostsJson);
      case #mainListPeerSecurityEntriesV2:
        return Future<List<PeerSecurityEntry>>.value(_testKnownHostsV2);
      case #mainGetPeerSync:
        return '{"info":{}}';
      case #isIncomingOnly:
      case #isOutgoingOnly:
      case #cmCanElevate:
      case #mainIsOptionFixed:
      case #mainShowOption:
      case #isDisableAb:
      case #isDisableAccount:
      case #isDisableGroupPanel:
        return false;
      case #getDoubleClickTime:
        return 500;
      case #cmGetClientsLength:
        return Future<int>.value(testClients.length);
      case #cmGetClickTime:
      case #mainGetMouseTime:
        return Future<double>.value(0);
      case #cmCheckClickTime:
      case #cmCloseConnection:
      case #cmRemoveDisconnectedConnection:
      case #cmRespondPermissionRequest:
      case #cmSwitchPermission:
      case #mainCheckMouseTime:
      case #mainLoadRecentPeers:
      case #mainSetLocalOption:
      case #setLocalFlutterOption:
        return Future<void>.value();
      default:
        throw UnimplementedError(
            'Unexpected Rust bridge call: ${invocation.memberName}');
    }
  }
}

Future<Object?> _handleWindowManagerCall(MethodCall call) async {
  switch (call.method) {
    case 'getBounds':
      return {
        'x': 0.0,
        'y': 0.0,
        'width': 400.0,
        'height': 600.0,
      };
    case 'isMaximized':
    case 'isMinimized':
    case 'isFullScreen':
    case 'isFocused':
    case 'isVisible':
    case 'isPreventClose':
    case 'isAlwaysOnTop':
    case 'isAlwaysOnBottom':
    case 'isSkipTaskbar':
      return false;
    case 'isResizable':
    case 'isMovable':
    case 'isMinimizable':
    case 'isMaximizable':
    case 'isClosable':
    case 'hasShadow':
    case 'grabKeyboard':
    case 'ungrabKeyboard':
      return true;
    case 'getOpacity':
      return 1.0;
    case 'getTitle':
      return 'RustDesk';
    case 'getTitleBarHeight':
      return 0;
    default:
      return null;
  }
}

Future<void> _initConnectionManagerTest() async {
  isTest = true;
  desktopType = DesktopType.cm;
  Get.testMode = true;
  _testShouldBlockRustAdminGuiForActiveSessions = false;
  _testRemoteModifyControlPermission = '';
  _testKnownHostsJson = '';
  _testKnownHostsV2 = const [];
  platformFFI.initForTest(_TestRustadminImpl());
  await initGlobalFFI();
}

void _seedConnectionManagerClients() {
  final serverModel = gFFI.serverModel;
  serverModel.clients.clear();
  serverModel.tabController.clear();
  for (final client in testClients) {
    final seededClient = Client.fromJson(client.toJson());
    serverModel.clients.add(seededClient);
    serverModel.tabController.add(TabInfo(
      key: seededClient.id.toString(),
      label: seededClient.name,
      closable: false,
      page: buildConnectionCard(seededClient),
    ));
  }
}

Widget _buildTestApp() {
  return GetMaterialApp(
    navigatorKey: globalKey,
    debugShowCheckedModeBanner: false,
    theme: MyTheme.lightTheme,
    darkTheme: MyTheme.darkTheme,
    themeMode: MyTheme.currentThemeMode(),
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: supportedLocales,
    home: const DesktopServerPage(),
  );
}

Widget _buildConnectionCardTestApp(Client client) {
  return GetMaterialApp(
    navigatorKey: globalKey,
    debugShowCheckedModeBanner: false,
    theme: MyTheme.lightTheme,
    home: ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: buildConnectionCard(client),
        ),
      ),
    ),
  );
}

Future<void> _disposeCmTestWidget(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  VisibilityDetectorController.instance.notifyNow();
}

void _clearDesktopListeners() {
  for (final listener in windowManager.listeners) {
    windowManager.removeListener(listener);
  }
  for (final listener in DesktopMultiWindow.listeners) {
    DesktopMultiWindow.removeListener(listener);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  test('RustAdmin default viewer permissions fail closed', () {
    final permissions = rustAdminDefaultSessionPermissions();

    expect(permissions['keyboard'], isTrue);
    for (final name in [
      'clipboard',
      'audio',
      'file',
      'restart',
      'recording',
      'block_input',
      'file_transfer',
      'port_forward',
      'view_camera',
      'terminal',
    ]) {
      expect(permissions[name], isFalse, reason: name);
    }
  });

  test('stored peer security includes config and QUIC-only records', () async {
    isTest = true;
    platformFFI.initForTest(_TestRustadminImpl());
    _testKnownHostsV2 = const [
      PeerSecurityEntry(
        id: 'peer-b',
        alias: '',
        username: '',
        hostname: 'beta',
        platform: 'Linux',
        lastUpdatedUnixMs: 100,
        hasPeerConfig: true,
        hasPassword: false,
        hasPinnedKey: false,
        pinnedKeyFingerprint: '',
        hasDirectPairingMemory: false,
        hasRendezvousPairingMemory: true,
        hasQuicIdentity: false,
        quicIdentityFingerprint: '',
        quicConfirmedAtUnixMs: 0,
      ),
      PeerSecurityEntry(
        id: 'peer-a',
        alias: 'Alias A',
        username: 'alice',
        hostname: 'alpha',
        platform: 'Windows',
        lastUpdatedUnixMs: 200,
        hasPeerConfig: true,
        hasPassword: true,
        hasPinnedKey: true,
        pinnedKeyFingerprint: 'signing fingerprint',
        hasDirectPairingMemory: true,
        hasRendezvousPairingMemory: false,
        hasQuicIdentity: true,
        quicIdentityFingerprint: 'quic fingerprint',
        quicConfirmedAtUnixMs: 200,
      ),
      PeerSecurityEntry(
        id: '192.0.2.10',
        alias: '',
        username: '',
        hostname: '',
        platform: '',
        lastUpdatedUnixMs: 50,
        hasPeerConfig: false,
        hasPassword: false,
        hasPinnedKey: false,
        pinnedKeyFingerprint: '',
        hasDirectPairingMemory: false,
        hasRendezvousPairingMemory: false,
        hasQuicIdentity: true,
        quicIdentityFingerprint: 'orphan fingerprint',
        quicConfirmedAtUnixMs: 50,
      ),
    ];

    final hosts = await KnownHost.get();

    expect(hosts.map((host) => host.id), [
      'peer-a',
      'peer-b',
      '192.0.2.10',
    ]);
    expect(hosts.first.displayName, 'Alias A');
    expect(hosts.first.userAndHost, 'alice@alpha');
    expect(hosts.first.hasPassword, isTrue);
    expect(hosts.first.hasPinnedKey, isTrue);
    expect(hosts.first.hasDirectPairingMemory, isTrue);
    expect(hosts.first.hasRendezvousPairingMemory, isFalse);
    expect(hosts.first.hasQuicIdentity, isTrue);
    expect(hosts.first.identitySummary, contains('quic fingerprint'));
    expect(hosts[1].hasRendezvousPairingMemory, isTrue);
    expect(hosts.last.hasPeerConfig, isFalse);
    expect(hosts.last.hasQuicIdentity, isTrue);
    expect(hosts.last.deviceSummary, contains('QUIC-only record'));
  });

  test('typed and web fallback peer security records stay equivalent', () {
    const timestamp = 1710000000000;
    const ffiEntry = PeerSecurityEntry(
      id: 'peer-parity',
      alias: 'Alias',
      username: 'user',
      hostname: 'host',
      platform: 'Windows',
      lastUpdatedUnixMs: timestamp,
      hasPeerConfig: true,
      hasPassword: true,
      hasPinnedKey: true,
      pinnedKeyFingerprint: 'signing',
      hasDirectPairingMemory: true,
      hasRendezvousPairingMemory: false,
      hasQuicIdentity: true,
      quicIdentityFingerprint: 'quic',
      quicConfirmedAtUnixMs: timestamp,
    );
    final fromFfi = KnownHost.fromFfi(ffiEntry);
    final fromJson = KnownHost.fromJson({
      'id': ffiEntry.id,
      'alias': ffiEntry.alias,
      'username': ffiEntry.username,
      'hostname': ffiEntry.hostname,
      'platform': ffiEntry.platform,
      'last_updated_unix_ms': timestamp.toString(),
      'has_peer_config': ffiEntry.hasPeerConfig,
      'has_password': ffiEntry.hasPassword,
      'has_pinned_key': ffiEntry.hasPinnedKey,
      'pinned_key_fingerprint': ffiEntry.pinnedKeyFingerprint,
      'has_direct_pairing_memory': ffiEntry.hasDirectPairingMemory,
      'has_rendezvous_pairing_memory': ffiEntry.hasRendezvousPairingMemory,
      'has_quic_identity': ffiEntry.hasQuicIdentity,
      'quic_identity_fingerprint': ffiEntry.quicIdentityFingerprint,
      'quic_confirmed_at_unix_ms': timestamp.toString(),
    });

    expect(fromJson.id, fromFfi.id);
    expect(fromJson.displayName, fromFfi.displayName);
    expect(fromJson.userAndHost, fromFfi.userAndHost);
    expect(fromJson.lastUpdatedUnixMs, timestamp);
    expect(fromJson.quicConfirmedAtUnixMs, timestamp);
    expect(fromJson.storedSecurity, fromFfi.storedSecurity);
    expect(fromJson.identitySummary, fromFfi.identitySummary);
  });

  testWidgets('stored peer security table renders orphan QUIC records',
      (tester) async {
    isTest = true;
    platformFFI.initForTest(_TestRustadminImpl());
    final hosts = <KnownHost>[
      KnownHost.fromJson({
        'id': '192.0.2.10',
        'last_updated_unix_ms': 50,
        'has_peer_config': false,
        'has_quic_identity': true,
        'quic_identity_fingerprint': 'orphan fingerprint',
        'quic_confirmed_at_unix_ms': 50,
      }),
    ].obs;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => knownHostsTable(
          context,
          hosts,
          <String>[].obs,
        ),
      ),
    ));

    expect(find.text('192.0.2.10'), findsWidgets);
    expect(find.textContaining('QUIC-only record'), findsOneWidget);
    expect(find.textContaining('orphan fingerprint'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('cursor cache data keeps independent height and y hotspot', () {
    final cursor = CursorData(
      peerId: 'peer-a',
      id: 'cursor-a',
      image: img2.Image(width: 12, height: 24),
      scale: 1.0,
      data: null,
      hotxOrigin: 3,
      hotyOrigin: 7,
      width: 12,
      height: 24,
    );

    expect(cursor.hotx, 3);
    expect(cursor.hoty, 7);

    expect(cursor.updateGetKey(2.0), 'peer-a_cursor-a_240000000_480000000');
    expect(cursor.hotx, 6);
    expect(cursor.hoty, 14);
  });

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            _windowManagerChannel, _handleWindowManagerCall);
    await windowManager.ensureInitialized();
    await _initConnectionManagerTest();
    _seedConnectionManagerClients();
  });

  tearDown(() {
    VisibilityDetectorController.instance.notifyNow();
    _clearDesktopListeners();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowManagerChannel, null);
    Get.reset();
  });

  test('remote CM modification cannot bypass active support-session block', () {
    expect(allowRemoteCMModification(), isTrue);

    _testShouldBlockRustAdminGuiForActiveSessions = true;

    expect(allowRemoteCMModification(), isFalse);
  });

  test('active support-session policy blocks settings unlocks', () async {
    expect(await canBeBlocked(), isFalse);

    _testShouldBlockRustAdminGuiForActiveSessions = true;

    expect(await canBeBlocked(), isTrue);

    _testRemoteModifyControlPermission = 'true';

    expect(await canBeBlocked(), isTrue);
  });

  testWidgets('renders seeded connection-manager clients', (tester) async {
    await tester.pumpWidget(_buildTestApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('UserAAAAAA'), findsWidgets);
    expect(find.text('UserBBBBB'), findsWidgets);
    expect(find.text('UserC'), findsWidgets);
    expect(find.text('UserDDDDDDDDDDDd'), findsWidgets);
    await _disposeCmTestWidget(tester);
  });

  testWidgets('renders a disconnected connection card', (tester) async {
    await tester.pumpWidget(_buildConnectionCardTestApp(testClients.first));
    await tester.pump();

    expect(find.text('UserAAAAAA'), findsOneWidget);
    expect(find.text('(123123123)'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    await _disposeCmTestWidget(tester);
  });

  testWidgets('connection permission icons follow authoritative CM updates',
      (tester) async {
    final client = Client(
      10,
      true,
      false,
      false,
      'SupportUser',
      '991122334',
      true,
      false,
      false,
    );
    gFFI.serverModel.clients
      ..clear()
      ..add(client);

    await tester.pumpWidget(_buildConnectionCardTestApp(client));
    await tester.pump();

    expect(find.byTooltip('Enable clipboard: OFF'), findsOneWidget);
    expect(find.byTooltip('Enable clipboard: ON'), findsNothing);

    gFFI.serverModel.updateClientPermissionEvent(
      const ClientPermissionSessionEvent(
        kind: ClientPermissionKind.update,
        clientId: 10,
        name: 'clipboard',
        enabled: true,
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Enable clipboard: OFF'), findsNothing);
    expect(find.byTooltip('Enable clipboard: ON'), findsOneWidget);

    await _disposeCmTestWidget(tester);
  });

  test('authorized connection refresh updates existing CM permission snapshot',
      () {
    final existing = Client(
      20,
      false,
      false,
      false,
      'PendingUser',
      '551122334',
      true,
      false,
      false,
    );
    gFFI.serverModel.clients
      ..clear()
      ..add(existing);
    gFFI.serverModel.hideCm = true;

    final authorized = Client(
      20,
      true,
      false,
      false,
      'PendingUser',
      '551122334',
      true,
      true,
      true,
    )
      ..file = true
      ..restart = true
      ..recording = true
      ..blockInput = true;

    gFFI.serverModel.addConnectionEvent(_sessionClient(authorized));

    expect(existing.authorized, isTrue);
    expect(existing.clipboard, isTrue);
    expect(existing.audio, isTrue);
    expect(existing.file, isTrue);
    expect(existing.restart, isTrue);
    expect(existing.recording, isTrue);
    expect(existing.blockInput, isTrue);
  });

  testWidgets('renders permission request below connection toolbar',
      (tester) async {
    await tester.pumpWidget(_buildTestApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    gFFI.serverModel.handlePermissionRequestEvent(
      const ClientPermissionSessionEvent(
        kind: ClientPermissionKind.request,
        clientId: 0,
        requestId: '42',
        name: 'clipboard',
        enabled: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('permission-request-overlay')),
        findsOneWidget);
    expect(find.text('Allow Clipboard?'), findsOneWidget);
    expect(
        find.text(
            'The remote user can read and write clipboard data during this session.'),
        findsOneWidget);

    final decline = find.widgetWithText(OutlinedButton, 'Decline');
    final allow = find.widgetWithText(ElevatedButton, 'Allow');
    expect(decline, findsOneWidget);
    expect(allow, findsOneWidget);
    expect(tester.getRect(decline).center.dy, tester.getRect(allow).center.dy);
    expect(
        tester
            .getTopLeft(
                find.byKey(const ValueKey('permission-request-overlay')))
            .dy,
        greaterThanOrEqualTo(kDesktopRemoteTabBarHeight));

    await _disposeCmTestWidget(tester);
  });
}
