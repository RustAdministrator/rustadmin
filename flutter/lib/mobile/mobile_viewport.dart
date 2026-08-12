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
