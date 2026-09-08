import 'dart:async';
import 'dart:collection';

typedef KeyboardCommandErrorHandler =
    void Function(Object error, StackTrace stackTrace);

class _QueuedKeyboardCommand {
  _QueuedKeyboardCommand(this.generation, this.command, this.keepOnCancel);

  final int generation;
  final Future<void> Function() command;
  final bool keepOnCancel;
  final completion = Completer<void>();
}

class KeyboardCommandQueue {
  KeyboardCommandQueue({this.onError});

  final KeyboardCommandErrorHandler? onError;
  final _pending = Queue<_QueuedKeyboardCommand>();
  Completer<void>? _idle;
  bool _running = false;
  var _generation = 0;

  Future<void> enqueue(
    Future<void> Function() command, {
    bool keepOnCancel = false,
  }) {
    final queued = _QueuedKeyboardCommand(_generation, command, keepOnCancel);
    _pending.addLast(queued);
    _idle ??= Completer<void>();
    _start();
    return queued.completion.future;
  }

  Future<void> get idle => _idle?.future ?? Future<void>.value();
  int get generation => _generation;

  void _start() {
    if (_running) return;
    _running = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      final queued = _pending.removeFirst();
      try {
        if (queued.keepOnCancel || queued.generation == _generation) {
          await queued.command();
        }
      } catch (error, stackTrace) {
        onError?.call(error, stackTrace);
      } finally {
        queued.completion.complete();
      }
    }
    _running = false;
    _idle?.complete();
    _idle = null;
    if (_pending.isNotEmpty) _start();
  }

  void cancelPending() {
    _generation++;
  }
}
