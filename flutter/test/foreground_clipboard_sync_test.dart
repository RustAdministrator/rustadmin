import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/foreground_clipboard_sync.dart';

void main() {
  test('foreground copies send once to each permitted session', () {
    fakeAsync((clock) {
      String? text = 'https://example.invalid/日本語';
      final sent = <String>[];
      var permitted = true;
      final sync = ForegroundClipboardSync(readText: () async => text);
      final token = Object();
      sync.attach(
        token,
        canSend: () => permitted,
        send: (value) {
          sent.add(value);
          return true;
        },
      );
      clock.elapse(const Duration(seconds: 2));
      expect(sent, [text]);
      permitted = false;
      text = 'blocked';
      clock.elapse(const Duration(seconds: 1));
      expect(sent.length, 1);
      permitted = true;
      clock.elapse(const Duration(seconds: 1));
      expect(sent.last, 'blocked');
      sync.detach(token);
    });
  });

  test('disabled sessions never read the OS clipboard', () {
    fakeAsync((clock) {
      var reads = 0;
      final sync = ForegroundClipboardSync(
        readText: () async {
          reads++;
          return 'private';
        },
      );
      final token = Object();
      sync.attach(token, canSend: () => false, send: (_) => true);
      clock.elapse(const Duration(seconds: 3));
      expect(reads, 0);
      sync.detach(token);
    });
  });

  test('incoming data is applied once without echoing to any session', () {
    fakeAsync((clock) {
      String? text = 'old';
      final sent = <String>[];
      final sync = ForegroundClipboardSync(
        readText: () async => text,
        writeText: (value) async => text = value,
      );
      final token = Object();
      sync.attach(
        token,
        canSend: () => true,
        send: (value) {
          sent.add(value);
          return true;
        },
      );
      unawaited(sync.applyRemoteText('remote URL'));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 2));
      expect(text, 'remote URL');
      expect(sent, isEmpty);
      text = 'new local copy';
      clock.elapse(const Duration(seconds: 1));
      expect(sent, ['new local copy']);
      sync.detach(token);
    });
  });

  test('background and detached sessions cannot send a pending read', () {
    fakeAsync((clock) {
      final read = Completer<String?>();
      var reads = 0;
      final sent = <String>[];
      final sync = ForegroundClipboardSync(
        readText: () {
          reads++;
          return read.future;
        },
      );
      final token = Object();
      sync.attach(
        token,
        canSend: () => true,
        send: (value) {
          sent.add(value);
          return true;
        },
      );
      clock.elapse(const Duration(seconds: 8));
      expect(reads, 1); // A hung OS read must not accumulate more reads.
      sync.setForeground(false);
      read.complete('late personal text');
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 2));
      expect(sent, isEmpty);
      sync.detach(token);
      sync.setForeground(true);
      clock.elapse(const Duration(seconds: 2));
      expect(reads, 1);
    });
  });

  test('remote writes invalidate older reads and serialize OS writes', () {
    fakeAsync((clock) {
      final oldRead = Completer<String?>();
      final firstWrite = Completer<void>();
      final writes = <String>[];
      final sent = <String>[];
      final sync = ForegroundClipboardSync(
        readText: () => oldRead.future,
        writeText: (text) {
          writes.add(text);
          return writes.length == 1 ? firstWrite.future : Future.value();
        },
      );
      final token = Object();
      sync.attach(
        token,
        canSend: () => true,
        send: (text) {
          sent.add(text);
          return true;
        },
      );
      clock.elapse(const Duration(seconds: 1));
      unawaited(sync.applyRemoteText('first'));
      unawaited(sync.applyRemoteText('second'));
      clock.flushMicrotasks();
      expect(writes, ['first']);
      oldRead.complete('stale');
      clock.flushMicrotasks();
      expect(sent, isEmpty);
      firstWrite.complete();
      clock.flushMicrotasks();
      expect(writes, ['first', 'second']);
      sync.detach(token);
    });
  });

  test('native rejection is retried and permission is checked after read', () {
    fakeAsync((clock) {
      var accepted = false;
      var attempts = 0;
      final sync = ForegroundClipboardSync(readText: () async => 'text');
      final token = Object();
      sync.attach(
        token,
        canSend: () => true,
        send: (_) {
          attempts++;
          return accepted;
        },
      );
      clock.elapse(const Duration(seconds: 1));
      accepted = true;
      clock.elapse(const Duration(seconds: 2));
      expect(attempts, 2);
      sync.detach(token);

      var permitted = true;
      final read = Completer<String?>();
      final gated = ForegroundClipboardSync(readText: () => read.future);
      gated.attach(
        token,
        canSend: () => permitted,
        send: (_) {
          fail('permission was revoked during read');
        },
      );
      clock.elapse(const Duration(seconds: 1));
      permitted = false;
      read.complete('text');
      clock.flushMicrotasks();
      gated.detach(token);
    });
  });
}
