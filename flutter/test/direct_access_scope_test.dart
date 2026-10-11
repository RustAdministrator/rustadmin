import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only empty and "any" mean any address; everything else narrows', () {
    expect(normalizeDirectAccessScope(''), kDirectAccessScopeAny);
    expect(normalizeDirectAccessScope('  '), kDirectAccessScopeAny);
    expect(normalizeDirectAccessScope('any'), kDirectAccessScopeAny);
    expect(normalizeDirectAccessScope('ANY'), kDirectAccessScopeAny);
    expect(normalizeDirectAccessScope('local'), kDirectAccessScopeLocal);
    // The same reading as the service: unknown values never widen access.
    for (final value in ['lan', 'yes', '1', 'internet']) {
      expect(normalizeDirectAccessScope(value), kDirectAccessScopeLocal,
          reason: value);
    }
  });
}
