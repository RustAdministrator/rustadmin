import 'package:flutter_hbb/models/monitor_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows numbers differ from capture indices without sorting them', () {
    final names = [r'\\.\DISPLAY2', r'\\.\DISPLAY1', r'\\.\DISPLAY3'];
    expect(monitorLabelsForDisplays(names, isWindows: true), ['2', '1', '3']);
    expect(names, [r'\\.\DISPLAY2', r'\\.\DISPLAY1', r'\\.\DISPLAY3']);
  });

  test('keeps non-contiguous Windows numbers across unplug and reconnect', () {
    expect(
      monitorLabelsForDisplays([
        r'\\.\DISPLAY4',
        r'\\.\DISPLAY2',
      ], isWindows: true),
      ['4', '2'],
    );
    expect(monitorLabelsForDisplays([r'\\.\DISPLAY2'], isWindows: true), ['2']);
  });

  test('accepts case-insensitive and NUL-padded native names', () {
    expect(
      monitorLabelsForDisplays([
        r'\\.\display2'
            '\u0000\u0000',
        r'\\.\DISPLAY10',
      ], isWindows: true),
      ['2', '10'],
    );
  });

  test('unnamed, malformed, and duplicate names fall back as one set', () {
    for (final name in [
      '',
      'DISPLAY1',
      r'\\.\DISPLAY0',
      r'\\.\DISPLAY01',
      r'\\.\DISPLAY-1',
      r'\\.\DISPLAY2',
      r'\\.\DISPLAY2147483648',
      r'\\.\DISPLAY3\Monitor0',
      r'\\.\DISPLAY3'
          '\n',
      r'\\.\DISPLAY3'
          '\u0000suffix',
      'x' * 257,
    ]) {
      expect(
        monitorLabelsForDisplays([r'\\.\DISPLAY2', name], isWindows: true),
        ['1', '2'],
        reason: 'Must not mix native and ordinal labels for $name',
      );
    }
  });

  test('other platforms retain capture-order numbering', () {
    expect(
      monitorLabelsForDisplays([
        r'\\.\DISPLAY2',
        r'\\.\DISPLAY1',
      ], isWindows: false),
      ['1', '2'],
    );
    expect(monitorLabelsForDisplays([], isWindows: true), isEmpty);
  });
}
