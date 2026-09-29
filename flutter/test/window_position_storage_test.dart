import 'dart:ui';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/utils/window_placement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('old window geometry remains readable without monitor metadata', () {
    final old = LastWindowPosition.loadFromString(
      '{"width":900,"height":600,"offsetWidth":-1200,"offsetHeight":40,"isMaximized":true}',
    );
    expect(old?.frame, const Rect.fromLTWH(-1200, 40, 900, 600));
    expect(old?.monitor, isNull);
    expect(old?.isMaximized, isTrue);
  });

  test('saved window retains its monitor and DPI after serialization', () {
    final saved = LastWindowPosition(
      900,
      600,
      -1200,
      40,
      false,
      false,
      monitor: WindowDisplay(
        id: 'name:secondary',
        workArea: const Rect.fromLTWH(-1920, 0, 1920, 1040),
        scaleFactor: 1.5,
      ),
    );
    final restored = LastWindowPosition.loadFromString(saved.toString())!;
    expect(restored.equals(saved), isTrue);
    expect(restored.monitor?.scaleFactor, 1.5);
  });

  test('invalid saved values cannot become an offscreen restore rectangle', () {
    expect(LastWindowPosition.loadFromString('[]'), isNull);
    final invalid = LastWindowPosition.loadFromString(
      '{"width":"bad","height":600,"offsetWidth":0,"offsetHeight":0,"monitor":42}',
    );
    expect(invalid?.frame, isNull);
    expect(invalid?.monitor, isNull);
  });
}
