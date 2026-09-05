import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/remote_session_controls.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpKeyTools(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  TextDirection direction = TextDirection.ltr,
  Brightness brightness = Brightness.light,
  bool isMac = false,
  bool active = false,
  bool locked = false,
  bool functionKeys = false,
  bool moreKeys = true,
  List<MobileRemoteQuickKey> order = mobileRemoteDefaultQuickKeyOrder,
  ValueChanged<String>? onKey,
  ValueChanged<String>? onModifier,
  ValueChanged<String>? onLock,
  String Function(String)? labelBuilder,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness, platform: platform),
      home: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 390,
              child: MobileRemoteKeyHelpTools(
                ctrlActive: active,
                altActive: active,
                shiftActive: active,
                commandActive: active,
                ctrlLocked: locked,
                altLocked: locked,
                shiftLocked: locked,
                commandLocked: locked,
                functionKeysActive: functionKeys,
                moreKeysActive: moreKeys,
                isMac: isMac,
                showWindowsLinuxKeys: !isMac,
                quickKeyOrder: order,
                onCtrl: () => onModifier?.call('ctrl'),
                onAlt: () => onModifier?.call('alt'),
                onShift: () => onModifier?.call('shift'),
                onCommand: () => onModifier?.call('command'),
                onCtrlDoubleTap: () => onLock?.call('ctrl'),
                onAltDoubleTap: () => onLock?.call('alt'),
                onShiftDoubleTap: () => onLock?.call('shift'),
                onCommandDoubleTap: () => onLock?.call('command'),
                onFunctionKeys: () {},
                onMoreKeys: () {},
                onKeyPressed: (key) => onKey?.call(key),
                onShortcutPressed: (_) {},
                labelBuilder: labelBuilder,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder quickKey(String name) => find.byKey(Key('mobile-remote-quick-$name'));

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final isMac in [false, true]) {
      testWidgets('$platform uses remote OS modifier icons (Mac: $isMac)', (
        tester,
      ) async {
        await pumpKeyTools(tester, platform: platform, isMac: isMac);

        final shift = tester.widget<SvgPicture>(
          find.descendant(
            of: quickKey('shift'),
            matching: find.byType(SvgPicture),
          ),
        );
        expect(
          (shift.bytesLoader as SvgAssetLoader).assetName,
          'assets/keyboard_shift.svg',
        );
        expect(find.text('Shift'), findsNothing);
        expect(find.byTooltip('Shift'), findsOneWidget);
        expect(find.text('Fn'), findsOneWidget);
        if (isMac) {
          expect(find.byIcon(Icons.keyboard_control_key), findsOneWidget);
          expect(find.byIcon(Icons.keyboard_option_key), findsOneWidget);
          expect(find.byIcon(Icons.keyboard_command_key), findsOneWidget);
          expect(find.byTooltip('Option'), findsOneWidget);
          expect(find.byTooltip('Command'), findsOneWidget);
          expect(find.text('Ctrl'), findsNothing);
          expect(find.text('Alt'), findsNothing);
          expect(find.byType(SvgPicture), findsOneWidget);
        } else {
          expect(find.text('Ctrl'), findsOneWidget);
          expect(find.text('Alt'), findsOneWidget);
          expect(find.byIcon(Icons.keyboard_command_key), findsNothing);
          final windows = tester.widget<SvgPicture>(
            find.descendant(
              of: quickKey('command'),
              matching: find.byType(SvgPicture),
            ),
          );
          expect(
            (windows.bytesLoader as SvgAssetLoader).assetName,
            'assets/win.svg',
          );
          expect(find.byTooltip('Windows'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }

    for (final direction in TextDirection.values) {
      testWidgets('$platform navigation icons send fixed keys in $direction', (
        tester,
      ) async {
        final sent = <String>[];
        await pumpKeyTools(
          tester,
          platform: platform,
          direction: direction,
          onKey: sent.add,
        );

        const keys = <(IconData, String, String)>[
          (Icons.keyboard_tab, 'Tab', 'VK_TAB'),
          (Icons.first_page, 'Home', 'VK_HOME'),
          (Icons.last_page, 'End', 'VK_END'),
          (Icons.keyboard_double_arrow_up, 'Page Up', 'VK_PRIOR'),
          (Icons.keyboard_double_arrow_down, 'Page Down', 'VK_NEXT'),
          (Icons.keyboard_return, 'Enter', 'VK_ENTER'),
          (Icons.arrow_left, 'Left', 'VK_LEFT'),
          (Icons.arrow_drop_up, 'Up', 'VK_UP'),
          (Icons.arrow_drop_down, 'Down', 'VK_DOWN'),
          (Icons.arrow_right, 'Right', 'VK_RIGHT'),
        ];
        for (final (icon, label, key) in keys) {
          final finder = find.byIcon(icon);
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          expect(tester.widget<Icon>(finder).textDirection, TextDirection.ltr);
          final isArrow = [
            'VK_LEFT',
            'VK_UP',
            'VK_DOWN',
            'VK_RIGHT',
          ].contains(key);
          expect(tester.widget<Icon>(finder).size, isArrow ? 28 : 18);
          expect(find.byTooltip(label), findsOneWidget);
          expect(
            tester.getSemantics(find.bySemanticsLabel(label)),
            matchesSemantics(label: label, isButton: true, hasTapAction: true),
          );
          await tester.tap(finder);
          await tester.pump();
          expect(sent.last, key);
        }
        expect(sent, keys.map((entry) => entry.$3).toList());
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final isMac in [false, true]) {
    testWidgets(
      'modifier icon taps and double taps stay separate (Mac: $isMac)',
      (tester) async {
        final tapped = <String>[];
        final locked = <String>[];
        await pumpKeyTools(
          tester,
          isMac: isMac,
          onModifier: tapped.add,
          onLock: locked.add,
        );

        for (final name in ['ctrl', 'alt', 'shift', 'command']) {
          final button = quickKey(name);
          await tester.tap(button);
          await tester.pump(
            kDoubleTapTimeout + const Duration(milliseconds: 1),
          );
          expect(tapped.last, name);

          await tester.tap(button);
          await tester.pump(kDoubleTapMinTime);
          await tester.tap(button);
          await tester.pump(
            kDoubleTapTimeout + const Duration(milliseconds: 1),
          );
          expect(locked.last, name);
        }
        expect(tapped, ['ctrl', 'alt', 'shift', 'command']);
        expect(locked, ['ctrl', 'alt', 'shift', 'command']);
      },
    );

    for (final brightness in Brightness.values) {
      testWidgets(
        'icons retain modifier colors and semantics ($isMac, $brightness)',
        (tester) async {
          for (final (active, locked) in [
            (false, false),
            (true, false),
            (true, true),
          ]) {
            await pumpKeyTools(
              tester,
              isMac: isMac,
              brightness: brightness,
              active: active,
              locked: locked,
            );
            final expectedForeground = locked || brightness == Brightness.dark
                ? Colors.white
                : Colors.black87;
            for (final (name, label) in [
              ('ctrl', 'Control'),
              ('alt', isMac ? 'Option' : 'Alt'),
              ('shift', 'Shift'),
              ('command', isMac ? 'Command' : 'Windows'),
            ]) {
              final button = quickKey(name);
              final context = tester.element(button);
              final material = tester.widget<Material>(
                find.descendant(of: button, matching: find.byType(Material)),
              );
              expect(
                material.color,
                locked
                    ? mobileRemoteAccentColor
                    : active
                    ? mobileRemoteToolbarActiveBackgroundColor(context)
                    : mobileRemoteQuickKeyButtonBackgroundColor(context),
              );
              for (final icon in tester.widgetList<Icon>(
                find.descendant(of: button, matching: find.byType(Icon)),
              )) {
                expect(icon.color, expectedForeground);
              }
              for (final svg in tester.widgetList<SvgPicture>(
                find.descendant(of: button, matching: find.byType(SvgPicture)),
              )) {
                expect(
                  svg.colorFilter,
                  ColorFilter.mode(expectedForeground, BlendMode.srcIn),
                );
              }
              expect(
                tester.getSemantics(find.bySemanticsLabel(label)),
                matchesSemantics(
                  label: label,
                  value: locked ? 'Locked' : '',
                  isButton: true,
                  hasToggledState: true,
                  isToggled: active,
                  hasTapAction: true,
                ),
              );
            }
          }
        },
      );
    }
  }

  testWidgets('function keys retain text and F1 through F12 dispatch', (
    tester,
  ) async {
    final sent = <String>[];
    await pumpKeyTools(tester, functionKeys: true, onKey: sent.add);
    expect(find.byIcon(Icons.first_page), findsOneWidget);
    for (var index = 1; index <= 12; index++) {
      final key = find.text('F$index');
      await tester.ensureVisible(key);
      await tester.tap(key);
      await tester.pump();
    }
    expect(sent, [for (var index = 1; index <= 12; index++) 'VK_F$index']);
  });

  testWidgets('icon tooltips and semantics use the label builder', (
    tester,
  ) async {
    await pumpKeyTools(tester, labelBuilder: (label) => 'translated $label');
    expect(find.byTooltip('translated Shift'), findsOneWidget);
    expect(find.bySemanticsLabel('translated Shift'), findsOneWidget);
    await tester.ensureVisible(find.byIcon(Icons.keyboard_double_arrow_up));
    await tester.pumpAndSettle();
    expect(find.byTooltip('translated Page Up'), findsOneWidget);
    expect(find.bySemanticsLabel('translated Page Up'), findsOneWidget);
  });

  testWidgets('icon buttons preserve configured quick-key order and size', (
    tester,
  ) async {
    final order = mobileRemoteDefaultQuickKeyOrder.reversed.toList();
    await pumpKeyTools(tester, order: order);
    final names = ['command', 'shift', 'alt', 'ctrl'];
    var previousX = double.negativeInfinity;
    for (final name in names) {
      final button = quickKey(name);
      final x = tester.getTopLeft(button).dx;
      expect(x, greaterThan(previousX));
      expect(tester.getSize(button), const Size.square(39.6));
      previousX = x;
    }
    expect(
      tester.getTopLeft(quickKey('function-keys')).dx,
      greaterThan(previousX),
    );
    expect(
      tester.getTopLeft(quickKey('extended-keys')).dx,
      greaterThan(tester.getTopLeft(quickKey('function-keys')).dx),
    );
  });

  for (final isMac in [false, true]) {
    for (final functionKeys in [false, true]) {
      testWidgets(
        'custom keys have ordered groups and half-key gaps (Mac: $isMac, Fn: $functionKeys)',
        (tester) async {
          await pumpKeyTools(tester, isMac: isMac, functionKeys: functionKeys);
          final groups = <String, List<String>>{
            'modifiers': [
              'Control',
              isMac ? 'Option' : 'Alt',
              'Shift',
              isMac ? 'Command' : 'Windows',
            ],
            'editing': ['Del', 'Esc', 'Tab', 'Ins'],
            'enter': ['Enter'],
            'arrows': ['Left', 'Up', 'Down', 'Right'],
            'navigation': ['Home', 'End', 'Page Up', 'Page Down'],
            'function-keys': [
              'Function keys',
              if (functionKeys)
                for (var i = 1; i <= 12; i++) 'F$i',
            ],
            if (!isMac) 'pause-break': ['Pause', 'Break'],
            'other': [
              'More keys',
              if (!isMac) ...['PrtScr', 'ScrollLock', 'Menu'],
              for (final letter in ['C', 'V', 'S'])
                '${isMac ? 'Cmd' : 'Ctrl'}+$letter',
            ],
          };
          Rect? previous;
          for (final entry in groups.entries) {
            final group = find.byKey(
              Key('mobile-remote-key-group-${entry.key}'),
            );
            final labels = tester
                .widgetList<Tooltip>(
                  find.descendant(of: group, matching: find.byType(Tooltip)),
                )
                .map((tooltip) => tooltip.message);
            expect(labels, entry.value);
            final rect = tester.getRect(group);
            expect(rect.height, closeTo(39.6, 0.000001));
            expect(
              rect.width,
              closeTo(
                entry.value.length * 39.6 + (entry.value.length - 1) * 4,
                0.000001,
              ),
            );
            if (previous != null) {
              expect(rect.left - previous.right, closeTo(39.6 / 2, 0.000001));
              expect(rect.top, previous.top);
            }
            previous = rect;
          }
          if (isMac) expect(find.text('Break'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'collapsing extended groups retains Fn and has no empty group gaps',
    (tester) async {
      await pumpKeyTools(tester, moreKeys: false, functionKeys: true);
      final modifiers = tester.getRect(
        find.byKey(const Key('mobile-remote-key-group-modifiers')),
      );
      final functions = tester.getRect(
        find.byKey(const Key('mobile-remote-key-group-function-keys')),
      );
      final other = tester.getRect(
        find.byKey(const Key('mobile-remote-key-group-other')),
      );
      expect(functions.left - modifiers.right, closeTo(19.8, 0.000001));
      expect(other.left - functions.right, closeTo(19.8, 0.000001));
      expect(find.byIcon(Icons.keyboard_return), findsNothing);
      expect(find.text('F1'), findsOneWidget);
      expect(find.text('F12'), findsOneWidget);
    },
  );

  testWidgets('Pause and Break send distinct control keys', (tester) async {
    final sent = <String>[];
    await pumpKeyTools(tester, onKey: sent.add);
    for (final label in ['Pause', 'Break']) {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pump();
    }
    expect(sent, ['VK_PAUSE', 'VK_CANCEL']);
  });
}
