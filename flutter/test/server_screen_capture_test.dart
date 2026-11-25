import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The Android host service keeps running when the screen capture ends outside the app
  // (the status bar on Android 14 and later, or the system). "Stop service" was tied to the
  // capture and disappeared, and "Screen Capture" offered to stop the whole service.
  test('a running service without the capture asks for the capture again', () {
    expect(
      screenCaptureTap(isStart: true, mediaOk: false, scamWarning: true),
      ScreenCaptureTap.requestCapture,
    );
    expect(
      showStopService(isStart: true, hideStopService: false),
      isTrue,
    );
  });

  test('a stopped service starts as before', () {
    expect(
      screenCaptureTap(isStart: false, mediaOk: false, scamWarning: true),
      ScreenCaptureTap.scamWarning,
    );
    expect(
      screenCaptureTap(isStart: false, mediaOk: false, scamWarning: false),
      ScreenCaptureTap.toggleService,
    );
    expect(
      showStopService(isStart: false, hideStopService: false),
      isFalse,
    );
  });

  test('a capturing service is stopped from the row as before', () {
    expect(
      screenCaptureTap(isStart: true, mediaOk: true, scamWarning: true),
      ScreenCaptureTap.toggleService,
    );
    expect(
      showStopService(isStart: true, hideStopService: true),
      isFalse,
    );
  });
}
