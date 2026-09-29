import 'package:flutter/services.dart';
import 'package:flutter_hbb/utils/desktop_window_geometry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_retriever/screen_retriever.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final primary = Display(
    id: 0,
    name: 'primary',
    size: const Size(1920, 1080),
    visiblePosition: Offset.zero,
    visibleSize: const Size(1920, 1040),
    scaleFactor: 1,
  );
  final secondary = Display(
    id: 0,
    name: 'secondary',
    size: const Size(1280, 720),
    visiblePosition: const Offset(-1280, -100),
    visibleSize: const Size(1280, 680),
    scaleFactor: 1.5,
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('screen_retriever'),
          null,
        );
  });

  test(
    'Windows uses each target monitor DPI, never the current window DPI',
    () {
      final monitor = windowDisplayFromScreen(secondary, physicalPixels: true)!;
      expect(monitor.workArea, const Rect.fromLTWH(-1920, -150, 1920, 1020));
      expect(monitor.scaleFactor, 1.5);
      expect(monitor.id, 'name:secondary');
    },
  );

  test('macOS/Linux retain native logical desktop coordinates', () {
    final monitor = windowDisplayFromScreen(secondary, physicalPixels: false)!;
    expect(monitor.workArea, const Rect.fromLTWH(-1280, -100, 1280, 680));
    expect(monitor.scaleFactor, 1);
  });

  test(
    'primary lookup ignores enumeration order and never queries the cursor',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('screen_retriever'), (
            call,
          ) async {
            calls.add(call.method);
            if (call.method == 'getAllDisplays') {
              return {
                'displays': [secondary.toJson(), primary.toJson()],
              };
            }
            if (call.method == 'getPrimaryDisplay') return primary.toJson();
            fail('Unexpected monitor query: ${call.method}');
          });
      final displays = await getDesktopWindowDisplays(physicalPixels: true);
      expect(displays.first.isPrimary, isFalse);
      expect(displays.last.isPrimary, isTrue);
      expect(calls, ['getAllDisplays', 'getPrimaryDisplay']);
    },
  );

  test('primary remains usable when enumeration fails', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('screen_retriever'), (
          call,
        ) async {
          if (call.method == 'getAllDisplays') {
            throw PlatformException(code: 'unavailable');
          }
          return primary.toJson();
        });
    final displays = await getDesktopWindowDisplays(physicalPixels: true);
    expect(displays.single.id, 'name:primary');
    expect(displays.single.workArea, const Rect.fromLTWH(0, 0, 1920, 1040));
  });
}
