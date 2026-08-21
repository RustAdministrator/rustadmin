import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/pages/remote_page.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote cursor overlay fills the video canvas without taking input', () {
    final overlay = mobileRemoteCursorOverlay('test-peer') as Positioned;

    expect(overlay.left, 0);
    expect(overlay.top, 0);
    expect(overlay.right, 0);
    expect(overlay.bottom, 0);
    expect(overlay.child, isA<IgnorePointer>());

    final pointerLayer = overlay.child as IgnorePointer;
    expect(pointerLayer.ignoring, isTrue);
    expect(pointerLayer.child, isA<CursorPaint>());
  });

  test('GPU texture is a renderable frame without a software image', () {
    expect(
      remoteRenderableFrameSize(
        softwareFrameSize: null,
        androidTextureActive: true,
        androidTextureFrameSize: const Size(2560, 1440),
      ),
      const Size(2560, 1440),
    );
    expect(
      remoteRenderableFrameSize(
        softwareFrameSize: null,
        androidTextureActive: true,
        androidTextureFrameSize: Size.zero,
      ),
      isNull,
    );
    expect(
      remoteRenderableFrameSize(
        softwareFrameSize: const Size(1920, 1080),
        androidTextureActive: false,
        androidTextureFrameSize: const Size(2560, 1440),
      ),
      const Size(1920, 1080),
    );
  });
}
