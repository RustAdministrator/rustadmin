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

const double kMobileRemoteAccelerationRampFraction = 2 / 3;

class MobileRemoteScrollDirections {
  const MobileRemoteScrollDirections({
    required this.left,
    required this.right,
    required this.up,
    required this.down,
  });

  static const all = MobileRemoteScrollDirections(
    left: true,
    right: true,
    up: true,
    down: true,
  );

  final bool left;
  final bool right;
  final bool up;
  final bool down;
}

MobileRemoteScrollDirections mobileRemoteScrollDirections({
  required Offset canvasOffset,
  required Size texture,
  required Size viewport,
  required double scale,
  double epsilon = 0.01,
}) {
  final contentWidth = texture.width * scale;
  final contentHeight = texture.height * scale;
  final minimumX = viewport.width - contentWidth;
  final minimumY = viewport.height - contentHeight;
  return MobileRemoteScrollDirections(
    left: contentWidth > viewport.width && canvasOffset.dx < -epsilon,
    right:
        contentWidth > viewport.width && canvasOffset.dx > minimumX + epsilon,
    up: contentHeight > viewport.height && canvasOffset.dy < -epsilon,
    down:
        contentHeight > viewport.height && canvasOffset.dy > minimumY + epsilon,
  );
}

double _mobileRemoteAxisEdgeThickness(
  double viewportExtent,
  double edgeThickness,
) {
  const minimumNeutralExtent = 1.0;
  final maximumThickness = math.max(
    (viewportExtent - minimumNeutralExtent) / 2,
    0.0,
  );
  return math.min(math.max(edgeThickness, 0), maximumThickness);
}

Rect mobileRemoteNeutralCursorRect({
  required Size viewport,
  required double edgeThickness,
  MobileRemoteScrollDirections directions = MobileRemoteScrollDirections.all,
}) {
  if (viewport.width <= 0 || viewport.height <= 0) {
    return Rect.zero;
  }
  final horizontalThickness = _mobileRemoteAxisEdgeThickness(
    viewport.width,
    edgeThickness,
  );
  final verticalThickness = _mobileRemoteAxisEdgeThickness(
    viewport.height,
    edgeThickness,
  );
  return Rect.fromLTRB(
    directions.left ? horizontalThickness : 0,
    directions.up ? verticalThickness : 0,
    directions.right ? viewport.width - horizontalThickness : viewport.width,
    directions.down ? viewport.height - verticalThickness : viewport.height,
  );
}

Offset mobileRemoteClampCursorToNeutralRegion({
  required Offset pointerPosition,
  required Size viewport,
  required double edgeThickness,
  MobileRemoteScrollDirections directions = MobileRemoteScrollDirections.all,
}) {
  if (viewport.width <= 0 || viewport.height <= 0) return pointerPosition;
  final neutralRect = mobileRemoteNeutralCursorRect(
    viewport: viewport,
    edgeThickness: edgeThickness,
    directions: directions,
  );
  return Offset(
    pointerPosition.dx.clamp(neutralRect.left, neutralRect.right).toDouble(),
    pointerPosition.dy.clamp(neutralRect.top, neutralRect.bottom).toDouble(),
  );
}

/// Fixed-speed edge scrolling starts when the local cursor enters a configured
/// edge band whose direction still has remote canvas available to scroll.
double mobileRemoteEdgeScrollAxisDirection({
  required double pointerPosition,
  required double viewportExtent,
  required double edgeThickness,
  required bool canScrollTowardStart,
  required bool canScrollTowardEnd,
}) {
  if (viewportExtent <= 0) return 0;
  final thickness = _mobileRemoteAxisEdgeThickness(
    viewportExtent,
    edgeThickness,
  );
  if (canScrollTowardStart && pointerPosition <= thickness) return -1;
  if (canScrollTowardEnd && pointerPosition >= viewportExtent - thickness) {
    return 1;
  }
  return 0;
}

/// Acceleration is zero outside the configured edge bands. The factor reaches
/// full speed after two thirds of a band, leaving its final third at maximum
/// speed near the device edge.
double mobileRemoteEdgeAccelerationAxisFactor({
  required double pointerPosition,
  required double viewportExtent,
  required double edgeThickness,
  required bool canScrollTowardStart,
  required bool canScrollTowardEnd,
}) {
  if (viewportExtent <= 0) return 0;
  final outerBand = _mobileRemoteAxisEdgeThickness(
    viewportExtent,
    edgeThickness,
  );
  final neutralStart = outerBand;
  final neutralEnd = viewportExtent - outerBand;
  final rampExtent = outerBand * kMobileRemoteAccelerationRampFraction;
  if (rampExtent <= 0) return 0;
  if (canScrollTowardStart && pointerPosition < neutralStart) {
    return -((neutralStart - pointerPosition) / rampExtent)
        .clamp(0.0, 1.0)
        .toDouble();
  }
  if (canScrollTowardEnd && pointerPosition > neutralEnd) {
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
  required double edgeThickness,
  required MobileRemoteScrollDirections directions,
  required Duration frameDuration,
  required Duration remainingDuration,
}) {
  if (frameDuration <= Duration.zero || remainingDuration <= Duration.zero) {
    return Offset.zero;
  }
  final target = mobileRemoteClampCursorToNeutralRegion(
    pointerPosition: pointerPosition,
    viewport: viewport,
    edgeThickness: edgeThickness,
    directions: directions,
  );
  final fraction =
      (frameDuration.inMicroseconds / remainingDuration.inMicroseconds)
          .clamp(0.0, 1.0)
          .toDouble();
  return (target - pointerPosition) * fraction;
}
