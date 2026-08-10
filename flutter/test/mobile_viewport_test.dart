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

  test('limits overscan to centred remote corners', () {
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

    expect(firstCorner.dx, closeTo(viewport.width / 2, 0.000001));
    expect(firstCorner.dy, closeTo(0, 0.000001));
    expect(
      oppositeCorner.dx,
      closeTo(viewport.width / 2 - texture.width * scale, 0.000001),
    );
    expect(oppositeCorner.dy, closeTo(0, 0.000001));
  });

  test('edge acceleration follows depth into the device viewport edge', () {
    expect(
      mobileRemoteDeviceEdgeScrollAxisFactor(
        pointerPosition: 0,
        viewportExtent: 400,
        edgeThickness: 100,
      ),
      -1,
    );
    expect(
      mobileRemoteDeviceEdgeScrollAxisFactor(
        pointerPosition: 50,
        viewportExtent: 400,
        edgeThickness: 100,
      ),
      closeTo(-0.5, 0.000001),
    );
    expect(
      mobileRemoteDeviceEdgeScrollAxisFactor(
        pointerPosition: 200,
        viewportExtent: 400,
        edgeThickness: 100,
      ),
      0,
    );
    expect(
      mobileRemoteDeviceEdgeScrollAxisFactor(
        pointerPosition: 350,
        viewportExtent: 400,
        edgeThickness: 100,
      ),
      closeTo(0.5, 0.000001),
    );
    expect(
      mobileRemoteDeviceEdgeScrollAxisFactor(
        pointerPosition: 400,
        viewportExtent: 400,
        edgeThickness: 100,
      ),
      1,
    );
  });
}
