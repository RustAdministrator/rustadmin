import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/connection_focus.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/session_tab.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/platform_channel.dart';
import 'package:flutter_test/flutter_test.dart';

class _FocusBindings implements Rustadmin {
  String defaultValue = '';

  @override
  String mainGetLocalOption({required String key, dynamic hint}) =>
      key == kOptionFocusConnectionWindow ? defaultValue : '';

  @override
  bool isIncomingOnly({dynamic hint}) => false;

  @override
  bool isOutgoingOnly({dynamic hint}) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bindings = _FocusBindings();
  setUpAll(() {
    isTest = true;
    platformFFI.initForTest(bindings);
  });
  setUp(() {
    bindings.defaultValue = '';
    stateGlobal.connectionActivationPending = false;
  });

  test(
    'global default is enabled and launch override wins in either direction',
    () {
      expect(focusConnectionWindowDefault(), isTrue);
      expect(
        resolveConnectionFocus(
          override: false,
          defaultValue: focusConnectionWindowDefault(),
        ),
        isFalse,
      );
      bindings.defaultValue = 'N';
      expect(focusConnectionWindowDefault(), isFalse);
      expect(
        resolveConnectionFocus(defaultValue: focusConnectionWindowDefault()),
        isFalse,
      );
      expect(
        resolveConnectionFocus(
          override: true,
          defaultValue: focusConnectionWindowDefault(),
        ),
        isTrue,
      );
      expect(bindings.defaultValue, 'N');
    },
  );

  test(
    'explicit inactive choice survives the window message and legacy defaults',
    () {
      for (final focus in [false, true]) {
        final message =
            jsonDecode(
                  jsonEncode({'id': 'peer', kConnectionFocusArgument: focus}),
                )
                as Map;
        expect(connectionFocusFromArguments(message), focus);
      }
      expect(connectionFocusFromArguments({'id': 'legacy'}), isTrue);
      expect(
        connectionFocusFromArguments({kConnectionFocusArgument: 'false'}),
        isTrue,
      );
      const launch = RemoteSessionLaunch(
        peerId: 'peer',
        sessionId: 'session',
        focusOnOpen: false,
      );
      expect(launch.focusOnOpen, isFalse);
    },
  );

  testWidgets(
    'inactive connection appends a tab without replacing current selection',
    (tester) async {
      final tabs = DesktopTabController(tabType: DesktopTabType.remoteScreen);
      TabInfo tab(String key) => TabInfo(
        key: key,
        label: key,
        selectedIcon: Icons.desktop_windows,
        unselectedIcon: Icons.desktop_windows_outlined,
        onTabCloseButton: () {},
        page: const SizedBox(),
      );
      tabs.add(tab('first'), activate: false);
      expect(tabs.state.value.selectedTabInfo.key, 'first');
      tabs.add(tab('second'), activate: false);
      expect(tabs.state.value.selectedTabInfo.key, 'first');
      expect(tabs.length, 2);
      tabs.add(tab('first'), activate: false);
      expect(tabs.length, 2);
      tabs.add(tab('third'));
      expect(tabs.state.value.selectedTabInfo.key, 'third');
      await tester.pump(const Duration(milliseconds: 150));
    },
  );

  test('awaiting native activation cannot restore remote keyboard focus', () {
    expect(
      shouldRestoreRemoteKeyboardFocus(
        windowBlurred: false,
        canRequestFocus: true,
        activeTab: true,
        editableTextFocused: false,
        activationPending: true,
      ),
      isFalse,
    );
    expect(
      shouldRestoreRemoteKeyboardFocus(
        windowBlurred: false,
        canRequestFocus: true,
        activeTab: true,
        editableTextFocused: false,
        activationPending: false,
      ),
      isTrue,
    );
  });

  test(
    'native inactive show is explicit and suppresses input only in an inactive window',
    () async {
      const host = MethodChannel('org.rustdesk.rustdesk/host');
      final calls = <MethodCall>[];
      var focused = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(host, (call) async {
        if (call.method == 'isConnectionWindowFocused') return focused;
        calls.add(call);
        return true;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(host, null);
      });
      await RdPlatformChannel.instance.showConnectionWindow(focus: false);
      expect(calls.single.method, 'showConnectionWindow');
      expect(calls.single.arguments, {'focus': false});
      expect(stateGlobal.connectionActivationPending, isTrue);
      stateGlobal.connectionActivationPending = false;
      focused = true;
      await RdPlatformChannel.instance.showConnectionWindow(focus: false);
      expect(stateGlobal.connectionActivationPending, isFalse);
      await RdPlatformChannel.instance.showConnectionWindow(focus: true);
      expect(calls.last.arguments, {'focus': true});
    },
  );
}
