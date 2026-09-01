import 'dart:async';

enum MobileSessionReconnectPhase {
  active,
  backgroundClosing,
  pending,
  reconnecting,
  disconnecting,
  disposed,
}

typedef ResetMobileSession =
    Future<void> Function({required bool closeSession});

class MobileSessionReconnectController {
  static const recoverableCloseReasons = {
    'background-timeout',
    'background-native-disconnect',
    'foreground-unhealthy',
    'foreground-service-timeout',
  };

  final ResetMobileSession _resetSession;
  final Future<void> Function() _prepareReconnect;
  final Future<void> Function() _connect;
  final void Function() _onReconnectStarted;
  final void Function(Object error, StackTrace stackTrace) _onReconnectFailed;
  final void Function() _onNotificationDisconnect;

  MobileSessionReconnectPhase _phase = MobileSessionReconnectPhase.active;
  Future<void>? _backgroundCloseFuture;
  AsyncError? _backgroundCloseFailure;
  Future<void>? _reconnectFuture;
  bool _foreground = true;
  bool _pending = false;
  int _epoch = 0;

  MobileSessionReconnectController({
    required ResetMobileSession resetSession,
    required Future<void> Function() prepareReconnect,
    required Future<void> Function() connect,
    required void Function() onReconnectStarted,
    required void Function(Object error, StackTrace stackTrace)
    onReconnectFailed,
    required void Function() onNotificationDisconnect,
  }) : _resetSession = resetSession,
       _prepareReconnect = prepareReconnect,
       _connect = connect,
       _onReconnectStarted = onReconnectStarted,
       _onReconnectFailed = onReconnectFailed,
       _onNotificationDisconnect = onNotificationDisconnect;

  MobileSessionReconnectPhase get phase => _phase;
  bool get reconnectPending => _pending;
  bool get reconnectInProgress => _reconnectFuture != null;

  void handleSessionClosed(String reason, {required bool isForeground}) {
    if (_isTerminal) return;
    _foreground = isForeground;
    if (reason == 'notification-disconnect') {
      _epoch++;
      _pending = false;
      _phase = MobileSessionReconnectPhase.disconnecting;
      _onNotificationDisconnect();
      return;
    }
    if (!recoverableCloseReasons.contains(reason)) return;

    _epoch++;
    _pending = true;
    if (_backgroundCloseFuture == null) {
      _phase = MobileSessionReconnectPhase.pending;
    }
    if (_foreground) {
      unawaited(_ensureReconnect());
    }
  }

  Future<void> enterForeground() {
    if (_isTerminal) return Future<void>.value();
    _foreground = true;
    return _ensureReconnect();
  }

  Future<void> enterBackground({
    required bool closeSession,
    required bool sessionClosed,
  }) {
    if (_isTerminal) return Future<void>.value();
    _foreground = false;
    if (!closeSession || (sessionClosed && _reconnectFuture == null)) {
      return Future<void>.value();
    }
    final activeClose = _backgroundCloseFuture;
    if (activeClose != null || _pending) {
      return activeClose ?? Future<void>.value();
    }

    _epoch++;
    _pending = true;
    _phase = MobileSessionReconnectPhase.backgroundClosing;
    _backgroundCloseFailure = null;
    late final Future<void> closeFuture;
    closeFuture = _captureBackgroundClose().whenComplete(() {
      if (identical(_backgroundCloseFuture, closeFuture)) {
        _backgroundCloseFuture = null;
      }
      if (!_isTerminal && !_foreground) {
        _phase = MobileSessionReconnectPhase.pending;
      }
    });
    _backgroundCloseFuture = closeFuture;
    return closeFuture;
  }

  void dispose() {
    if (_phase == MobileSessionReconnectPhase.disposed) return;
    _epoch++;
    _pending = false;
    _phase = MobileSessionReconnectPhase.disposed;
  }

  bool get _isTerminal =>
      _phase == MobileSessionReconnectPhase.disconnecting ||
      _phase == MobileSessionReconnectPhase.disposed;

  Future<void> _captureBackgroundClose() async {
    try {
      await _resetSession(closeSession: true);
    } catch (error, stackTrace) {
      _backgroundCloseFailure = AsyncError(error, stackTrace);
    }
  }

  Future<void> _ensureReconnect() {
    if (_isTerminal || !_foreground || !_pending) {
      return Future<void>.value();
    }
    final active = _reconnectFuture;
    if (active != null) return active;

    late final Future<void> reconnectFuture;
    reconnectFuture = _runReconnects().whenComplete(() {
      if (identical(_reconnectFuture, reconnectFuture)) {
        _reconnectFuture = null;
      }
      if (!_isTerminal && _foreground && _pending) {
        unawaited(_ensureReconnect());
      }
    });
    _reconnectFuture = reconnectFuture;
    return reconnectFuture;
  }

  Future<void> _runReconnects() async {
    while (!_isTerminal && _foreground && _pending) {
      _pending = false;
      final epoch = _epoch;
      _phase = MobileSessionReconnectPhase.reconnecting;
      try {
        _onReconnectStarted();
        final backgroundClose = _backgroundCloseFuture;
        if (backgroundClose != null) await backgroundClose;
        if (!_accepts(epoch)) continue;

        final closeFailure = _backgroundCloseFailure;
        _backgroundCloseFailure = null;
        if (closeFailure != null) {
          Error.throwWithStackTrace(
            closeFailure.error,
            closeFailure.stackTrace,
          );
        }

        await _resetSession(closeSession: false);
        if (!_accepts(epoch)) continue;
        await _prepareReconnect();
        if (!_accepts(epoch)) continue;
        await _connect();
        if (!_accepts(epoch)) continue;
        _phase = MobileSessionReconnectPhase.active;
      } catch (error, stackTrace) {
        if (!_accepts(epoch)) continue;
        _phase = MobileSessionReconnectPhase.disconnecting;
        _onReconnectFailed(error, stackTrace);
        return;
      }
    }
  }

  bool _accepts(int epoch) => !_isTerminal && _foreground && epoch == _epoch;
}
