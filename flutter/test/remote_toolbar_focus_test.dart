import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/remote_input.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _TestRustadminImpl implements Rustadmin {
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
    if (name == #mainSetLocalOption) {
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
  setUpAll(() {
    isTest = true;
    platformFFI.initForTest(_TestRustadminImpl());
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
  });
}
