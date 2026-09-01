import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../mobile/mobile_viewport.dart';

enum MobileTwoFingerMotionKind {
  pending,
  viewportZoom,
  remoteWheel,
  viewportPan,
}

class MobileTwoFingerMotionUpdate {
  const MobileTwoFingerMotionUpdate({
    required this.kind,
    required this.focalPoint,
    required this.localFocalPoint,
    required this.focalPointDelta,
    required this.scaleDelta,
  });

  final MobileTwoFingerMotionKind kind;
  final Offset focalPoint;
  final Offset localFocalPoint;
  final Offset focalPointDelta;
  final double scaleDelta;
}

/// Classifies a two-finger motion once, then keeps that ownership until every
/// finger is released. This prevents a remote wheel gesture from turning into
/// viewport zoom or cursor motion halfway through the same gesture.
class MobileTwoFingerMotionController {
  MobileTwoFingerMotionController({
    this.scaleThreshold = 0.035,
    this.translationThreshold = 8,
    this.verticalDominanceRatio = 1.25,
  });

  final double scaleThreshold;
  final double translationThreshold;
  final double verticalDominanceRatio;

  MobileTwoFingerMotionKind _kind = MobileTwoFingerMotionKind.pending;
  Offset _startFocalPoint = Offset.zero;
  Offset _lastFocalPoint = Offset.zero;
  double _initialScale = 1;
  double _lastNormalizedScale = 1;
  int _scaleCandidateDirection = 0;
  int _scaleCandidateUpdates = 0;
  bool _started = false;

  MobileTwoFingerMotionKind get kind => _kind;

  void start({required double scale, required Offset focalPoint}) {
    _kind = MobileTwoFingerMotionKind.pending;
    _startFocalPoint = focalPoint;
    _lastFocalPoint = focalPoint;
    _initialScale = scale.isFinite && scale > 0 ? scale : 1;
    _lastNormalizedScale = 1;
    _scaleCandidateDirection = 0;
    _scaleCandidateUpdates = 0;
    _started = true;
  }

  MobileTwoFingerMotionUpdate update({
    required double scale,
    required Offset focalPoint,
    required Offset localFocalPoint,
    required bool enableRemoteWheel,
  }) {
    if (!_started) {
      start(scale: scale, focalPoint: focalPoint);
    }

    final normalizedScale = scale.isFinite && scale > 0
        ? scale / _initialScale
        : _lastNormalizedScale;
    final totalTranslation = focalPoint - _startFocalPoint;
    final previousKind = _kind;

    if (_kind == MobileTwoFingerMotionKind.pending) {
      final scaleDistance = (normalizedScale - 1).abs();
      if (scaleDistance >= scaleThreshold) {
        final direction = normalizedScale > 1 ? 1 : -1;
        if (_scaleCandidateDirection == direction) {
          _scaleCandidateUpdates += 1;
        } else {
          _scaleCandidateDirection = direction;
          _scaleCandidateUpdates = 1;
        }
      } else {
        _scaleCandidateDirection = 0;
        _scaleCandidateUpdates = 0;
      }
      // Pointer move events arrive one finger at a time. Requiring two
      // consistent scale samples avoids mistaking the temporary span change
      // from a parallel two-finger scroll for a pinch.
      if (_scaleCandidateUpdates >= 2) {
        _kind = MobileTwoFingerMotionKind.viewportZoom;
      } else if (scaleDistance < scaleThreshold &&
          totalTranslation.distance >= translationThreshold) {
        final horizontal = totalTranslation.dx.abs();
        final vertical = totalTranslation.dy.abs();
        if (enableRemoteWheel &&
            vertical >= horizontal * verticalDominanceRatio) {
          _kind = MobileTwoFingerMotionKind.remoteWheel;
        } else {
          _kind = MobileTwoFingerMotionKind.viewportPan;
        }
      }
    }

    final wasJustCommitted =
        previousKind == MobileTwoFingerMotionKind.pending &&
        _kind != MobileTwoFingerMotionKind.pending;
    final delta = wasJustCommitted
        ? switch (_kind) {
            MobileTwoFingerMotionKind.remoteWheel ||
            MobileTwoFingerMotionKind.viewportPan => totalTranslation,
            _ => Offset.zero,
          }
        : focalPoint - _lastFocalPoint;
    final scaleDelta = _kind == MobileTwoFingerMotionKind.viewportZoom
        ? wasJustCommitted
              ? normalizedScale
              : normalizedScale / math.max(_lastNormalizedScale, 0.000001)
        : 1.0;

    _lastFocalPoint = focalPoint;
    _lastNormalizedScale = normalizedScale;

    return MobileTwoFingerMotionUpdate(
      kind: _kind,
      focalPoint: focalPoint,
      localFocalPoint: localFocalPoint,
      focalPointDelta: delta,
      scaleDelta: scaleDelta,
    );
  }

  void reset() {
    _kind = MobileTwoFingerMotionKind.pending;
    _started = false;
    _lastNormalizedScale = 1;
    _scaleCandidateDirection = 0;
    _scaleCandidateUpdates = 0;
  }
}

/// Converts continuous finger translation into discrete remote wheel steps
/// while preserving fractional motion between updates.
class MobileWheelAccumulator {
  MobileWheelAccumulator({this.logicalPixelsPerStep = 8});

  final double logicalPixelsPerStep;
  double _remainder = 0;

  int add(double logicalPixelDelta) {
    if (!logicalPixelDelta.isFinite || logicalPixelsPerStep <= 0) return 0;
    _remainder += logicalPixelDelta / logicalPixelsPerStep;
    final steps = _remainder.truncate();
    _remainder -= steps;
    return steps;
  }

  void reset() => _remainder = 0;
}

class MobileCursorInertiaFrame {
  const MobileCursorInertiaFrame({
    required this.delta,
    required this.localPosition,
    required this.frameDuration,
    required this.remainingDuration,
  });

  final Offset delta;
  final Offset localPosition;
  final Duration frameDuration;
  final Duration remainingDuration;
}

typedef MobileCursorInertiaFrameHandler =
    Future<Offset> Function(MobileCursorInertiaFrame frame);

class MobileCursorInertiaController {
  MobileCursorInertiaController({
    required this.onFrame,
    required this.onStopped,
    this.onError,
    this.elapsedNow,
    this.tickInterval = const Duration(milliseconds: 16),
  });

  final MobileCursorInertiaFrameHandler onFrame;
  final VoidCallback onStopped;
  final void Function(Object error, StackTrace stackTrace)? onError;
  final Duration Function()? elapsedNow;
  final Duration tickInterval;

  Timer? _timer;
  Stopwatch? _stopwatch;
  Duration _previousElapsed = Duration.zero;
  Offset _velocity = Offset.zero;
  Offset _localPosition = Offset.zero;
  bool _tickPending = false;
  int _generation = 0;
  Duration _duration = Duration.zero;

  bool get active => _timer != null;

  bool start({
    required Duration duration,
    required Offset velocity,
    required Offset localPosition,
  }) {
    stop(notify: false);
    if (duration <= Duration.zero || velocity.distance < 50) return false;
    const maximumVelocity = 3000.0;
    _velocity = velocity.distance > maximumVelocity
        ? velocity / velocity.distance * maximumVelocity
        : velocity;
    _localPosition = localPosition;
    _duration = duration;
    _previousElapsed = Duration.zero;
    _stopwatch = elapsedNow == null ? (Stopwatch()..start()) : null;
    final generation = _generation;
    _timer = Timer.periodic(tickInterval, (_) => unawaited(_tick(generation)));
    return true;
  }

  void stop({bool notify = true}) {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _stopwatch?.stop();
    _stopwatch = null;
    _previousElapsed = Duration.zero;
    _tickPending = false;
    if (notify) onStopped();
  }

  void dispose() => stop();

  Future<void> _tick(int generation) async {
    if (generation != _generation || _tickPending) return;
    final elapsed = elapsedNow?.call() ?? _stopwatch?.elapsed;
    if (elapsed == null) return;
    final remaining = _duration - _previousElapsed;
    if (remaining <= Duration.zero) {
      stop();
      return;
    }
    final frameDuration = elapsed >= _duration
        ? remaining
        : elapsed - _previousElapsed;
    final delta = mobileCursorInertiaFrameDelta(
      velocityPixelsPerSecond: _velocity,
      elapsedBeforeFrame: _previousElapsed,
      frameDuration: frameDuration,
      totalDuration: _duration,
    );
    _previousElapsed = elapsed;
    if (delta == Offset.zero) {
      stop();
      return;
    }
    _tickPending = true;
    try {
      _localPosition += delta;
      final adjustment = await onFrame(
        MobileCursorInertiaFrame(
          delta: delta,
          localPosition: _localPosition,
          frameDuration: frameDuration,
          remainingDuration: remaining,
        ),
      );
      if (generation == _generation) _localPosition += adjustment;
    } catch (error, stackTrace) {
      stop();
      onError?.call(error, stackTrace);
      return;
    } finally {
      if (generation == _generation) _tickPending = false;
    }
    if (generation == _generation && elapsed >= _duration) stop();
  }
}

/// Serializes one remote button lifetime. Cancellation invalidates a pending
/// request, while a release queued during an in-flight down waits and emits one
/// matching up.
class MobileButtonSequenceController {
  var _generation = 0;
  int? _request;
  var _pressed = false;
  Future<void> _tail = Future<void>.value();

  bool get hasIntent => _request != null || _pressed;
  bool get isPressed => _pressed;
  Future<void> get settled => _tail;

  int beginRequest() {
    final token = ++_generation;
    _request = token;
    return token;
  }

  bool isRequested(int token) => _request == token;

  void cancelRequest(int token) {
    if (_request == token) {
      _request = null;
      _generation += 1;
    }
  }

  Future<void> activate(int token, Future<void> Function() sendDown) =>
      _enqueue(() async {
        if (_request != token || _pressed) return;
        await sendDown();
        _pressed = true;
      });

  Future<void> release(Future<void> Function() sendUp) {
    _request = null;
    _generation += 1;
    return _enqueue(() async {
      if (!_pressed) return;
      await sendUp();
      _pressed = false;
    });
  }

  Future<void> _enqueue(Future<void> Function() command) {
    final result = _tail.then((_) => command());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
