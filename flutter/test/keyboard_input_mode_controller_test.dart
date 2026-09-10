import 'dart:async';

import 'package:flutter_hbb/models/keyboard_input_mode_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class ModeHarness {
  int resets = 0;
  bool active = true;
  String stored = 'auto';
  bool failWrite = false;
  Completer<void>? resetGate;
  Completer<void>? writeGate;
  final reads = <Completer<String>>[];
  final writes = <String>[];
  late final owner = KeyboardInputModeController(
    resetKeyboard: () async {
      resets++;
      await resetGate?.future;
    },
    readMode: () {
      final read = Completer<String>();
      reads.add(read);
      return read.future;
    },
    writeMode: (mode, isCurrent) async {
      writes.add('primary:$mode');
      stored = mode;
      await writeGate?.future;
      if (failWrite) throw StateError('write failed');
      if (isCurrent()) writes.add('mirror:$mode');
    },
    sessionIsActive: () => active,
  );
}

Future<void> turn() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'reentrant observer requests remain part of the ordered drain',
    () async {
      final h = ModeHarness()..writeGate = Completer<void>();
      Future<bool>? latest;
      var requested = false;
      h.owner.addListener(() {
        if (requested) return;
        requested = true;
        latest = h.owner.setMode('physical', persist: true);
      });
      final first = h.owner.setMode('text', persist: true);
      expect(await first, isFalse);
      await turn();
      expect(h.writes, ['primary:physical']);
      var drained = false;
      final idle = h.owner.idle.then((_) => drained = true);
      await turn();
      expect(drained, isFalse);
      h.writeGate!.complete();
      expect(await latest!, isTrue);
      await idle;
      expect(h.owner.value.storedMode, 'physical');
    },
  );

  test(
    'latest Auto supersedes Text even when Auto matches applied mode',
    () async {
      final h = ModeHarness();
      final text = h.owner.setMode('text');
      final auto = h.owner.setMode('auto');
      expect(await text, isFalse);
      expect(await auto, isTrue);
      expect(h.owner.value.storedMode, 'auto');
      expect(h.owner.value.physicalKeyInput, isTrue);
    },
  );

  test('latest request also wins while the earlier reset is running', () async {
    final h = ModeHarness()..resetGate = Completer<void>();
    final first = h.owner.setMode('text', persist: true);
    await turn();
    final latest = h.owner.setMode('physical', persist: true);
    expect(h.owner.canDispatch, isFalse);
    h.resetGate!.complete();
    expect(await first, isFalse);
    expect(await latest, isTrue);
    expect(h.owner.value.storedMode, 'physical');
    expect(h.writes, ['primary:physical', 'mirror:physical']);
    expect(h.owner.canDispatch, isTrue);
  });

  test(
    'no-op user choice invalidates a previously started settings read',
    () async {
      final h = ModeHarness();
      final load = h.owner.refresh();
      expect(await h.owner.setMode('auto'), isTrue);
      h.reads.single.complete('text');
      expect(await load, isFalse);
      expect(h.owner.value.storedMode, 'auto');
      expect(h.resets, 0);
    },
  );

  test('latest refresh wins when settings reads finish out of order', () async {
    final h = ModeHarness();
    final old = h.owner.refresh();
    final current = h.owner.refresh();
    h.reads.last.complete('physical');
    expect(await current, isTrue);
    h.reads.first.complete('text');
    expect(await old, isFalse);
    expect(h.owner.value.storedMode, 'physical');
  });

  test('refresh cannot override an in-flight explicit mode change', () async {
    final h = ModeHarness()..resetGate = Completer<void>();
    final change = h.owner.setMode('text', persist: true);
    expect(await h.owner.refresh(), isFalse);
    expect(h.reads, isEmpty);
    h.resetGate!.complete();
    await change;
  });

  test(
    'pending reads do not block close or affect the replacement session',
    () async {
      final h = ModeHarness();
      final epoch = h.owner.epoch;
      final load = h.owner.refresh();
      await h.owner.endSession();
      expect(h.owner.accepts(epoch), isFalse);
      h.owner.beginSession();
      await h.owner.setMode('physical');
      h.reads.single.complete('text');
      expect(await load, isFalse);
      expect(h.owner.value.storedMode, 'physical');
    },
  );

  test('session close cancels an awaiting reset before persistence', () async {
    final h = ModeHarness()..resetGate = Completer<void>();
    final change = h.owner.setMode('text', persist: true);
    await turn();
    final close = h.owner.endSession();
    expect(h.owner.canDispatch, isFalse);
    h.resetGate!.complete();
    expect(await change, isFalse);
    await close;
    expect(h.writes, isEmpty);
  });

  test(
    'writes are ordered and superseded compatibility mirrors are skipped',
    () async {
      final h = ModeHarness()..writeGate = Completer<void>();
      final first = h.owner.setMode('text', persist: true);
      await turn();
      final last = h.owner.setMode('auto', persist: true);
      expect(h.writes, ['primary:text']);
      h.writeGate!.complete();
      expect(await first, isFalse);
      expect(await last, isTrue);
      expect(h.writes, ['primary:text', 'primary:auto', 'mirror:auto']);
      expect(h.stored, 'auto');
      expect(h.owner.value.storedMode, 'auto');
    },
  );

  test('close drains an admitted write before SessionID reuse', () async {
    final h = ModeHarness()..writeGate = Completer<void>();
    final change = h.owner.setMode('text', persist: true);
    await turn();
    var closed = false;
    final close = h.owner.endSession().then((_) => closed = true);
    await turn();
    expect(closed, isFalse);
    h.writeGate!.complete();
    expect(await change, isFalse);
    await close;
    expect(h.writes, ['primary:text']);
    h.owner.beginSession();
    expect(h.owner.value.storedMode, 'auto');
  });

  test(
    'persistence failure blocks uncertain input and a retry recovers',
    () async {
      final h = ModeHarness()..failWrite = true;
      await expectLater(
        h.owner.setMode('text', persist: true),
        throwsStateError,
      );
      expect(h.owner.value.failed, isTrue);
      expect(h.owner.canDispatch, isFalse);
      h.failWrite = false;
      expect(await h.owner.setMode('auto', persist: true), isTrue);
      expect(h.owner.canDispatch, isTrue);
      expect(h.owner.value.failed, isFalse);
      expect(h.stored, 'auto');
    },
  );

  test(
    'native start failure invalidates reads even before explicit cleanup',
    () async {
      final h = ModeHarness();
      final read = h.owner.refresh();
      h.active = false;
      h.reads.single.complete('text');
      expect(await read, isFalse);
      expect(await h.owner.setMode('physical'), isFalse);
      expect(h.owner.canDispatch, isFalse);
    },
  );

  test('UI projections and routing share the applied snapshot', () async {
    final h = ModeHarness()..resetGate = Completer<void>();
    final snapshots = <KeyboardInputModeSnapshot>[];
    h.owner.addListener(() => snapshots.add(h.owner.value));
    final change = h.owner.setMode('TEXT');
    expect(h.owner.value.changing, isTrue);
    expect(h.owner.value.storedMode, 'auto');
    h.resetGate!.complete();
    await change;
    expect(snapshots.last.storedMode, 'text');
    expect(snapshots.last.physicalKeyInput, isFalse);
    expect(snapshots.last.changing, isFalse);
  });
}
