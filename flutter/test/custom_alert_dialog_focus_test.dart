import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('editable dialog keeps its focus scope across text rebuilds', (
    tester,
  ) async {
    final controller = TextEditingController();
    final fieldFocusNode = FocusNode(debugLabel: 'dialogTextField');
    addTearDown(controller.dispose);
    addTearDown(fieldFocusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => CustomAlertDialog(
              content: TextField(
                key: const ValueKey('dialogTextField'),
                controller: controller,
                focusNode: fieldFocusNode,
                autofocus: true,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final textField = find.byKey(const ValueKey('dialogTextField'));
    final initialScope = FocusScope.of(tester.element(textField));
    expect(fieldFocusNode.hasFocus, isTrue);

    await tester.enterText(textField, 'a');
    await tester.pumpAndSettle();

    expect(FocusScope.of(tester.element(textField)), same(initialScope));
    expect(fieldFocusNode.hasFocus, isTrue);
    expect(
      controller.value.selection,
      const TextSelection.collapsed(offset: 1),
    );

    await tester.enterText(textField, 'ab');
    await tester.pumpAndSettle();

    expect(fieldFocusNode.hasFocus, isTrue);
    expect(controller.text, 'ab');
    expect(
      controller.value.selection,
      const TextSelection.collapsed(offset: 2),
    );
  });
}
