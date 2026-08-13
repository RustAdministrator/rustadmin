import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// One-shot mobile canvas transforms. Selecting a mode applies it once;
/// subsequent gesture zooming and panning remain unconstrained by that mode.
enum MobileRemoteViewScaleMode { fitAll, fitWidth, fitHeight, oneToOne }

extension MobileRemoteViewScaleModeDetails on MobileRemoteViewScaleMode {
  String get value => switch (this) {
    MobileRemoteViewScaleMode.fitAll => 'fit-all',
    MobileRemoteViewScaleMode.fitWidth => 'fit-width',
    MobileRemoteViewScaleMode.fitHeight => 'fit-height',
    MobileRemoteViewScaleMode.oneToOne => 'one-to-one',
  };

  String get label => switch (this) {
    MobileRemoteViewScaleMode.fitAll => 'Fit All',
    MobileRemoteViewScaleMode.fitWidth => 'Fit Width',
    MobileRemoteViewScaleMode.fitHeight => 'Fit Height',
    MobileRemoteViewScaleMode.oneToOne => '1:1',
  };
}

double mobileRemoteScaleForMode({
  required MobileRemoteViewScaleMode mode,
  required Size texture,
  required Size viewport,
  required double devicePixelRatio,
}) {
  if (texture.width <= 0 ||
      texture.height <= 0 ||
      viewport.width <= 0 ||
      viewport.height <= 0) {
    return 1;
  }
  final widthScale = viewport.width / texture.width;
  final heightScale = viewport.height / texture.height;
  return switch (mode) {
    MobileRemoteViewScaleMode.fitAll => math.min(widthScale, heightScale),
    MobileRemoteViewScaleMode.fitWidth => widthScale,
    MobileRemoteViewScaleMode.fitHeight => heightScale,
    MobileRemoteViewScaleMode.oneToOne => 1 / math.max(devicePixelRatio, 1),
  };
}

double mobileRemoteMinimumCanvasScale({
  required Size texture,
  required Size viewport,
}) => mobileRemoteScaleForMode(
  mode: MobileRemoteViewScaleMode.fitAll,
  texture: texture,
  viewport: viewport,
  devicePixelRatio: 1,
);

double mobileRemoteMinimumEdgeScrollScale({
  required Size texture,
  required Size viewport,
  required double edgeThickness,
}) {
  if (texture.width <= 0 ||
      texture.height <= 0 ||
      viewport.width <= 0 ||
      viewport.height <= 0) {
    return 1;
  }
  final margin = math.min(
    math.max(edgeThickness, 0.0),
    math.min(viewport.width, viewport.height) / 2,
  );
  return math.max(
    (viewport.width + margin * 2) / texture.width,
    (viewport.height + margin * 2) / texture.height,
  );
}

FilterQuality mobileRemoteTextureFilterQuality({
  required double logicalScale,
}) => logicalScale < 1 ? FilterQuality.low : FilterQuality.none;

Offset mobileRemoteClampCanvasOffset({
  required Offset proposed,
  required Size texture,
  required Size viewport,
  required double scale,
}) {
  double clampAxis(double value, double textureExtent, double viewportExtent) {
    final contentExtent = textureExtent * scale;
    if (contentExtent <= viewportExtent) {
      return (viewportExtent - contentExtent) / 2;
    }
    return value.clamp(viewportExtent - contentExtent, 0.0).toDouble();
  }

  return Offset(
    clampAxis(proposed.dx, texture.width, viewport.width),
    clampAxis(proposed.dy, texture.height, viewport.height),
  );
}

Offset mobileRemoteTexturePositionFromViewport({
  required Offset viewportPosition,
  required Offset canvasOffset,
  required double scale,
}) {
  if (!scale.isFinite || scale <= 0) {
    return Offset.zero;
  }
  return Offset(
    (viewportPosition.dx - canvasOffset.dx) / scale,
    (viewportPosition.dy - canvasOffset.dy) / scale,
  );
}

Offset mobileRemoteViewportPositionFromTexture({
  required Offset texturePosition,
  required Offset canvasOffset,
  required double scale,
}) => Offset(
  canvasOffset.dx + texturePosition.dx * scale,
  canvasOffset.dy + texturePosition.dy * scale,
);

Offset mobileRemoteCursorAfterCanvasScroll({
  required Offset currentRemotePosition,
  required Offset canvasDelta,
  required double scale,
  required Rect remoteBounds,
  double farEdgeInset = 1,
}) {
  if (!scale.isFinite || scale <= 0 || remoteBounds.isEmpty) {
    return currentRemotePosition;
  }
  final maxX = math.max(remoteBounds.left, remoteBounds.right - farEdgeInset);
  final maxY = math.max(remoteBounds.top, remoteBounds.bottom - farEdgeInset);
  return Offset(
    (currentRemotePosition.dx - canvasDelta.dx / scale)
        .clamp(remoteBounds.left, maxX)
        .toDouble(),
    (currentRemotePosition.dy - canvasDelta.dy / scale)
        .clamp(remoteBounds.top, maxY)
        .toDouble(),
  );
}

double mobileRemoteUsableViewportHeight({
  required double screenHeight,
  required double topInset,
  required double keyboardInset,
  double? keyHelpTop,
}) {
  final safeTop = math.max(topInset, 0.0);
  final keyboardTop = screenHeight - math.max(keyboardInset, 0.0);
  final usableBottom = keyHelpTop == null
      ? keyboardTop
      : math.min(keyHelpTop, keyboardTop);
  return math.max(usableBottom - safeTop, 0.0);
}

double mobileRemoteDeviceEdgeScrollAxisFactor({
  required double pointerPosition,
  required double viewportExtent,
  required double edgeThickness,
}) {
  if (viewportExtent <= 0 || edgeThickness <= 0) {
    return 0;
  }
  final thickness = math.min(edgeThickness, viewportExtent / 2);
  if (pointerPosition < thickness) {
    return -((thickness - pointerPosition) / thickness)
        .clamp(0.0, 1.0)
        .toDouble();
  }
  if (pointerPosition >= viewportExtent - thickness) {
    return ((pointerPosition - (viewportExtent - thickness)) / thickness)
        .clamp(0.0, 1.0)
        .toDouble();
  }
  return 0;
}

const double kMobileRemoteNeutralCursorFraction = 1 / 3;
const double kMobileRemoteAccelerationRampFraction = 2 / 3;

Rect mobileRemoteNeutralCursorRect(Size viewport) {
  if (viewport.width <= 0 || viewport.height <= 0) {
    return Rect.zero;
  }
  return Rect.fromLTRB(
    viewport.width * kMobileRemoteNeutralCursorFraction,
    viewport.height * kMobileRemoteNeutralCursorFraction,
    viewport.width * (1 - kMobileRemoteNeutralCursorFraction),
    viewport.height * (1 - kMobileRemoteNeutralCursorFraction),
  );
}

Offset mobileRemoteClampCursorToNeutralRegion({
  required Offset pointerPosition,
  required Size viewport,
}) {
  final neutralRect = mobileRemoteNeutralCursorRect(viewport);
  if (neutralRect.isEmpty) return pointerPosition;
  return Offset(
    pointerPosition.dx.clamp(neutralRect.left, neutralRect.right).toDouble(),
    pointerPosition.dy.clamp(neutralRect.top, neutralRect.bottom).toDouble(),
  );
}

/// Fixed-speed edge scrolling starts when the local cursor reaches the
/// boundary of the centered neutral third of the viewport.
double mobileRemoteEdgeScrollAxisDirection({
  required double pointerPosition,
  required double viewportExtent,
}) {
  if (viewportExtent <= 0) return 0;
  final neutralStart = viewportExtent * kMobileRemoteNeutralCursorFraction;
  final neutralEnd = viewportExtent * (1 - kMobileRemoteNeutralCursorFraction);
  if (pointerPosition <= neutralStart) return -1;
  if (pointerPosition >= neutralEnd) return 1;
  return 0;
}

/// Acceleration is zero in the centered third. Each outer third is an
/// acceleration band. The factor reaches full speed after two thirds of that
/// band, leaving the final third at the maximum speed near the device edge.
double mobileRemoteEdgeAccelerationAxisFactor({
  required double pointerPosition,
  required double viewportExtent,
}) {
  if (viewportExtent <= 0) return 0;
  final outerBand = viewportExtent * kMobileRemoteNeutralCursorFraction;
  final neutralStart = outerBand;
  final neutralEnd = viewportExtent - outerBand;
  final rampExtent = outerBand * kMobileRemoteAccelerationRampFraction;
  if (rampExtent <= 0) return 0;
  if (pointerPosition < neutralStart) {
    return -((neutralStart - pointerPosition) / rampExtent)
        .clamp(0.0, 1.0)
        .toDouble();
  }
  if (pointerPosition > neutralEnd) {
    return ((pointerPosition - neutralEnd) / rampExtent)
        .clamp(0.0, 1.0)
        .toDouble();
  }
  return 0;
}

/// Returns the per-frame correction that brings an acceleration-mode cursor
/// back to the neutral region exactly as the remaining inertia reaches zero.
Offset mobileRemoteAccelerationReturnDelta({
  required Offset pointerPosition,
  required Size viewport,
  required Duration frameDuration,
  required Duration remainingDuration,
}) {
  if (frameDuration <= Duration.zero || remainingDuration <= Duration.zero) {
    return Offset.zero;
  }
  final target = mobileRemoteClampCursorToNeutralRegion(
    pointerPosition: pointerPosition,
    viewport: viewport,
  );
  final fraction =
      (frameDuration.inMicroseconds / remainingDuration.inMicroseconds)
          .clamp(0.0, 1.0)
          .toDouble();
  return (target - pointerPosition) * fraction;
}
