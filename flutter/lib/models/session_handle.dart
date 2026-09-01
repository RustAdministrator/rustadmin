import 'dart:async';

import 'package:flutter_hbb/models/session_lifecycle.dart';
import 'package:uuid/uuid.dart';

enum SessionKind {
  remoteDesktop,
  fileTransfer,
  viewCamera,
  portForward,
  rdp,
  terminal;

  factory SessionKind.fromLegacyFlags({
    required bool isFileTransfer,
    required bool isViewCamera,
    required bool isPortForward,
    required bool isRdp,
    required bool isTerminal,
  }) {
    assert(
      !(isPortForward && isViewCamera) &&
          !(isPortForward && isFileTransfer) &&
          !(isTerminal && isFileTransfer) &&
          !(isTerminal && isViewCamera) &&
          !(isTerminal && isPortForward),
      'more than one connect type',
    );
    if (isFileTransfer) return SessionKind.fileTransfer;
    if (isViewCamera) return SessionKind.viewCamera;
    if (isTerminal) return SessionKind.terminal;
    if (isPortForward) {
      return isRdp ? SessionKind.rdp : SessionKind.portForward;
    }
    return SessionKind.remoteDesktop;
  }
}

enum NativeSessionClosePolicy { requestClose, alreadyClosed }

class SessionStartLease<T> {
  final int generation;
  final Stream<T> events;

  const SessionStartLease(this.generation, this.events);
}

class SessionHandle<T> {
  final UuidValue sessionId;
  final Future<void> Function() _closeNative;
  final Future<void> Function(int? generation)? _releasePlatformLease;
  final SessionLifecycle _lifecycle = SessionLifecycle();

  Future<SessionStartLease<T>?>? _startFuture;
  Future<void>? _closeFuture;
  StreamSubscription<T>? _subscription;
  int? _platformLeaseGeneration;
  bool _startRequested = false;
  bool _nativeSessionActive = false;
  bool _cleanupFinished = false;

  SessionHandle({
    required this.sessionId,
    required Future<void> Function() closeNative,
    Future<void> Function(int? generation)? releasePlatformLease,
  }) : _closeNative = closeNative,
       _releasePlatformLease = releasePlatformLease;

  SessionPhase get phase => _lifecycle.phase;
  bool get isClosed => _lifecycle.isClosed;
  bool get isPristine => !_startRequested && phase == SessionPhase.created;
  bool get canBeReplaced => isClosed && _cleanupFinished;
  bool accepts(int generation) => _lifecycle.accepts(generation);

  Future<void> waitForClose() => _closeFuture ?? Future<void>.value();

  Future<SessionStartLease<T>?> start({
    required Future<void> Function() addNative,
    required Stream<T> Function() startEvents,
    Future<void> Function()? prepareEvents,
    Future<int?> Function()? acquirePlatformLease,
  }) {
    if (_startRequested) {
      throw StateError('SessionHandle is single-use');
    }
    _startRequested = true;
    final generation = _lifecycle.beginStart();
    late final Future<SessionStartLease<T>?> future;
    future =
        _start(
          generation: generation,
          addNative: addNative,
          startEvents: startEvents,
          prepareEvents: prepareEvents,
          acquirePlatformLease: acquirePlatformLease,
        ).whenComplete(() {
          if (identical(_startFuture, future)) {
            _startFuture = null;
          }
        });
    _startFuture = future;
    return future;
  }

  Future<SessionStartLease<T>?> _start({
    required int generation,
    required Future<void> Function() addNative,
    required Stream<T> Function() startEvents,
    Future<void> Function()? prepareEvents,
    Future<int?> Function()? acquirePlatformLease,
  }) async {
    try {
      if (acquirePlatformLease != null) {
        _platformLeaseGeneration = await acquirePlatformLease();
        if (!accepts(generation)) {
          await _releasePlatformLeaseOnce();
          return null;
        }
      }
      await addNative();
      _nativeSessionActive = true;
      if (!accepts(generation)) {
        await _rollbackStartResources();
        return null;
      }
      await prepareEvents?.call();
      if (!accepts(generation)) {
        await _rollbackStartResources();
        return null;
      }
      return SessionStartLease(generation, startEvents());
    } catch (_) {
      try {
        await _rollbackStartResources();
      } finally {
        _lifecycle.failed(generation);
      }
      rethrow;
    }
  }

  Future<void> bindSubscription(
    int generation,
    StreamSubscription<T> subscription,
  ) async {
    if (!accepts(generation) || _subscription != null) {
      await subscription.cancel();
      if (_subscription != null) {
        throw StateError('SessionHandle already owns an event subscription');
      }
      return;
    }
    _subscription = subscription;
  }

  void connected(int generation) => _lifecycle.connected(generation);

  Future<void> remoteClosed(int generation) async {
    if (!accepts(generation)) return;
    _nativeSessionActive = false;
    _lifecycle.closed(generation);
    try {
      await _cancelSubscription();
    } finally {
      await _releasePlatformLeaseOnce();
    }
  }

  Future<void> close({
    required NativeSessionClosePolicy nativeClosePolicy,
    required Future<void> Function() cleanup,
  }) {
    final active = _closeFuture;
    if (active != null) return active;
    if (isClosed &&
        !_nativeSessionActive &&
        _subscription == null &&
        _platformLeaseGeneration == null &&
        _cleanupFinished) {
      return Future<void>.value();
    }
    final closeGeneration = _lifecycle.beginClose();
    late final Future<void> future;
    future =
        _close(
          closeGeneration: closeGeneration,
          nativeClosePolicy: nativeClosePolicy,
          cleanup: cleanup,
        ).whenComplete(() {
          if (identical(_closeFuture, future)) {
            _closeFuture = null;
          }
        });
    _closeFuture = future;
    return future;
  }

  Future<void> _close({
    required int closeGeneration,
    required NativeSessionClosePolicy nativeClosePolicy,
    required Future<void> Function() cleanup,
  }) async {
    try {
      try {
        final start = _startFuture;
        if (start != null) {
          await start;
        }
      } catch (_) {
        // start() reports its own failure; close still has to finish cleanup.
      }
      try {
        await _cancelSubscription();
      } finally {
        try {
          await cleanup();
        } finally {
          _cleanupFinished = true;
        }
      }
    } finally {
      try {
        if (nativeClosePolicy == NativeSessionClosePolicy.requestClose) {
          await _closeNativeOnce();
        } else {
          _nativeSessionActive = false;
        }
      } finally {
        try {
          await _releasePlatformLeaseOnce();
        } finally {
          _lifecycle.closed(closeGeneration);
        }
      }
    }
  }

  Future<void> _cancelSubscription() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  Future<void> _closeNativeOnce() async {
    if (!_nativeSessionActive) return;
    _nativeSessionActive = false;
    await _closeNative();
  }

  Future<void> _rollbackStartResources() async {
    try {
      await _closeNativeOnce();
    } finally {
      await _releasePlatformLeaseOnce();
    }
  }

  Future<void> _releasePlatformLeaseOnce() async {
    final generation = _platformLeaseGeneration;
    _platformLeaseGeneration = null;
    if (generation != null) {
      await _releasePlatformLease?.call(generation);
    }
  }
}
