import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const sourceRoot =
      'android/app/src/main/kotlin/io/github/rustadministrator/rustadmin';
  final directLogger = RegExp(
    r'\b(?:Log\.(?:v|d|i|w|e|wtf)|FFI\.logDiagnostic|AndroidDiagnosticLog\.\w+)\s*\(',
  );

  for (final name in ['InputService.kt', 'RemoteKeyboardInputView.kt']) {
    test('$name uses the typed input diagnostics boundary', () {
      final source = File('$sourceRoot/$name').readAsStringSync();
      final calls = directLogger
          .allMatches(source)
          .map((match) => match.group(0))
          .toList();
      expect(
        calls,
        isEmpty,
        reason: 'Input entrypoints must not format payloads for raw loggers',
      );
      expect(source, contains('AndroidInputDiagnostics'));
    });
  }
}
