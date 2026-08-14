import 'dart:math' as math;

import 'package:flutter/widgets.dart';

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
