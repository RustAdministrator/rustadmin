import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/toolbar_reveal_transition.dart';
import 'package:flutter_test/flutter_test.dart';

class _Visibility extends ValueNotifier<bool> {
  _Visibility(super.value);

  bool get observed => hasListeners;
}

Widget _toolbar(ValueNotifier<bool> visible, VoidCallback onTap) => MaterialApp(
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(100),
      child: Align(
        alignment: Alignment.topLeft,
        child: ToolbarRevealTransition(
          visible: visible,
          child: Semantics(
            label: 'Toolbar action',
            child: GestureDetector(
              onTap: onTap,
              behavior: HitTestBehavior.opaque,
              child: const ColoredBox(
                key: ValueKey('toolbar-target'),
                color: Colors.blue,
                child: SizedBox(width: 96, height: 40),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('reveal restores bounds and input before another frame', (
    tester,
  ) async {
    final visible = _Visibility(true);
    addTearDown(visible.dispose);
    var taps = 0;
    await tester.pumpWidget(_toolbar(visible, () => taps++));
    final target = find.byKey(const ValueKey('toolbar-target'));
    final restingBounds = tester.getRect(target);
    for (final delay in [
      Duration.zero,
      const Duration(milliseconds: 80),
      const Duration(milliseconds: 300),
    ]) {
      visible.value = false;
      expect(target.hitTestable(), findsNothing);
      await tester.pump();
      await tester.pump(delay);
      if (delay != Duration.zero) {
        expect(tester.getRect(target).top, lessThan(restingBounds.top));
      }
      final before = taps;
      visible.value = true;
      // Neither a widget rebuild nor an animation tick is permitted here.
      expect(tester.getRect(target), restingBounds);
      expect(target.hitTestable(), findsOneWidget);
      await tester.tapAt(restingBounds.center);
      expect(taps, before + 1);
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(visible.observed, isFalse);
  });

  testWidgets(
    'hidden toolbar semantics and replacement visibility are isolated',
    (tester) async {
      final first = _Visibility(true);
      final second = _Visibility(false);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(_toolbar(first, () {}));
        expect(find.semantics.byLabel('Toolbar action'), findsOne);
        first.value = false;
        await tester.pumpAndSettle();
        expect(find.semantics.byLabel('Toolbar action'), findsNothing);

        await tester.pumpWidget(_toolbar(second, () {}));
        expect(first.observed, isFalse);
        first.value = true;
        final target = find.byKey(const ValueKey('toolbar-target'));
        expect(target.hitTestable(), findsNothing);
        second.value = true;
        expect(target.hitTestable(), findsOneWidget);
        await tester.pumpAndSettle();
        expect(find.semantics.byLabel('Toolbar action'), findsOne);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(second.observed, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}
