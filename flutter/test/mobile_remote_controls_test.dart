import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/common/widgets/edge_thickness_control.dart';
import 'package:flutter_hbb/mobile/widgets/remote_session_controls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpToolbar(
    WidgetTester tester, {
    ThemeData? theme,
    Offset? cursorPosition,
    List<MobileRemoteToolbarMonitor> monitors = const [],
    MobileRemoteToolbarTransparencySettings transparencySettings =
        MobileRemoteToolbarTransparencySettings.defaults,
    MobileRemoteToolbarPlacementSettings placementSettings =
        MobileRemoteToolbarPlacementSettings.defaults,
    ValueChanged<MobileRemoteToolbarPlacementSettings>? onPlacementChanged,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: theme,
      darkTheme: theme,
      themeMode: theme?.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
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
            monitors: monitors,
            cursorPosition: cursorPosition,
            transparencySettings: transparencySettings,
            placementSettings: placementSettings,
            onPlacementChanged: onPlacementChanged,
          ),
        ),
      ),
    ),
  );

  testWidgets('toolbar uses theme surface and icon-colored outline', (
    tester,
  ) async {
    await pumpToolbar(tester, theme: ThemeData.dark());
    await tester.pumpAndSettle();
    var material = tester.widget<Material>(
      find.byKey(const Key('mobile-remote-floating-toolbar')),
    );
    expect(material.color, Colors.black);
    expect((material.shape as StadiumBorder).side.color, Colors.white);

    await pumpToolbar(tester, theme: ThemeData.light());
    await tester.pumpAndSettle();
    material = tester.widget<Material>(
      find.byKey(const Key('mobile-remote-floating-toolbar')),
    );
    expect(material.color, Colors.white);
    expect((material.shape as StadiumBorder).side.color, Colors.black87);
  });

  testWidgets('toolbar transparency follows cursor overlap immediately', (
    tester,
  ) async {
    await pumpToolbar(
      tester,
      cursorPosition: const Offset(160, 580),
      transparencySettings: const MobileRemoteToolbarTransparencySettings(
        overlapOpacityPercent: 60,
      ),
    );
    await tester.pump();
    var opacity = tester.widget<AnimatedOpacity>(
      find.byKey(const Key('mobile-remote-toolbar-opacity')),
    );
    expect(opacity.opacity, 0.6);
    expect(opacity.duration, Duration.zero);

    await pumpToolbar(
      tester,
      cursorPosition: const Offset(10, 10),
      transparencySettings: const MobileRemoteToolbarTransparencySettings(
        overlapOpacityPercent: 60,
      ),
    );
    await tester.pump();
    opacity = tester.widget<AnimatedOpacity>(
      find.byKey(const Key('mobile-remote-toolbar-opacity')),
    );
    expect(opacity.opacity, 1.0);
    expect(opacity.duration, Duration.zero);
  });

  test('toolbar overlap area extends by half its thickness', () {
    expect(
      mobileRemoteToolbarOverlapRect(
        toolbarRect: const Rect.fromLTWH(100, 500, 120, 48),
        toolbarThickness: 48,
      ),
      const Rect.fromLTRB(76, 476, 244, 572),
    );
  });

  test('mobile toolbar and inertia settings normalize stored values', () {
    expect(
      MobileRemoteToolbarTransparencySettings.fromStored(
        overlapOpacityPercent: '200',
      ),
      const MobileRemoteToolbarTransparencySettings(overlapOpacityPercent: 100),
    );
    expect(
      MobileCursorInertiaSettings.fromStored('-1'),
      const MobileCursorInertiaSettings(durationMs: 100),
    );
    expect(
      MobileCursorInertiaSettings.fromStored('5000'),
      const MobileCursorInertiaSettings(durationMs: 1000),
    );
    expect(normalizeMobileRemoteScrollStyle('unknown'), kRemoteScrollStyleAuto);
    expect(
      normalizeMobileRemoteScrollStyle(kRemoteScrollStyleEdgeAcceleration),
      kRemoteScrollStyleEdgeAcceleration,
    );
    expect(
      MobileRemoteToolbarPlacementSettings.fromStored('vertical,0.25,0.75'),
      const MobileRemoteToolbarPlacementSettings(
        axis: MobileRemoteToolbarAxis.vertical,
        horizontalPosition: 0.25,
        verticalPosition: 0.75,
      ),
    );
    expect(
      MobileRemoteToolbarPlacementSettings.fromStored(
        'horizontal,-1,2',
      ).storedValue,
      'horizontal,0.000000,1.000000',
    );
  });

  testWidgets('cursor inertia control uses the 100-1000 ms slider range', (
    tester,
  ) async {
    var changed = 0;
    var committed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileCursorInertiaControl(
            durationMs: 150,
            onChanged: (value) => changed = value,
            onChangeEnd: (value) => committed = value,
          ),
        ),
      ),
    );

    final slider = tester.widget<Slider>(
      find.byKey(const Key('mobile-cursor-inertia-slider')),
    );
    expect(slider.min, 100);
    expect(slider.max, 1000);
    expect(slider.divisions, 18);
    expect(find.text('150 ms'), findsOneWidget);

    await tester.drag(
      find.byKey(const Key('mobile-cursor-inertia-slider')),
      const Offset(200, 0),
    );
    await tester.pump();
    expect(changed, inInclusiveRange(100, 1000));
    expect(committed, changed);
  });

  testWidgets('floating toolbar drags, changes axis, and collapses', (
    tester,
  ) async {
    var placement = MobileRemoteToolbarPlacementSettings.defaults;
    await pumpToolbar(tester, onPlacementChanged: (value) => placement = value);
    await tester.pump();

    expect(
      tester.getCenter(find.byTooltip('Collapse toolbar')).dx,
      lessThan(tester.getCenter(find.byTooltip('Disconnect')).dx),
    );

    final toolbar = find.byKey(const Key('mobile-remote-floating-toolbar'));
    final before = tester.getTopLeft(toolbar);
    await tester.drag(toolbar, const Offset(-60, -80));
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(toolbar);
    expect(after.dy, lessThan(before.dy));
    expect(placement.verticalPosition, lessThan(1));

    await tester.tap(find.byTooltip('Vertical toolbar'));
    await tester.pumpAndSettle();
    expect(placement.axis, MobileRemoteToolbarAxis.vertical);
    expect(find.text('V'), findsOneWidget);
    await tester.tap(find.byTooltip('Collapse toolbar'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Show toolbar'), findsOneWidget);

    await tester.tap(find.byTooltip('Show toolbar'));
    await tester.pumpAndSettle();
    final opacity = tester.widget<AnimatedOpacity>(
      find.byKey(const Key('mobile-remote-toolbar-opacity')),
    );
    expect(opacity.opacity, 1.0);
    expect(opacity.duration, Duration.zero);

    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pump();
  });

  testWidgets('toolbar exposes direct monitor buttons', (tester) async {
    var selected = -1;
    await pumpToolbar(
      tester,
      monitors: [
        MobileRemoteToolbarMonitor(
          value: 0,
          label: '1',
          tooltip: '#1 monitor',
          selected: true,
          onPressed: () => selected = 0,
        ),
        MobileRemoteToolbarMonitor(
          value: 1,
          label: '2',
          tooltip: '#2 monitor',
          selected: false,
          onPressed: () => selected = 1,
        ),
      ],
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mobile-remote-monitor-0')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('#2 monitor'));
    expect(selected, 1);
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

  testWidgets('quick keys use theme-aware gray button surfaces', (
    tester,
  ) async {
    Future<Color?> buttonColor(ThemeData theme) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          darkTheme: theme,
          themeMode: theme.brightness == Brightness.dark
              ? ThemeMode.dark
              : ThemeMode.light,
          home: Scaffold(
            body: MobileRemoteKeyHelpTools(
              ctrlActive: false,
              altActive: false,
              shiftActive: false,
              commandActive: false,
              functionKeysActive: false,
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
      );
      await tester.pumpAndSettle();
      final button = tester.widget<TextButton>(
        find.descendant(
          of: find.byKey(const Key('mobile-remote-quick-ctrl')),
          matching: find.byType(TextButton),
        ),
      );
      return button.style?.backgroundColor?.resolve({});
    }

    expect(await buttonColor(ThemeData.dark()), const Color(0xFF424242));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(await buttonColor(ThemeData.light()), const Color(0xFFE0E0E0));
  });

  testWidgets('custom arrow buttons send the matching named control keys', (
    tester,
  ) async {
    final sentKeys = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileRemoteKeyHelpTools(
            ctrlActive: false,
            altActive: false,
            shiftActive: false,
            commandActive: false,
            functionKeysActive: false,
            moreKeysActive: true,
            isMac: false,
            showWindowsLinuxKeys: true,
            quickKeyOrder: mobileRemoteDefaultQuickKeyOrder,
            onCtrl: () {},
            onAlt: () {},
            onShift: () {},
            onCommand: () {},
            onFunctionKeys: () {},
            onMoreKeys: () {},
            onKeyPressed: sentKeys.add,
            onShortcutPressed: (_) {},
          ),
        ),
      ),
    );

    for (final entry in const <(IconData, String)>[
      (Icons.keyboard_arrow_left, 'VK_LEFT'),
      (Icons.keyboard_arrow_up, 'VK_UP'),
      (Icons.keyboard_arrow_down, 'VK_DOWN'),
      (Icons.keyboard_arrow_right, 'VK_RIGHT'),
    ]) {
      await tester.ensureVisible(find.byIcon(entry.$1));
      await tester.tap(find.byIcon(entry.$1));
      await tester.pump();
      expect(sentKeys.last, entry.$2);
    }
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

  testWidgets('keyboard submenu updates modes and keyboard toggles', (
    tester,
  ) async {
    String? selectedMode;
    bool? reverseWheel;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileRemoteActionsContent(
            sections: [
              MobileRemoteActionSection(
                id: 'keyboard',
                title: const Text('Keyboard settings'),
                content: MobileRemoteKeyboardSettingsContent(
                  mode: 'map',
                  modes: [
                    MobileRemoteRadioItem(
                      value: 'legacy',
                      child: const Text('Legacy mode'),
                      onChanged: (value) => selectedMode = value,
                    ),
                    MobileRemoteRadioItem(
                      value: 'map',
                      child: const Text('Map mode'),
                      onChanged: (value) => selectedMode = value,
                    ),
                  ],
                  toggles: [
                    MobileRemoteToggleItem(
                      id: 'reverse-wheel',
                      value: false,
                      child: const Text('Reverse mouse wheel'),
                      onChanged: (value) => reverseWheel = value,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const Key('mobile-remote-actions-open-keyboard')),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('mobile-remote-keyboard-settings')),
      findsOneWidget,
    );

    await tester.tap(find.text('Legacy mode'));
    await tester.pump();
    expect(selectedMode, 'legacy');

    await tester.tap(find.text('Reverse mouse wheel'));
    await tester.pump();
    expect(reverseWheel, isTrue);
  });

  testWidgets('shared edge-size control reports session slider changes', (
    tester,
  ) async {
    double? changedValue;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EdgeThicknessControl(
            value: 100,
            onChanged: (value) => changedValue = value,
          ),
        ),
      ),
    );

    await tester.drag(
      find.byKey(const Key('edge-thickness-slider')),
      const Offset(80, 0),
    );
    await tester.pump();
    expect(changedValue, isNotNull);
    expect(changedValue!, greaterThan(100));
  });
}
