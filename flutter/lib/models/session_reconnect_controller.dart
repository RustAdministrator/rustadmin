import 'dart:async';

typedef FreshSessionRestart =
    Future<void> Function(bool forceRelay, bool Function() isCurrent);

/// One owner for retry backoff and desktop wake recovery. Native connection
/// attempts and SessionHandle generations remain owned by their existing layers.
class SessionReconnectController {
  SessionReconnectController({
    required this.retry,
    required this.onFailure,
    this.onDiagnostic,
    DateTime Function()? now,
    this.staleThreshold = const Duration(minutes: 5),
  }) : _now = now ?? DateTime.now {
    _lastObserved = _now();
  }

  final void Function(bool forceRelay) retry;
  final void Function(Object error, StackTrace stack) onFailure;
  final void Function(String message)? onDiagnostic;
  final DateTime Function() _now;
  final Duration staleThreshold;
  late DateTime _lastObserved;
  final Zone _ownerZone = Zone.current;
  FreshSessionRestart? _restart;
  Timer? _retryTimer;
  Timer? _clockTimer;
  Future<void>? _restartFuture;
  DateTime? _offlineSince;
  int _retrySeconds = 1;
  int _generation = 0;
  bool _stopped = false;
  bool _needsFresh = false;
  bool _forceRelay = false;

  Duration get nextRetryDelay => Duration(seconds: _retrySeconds);
  bool get isRestarting => _restartFuture != null;

  void sessionStarted() {
    _stopped = false;
    if (!isRestarting) _forceRelay = false;
    _lastObserved = _now();
    resetBackoff();
  }

  void attachFreshRestart(FreshSessionRestart restart) {
    _restart = restart;
    _stopped = false;
    _lastObserved = _now();
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      checkElapsed();
    });
  }

  /// Runs on timer ticks, lifecycle resume, activation and before any retry.
  /// A wall-clock gap includes machine sleep even if a monotonic timer paused.
  bool checkElapsed() {
    if (_stopped || _restart == null) return false;
    final now = _now();
    final elapsed = now.difference(_lastObserved);
    _lastObserved = now;
    if (elapsed >= staleThreshold) {
      onDiagnostic?.call(
        'fresh restart selected after ${elapsed.inSeconds}s clock gap',
      );
      _needsFresh = true;
      requestReconnect();
      return true;
    }
    return false;
  }

  bool shouldRetryOffline() {
    final now = _now();
    _offlineSince ??= now;
    return now.difference(_offlineSince!) < const Duration(seconds: 30);
  }

  void resetBackoff() {
    cancelRetry();
    _retrySeconds = 1;
    _offlineSince = null;
  }

  void cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void scheduleRetry() {
    if (_stopped) return;
    cancelRetry();
    final generation = _generation;
    _retryTimer = Timer(nextRetryDelay, () {
      _retryTimer = null;
      if (_stopped || generation != _generation) return;
      requestReconnect();
    });
    _retrySeconds = (_retrySeconds * 2).clamp(1, 30);
  }

  void requestReconnect({bool forceRelay = false}) {
    if (_stopped) return;
    _forceRelay = _forceRelay || forceRelay;
    cancelRetry();
    if (isRestarting) return;
    if (checkElapsed()) return;
    if (!_needsFresh || _restart == null) {
      onDiagnostic?.call('normal reconnect requested; forceRelay=$_forceRelay');
      retry(_forceRelay);
      return;
    }
    final restart = _restart!;
    final generation = ++_generation;
    resetBackoff();
    // Enter from the owning zone, never from a SessionHandle event callback
    // whose completion teardown itself must await.
    final completion = Completer<void>();
    _restartFuture = completion.future;
    _ownerZone.run(() {
      unawaited(
        Future<void>(() async {
          bool isCurrent() => !_stopped && generation == _generation;
          try {
            if (!isCurrent()) return;
            await restart(_forceRelay, isCurrent);
            if (isCurrent()) {
              _needsFresh = false;
              onDiagnostic?.call(
                'fresh session started and event stream attached',
              );
            }
          } catch (error, stack) {
            if (isCurrent()) onFailure(error, stack);
          } finally {
            if (identical(_restartFuture, completion.future)) {
              _restartFuture = null;
            }
            completion.complete();
          }
        }),
      );
    });
  }

  void stop() {
    _stopped = true;
    _generation++;
    cancelRetry();
    _clockTimer?.cancel();
    _clockTimer = null;
  }
}
