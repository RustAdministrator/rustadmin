import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/clipboard_diagnostics.dart';

class _Pair {
  _Pair(this.clock, {this.forward = true, this.reverse = true}) {
    a = makeController('A', () async => aText, (text) async {
      aWrites.add(text);
      aText = text;
      if (forward) bText = text;
    });
    b = makeController('B', () async => bText, (text) async {
      bWrites.add(text);
      bText = text;
      if (reverse) aText = alterReturn?.call(text) ?? text;
    });
    b.startListener();
  }

  final FakeAsync clock;
  bool forward;
  bool reverse;
  String? aText;
  String? bText;
  String Function(String)? alterReturn;
  final aWrites = <String>[];
  final bWrites = <String>[];
  late final ClipboardDiagnostics a;
  late final ClipboardDiagnostics b;

  ClipboardDiagnostics makeController(
    String prefix,
    Future<String?> Function() read,
    Future<void> Function(String) write,
  ) {
    var sequence = 0;
    return ClipboardDiagnostics(
      readText: read,
      writeText: write,
      now: () => DateTime.utc(2026, 11, 5).add(clock.elapsed),
      makeId: (length) =>
          '$prefix${(++sequence).toRadixString(16).toUpperCase().padLeft(length - 1, '0')}',
      pollInterval: const Duration(milliseconds: 10),
      caseTimeout: const Duration(milliseconds: 100),
      operationTimeout: const Duration(milliseconds: 50),
      listenerLifetime: const Duration(minutes: 1),
    )..setDeviceIdentity('device-$prefix');
  }

  void run() {
    unawaited(a.runSuite(b.listenerCode));
    clock.flushMicrotasks();
    clock.elapse(const Duration(milliseconds: 400));
  }

  void dispose() {
    a.dispose();
    b.dispose();
    clock.flushMicrotasks();
  }
}

void main() {
  test(
    'each fixture proves both directions via a distinct OS clipboard reply',
    () {
      fakeAsync((clock) {
        final pair = _Pair(clock);
        pair.run();
        expect(pair.a.results, hasLength(3));
        expect(pair.a.results.every((r) => r.passed), isTrue);
        expect(pair.bWrites, hasLength(3));
        for (var i = 0; i < 3; i++) {
          expect(pair.aWrites[i], isNot(pair.bWrites[i]));
          expect(pair.a.results[i].forward, 'Passed');
          expect(pair.a.results[i].reverse, 'Passed');
        }
        expect(pair.aWrites.last, contains('日本語'));
        expect(pair.bWrites.last, contains('Русский'));
        pair.dispose();
      });
    },
  );

  for (final forward in [false, true]) {
    test(
      'blocked ${forward ? 'return' : 'forward'} leaves both directions unverified',
      () {
        fakeAsync((clock) {
          final pair = _Pair(clock, forward: forward, reverse: false);
          pair.run();
          expect(pair.a.results, hasLength(3));
          expect(pair.a.results.every((r) => r.status == 'timeout'), isTrue);
          expect(
            pair.a.results.every(
              (r) => r.forward == 'Unverified' && r.reverse == 'Unverified',
            ),
            isTrue,
          );
          expect(
            pair.b.entries.where((e) => e.event == 'forward-verified'),
            hasLength(forward ? 3 : 0),
          );
          expect(pair.b.entries.any((e) => e.event == 'passed'), isFalse);
          pair.dispose();
        });
      },
    );
  }

  test('modified text and unrelated target codes cannot pass', () {
    fakeAsync((clock) {
      final pair = _Pair(clock);
      pair.alterReturn = (text) => '$text modified';
      pair.run();
      expect(pair.a.results.any((r) => r.passed), isFalse);
      pair.a.clear();
      final before = pair.bWrites.length;
      unawaited(pair.a.runSuite('FFFFFFFF'));
      clock.flushMicrotasks();
      clock.elapse(const Duration(milliseconds: 400));
      expect(pair.bWrites.length, before);
      expect(pair.a.results.any((r) => r.passed), isFalse);
      pair.dispose();
    });
  });

  test('old replies cannot satisfy a later run', () {
    fakeAsync((clock) {
      final pair = _Pair(clock);
      pair.run();
      final oldReply = pair.bWrites.first;
      pair.forward = false;
      unawaited(pair.a.runSuite(pair.b.listenerCode));
      clock.flushMicrotasks();
      pair.aText = oldReply;
      clock.elapse(const Duration(milliseconds: 400));
      expect(pair.a.results.every((r) => !r.passed), isTrue);
      pair.dispose();
    });
  });

  test('two windows on the same device cannot prove a remote round trip', () {
    fakeAsync((clock) {
      final pair = _Pair(clock);
      pair.b.stopListener();
      pair.b.setDeviceIdentity('device-A');
      pair.b.startListener();
      pair.run();
      expect(pair.a.results.any((r) => r.passed), isFalse);
      expect(pair.bWrites, isEmpty);
      expect(
        pair.b.entries.any((e) => e.event == 'same-device-rejected'),
        isTrue,
      );
      expect(pair.a.exportReport(), isNot(contains('device-A')));
      expect(pair.aWrites.first, isNot(contains('device-A')));
      pair.dispose();
    });
  });

  test('restarting listener recovers from a permanently pending OS read', () {
    fakeAsync((clock) {
      final pair = _Pair(clock);
      final hungRead = Completer<String?>();
      var reads = 0;
      final listener = pair.makeController('C', () {
        if (++reads == 1) return hungRead.future;
        return Future.value('ordinary text');
      }, (_) async {});
      listener.startListener();
      clock.elapse(const Duration(milliseconds: 200));
      expect(reads, 1);
      listener.stopListener();
      listener.startListener();
      clock.elapse(const Duration(milliseconds: 20));
      expect(reads, greaterThan(1));
      listener.dispose();
      pair.dispose();
    });
  });

  test('duplicate requests and clearing reports do not create echo loops', () {
    fakeAsync((clock) {
      final pair = _Pair(clock);
      pair.run();
      pair.b.clear();
      pair.bText = pair.aWrites.first;
      clock.elapse(const Duration(milliseconds: 100));
      expect(pair.bWrites, hasLength(3));
      expect(pair.aWrites, hasLength(3));
      pair.dispose();
    });
  });

  test('only CRLF normalization is permitted', () {
    fakeAsync((clock) {
      final pair = _Pair(clock);
      pair.alterReturn = (text) => text.replaceAll('\n', '\r\n');
      pair.run();
      expect(pair.a.results.every((r) => r.passed), isTrue);
      pair.dispose();
    });
  });

  test('stop during a pending read never copies a late reply', () {
    fakeAsync((clock) {
      final pair = _Pair(clock, forward: false);
      final read = Completer<String?>();
      final writes = <String>[];
      final listener = pair.makeController('C', () => read.future, (
        text,
      ) async {
        writes.add(text);
      });
      listener.startListener();
      unawaited(pair.a.runSuite(listener.listenerCode));
      clock.flushMicrotasks();
      unawaited(listener.inspectNow());
      listener.stopListener();
      read.complete(pair.aWrites.first);
      clock.flushMicrotasks();
      expect(writes, isEmpty);
      expect(
        listener.entries.any((e) => e.event == 'forward-verified'),
        isFalse,
      );
      listener.dispose();
      pair.dispose();
    });
  });

  test('a newer clipboard value is not overwritten by a pending responder', () {
    fakeAsync((clock) {
      final pair = _Pair(clock, forward: false);
      final secondRead = Completer<String?>();
      var reads = 0;
      final writes = <String>[];
      final listener = pair.makeController('C', () async {
        if (++reads == 1) return pair.aWrites.first;
        return secondRead.future;
      }, (text) async => writes.add(text));
      listener.startListener();
      unawaited(pair.a.runSuite(listener.listenerCode));
      clock.flushMicrotasks();
      unawaited(listener.inspectNow());
      clock.flushMicrotasks();
      secondRead.complete('a newer personal copy');
      clock.flushMicrotasks();
      expect(writes, isEmpty);
      expect(listener.exportReport(), isNot(contains('a newer personal copy')));
      listener.dispose();
      pair.dispose();
    });
  });

  test(
    'backgrounding cancels pending cases and restart rotates the listener code',
    () {
      fakeAsync((clock) {
        final pair = _Pair(clock, forward: false);
        unawaited(pair.a.runSuite(pair.b.listenerCode));
        clock.flushMicrotasks();
        pair.a.setForeground(false);
        clock.elapse(const Duration(seconds: 1));
        expect(pair.a.running, isFalse);
        expect(pair.a.results.single.status, 'cancelled');
        expect(pair.aWrites, hasLength(1));
        final oldCode = pair.a.listenerCode;
        pair.a.stopListener();
        pair.a.setForeground(true);
        pair.a.startListener();
        expect(pair.a.listenerCode, isNot(oldCode));
        pair.dispose();
      });
    },
  );

  test('hung writes time out without queuing another fixture or run', () {
    fakeAsync((clock) {
      final pair = _Pair(clock);
      final write = Completer<void>();
      var writes = 0;
      final controller = pair.makeController('C', () async => null, (_) {
        writes++;
        return write.future;
      });
      unawaited(controller.runSuite(pair.b.listenerCode));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      expect(controller.running, isFalse);
      expect(controller.results.single.status, 'error');
      var rejected = false;
      controller.runSuite(pair.b.listenerCode).catchError((_) {
        rejected = true;
      });
      clock.flushMicrotasks();
      expect(rejected, isTrue);
      expect(writes, 1);
      controller.stopListener();
      write.complete();
      clock.flushMicrotasks();
      expect(controller.results.single.passed, isFalse);
      controller.dispose();
      pair.dispose();
    });
  });

  test('listener log is bounded and never exports personal text', () {
    fakeAsync((clock) {
      final pair = _Pair(clock);
      for (var i = 0; i < 150; i++) {
        pair.bText = 'personal secret $i';
        unawaited(pair.b.inspectNow());
        clock.flushMicrotasks();
      }
      expect(pair.b.entries, hasLength(ClipboardDiagnostics.maxEntries));
      expect(pair.b.exportReport(), isNot(contains('personal secret')));
      clock.elapse(const Duration(minutes: 1));
      expect(pair.b.listening, isFalse);
      pair.dispose();
    });
  });

  test('stopped responder never reports a late OS write as delivered', () {
    fakeAsync((clock) {
      final pair = _Pair(clock, forward: false);
      final write = Completer<void>();
      var issuedWrites = 0;
      final listener = pair.makeController(
        'C',
        () async => pair.aWrites.first,
        (_) {
          issuedWrites++;
          return write.future;
        },
      );
      listener.startListener();
      unawaited(pair.a.runSuite(listener.listenerCode));
      clock.flushMicrotasks();
      unawaited(listener.inspectNow());
      clock.flushMicrotasks();
      expect(issuedWrites, 1);
      listener.stopListener();
      write.complete();
      clock.flushMicrotasks();
      expect(listener.listening, isFalse);
      expect(listener.entries.any((e) => e.event == 'return-written'), isFalse);
      expect(listener.entries.any((e) => e.event == 'passed'), isFalse);
      clock.elapse(const Duration(milliseconds: 100));
      expect(issuedWrites, 1);
      listener.dispose();
      pair.dispose();
    });
  });
}
