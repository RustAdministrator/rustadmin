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
      return Future<bool?>.value(false);
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

  test('toolbar menu activation recovers stale child open state', () {
    expect(
      shouldOpenToolbarMenuOnActivation(
        targetMenuOpen: false,
        menuGroupOpen: false,
      ),
      isTrue,
    );
    expect(
      shouldOpenToolbarMenuOnActivation(
        targetMenuOpen: true,
        menuGroupOpen: false,
      ),
      isTrue,
      reason: 'no visible group menu must make the first click open the target',
    );
    expect(
      shouldOpenToolbarMenuOnActivation(
        targetMenuOpen: false,
        menuGroupOpen: true,
      ),
      isTrue,
      reason: 'a sibling menu should switch to the target on the first click',
    );
    expect(
      shouldOpenToolbarMenuOnActivation(
        targetMenuOpen: true,
        menuGroupOpen: true,
      ),
      isFalse,
      reason: 'clicking the visibly open target should close it',
    );
  });

  testWidgets('an open toolbar menu blocks remote canvas focus stealing', (
    tester,
  ) async {
    const peerId = 'toolbar-focus-test-peer';
    initSharedStates(peerId);
    addTearDown(() => removeSharedStates(peerId));

    final rawKeyFocusNode = FocusNode(debugLabel: 'testRawKeyFocusNode');
    addTearDown(rawKeyFocusNode.dispose);

    final state = ToolbarState()..initialized.value = true;
    final ffi = FFI(null)
      ..id = peerId
      ..connType = ConnType.viewCamera;
    final menuFocusChanges = <bool>[];
    var closeCount = 0;
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
                    child: RemoteToolbar(
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
                    ),
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

    await tester.tap(
      find.byTooltip('Display Settings'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(menuFocusChanges, [true]);
    expect(rawKeyFocusNode.canRequestFocus, isFalse);
    expect(find.text('Scale original'), findsOneWidget);
    expect(find.text('Tabs in fullscreen'), findsOneWidget);

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

    await state.setPin(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));

    final dimmedMenuButton = find.byTooltip('Display Settings');
    final gesture = await tester.startGesture(
      tester.getCenter(dimmedMenuButton),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(menuFocusChanges, [true, false, true]);
    expect(find.text('Scale original'), findsOneWidget);

    await tester.tap(find.byTooltip('Close').hitTestable().first);
    await tester.pumpAndSettle();

    expect(menuFocusChanges, [true, false, true, false]);
    expect(find.text('Scale original'), findsNothing);
    expect(closeCount, 1);
  });
}
