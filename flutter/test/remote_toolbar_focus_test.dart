import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/remote_input.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _TestRustadminImpl implements Rustadmin {
  int initInputSourceCalls = 0;
  String toolbarDragX = '';
  String toolbarOrientation = '';
  bool qualityMonitorVisible = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    if (name == #translate) {
      return invocation.namedArguments[#name] as String;
    }
    if (name == #getLocalFlutterOption ||
        name == #mainGetLocalOption ||
        name == #mainGetUserDefaultOption ||
        name == #mainSupportedInputSource ||
        name == #mainGetDisplays) {
      return '';
    }
    if (name == #mainGetInputSource) {
      return 'Input source 1';
    }
    if (name == #mainInitInputSource) {
      initInputSourceCalls += 1;
      return null;
    }
    if (name == #sessionGetOption) {
      final option = invocation.namedArguments[#arg];
      if (option == 'remote-menubar-drag-x') {
        return Future<String?>.value(toolbarDragX);
      }
      if (option == 'remote-menubar-orientation') {
        return Future<String?>.value(toolbarOrientation);
      }
      return Future<String?>.value('');
    }
    if (name == #sessionGetViewStyle ||
        name == #sessionGetScrollStyle ||
        name == #sessionGetImageQuality) {
      return Future<String?>.value('');
    }
    if (name == #sessionAlternativeCodecs) {
      return Future<String>.value('{}');
    }
    if (name == #sessionGetToggleOption) {
      final option = invocation.namedArguments[#arg];
      return Future<bool?>.value(
          option == 'show-quality-monitor' && qualityMonitorVisible);
    }
    if (name == #sessionToggleOption) {
      if (invocation.namedArguments[#value] == 'show-quality-monitor') {
        qualityMonitorVisible = !qualityMonitorVisible;
      }
      return Future<void>.value();
    }
    if (name == #mainSetLocalOption || name == #setLocalFlutterOption) {
      return Future<void>.value();
    }
    if (name == #isDisableAb ||
        name == #isDisableAccount ||
        name == #isDisableGroupPanel ||
        name == #mainCurrentIsWayland ||
        name == #mainHasFileClipboard ||
        name == #sessionGetToggleOptionSync) {
      return false;
    }
    if (name == #versionToNumber || name == #peerGetSessionsCount) {
      return 0;
    }
    return null;
  }
}

void main() {
  late _TestRustadminImpl testImpl;

  setUpAll(() {
    isTest = true;
    testImpl = _TestRustadminImpl();
    platformFFI.initForTest(testImpl);
  });

  test('shared remote page initializes the native input source', () {
    final callsBefore = testImpl.initInputSourceCalls;

    initializeDesktopRemoteInputSource();

    expect(testImpl.initInputSourceCalls, callsBefore + 1);
    expect(stateGlobal.getInputSource(), 'Input source 1');
  });

  test('pointer-down recovery only rearms a missed non-Windows enter', () {
    expect(
      shouldRearmDesktopRemoteInputOnPointerDown(
        isWindowsPlatform: false,
        cursorOverImage: false,
      ),
      isTrue,
    );
    expect(
      shouldRearmDesktopRemoteInputOnPointerDown(
        isWindowsPlatform: false,
        cursorOverImage: true,
      ),
      isFalse,
    );
    expect(
      shouldRearmDesktopRemoteInputOnPointerDown(
        isWindowsPlatform: true,
        cursorOverImage: false,
      ),
      isFalse,
    );
  });

  testWidgets('an open toolbar menu blocks remote canvas focus stealing', (
    tester,
  ) async {
    const peerId = 'toolbar-focus-test-peer';
    initSharedStates(peerId);
    addTearDown(() => removeSharedStates(peerId));
    testImpl.toolbarDragX = '0.0';
    testImpl.toolbarOrientation = 'vertical';
    testImpl.qualityMonitorVisible = false;
    addTearDown(() {
      testImpl.toolbarDragX = '';
      testImpl.toolbarOrientation = '';
      testImpl.qualityMonitorVisible = false;
    });

    final rawKeyFocusNode = FocusNode(debugLabel: 'testRawKeyFocusNode');
    addTearDown(rawKeyFocusNode.dispose);

    final state = ToolbarState()..initialized.value = true;
    final ffi = FFI(null)
      ..id = peerId
      ..connType = ConnType.viewCamera;
    final menuFocusChanges = <bool>[];
    var closeCount = 0;
    var showToolbar = true;
    late StateSetter rebuildRemotePage;

    await tester.pumpWidget(
      MaterialApp(
        theme: MyTheme.lightTheme,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuildRemotePage = setState;
              return Stack(
                children: [
                  Positioned.fill(
                    child: RawKeyFocusScope(
                      focusNode: rawKeyFocusNode,
                      inputModel: ffi.inputModel,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  MultiProvider(
                    providers: [
                      ChangeNotifierProvider.value(value: ffi.ffiModel),
                      ChangeNotifierProvider.value(value: ffi.imageModel),
                      ChangeNotifierProvider.value(value: ffi.cursorModel),
                      ChangeNotifierProvider.value(value: ffi.canvasModel),
                      ChangeNotifierProvider.value(value: ffi.recordingModel),
                    ],
                    child: showToolbar
                        ? RemoteToolbar(
                            id: peerId,
                            ffi: ffi,
                            state: state,
                            onEnterOrLeaveImageSetter: (_, __) {},
                            onEnterOrLeaveImageCleaner: (_) {},
                            onImagePointerStateSetter: (_, __) {},
                            onImagePointerStateCleaner: (_) {},
                            onWindowPointerStateSetter: (_, __) {},
                            onWindowPointerStateCleaner: (_) {},
                            onMenuFocusChanged: (menuOpen) {
                              menuFocusChanges.add(menuOpen);
                              rawKeyFocusNode.canRequestFocus = !menuOpen;
                            },
                            onCloseConnection: () => closeCount++,
                            setRemoteState: (_) {},
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    rawKeyFocusNode.requestFocus();
    await tester.pump();
    expect(rawKeyFocusNode.hasFocus, isTrue);

    expect(find.text('QM'), findsOneWidget);
    final qmInk = find
        .ancestor(of: find.text('QM'), matching: find.byType(Ink))
        .first;
    expect(
      tester.getSize(qmInk),
      const Size.square(32),
      reason: 'QM must use the same stable square surface as toolbar icons',
    );
    expect(ffi.qualityMonitorModel.showListenable.value, isFalse);
    await tester.tap(find.text('QM'));
    await tester.pumpAndSettle();
    expect(ffi.qualityMonitorModel.showListenable.value, isTrue);
    await tester.tap(find.text('QM'));
    await tester.pumpAndSettle();
    expect(ffi.qualityMonitorModel.showListenable.value, isFalse);

    await tester.tap(
      find.byTooltip('Display Settings'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(menuFocusChanges, [true]);
    expect(rawKeyFocusNode.canRequestFocus, isFalse);
    expect(find.text('Scale original'), findsOneWidget);
    expect(find.text('Tabs in fullscreen'), findsOneWidget);

    final toolbarButtonRect = tester.getRect(
      find.byTooltip('Display Settings'),
    );
    final rootMenuItemRect = tester.getRect(find.text('Scale original'));
    expect(
      rootMenuItemRect.left,
      greaterThan(toolbarButtonRect.right),
      reason: 'a fresh left-side vertical toolbar must open menus to its right',
    );

    final imageQualityItem = find.text('Image Quality');
    final imageQualityRect = tester.getRect(imageQualityItem);
    await tester.tap(imageQualityItem, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    final submenuItemRect = tester.getRect(find.text('Good image quality'));
    expect(
      submenuItemRect.left,
      greaterThan(imageQualityRect.right),
      reason: 'vertical toolbar submenus must advance horizontally',
    );

    await tester.tap(
      find.byTooltip('Chat'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(menuFocusChanges, [true]);
    expect(find.text('Scale original'), findsNothing);
    expect(find.text('Text chat'), findsOneWidget);

    await tester.tap(
      find.byTooltip('Display Settings'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(menuFocusChanges, [true]);
    expect(find.text('Scale original'), findsOneWidget);
    expect(find.text('Text chat'), findsNothing);

    rebuildRemotePage(() {});
    await tester.pump();

    expect(rawKeyFocusNode.canRequestFocus, isFalse);
    expect(find.text('Scale original'), findsOneWidget);

    rawKeyFocusNode.requestFocus();
    await tester.pump();

    expect(rawKeyFocusNode.hasFocus, isFalse);
    expect(find.text('Scale original'), findsOneWidget);

    await tester.tapAt(const Offset(10, 550), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(menuFocusChanges, [true, false]);
    expect(rawKeyFocusNode.canRequestFocus, isTrue);
    expect(find.text('Scale original'), findsNothing);

    await tester.tap(
      find.byTooltip('Display Settings'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Scale original'), findsOneWidget);

    // Flutter keeps MenuController.isOpen true until its asynchronous close
    // completion removes the overlay. Dispatch the next mouse activation in
    // that interval and verify that it reopens on the first activation.
    final groupController = tester
        .widget<RawMenuAnchorGroup>(find.byType(RawMenuAnchorGroup))
        .controller;
    groupController.close();
    expect(groupController.isOpen, isTrue);

    final menuButtonCenter = tester.getCenter(
      find.byTooltip('Display Settings'),
    );
    final pointer = TestPointer(91, PointerDeviceKind.mouse, 91);
    tester.binding.handlePointerEvent(
      pointer.addPointer(location: menuButtonCenter),
    );
    tester.binding.handlePointerEvent(pointer.down(menuButtonCenter));
    tester.binding.handlePointerEvent(pointer.up());
    tester.binding.handlePointerEvent(pointer.removePointer());
    await tester.pumpAndSettle();

    expect(find.text('Scale original'), findsOneWidget);

    await tester.tapAt(const Offset(10, 550), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(menuFocusChanges, [true, false, true, false]);
    expect(find.text('Scale original'), findsNothing);

    await state.setPin(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));

    final dimmedMenuButton = find.byTooltip('Display Settings');
    AnimatedOpacity toolbarOpacity() => tester.widget<AnimatedOpacity>(
          find
              .ancestor(
                of: dimmedMenuButton,
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        );
    expect(toolbarOpacity().opacity, lessThan(1.0));

    final gesture = await tester.startGesture(
      tester.getCenter(dimmedMenuButton),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(toolbarOpacity().opacity, 1.0);
    expect(find.text('Scale original'), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(menuFocusChanges, [true, false, true, false, true]);
    expect(find.text('Scale original'), findsOneWidget);

    await tester.tap(find.byTooltip('Close').hitTestable().first);
    await tester.pumpAndSettle();

    expect(menuFocusChanges, [true, false, true, false, true, false]);
    expect(find.text('Scale original'), findsNothing);
    expect(closeCount, 1);

    await tester.tap(
      find.byTooltip('Display Settings'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Scale original'), findsOneWidget);

    // Rapid sibling intent must keep only the latest target without briefly
    // releasing the remote-input focus guard.
    await tester.tap(find.byTooltip('Chat'), kind: PointerDeviceKind.mouse);
    await tester.tap(
      find.byTooltip('Display Settings'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Scale original'), findsOneWidget);
    expect(find.text('Text chat'), findsNothing);
    expect(menuFocusChanges.last, isTrue);

    // A non-menu toolbar action, including the detachable quality monitor,
    // must cancel all pending menu intent. Returning to the toolbar then opens
    // a menu on the first click.
    await tester.tap(find.text('QM'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('Scale original'), findsNothing);
    expect(ffi.qualityMonitorModel.showListenable.value, isTrue);
    expect(rawKeyFocusNode.canRequestFocus, isTrue);

    rawKeyFocusNode.unfocus();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    await tester.tap(
      find.byTooltip('Display Settings'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Scale original'), findsOneWidget);
    expect(rawKeyFocusNode.canRequestFocus, isFalse);

    // Disposing the toolbar during an asynchronous group close must cancel the
    // coordinator generation and restore the remote-input focus gate.
    final disposingGroupController = tester
        .widget<RawMenuAnchorGroup>(find.byType(RawMenuAnchorGroup))
        .controller;
    disposingGroupController.close();
    expect(disposingGroupController.isOpen, isTrue);
    rebuildRemotePage(() => showToolbar = false);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Display Settings'), findsNothing);
    expect(rawKeyFocusNode.canRequestFocus, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.desktop());
}
