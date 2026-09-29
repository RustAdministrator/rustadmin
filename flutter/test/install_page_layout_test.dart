import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/install_page.dart';
import 'package:flutter_hbb/desktop/widgets/content_sized_window.dart';
import 'package:flutter_hbb/generated_bridge.dart' show Rustadmin;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

class _InstallerBridge implements Rustadmin {
  bool longText = false;
  int installs = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #translate:
        final name = invocation.namedArguments[#name] as String;
        if (name == 'agreement_tip') {
          return 'Installing RustAdmin means you agree to the license terms.';
        }
        return longText ? '$name with a much longer translated label' : name;
      case #installInstallPath:
        return '/Applications/RustAdmin.app';
      case #installInstallOptions:
        return '{}';
      case #mainGetAppNameSync:
        return 'RustAdmin';
      case #getLocalFlutterOption:
      case #mainGetLocalOption:
        return '';
      case #isIncomingOnly:
      case #isOutgoingOnly:
      case #installShowRunWithoutInstall:
        return false;
      case #installInstallMe:
        installs++;
        return Future<void>.value();
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _InstallerBridge bridge;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    isTest = true;
    bridge = _InstallerBridge();
    platformFFI.initForTest(bridge);
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
    Get.reset();
  });

  Future<List<Size>> showInstaller(
    WidgetTester tester, {
    bool upgrade = false,
    double width = 800,
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    final requests = <Size>[];
    final controller = ContentSizedWindowController(
      availableHeight: () => 800,
      nativeChromeHeight: () => 0,
      onSizeChanged: (size) {
        requests.add(size);
        tester.view.physicalSize = Size(width, size.height);
      },
    );
    await tester.pumpWidget(
      GetMaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: InstallPage(
          isUpgrade: upgrade,
          contentSizedWindowController: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Drain the existing delayed native maximization query before disposing.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byType(ContentSizedWindow), findsOneWidget);
    expect(controller.isReady, isTrue);
    expect(tester.takeException(), isNull);
    return requests;
  }

  Future<void> clearInstaller(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  testWidgets(
    'install and upgrade fit their actual content with matching footer padding',
    (tester) async {
      final install = await showInstaller(tester);
      final installHeight = install.last.height;
      final contentBottom = tester
          .getBottomLeft(find.byKey(const ValueKey('install-body-column')))
          .dy;
      expect(installHeight - contentBottom, closeTo(52, 1));
      expect(find.byType(Checkbox), findsNWidgets(3));
      final button = find.text('Accept and Install');
      final buttonBefore = tester.getRect(button);
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(bridge.installs, 1);
      expect(tester.getRect(button), buttonBefore);
      expect(install.last.height, installHeight);
      await clearInstaller(tester);

      final upgrade = await showInstaller(tester, upgrade: true);
      expect(upgrade.last.height, lessThan(installHeight));
      expect(find.byType(Checkbox), findsNothing);
      final upgradeBottom = tester
          .getBottomLeft(find.byKey(const ValueKey('install-body-column')))
          .dy;
      expect(upgrade.last.height - upgradeBottom, closeTo(52, 1));
      await clearInstaller(tester);
    },
  );

  testWidgets(
    'long labels and enlarged text fit normal and narrow installers',
    (tester) async {
      bridge.longText = true;
      for (final width in [800.0, 460.0]) {
        final requests = await showInstaller(
          tester,
          width: width,
          textScale: 1.5,
        );
        expect(requests.last.height, lessThanOrEqualTo(800));
        final viewport = find.byType(SingleChildScrollView).first;
        await tester.drag(viewport, const Offset(0, -2000));
        await tester.pumpAndSettle();
        expect(
          find.text('Cancel with a much longer translated label').hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await clearInstaller(tester);
      }
    },
  );
}
