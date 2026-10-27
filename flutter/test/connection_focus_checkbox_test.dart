import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/connection_focus_checkbox.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _FocusCheckboxBindings implements Rustadmin {
  @override
  String translate({
    required String name,
    required String locale,
    dynamic hint,
  }) => name;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() {
    isTest = true;
    platformFFI.initForTest(_FocusCheckboxBindings());
  });

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

  testWidgets('attempt callback leaves other choices and credentials intact', (
    tester,
  ) async {
    var attempt = true;
    var globalDefault = true;
    var rememberPassword = false;
    final attemptWrites = <bool>[];
    final globalWrites = <bool>[];
    final password = TextEditingController(text: 'unchanged credential');
    addTearDown(password.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                TextField(controller: password),
                CheckboxListTile(
                  title: const Text('Remember password'),
                  value: rememberPassword,
                  onChanged: (value) =>
                      setState(() => rememberPassword = value ?? false),
                ),
                ConnectionFocusCheckbox(
                  value: attempt,
                  onChanged: (value) => setState(() {
                    attempt = value;
                    attemptWrites.add(value);
                  }),
                ),
                ConnectionFocusCheckbox(
                  label: 'Global default',
                  value: globalDefault,
                  onChanged: (value) => setState(() {
                    globalDefault = value;
                    globalWrites.add(value);
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text(kConnectionFocusCheckboxLabel));
    await tester.pump();
    expect(attemptWrites, [false]);
    expect(globalWrites, isEmpty);
    expect(globalDefault, isTrue);
    expect(rememberPassword, isFalse);
    expect(password.text, 'unchanged credential');

    await tester.tap(find.text('Global default'));
    await tester.pump();
    expect(globalWrites, [false]);
    expect(attemptWrites, [false]);
    expect(attempt, isFalse);
    expect(rememberPassword, isFalse);
    expect(password.text, 'unchanged credential');
    expect(tester.takeException(), isNull);
  });

  testWidgets('nonpending authentication session has no focus checkbox', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => pendingConnectionFocusCheckbox(
              SessionID('00000000-0000-4000-8000-000000000252'),
              setState,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(ConnectionFocusCheckbox), findsNothing);
  });

  for (final width in [320.0, 540.0]) {
    testWidgets(
      'credential checkbox fits $width at 2x and keeps actions accessible',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 420));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final password = TextEditingController(text: 'existing passphrase');
        addTearDown(password.dispose);
        var focusOnOpen = true;

        Widget dialog({required bool showCheckbox}) => MaterialApp(
          theme: MyTheme.lightTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(2),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => CustomAlertDialog(
                preferredContentWidth: credentialDialogWidth(context),
                title: const Text('Password Required'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Enter your login credentials to continue.'),
                    for (var index = 0; index < 3; index++)
                      TextField(
                        controller: index == 0 ? password : null,
                        decoration: InputDecoration(labelText: 'Field $index'),
                      ),
                    if (showCheckbox)
                      ConnectionFocusCheckbox(
                        value: focusOnOpen,
                        onChanged: (value) =>
                            setState(() => focusOnOpen = value),
                      ),
                  ],
                ),
                actions: [
                  TextButton(onPressed: () {}, child: const Text('Continue')),
                ],
              ),
            ),
          ),
        );

        await tester.pumpWidget(dialog(showCheckbox: false));
        await tester.pumpAndSettle();
        final credentialWidth =
            tester.getSize(find.byType(TextField).first).width;
        await tester.pumpWidget(dialog(showCheckbox: true));
        await tester.pumpAndSettle();

        expect(
          tester.getSize(find.byType(TextField).first).width,
          credentialWidth,
        );
        expect(
          tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
          isTrue,
        );
        expect(find.text('Continue').hitTestable(), findsOneWidget);
        await tester.ensureVisible(find.byType(ConnectionFocusCheckbox));
        await tester.pumpAndSettle();
        await tester.tap(find.text(kConnectionFocusCheckboxLabel));
        await tester.pump();
        expect(focusOnOpen, isFalse);
        expect(password.text, 'existing passphrase');
        expect(find.text('Continue').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
