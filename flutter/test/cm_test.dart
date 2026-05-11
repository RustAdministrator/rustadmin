import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/server_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
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

class _TestRustdeskImpl implements RustdeskImpl {
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
      case #mainGetAppNameSync:
      case #mainUriPrefixSync:
      case #getLocalFlutterOption:
        return '';
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
      case #cmSwitchPermission:
      case #mainCheckMouseTime:
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
  platformFFI.initForTest(_TestRustdeskImpl());
  await initGlobalFFI();
}

void _seedConnectionManagerClients() {
  final serverModel = gFFI.serverModel;
  serverModel.clients.clear();
  serverModel.tabController.clear();
  for (final client in testClients) {
    serverModel.clients.add(client);
    serverModel.tabController.add(TabInfo(
      key: client.id.toString(),
      label: client.name,
      closable: false,
      page: buildConnectionCard(client),
    ));
  }
}

Widget _buildTestApp() {
  return GetMaterialApp(
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            _windowManagerChannel, _handleWindowManagerCall);
    await windowManager.ensureInitialized();
    await _initConnectionManagerTest();
    _seedConnectionManagerClients();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowManagerChannel, null);
    Get.reset();
  });

  testWidgets('renders seeded connection-manager clients', (tester) async {
    await tester.pumpWidget(_buildTestApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('UserAAAAAA'), findsWidgets);
    expect(find.text('UserBBBBB'), findsWidgets);
    expect(find.text('UserC'), findsWidgets);
    expect(find.text('UserDDDDDDDDDDDd'), findsWidgets);
  });

  testWidgets('renders a disconnected connection card', (tester) async {
    await tester.pumpWidget(_buildConnectionCardTestApp(testClients.first));
    await tester.pump();

    expect(find.text('UserAAAAAA'), findsOneWidget);
    expect(find.text('(123123123)'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });
}
