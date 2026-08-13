import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/mobile_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'calculates one-shot mobile view scales from decoded texture pixels',
    () {
      const texture = Size(2560, 1440);
      const viewport = Size(393, 873);
      const devicePixelRatio = 3.0;

      expect(
        mobileRemoteScaleForMode(
          mode: MobileRemoteViewScaleMode.fitAll,
          texture: texture,
          viewport: viewport,
          devicePixelRatio: devicePixelRatio,
        ),
        closeTo(393 / 2560, 0.000001),
      );
      expect(
        mobileRemoteScaleForMode(
          mode: MobileRemoteViewScaleMode.fitWidth,
          texture: texture,
          viewport: viewport,
          devicePixelRatio: devicePixelRatio,
        ),
        closeTo(393 / 2560, 0.000001),
      );
      expect(
        mobileRemoteScaleForMode(
          mode: MobileRemoteViewScaleMode.fitHeight,
          texture: texture,
          viewport: viewport,
          devicePixelRatio: devicePixelRatio,
        ),
        closeTo(873 / 1440, 0.000001),
      );
      expect(
        mobileRemoteScaleForMode(
          mode: MobileRemoteViewScaleMode.oneToOne,
          texture: texture,
          viewport: viewport,
          devicePixelRatio: devicePixelRatio,
        ),
        closeTo(1 / devicePixelRatio, 0.000001),
      );
      expect(
        mobileRemoteMinimumCanvasScale(texture: texture, viewport: viewport),
        closeTo(393 / 2560, 0.000001),
      );
      expect(
        mobileRemoteMinimumEdgeScrollScale(
          texture: texture,
          viewport: viewport,
          edgeThickness: 100,
        ),
        closeTo((873 + 200) / 1440, 0.000001),
      );
    },
  );

  test('uses linear minification and nearest-neighbour magnification', () {
    expect(
      mobileRemoteTextureFilterQuality(logicalScale: 0.2),
      FilterQuality.low,
    );
    expect(
      mobileRemoteTextureFilterQuality(logicalScale: 0.999),
      FilterQuality.low,
    );
    expect(
      mobileRemoteTextureFilterQuality(logicalScale: 1),
      FilterQuality.none,
    );
    expect(
      mobileRemoteTextureFilterQuality(logicalScale: 10),
      FilterQuality.none,
    );
  });

  test('clamps remote screen edges without empty overscan', () {
    const texture = Size(2560, 1440);
    const viewport = Size(393, 873);
    const scale = 873 / 1440;

    final firstCorner = mobileRemoteClampCanvasOffset(
      proposed: const Offset(99999, 99999),
      texture: texture,
      viewport: viewport,
      scale: scale,
    );
    final oppositeCorner = mobileRemoteClampCanvasOffset(
      proposed: const Offset(-99999, -99999),
      texture: texture,
      viewport: viewport,
      scale: scale,
    );

    expect(firstCorner.dx, closeTo(0, 0.000001));
    expect(firstCorner.dy, closeTo(0, 0.000001));
    expect(
      oppositeCorner.dx,
      closeTo(viewport.width - texture.width * scale, 0.000001),
    );
    expect(oppositeCorner.dy, closeTo(0, 0.000001));
  });

  test('uses custom-key top as keyboard viewport bottom', () {
    expect(
      mobileRemoteUsableViewportHeight(
        screenHeight: 852,
        topInset: 59,
        keyboardInset: 300,
        keyHelpTop: 500,
      ),
      441,
    );
    expect(
      mobileRemoteUsableViewportHeight(
        screenHeight: 852,
        topInset: 59,
        keyboardInset: 300,
      ),
      493,
    );
    expect(
      mobileRemoteUsableViewportHeight(
        screenHeight: 852,
        topInset: 59,
        keyboardInset: 0,
      ),
      793,
    );
  });

  test('mobile pointer mapping follows the moved canvas on both axes', () {
    const texturePosition = Offset(1200, 800);
    const canvasOffset = Offset(-700, -450);
    const scale = 0.75;
    final viewportPosition = mobileRemoteViewportPositionFromTexture(
      texturePosition: texturePosition,
      canvasOffset: canvasOffset,
      scale: scale,
    );
    expect(viewportPosition, const Offset(200, 150));
    expect(
      mobileRemoteTexturePositionFromViewport(
        viewportPosition: viewportPosition,
        canvasOffset: canvasOffset,
        scale: scale,
      ),
      texturePosition,
    );
  });

  test('cursor follows canvas scrolling and stops at remote edges', () {
    expect(
      mobileRemoteCursorAfterCanvasScroll(
        currentRemotePosition: const Offset(1200, 700),
        canvasDelta: const Offset(-30, -60),
        scale: 0.5,
        remoteBounds: const Rect.fromLTWH(0, 0, 2560, 1440),
      ),
      const Offset(1260, 820),
    );
    expect(
      mobileRemoteCursorAfterCanvasScroll(
        currentRemotePosition: const Offset(2550, 1430),
        canvasDelta: const Offset(-30, -60),
        scale: 0.5,
        remoteBounds: const Rect.fromLTWH(0, 0, 2560, 1440),
      ),
      const Offset(2559, 1439),
    );
  });

  test('fixed edge mode uses the center third as its cursor region', () {
    const viewport = Size(300, 600);
    final neutralRect = mobileRemoteNeutralCursorRect(viewport);
    expect(neutralRect.left, closeTo(100, 0.000001));
    expect(neutralRect.top, closeTo(200, 0.000001));
    expect(neutralRect.right, closeTo(200, 0.000001));
    expect(neutralRect.bottom, closeTo(400, 0.000001));
    final clamped = mobileRemoteClampCursorToNeutralRegion(
      pointerPosition: const Offset(20, 580),
      viewport: viewport,
    );
    expect(clamped.dx, closeTo(100, 0.000001));
    expect(clamped.dy, closeTo(400, 0.000001));
    expect(
      mobileRemoteClampCursorToNeutralRegion(
        pointerPosition: const Offset(150, 300),
        viewport: viewport,
      ),
      const Offset(150, 300),
    );
    expect(
      mobileRemoteEdgeScrollAxisDirection(
        pointerPosition: 100,
        viewportExtent: 300,
      ),
      -1,
    );
    expect(
      mobileRemoteEdgeScrollAxisDirection(
        pointerPosition: 150,
        viewportExtent: 300,
      ),
      0,
    );
    expect(
      mobileRemoteEdgeScrollAxisDirection(
        pointerPosition: neutralRect.right,
        viewportExtent: 300,
      ),
      1,
    );
  });

  test('edge acceleration ramps over two thirds of each outer band', () {
    expect(
      mobileRemoteEdgeAccelerationAxisFactor(
        pointerPosition: 100,
        viewportExtent: 300,
      ),
      0,
    );
    expect(
      mobileRemoteEdgeAccelerationAxisFactor(
        pointerPosition: 200 / 3,
        viewportExtent: 300,
      ),
      closeTo(-0.5, 0.000001),
    );
    expect(
      mobileRemoteEdgeAccelerationAxisFactor(
        pointerPosition: 100 / 3,
        viewportExtent: 300,
      ),
      -1,
    );
    expect(
      mobileRemoteEdgeAccelerationAxisFactor(
        pointerPosition: 0,
        viewportExtent: 300,
      ),
      -1,
    );
    expect(
      mobileRemoteEdgeAccelerationAxisFactor(
        pointerPosition: 700 / 3,
        viewportExtent: 300,
      ),
      closeTo(0.5, 0.000001),
    );
    expect(
      mobileRemoteEdgeAccelerationAxisFactor(
        pointerPosition: 800 / 3,
        viewportExtent: 300,
      ),
      1,
    );
  });

  test('acceleration cursor returns to neutral as inertia expires', () {
    const viewport = Size(300, 600);
    final first = mobileRemoteAccelerationReturnDelta(
      pointerPosition: const Offset(40, 500),
      viewport: viewport,
      frameDuration: const Duration(milliseconds: 25),
      remainingDuration: const Duration(milliseconds: 100),
    );
    expect(first.dx, closeTo(15, 0.000001));
    expect(first.dy, closeTo(-25, 0.000001));
    final second = mobileRemoteAccelerationReturnDelta(
      pointerPosition: const Offset(55, 475),
      viewport: viewport,
      frameDuration: const Duration(milliseconds: 75),
      remainingDuration: const Duration(milliseconds: 75),
    );
    expect(second.dx, closeTo(45, 0.000001));
    expect(second.dy, closeTo(-75, 0.000001));
  });
}
