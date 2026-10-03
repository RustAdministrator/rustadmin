import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/widgets/mobile_remote_text_edit.dart';

TextEditingValue _value(String text, int offset) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: offset),
);

void main() {
  final sentinel = '1' * 1024;

  test('coalesced backspace keeps the sentinel out of the payload', () {
    final edit = mobileIOSSoftKeyboardTextEdit(
      _value(sentinel, sentinel.length),
      _value('1' * 1022, 1022),
      internalSentinel: sentinel,
    );

    expect(edit.text, isEmpty);
    expect(edit.deleteBeforeGraphemes, 2);
    expect(edit.deleteAfterGraphemes, 0);
  });

  test('held backspace batches preserve their deletion count', () {
    final oldText = '$sentinel abc';
    final newText = '$sentinel a';
    final edit = mobileIOSSoftKeyboardTextEdit(
      _value(oldText, oldText.length),
      _value(newText, newText.length),
      internalSentinel: sentinel,
    );

    expect(edit.text, isEmpty);
    expect(edit.deleteBeforeGraphemes, 2);
  });

  test('deletion crossing the sentinel does not replay prior history', () {
    final history = 'already sent${'\n' * 12}';
    final oldText = '$sentinel$history';
    final newText = '${'1' * 1023}$history';
    final edit = mobileIOSSoftKeyboardTextEdit(
      _value(oldText, oldText.length),
      _value(newText, newText.length),
      internalSentinel: sentinel,
    );

    expect(edit.text, isEmpty);
    expect(edit.deleteBeforeGraphemes, 1);
  });

  test('middle deletion does not replay an unchanged multiline suffix', () {
    final oldText = '$sentinel abc${'\n' * 12}';
    final newText = '$sentinel ac${'\n' * 12}';
    final edit = mobileIOSSoftKeyboardTextEdit(
      _value(oldText, oldText.length),
      _value(newText, newText.length),
      internalSentinel: sentinel,
    );

    expect(edit.text, isEmpty);
    expect(edit.deleteBeforeGraphemes, 1);
  });

  test('a single deletion immediately after the sentinel shrinks locally', () {
    final oldText = '${sentinel}a';
    final edit = mobileIOSSoftKeyboardTextEdit(
      _value(oldText, oldText.length),
      _value(sentinel, sentinel.length),
      internalSentinel: sentinel,
    );

    expect(edit.text, isEmpty);
    expect(edit.deleteBeforeGraphemes, 1);
  });

  test('typing one at the sentinel boundary stays a literal insertion', () {
    final newText = '${sentinel}1';
    final edit = mobileIOSSoftKeyboardTextEdit(
      _value(sentinel, sentinel.length),
      _value(newText, newText.length),
      internalSentinel: sentinel,
    );

    expect(edit.text, '1');
    expect(edit.deleteBeforeGraphemes, 0);
  });

  test('literal paste can replace the sentinel with one', () {
    final edit = mobileIOSSoftKeyboardTextEdit(
      TextEditingValue(
        text: sentinel,
        selection: TextSelection(baseOffset: 0, extentOffset: sentinel.length),
      ),
      _value('1', 1),
      internalSentinel: sentinel,
      hasPasteProvenance: true,
    );

    expect(edit.text, '1');
    expect(edit.deleteBeforeGraphemes, 0);
  });

  test(
    'native full-buffer replacement uses selection without paste provenance',
    () {
      const pasted = 'pasted text';
      final edit = mobileIOSSoftKeyboardTextEdit(
        TextEditingValue(
          text: sentinel,
          selection: TextSelection(
            baseOffset: 0,
            extentOffset: sentinel.length,
          ),
        ),
        _value(pasted, pasted.length),
        internalSentinel: sentinel,
      );

      expect(edit.text, pasted);
      expect(edit.deleteBeforeGraphemes, 0);
    },
  );

  test(
    'native replacement keeps an unchanged history suffix out of the edit',
    () {
      final history = 'already sent${'\n' * 12}';
      const pasted = 'pasted text';
      final oldText = '$sentinel$history';
      final newText = '$pasted$history';
      final edit = mobileIOSSoftKeyboardTextEdit(
        TextEditingValue(
          text: oldText,
          selection: TextSelection(
            baseOffset: 0,
            extentOffset: sentinel.length,
          ),
        ),
        _value(newText, pasted.length),
        internalSentinel: sentinel,
        hasPasteProvenance: true,
      );

      expect(edit.text, pasted);
      expect(edit.deleteBeforeGraphemes, 0);
    },
  );

  test('selection deletion still emits deletion with no inserted text', () {
    final oldText = '${sentinel}history';
    final newText = 'history';
    final edit = mobileIOSSoftKeyboardTextEdit(
      TextEditingValue(
        text: oldText,
        selection: TextSelection(baseOffset: 0, extentOffset: sentinel.length),
      ),
      _value(newText, 0),
      internalSentinel: sentinel,
      hasPasteProvenance: true,
    );

    expect(edit.text, isEmpty);
    expect(edit.deleteBeforeGraphemes, sentinel.length);
  });

  test(
    'one-character sentinel replacement does not replay a multiline suffix',
    () {
      final history = 'already sent${'\n' * 12}';
      final oldText = '$sentinel$history';
      final newText = 'p${sentinel.substring(1)}$history';
      final edit = mobileIOSSoftKeyboardTextEdit(
        TextEditingValue(
          text: oldText,
          selection: const TextSelection(baseOffset: 0, extentOffset: 1),
        ),
        _value(newText, 1),
        internalSentinel: sentinel,
        hasPasteProvenance: true,
      );

      expect(edit.text, 'p');
      expect(edit.deleteBeforeGraphemes, 0);
      expect(edit.deleteAfterGraphemes, 0);
    },
  );

  test(
    'unanchored prefix loss keeps the unchanged suffix out of the payload',
    () {
      final history = 'already sent${'\n' * 12}';
      final oldText = '$sentinel$history';
      final newText = '1pasted$history';
      final edit = mobileIOSSoftKeyboardTextEdit(
        _value(oldText, oldText.length),
        _value(newText, '1pasted'.length),
        internalSentinel: sentinel,
        hasPasteProvenance: true,
      );

      expect(edit.text, 'pasted');
      expect(edit.text, isNot(newText));
    },
  );

  test('composition or deletion prefix loss is never treated as paste', () {
    final history = 'already sent${'\n' * 12}';
    final oldText = '$sentinel$history';
    final newText = '${'1' * 1023}$history';
    final edit = mobileIOSSoftKeyboardTextEdit(
      _value(oldText, oldText.length),
      _value(newText, newText.length),
      internalSentinel: sentinel,
      hasPasteProvenance: false,
    );

    expect(edit.text, isEmpty);
    expect(edit.deleteBeforeGraphemes, 1);
  });

  test('multiline paste keeps literal ones and newlines', () {
    const pasted = '1\nfirst\n1\nlast';
    final newText = '$sentinel$pasted';
    final edit = mobileIOSSoftKeyboardTextEdit(
      _value(sentinel, sentinel.length),
      _value(newText, newText.length),
      internalSentinel: sentinel,
    );

    expect(edit.text, pasted);
    expect(edit.deleteBeforeGraphemes, 0);
  });

  test('selection anchors repeated-character insertion at the start', () {
    final oldText = '1111\n\n';
    final newText = '11111\n\n';
    final edit = mobileCommittedTextEditValue(
      _value(oldText, 0),
      _value(newText, 1),
    );

    expect(edit.text, '1');
    expect(edit.deleteBeforeGraphemes, 0);
    expect(edit.deleteAfterGraphemes, 0);
  });
}
