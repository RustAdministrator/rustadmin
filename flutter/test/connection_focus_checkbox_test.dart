import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/connection_focus_checkbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('focus checkbox defaults to enabled and label toggles it', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionFocusCheckbox(onChanged: changes.add),
        ),
      ),
    );

    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    await tester.tap(find.text(kConnectionFocusCheckboxLabel));
    expect(changes, [false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit unchecked choice can be enabled again', (tester) async {
    var focusOnOpen = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ConnectionFocusCheckbox(
              value: focusOnOpen,
              onChanged: (value) => setState(() => focusOnOpen = value),
            ),
          ),
        ),
      ),
    );

    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(focusOnOpen, isTrue);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
  });
}
