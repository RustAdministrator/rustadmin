import 'dart:async';

import 'package:flutter_hbb/models/session_lifecycle.dart';
import 'package:uuid/uuid.dart';

final _sessionEventZoneKey = Object();

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
  Future<void>? _remoteCloseFuture;
  Future<void>? _eventCloseFuture;
  Future<void> _eventTail = Future<void>.value();
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

  Future<void> waitForClose() async {
    final eventClose = _eventCloseFuture;
    if (eventClose != null) await eventClose;
    final remoteClose = _remoteCloseFuture;
    if (remoteClose != null) await remoteClose;
    final close = _closeFuture;
    if (close != null) await close;
  }

  Future<bool> prepareForReplacement({
    Future<void> Function()? cleanupClosedSession,
  }) async {
    await waitForClose();
    if (!canBeReplaced && isClosed && cleanupClosedSession != null) {
      await close(
        nativeClosePolicy: NativeSessionClosePolicy.alreadyClosed,
        cleanup: cleanupClosedSession,
      );
    }
    return canBeReplaced;
  }

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

  Future<void> bindEventStream(
    SessionStartLease<T> lease, {
    required bool Function(T event) isCloseEvent,
    required Future<void> Function(T event) onEvent,
    required void Function(Object error, StackTrace stackTrace) onError,
  }) async {
    var ended = false;
    void finish() {
      if (ended) return;
      ended = true;
      unawaited(remoteClosedAfterEvents(lease.generation).catchError(onError));
    }

    final subscription = lease.events.listen(
      (event) {
        if (ended || !accepts(lease.generation)) return;
        if (isCloseEvent(event)) {
          finish();
        } else {
          unawaited(
            dispatchEvent(
              lease.generation,
              () => onEvent(event),
              onError: onError,
            ),
          );
        }
      },
      onDone: finish,
      onError: onError,
    );
    await bindSubscription(lease.generation, subscription);
  }

  Future<void> dispatchEvent(
    int generation,
    Future<void> Function() dispatch, {
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    _eventTail = _eventTail.then((_) async {
      if (!accepts(generation)) return;
      try {
        await runZoned(dispatch, zoneValues: {_sessionEventZoneKey: this});
      } catch (error, stackTrace) {
        onError?.call(error, stackTrace);
      }
    });
    return _eventTail;
  }

  Future<void> remoteClosedAfterEvents(int generation) {
    final active = _eventCloseFuture;
    if (active != null) return active;
    if (!accepts(generation)) return Future<void>.value();
    late final Future<void> future;
    future = dispatchEvent(generation, () async {})
        .then((_) => remoteClosed(generation))
        .whenComplete(() {
          if (identical(_eventCloseFuture, future)) _eventCloseFuture = null;
        });
    _eventCloseFuture = future;
    return future;
  }

  Future<void> remoteClosed(int generation) {
    final active = _remoteCloseFuture;
    if (active != null) return active;
    if (!accepts(generation)) return Future<void>.value();
    _nativeSessionActive = false;
    _lifecycle.closed(generation);
    late final Future<void> future;
    future = _finishRemoteClose().whenComplete(() {
      if (identical(_remoteCloseFuture, future)) _remoteCloseFuture = null;
    });
    _remoteCloseFuture = future;
    return future;
  }

  Future<void> _finishRemoteClose() async {
    try {
      await _cancelSubscription();
    } finally {
      try {
        await _eventTail;
      } finally {
        await _releasePlatformLeaseOnce();
      }
    }
  }

  Future<void> close({
    required NativeSessionClosePolicy nativeClosePolicy,
    required Future<void> Function() cleanup,
  }) {
    final insideEventDispatch = identical(
      Zone.current[_sessionEventZoneKey],
      this,
    );
    final active = _closeFuture;
    if (active != null) {
      return insideEventDispatch ? Future<void>.value() : active;
    }
    if (isClosed &&
        !_nativeSessionActive &&
        _subscription == null &&
        _platformLeaseGeneration == null &&
        _cleanupFinished) {
      return Future<void>.value();
    }
    final closeGeneration = _lifecycle.beginClose();
    if (insideEventDispatch) {
      final completion = Completer<void>();
      final future = completion.future;
      _closeFuture = future;
      unawaited(future.catchError((_) {}));
      scheduleMicrotask(() async {
        try {
          await _close(
            closeGeneration: closeGeneration,
            nativeClosePolicy: nativeClosePolicy,
            cleanup: cleanup,
          );
          completion.complete();
        } catch (error, stackTrace) {
          completion.completeError(error, stackTrace);
        } finally {
          if (identical(_closeFuture, future)) _closeFuture = null;
        }
      });
      return Future<void>.value();
    }
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
      final remoteClose = _remoteCloseFuture;
      if (remoteClose != null) {
        await remoteClose;
      }
      try {
        await _cancelSubscription();
      } finally {
        try {
          await _eventTail;
        } finally {
          try {
            await cleanup();
          } finally {
            _cleanupFinished = true;
          }
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
