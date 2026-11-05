import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Foreground text adapter for iOS, whose Rust core cannot observe UIPasteboard.
/// All network sends still pass the session's native clipboard permission gate.
class ForegroundClipboardSync {
  ForegroundClipboardSync({
    Future<String?> Function()? readText,
    Future<void> Function(String)? writeText,
    this.interval = const Duration(seconds: 1),
  }) : _readText = readText ?? _readSystemText,
       _writeText = writeText ?? _writeSystemText;

  static final instance = ForegroundClipboardSync();
  static const maxTextBytes = 4 * 1024 * 1024;
  final Future<String?> Function() _readText;
  final Future<void> Function(String) _writeText;
  final Duration interval;
  final _targets = <Object, _ClipboardTarget>{};
  Timer? _timer;
  bool _foreground = true;
  bool _reading = false;
  int _generation = 0;
  int _pendingWrites = 0;
  String? _remoteText;
  Future<void> _writeQueue = Future.value();

  static Future<String?> _readSystemText() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return const MethodChannel(
        'rustadmin/clipboard',
      ).invokeMethod<String>('readText');
    }
    return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  }

  static Future<void> _writeSystemText(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  void attach(
    Object token, {
    required bool Function() canSend,
    required bool Function(String) send,
  }) {
    _targets[token] = _ClipboardTarget(canSend, send);
    _schedule();
  }

  void detach(Object token) {
    _targets.remove(token);
    if (_targets.isEmpty) {
      _generation++;
      _reading = false;
    }
    _schedule();
  }

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _generation++;
    _reading = false;
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (_foreground && _targets.isNotEmpty) {
      _timer = Timer.periodic(interval, (_) => unawaited(poll()));
    }
  }

  Future<void> poll() async {
    if (!_foreground ||
        _reading ||
        _pendingWrites != 0 ||
        !_targets.values.any((target) => target.canSend())) {
      return;
    }
    final generation = _generation;
    _reading = true;
    try {
      final text = await _readText();
      if (generation != _generation ||
          !_foreground ||
          text == null ||
          text.isEmpty ||
          text.length > maxTextBytes ||
          utf8.encode(text).length > maxTextBytes) {
        return;
      }
      if (text == _remoteText) return;
      _remoteText = null;
      for (final target in _targets.values.toList()) {
        if (generation != _generation || !_foreground) break;
        if (target.canSend() && target.lastSent != text && target.send(text)) {
          target.lastSent = text;
        }
      }
    } catch (_) {
      // A denied/unavailable clipboard must not clear either endpoint or log text.
    } finally {
      if (generation == _generation) _reading = false;
    }
  }

  Future<void> applyRemoteText(String text) async {
    _generation++;
    _reading = false;
    _pendingWrites++;
    _remoteText = text;
    for (final target in _targets.values) {
      target.lastSent = text;
    }
    final write = _writeQueue.then((_) => _writeText(text));
    // Serialize OS writes, while allowing recovery after an individual failure.
    _writeQueue = write.then<void>((_) {}, onError: (Object _) {});
    try {
      await write;
    } catch (_) {
      // Leave the existing clipboard untouched if the OS rejects this update.
    } finally {
      _pendingWrites--;
    }
  }
}

class _ClipboardTarget {
  _ClipboardTarget(this.canSend, this.send);
  final bool Function() canSend;
  final bool Function(String) send;
  String? lastSent;
}
