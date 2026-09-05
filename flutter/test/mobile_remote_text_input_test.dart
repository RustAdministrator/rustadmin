import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/remote_session_controls.dart';
import 'package:flutter_hbb/mobile/widgets/remote_text_input.dart';
import 'package:flutter_hbb/models/keyboard_dispatcher.dart';
import 'package:flutter_hbb/models/keyboard_event_normalizer.dart';
import 'package:flutter_hbb/models/keyboard_input_controller.dart';
import 'package:flutter_hbb/models/keyboard_intent.dart';
import 'package:flutter_test/flutter_test.dart';

const _enter = <Object>[
  ('key', 'VK_ENTER', true, false, false),
  ('key', 'VK_ENTER', false, false, false),
];

class _KeyboardHarness {
  _KeyboardHarness(TargetPlatform platform, ControllerKeyboardInputMode mode)
    : context = KeyboardRoutingContext(
        keyboardMode: ControllerKeyboardMode.legacy,
        inputMode: mode,
        clientKind: platform == TargetPlatform.iOS
            ? KeyboardClientKind.ios
            : KeyboardClientKind.android,
        peerIsAndroid: false,
      ) {
    text.addListener(_editingChanged);
  }

  final KeyboardRoutingContext context;
  final text = MobileRemoteTextEditingController(text: '1111');
  final focus = FocusNode();
  final events = <Object>[];
  String _previous = '1111';
  bool allowed = true;
  late final keyboard = KeyboardInputController(
    canDispatch: () => allowed,
    sendHid: ({required key, required action, required lockMask}) {
      events.add(('hid', key.usage, action));
    },
    sendLegacy: ({required name, required down, required modifiers}) {
      events.add(('key', name, down, modifiers.ctrl, modifiers.shift));
    },
    sendText:
        ({
          required text,
          required deleteBeforeGraphemes,
          required deleteAfterGraphemes,
          required sourceLanguageTag,
          required sourceLayoutType,
        }) {
          events.add((
            'text',
            text,
            deleteBeforeGraphemes,
            deleteAfterGraphemes,
          ));
        },
  );

  void _editingChanged() {
    final returnBaseline = text.returnEchoBaseline;
    if (returnBaseline != null) _previous = returnBaseline;
    final composing = text.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    final edit = mobileCommittedTextEdit(_previous, text.text);
    _previous = text.text;
    if (edit.isEmpty) return;
    keyboard.handle(
      CommittedTextIntent(
        text: edit.text,
        source: KeyboardInputSource.futureIme,
        deleteBeforeGraphemes: edit.deleteBeforeGraphemes,
        deleteAfterGraphemes: edit.deleteAfterGraphemes,
        allowMobileShortcut: !text.isLiteralEdit,
      ),
      context,
    );
  }

  void enter() {
    for (final intent in const MobileToolbarKeyboardNormalizer().click(
      'VK_ENTER',
    )) {
      keyboard.handle(intent, context);
    }
  }

  Future<void> nativeReturn(WidgetTester tester) async {
    if (context.clientKind == KeyboardClientKind.ios) {
      final before = text.value;
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      // Match FlutterTextInputPlugin: action first, then its inserted newline.
      tester.testTextInput.updateEditingValue(
        before
            .replaced(before.selection, '\n')
            .copyWith(composing: TextRange.empty),
      );
    } else {
      await tester.testTextInput.receiveAction(TextInputAction.done);
    }
  }

  void modifier(CanonicalModifier modifier, SyntheticModifierAction action) {
    keyboard.handle(
      SyntheticModifierIntent(modifier: modifier, action: action),
      context,
    );
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 0,
            height: 0,
            child: MobileRemoteTextInput(
              controller: text,
              focusNode: focus,
              onEnter: enter,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    text.dispose();
    focus.dispose();
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final mode in ControllerKeyboardInputMode.values) {
      testWidgets(
        '${platform.name} ${mode.name}: submit sends Enter once and keeps keyboard open',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          final harness = _KeyboardHarness(platform, mode);
          await harness.mount(tester);
          final field = tester.widget<EditableText>(
            find.byWidgetPredicate((widget) => widget is EditableText),
          );
          expect(field.controller, same(harness.text));
          expect(
            tester.testTextInput.setClientArgs!['inputAction'],
            platform == TargetPlatform.iOS
                ? 'TextInputAction.newline'
                : 'TextInputAction.done',
          );

          await harness.nativeReturn(tester);
          await tester.pump();
          await harness.keyboard.idle;
          expect(harness.events, _enter);
          expect(
            harness.text.text,
            platform == TargetPlatform.iOS ? '1111\n' : '1111',
          );
          expect(harness.focus.hasFocus, isTrue);
          expect(tester.testTextInput.isVisible, isTrue);

          // A repeated/selection-only editing update must not duplicate Enter.
          tester.testTextInput.updateEditingValue(harness.text.value);
          await tester.pump();
          await harness.keyboard.idle;
          expect(harness.events, _enter);

          await harness.nativeReturn(tester);
          await tester.pump();
          await harness.keyboard.idle;
          expect(harness.events, [..._enter, ..._enter]);
          await harness.unmount(tester);
        },
      );
    }

    for (final pasted in ['\n', 'one\ntwo\r\nthree']) {
      testWidgets(
        '${platform.name}: pasted ${pasted.length} characters remain text',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          final harness = _KeyboardHarness(
            platform,
            ControllerKeyboardInputMode.auto,
          );
          await harness.mount(tester);
          final value = '1111$pasted';
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: value,
              selection: TextSelection.collapsed(offset: value.length),
            ),
          );
          await tester.pump();
          await harness.keyboard.idle;
          expect(harness.events, [('text', pasted, 0, 0)]);
          await harness.unmount(tester);
        },
      );
    }

    testWidgets(
      '${platform.name}: composition commits before Enter without duplicate text',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final harness = _KeyboardHarness(
          platform,
          ControllerKeyboardInputMode.auto,
        );
        await harness.mount(tester);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '1111日本語',
            selection: TextSelection.collapsed(offset: 7),
            composing: TextRange(start: 4, end: 7),
          ),
        );
        await tester.pump();
        expect(harness.events, isEmpty);

        await harness.nativeReturn(tester);
        await tester.pump();
        await harness.keyboard.idle;
        expect(harness.events, [('text', '日本語', 0, 0), ..._enter]);
        expect(harness.text.value.composing.isCollapsed, isTrue);
        tester.testTextInput.updateEditingValue(harness.text.value);
        await tester.pump();
        await harness.keyboard.idle;
        expect(harness.events, [('text', '日本語', 0, 0), ..._enter]);
        await harness.unmount(tester);
      },
    );

    testWidgets(
      '${platform.name}: composition confirmation alone is not Enter',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final harness = _KeyboardHarness(
          platform,
          ControllerKeyboardInputMode.auto,
        );
        await harness.mount(tester);
        const composing = TextEditingValue(
          text: '1111한글',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 4, end: 6),
        );
        tester.testTextInput.updateEditingValue(composing);
        await tester.pump();
        expect(harness.events, isEmpty);
        tester.testTextInput.updateEditingValue(
          composing.copyWith(composing: TextRange.empty),
        );
        await tester.pump();
        await harness.keyboard.idle;
        expect(harness.events, [('text', '한글', 0, 0)]);
        await harness.unmount(tester);
      },
    );

    testWidgets('${platform.name}: typing and backspace continue after Enter', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final harness = _KeyboardHarness(
        platform,
        ControllerKeyboardInputMode.auto,
      );
      await harness.mount(tester);
      await harness.nativeReturn(tester);
      await tester.pump();
      final baseline = harness.text.text;
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${baseline}a',
          selection: TextSelection.collapsed(offset: baseline.length + 1),
        ),
      );
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: baseline,
          selection: TextSelection.collapsed(offset: baseline.length),
        ),
      );
      await tester.pump();
      await harness.keyboard.idle;
      expect(harness.events, [
        ..._enter,
        ('text', 'a', 0, 0),
        ('text', '', 1, 0),
      ]);
      await harness.unmount(tester);
    });

    testWidgets(
      '${platform.name}: one-shot Ctrl and locked Shift surround Enter',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final harness = _KeyboardHarness(
          platform,
          ControllerKeyboardInputMode.auto,
        );
        await harness.mount(tester);
        harness.modifier(
          CanonicalModifier.control,
          SyntheticModifierAction.toggle,
        );
        harness.modifier(CanonicalModifier.shift, SyntheticModifierAction.lock);
        await harness.nativeReturn(tester);
        await tester.pump();
        await harness.keyboard.idle;
        expect(harness.events, [
          ('hid', 0xe0, KeyboardIntentAction.down),
          ('hid', 0xe1, KeyboardIntentAction.down),
          ('key', 'VK_ENTER', true, true, true),
          ('key', 'VK_ENTER', false, true, true),
          ('hid', 0xe0, KeyboardIntentAction.up),
        ]);
        expect(harness.keyboard.effectiveModifiers.ctrl, isFalse);
        expect(harness.keyboard.effectiveModifiers.shift, isTrue);
        await harness.keyboard.reset(KeyboardResetReason.sessionClose);
        await harness.unmount(tester);
      },
    );
  }

  testWidgets('permission-blocked submit does not send an Enter', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = _KeyboardHarness(
      TargetPlatform.iOS,
      ControllerKeyboardInputMode.auto,
    )..allowed = false;
    await harness.mount(tester);
    await harness.nativeReturn(tester);
    await tester.pump();
    await harness.keyboard.idle;
    expect(harness.events, isEmpty);
    await harness.unmount(tester);
  });

  testWidgets('iOS Return echo survives rebuild and duplicate native updates', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = _KeyboardHarness(
      TargetPlatform.iOS,
      ControllerKeyboardInputMode.auto,
    );
    try {
      await harness.mount(tester);
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await harness.mount(tester);
      const echo = TextEditingValue(
        text: '1111\n',
        selection: TextSelection.collapsed(offset: 5),
      );
      tester.testTextInput.updateEditingValue(echo);
      await tester.pump();
      tester.testTextInput.updateEditingValue(echo);
      await tester.pump();
      await harness.keyboard.idle;
      expect(harness.events, _enter);
      // The next pasted newline is literal, even immediately after Return.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '1111\n\n',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump();
      await harness.keyboard.idle;
      expect(harness.events, [..._enter, ('text', '\n', 0, 0)]);
    } finally {
      await harness.unmount(tester);
    }
  });

  testWidgets(
    'replacing the editor controller discards a pending Return echo',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final first = _KeyboardHarness(
        TargetPlatform.iOS,
        ControllerKeyboardInputMode.auto,
      );
      final replacement = _KeyboardHarness(
        TargetPlatform.iOS,
        ControllerKeyboardInputMode.auto,
      );
      try {
        await first.mount(tester);
        await tester.testTextInput.receiveAction(TextInputAction.newline);
        replacement.focus.requestFocus();
        await replacement.mount(tester);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '1111\n',
            selection: TextSelection.collapsed(offset: 5),
          ),
        );
        await tester.pump();
        await first.keyboard.idle;
        await replacement.keyboard.idle;
        expect(first.events, _enter);
        expect(replacement.events, [('text', '\n', 0, 0)]);
      } finally {
        await replacement.unmount(tester);
        first.text.dispose();
        first.focus.dispose();
      }
    },
  );

  testWidgets('iOS coalesced Return echoes preserve subsequent typing', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = _KeyboardHarness(
      TargetPlatform.iOS,
      ControllerKeyboardInputMode.auto,
    );
    try {
      await harness.mount(tester);
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '1111\n\nx',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      await tester.pump();
      await harness.keyboard.idle;
      expect(harness.events, [..._enter, ..._enter, ('text', 'x', 0, 0)]);
    } finally {
      await harness.unmount(tester);
    }
  });

  testWidgets('iOS Return over an editor selection does not send a deletion', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = _KeyboardHarness(
      TargetPlatform.iOS,
      ControllerKeyboardInputMode.auto,
    );
    try {
      await harness.mount(tester);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '1111',
          selection: TextSelection(baseOffset: 2, extentOffset: 4),
        ),
      );
      await tester.pump();
      await harness.nativeReturn(tester);
      await tester.pump();
      await harness.keyboard.idle;
      expect(harness.events, _enter);
      expect(harness.text.text, '11\n');
    } finally {
      await harness.unmount(tester);
    }
  });
}
