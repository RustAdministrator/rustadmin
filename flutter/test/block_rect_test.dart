import 'dart:ui';

import 'package:flutter_hbb/common/block_rect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a global rectangle becomes one in the region coordinates', () {
    final local = localBlockRect(
      const Rect.fromLTWH(110, 260, 100, 50),
      const Offset(10, 60),
    );
    expect(local, const Rect.fromLTWH(100, 200, 100, 50));
    expect(local!.contains(const Offset(120, 220)), isTrue);
    expect(local.contains(const Offset(20, 20)), isFalse);
  });

  test('null stays null', () {
    expect(localBlockRect(null, const Offset(1, 2)), isNull);
  });
}
