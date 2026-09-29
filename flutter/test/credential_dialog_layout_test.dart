import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _CredentialBridge implements Rustadmin {
  @override
  String translate({
    required String name,
    required String locale,
    dynamic hint,
  }) => name;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget dialog({
  required int fields,
  String description = '',
  String title = 'Credentials',
}) => MaterialApp(
  // Ahem is wider than UI fonts; keep the reference title below the width cap.
  theme: MyTheme.lightTheme.copyWith(
    textTheme: MyTheme.lightTheme.textTheme.copyWith(
      titleLarge: const TextStyle(fontSize: 12),
    ),
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) => CustomAlertDialog(
        preferredContentWidth: credentialDialogWidth(context),
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
  ),
);

void main() {
  setUpAll(() {
    isTest = true;
    platformFFI.initForTest(_CredentialBridge());
  });

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
        tester
            .widget<CustomAlertDialog>(find.byType(CustomAlertDialog))
            .preferredContentWidth,
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
      lessThan(
        tester
            .widget<CustomAlertDialog>(find.byType(CustomAlertDialog))
            .preferredContentWidth!,
      ),
    );
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(tester.getBottomRight(find.text('Continue')).dy, lessThan(420));
    expect(tester.takeException(), isNull);
  });
}
