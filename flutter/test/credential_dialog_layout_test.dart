import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_test/flutter_test.dart';

Widget dialog({
  required int fields,
  String description = '',
  String title = 'Credentials',
}) => MaterialApp(
  home: Scaffold(
    body: CustomAlertDialog(
      preferredContentWidth: kCredentialDialogWidth,
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.password_rounded),
          const SizedBox(width: 10),
          Flexible(child: Text(title)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (description.isNotEmpty) Text(description),
          for (var i = 0; i < fields; i++)
            TextField(decoration: InputDecoration(labelText: 'Field $i')),
        ],
      ),
      actions: [TextButton(onPressed: () {}, child: const Text('Continue'))],
    ),
  ),
);

void main() {
  testWidgets(
    'credential dialogs keep the same width and fit their own height',
    (tester) async {
      await tester.pumpWidget(dialog(fields: 1));
      await tester.pumpAndSettle();
      final small = tester.getSize(find.byType(IntrinsicWidth).first);
      await tester.pumpWidget(
        dialog(
          fields: 3,
          description: 'Enter your login credentials.',
          title: 'A longer translated title for administrator credentials',
        ),
      );
      await tester.pumpAndSettle();
      final large = tester.getSize(find.byType(IntrinsicWidth).first);
      expect(large.width, small.width);
      expect(large.height, greaterThan(small.height));
      expect(
        tester.getSize(find.byType(TextField).first).width,
        kCredentialDialogWidth,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('narrow screen and long text scroll without hiding the actions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 420);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      dialog(
        fields: 3,
        description: List.filled(50, 'Long translated text.').join(' '),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(TextField).first).width,
      lessThan(kCredentialDialogWidth),
    );
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(tester.getBottomRight(find.text('Continue')).dy, lessThan(420));
    expect(tester.takeException(), isNull);
  });
}
