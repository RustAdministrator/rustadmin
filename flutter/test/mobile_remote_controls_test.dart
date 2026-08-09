import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/remote_session_controls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpToolbar(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 600,
          child: MobileRemoteToolbar(
            onDisconnect: () {},
            onOptions: () {},
            onMore: () {},
            onKeyboard: () {},
            onGestureHelp: () {},
            showInputControls: true,
            peerIsAndroid: false,
            touchMode: true,
            waitForFirstImage: false,
          ),
        ),
      ),
    ),
  );

  testWidgets('floating toolbar drags, changes axis, collapses, and dims', (
    tester,
  ) async {
    await pumpToolbar(tester);
    await tester.pump();

    final toolbar = find.byKey(const Key('mobile-remote-floating-toolbar'));
    final before = tester.getTopLeft(toolbar);
    await tester.drag(toolbar, const Offset(-60, -80));
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(toolbar);
    expect(after.dy, lessThan(before.dy));

    await tester.tap(find.byTooltip('Vertical toolbar'));
    await tester.pumpAndSettle();
    expect(find.text('V'), findsOneWidget);
    await tester.tap(find.byTooltip('Collapse toolbar'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Show toolbar'), findsOneWidget);

    await tester.tap(find.byTooltip('Show toolbar'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3));
    final opacity = tester.widget<AnimatedOpacity>(
      find.byKey(const Key('mobile-remote-toolbar-opacity')),
    );
    expect(opacity.opacity, 0.2);
    expect(opacity.duration, const Duration(seconds: 3));

    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pump();
    final restoredOpacity = tester.widget<AnimatedOpacity>(
      find.byKey(const Key('mobile-remote-toolbar-opacity')),
    );
    expect(restoredOpacity.opacity, 1.0);
    expect(restoredOpacity.duration, Duration.zero);
  });

  testWidgets('quick keys stay in one square scrollable row', (tester) async {
    var remotePanUpdates = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              child: GestureDetector(
                onPanUpdate: (_) => remotePanUpdates += 1,
                child: MobileRemoteKeyHelpTools(
                  ctrlActive: false,
                  altActive: false,
                  shiftActive: false,
                  commandActive: false,
                  functionKeysActive: true,
                  moreKeysActive: false,
                  isMac: false,
                  showWindowsLinuxKeys: true,
                  quickKeyOrder: mobileRemoteDefaultQuickKeyOrder,
                  onCtrl: () {},
                  onAlt: () {},
                  onShift: () {},
                  onCommand: () {},
                  onFunctionKeys: () {},
                  onMoreKeys: () {},
                  onKeyPressed: (_) {},
                  onShortcutPressed: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final strip = find.byKey(const Key('mobile-remote-key-help-scroll'));
    final scrollable = find.descendant(
      of: strip,
      matching: find.byType(Scrollable),
    );
    final state = tester.state<ScrollableState>(scrollable);
    expect(state.position.maxScrollExtent, greaterThan(0));

    final gesture = await tester.startGesture(tester.getCenter(strip));
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    expect(state.position.pixels, greaterThan(0));
    await gesture.up();
    expect(remotePanUpdates, 0);

    state.position.jumpTo(0);
    final mouse = await tester.startGesture(
      tester.getCenter(strip),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await mouse.moveBy(const Offset(-20, 0));
    await mouse.moveBy(const Offset(-100, 0));
    await tester.pump();
    expect(state.position.pixels, greaterThan(0));
    await mouse.up();

    final firstButton = tester.getSize(
      find.byKey(const Key('mobile-remote-quick-ctrl')),
    );
    expect(firstButton, const Size.square(39.6));
    expect(find.byIcon(Icons.push_pin), findsNothing);
  });

  testWidgets('options use in-dialog submenus with an internal back button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileRemoteOptionsContent(
            radioSections: [
              MobileRemoteRadioSection(
                id: 'scale',
                value: 'fit-height',
                heading: const Text('Scale'),
                items: [
                  MobileRemoteRadioItem(
                    value: 'fit-height',
                    child: const Text('Fit Height'),
                    onChanged: (_) {},
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('mobile-remote-options-open-scale')));
    await tester.pump();
    expect(find.text('Fit Height'), findsOneWidget);
    expect(find.byTooltip('Back to options'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to options'));
    await tester.pump();
    expect(find.byKey(const Key('mobile-remote-options-root')), findsOneWidget);
  });

  testWidgets('more actions are grouped into navigable submenus', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileRemoteActionsContent(
            sections: [
              MobileRemoteActionSection(
                id: 'session',
                title: const Text('Session actions'),
                actions: [
                  MobileRemoteActionItem(
                    child: const Text('Reset canvas'),
                    onPressed: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const Key('mobile-remote-actions-open-session')),
    );
    await tester.pump();
    expect(find.text('Reset canvas'), findsOneWidget);
    expect(find.byTooltip('Back to actions'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to actions'));
    await tester.pump();
    expect(find.byKey(const Key('mobile-remote-actions-root')), findsOneWidget);
  });
}
