import 'dart:async';

import 'package:flutter/foundation.dart';

import '../consts.dart';
import 'keyboard_dispatcher.dart';

@immutable
class KeyboardInputModeSnapshot {
  const KeyboardInputModeSnapshot({
    this.mode = ControllerKeyboardInputMode.auto,
    this.changing = false,
    this.failed = false,
  });

  final ControllerKeyboardInputMode mode;
  final bool changing;
  final bool failed;

  String get storedMode => switch (mode) {
    ControllerKeyboardInputMode.auto => kKeyboardInputModeAuto,
    ControllerKeyboardInputMode.text => kKeyboardInputModeText,
    ControllerKeyboardInputMode.physical => kKeyboardInputModePhysical,
  };
  bool get physicalKeyInput => mode != ControllerKeyboardInputMode.text;
}

/// Owns Auto/Text/Physical application, not the native Legacy/Map/Translate
/// protocol or the desktop grab ledger. Reads are observations; explicit
/// requests win over any read that started before them.
class KeyboardInputModeController extends ChangeNotifier {
  factory KeyboardInputModeController({
    required Future<void> Function() resetKeyboard,
    required Future<String> Function() readMode,
    required Future<void> Function(String mode, bool Function() isCurrent)
    writeMode,
    required bool Function() sessionIsActive,
  }) => KeyboardInputModeController._(
    resetKeyboard,
    readMode,
    writeMode,
    sessionIsActive,
  );

  KeyboardInputModeController._(
    this._resetKeyboard,
    this._readMode,
    this._writeMode,
    this._sessionIsActive,
  );

  final Future<void> Function() _resetKeyboard;
  final Future<String> Function() _readMode;
  final Future<void> Function(String, bool Function()) _writeMode;
  final bool Function() _sessionIsActive;
  KeyboardInputModeSnapshot _value = const KeyboardInputModeSnapshot();
  Future<void>? _tail;
  int _epoch = 0;
  int _request = 0;
  int _read = 0;
  bool _active = true;

  KeyboardInputModeSnapshot get value => _value;
  int get epoch => _epoch;
  Future<void> get idle => _tail ?? Future<void>.value();
  bool accepts(int epoch) => _active && epoch == _epoch && _sessionIsActive();
  bool get canDispatch => accepts(_epoch) && !_value.changing && !_value.failed;

  void beginSession() {
    _epoch++;
    _request++;
    _read++;
    _active = true;
    _publish(const KeyboardInputModeSnapshot());
  }

  /// Invalidate immediately; callers drain admitted writes before native
  /// teardown/reuse of a mobile SessionID. Pending reads need not block close.
  Future<void> endSession() {
    _active = false;
    _epoch++;
    _request++;
    _read++;
    _publish(KeyboardInputModeSnapshot(mode: _value.mode));
    return idle;
  }

  Future<bool> refresh() async {
    final epoch = _epoch;
    if (!accepts(epoch) || _value.changing) return false;
    final request = _request;
    final read = ++_read;
    final mode = await _readMode();
    if (!accepts(epoch) || request != _request || read != _read) return false;
    return setMode(mode);
  }

  Future<bool> setMode(String mode, {bool persist = false}) {
    final epoch = _epoch;
    if (!accepts(epoch)) return Future<bool>.value(false);
    final next = switch (mode.toLowerCase()) {
      kKeyboardInputModeText => ControllerKeyboardInputMode.text,
      kKeyboardInputModePhysical => ControllerKeyboardInputMode.physical,
      _ => ControllerKeyboardInputMode.auto,
    };
    // Reserve even an apparent no-op: it may supersede an in-flight change.
    final request = ++_request;
    _read++;
    final needsReset = _value.mode != next || _value.changing || _value.failed;
    if (!needsReset && !persist) return Future<bool>.value(true);
    bool isCurrent() => accepts(epoch) && request == _request;

    Future<bool> apply() async {
      if (!isCurrent()) return false;
      try {
        if (needsReset) await _resetKeyboard();
        if (!isCurrent()) return false;
        if (persist) {
          await _writeMode(
            KeyboardInputModeSnapshot(mode: next).storedMode,
            isCurrent,
          );
        }
        if (!isCurrent()) return false;
        _publish(KeyboardInputModeSnapshot(mode: next));
        return true;
      } catch (_) {
        if (isCurrent()) {
          // Persistence can fail after its primary write. Do not dispatch with
          // an uncertain native preference; a retry/refresh can recover.
          _publish(KeyboardInputModeSnapshot(mode: _value.mode, failed: true));
        }
        rethrow;
      }
    }

    final previous = _tail;
    final completion = Completer<bool>();
    final result = completion.future;
    // Errors reach the requester but must not poison later commands or close.
    late final Future<void> drained;
    drained = result
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() {
          if (identical(_tail, drained)) _tail = null;
        });
    _tail = drained;
    // Reserve the queue before notifying UI observers, which may submit a
    // newer request synchronously. No in-flight write may be lost from idle.
    _publish(KeyboardInputModeSnapshot(mode: _value.mode, changing: true));
    Future<void> run() async {
      try {
        completion.complete(await apply());
      } catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      }
    }

    if (previous == null) {
      unawaited(run());
    } else {
      unawaited(previous.then((_) => run()));
    }
    return result;
  }

  void _publish(KeyboardInputModeSnapshot next) {
    _value = next;
    notifyListeners();
  }
}
