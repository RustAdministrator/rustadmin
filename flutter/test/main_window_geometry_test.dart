import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_hbb/generated_bridge.dart' show Rustadmin;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_retriever/screen_retriever.dart';

class GeometryBridge implements Rustadmin {
  String stored = '';
  int writes = 0;
  Completer<void>? writeGate;
  bool incomingOnly = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #isIncomingOnly:
        return incomingOnly;
      case #isOutgoingOnly:
        return false;
      case #mainGetEnv:
        return '';
      case #getLocalFlutterOption:
        return stored;
      case #setLocalFlutterOption:
        return () async {
          await writeGate?.future;
          stored = invocation.namedArguments[#v] as String;
          writes++;
        }();
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GeometryBridge bridge;
  var frame = const Rect.fromLTWH(0, 0, 800, 600);
  var maximized = false;
  var minimized = false;
  var screensAvailable = true;
  final primary = Display(
    id: 1,
    name: 'primary',
    size: const Size(1920, 1080),
    visiblePosition: Offset.zero,
    visibleSize: const Size(1920, 1040),
  );
  final secondary = Display(
    id: 2,
    name: 'secondary',
    size: const Size(1600, 1000),
    visiblePosition: const Offset(-1600, 0),
    visibleSize: const Size(1600, 960),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    isTest = true;
    bridge = GeometryBridge();
    platformFFI.initForTest(bridge);
    frame = const Rect.fromLTWH(0, 0, 800, 600);
    maximized = false;
    minimized = false;
    screensAvailable = true;
    messenger.setMockMethodCallHandler(
      const MethodChannel('screen_retriever'),
      (call) async {
        if (!screensAvailable) {
          throw PlatformException(code: 'display-query-failed');
        }
        if (call.method == 'getPrimaryDisplay') return primary.toJson();
        if (call.method == 'getAllDisplays') {
          return {
            'displays': [secondary.toJson(), primary.toJson()],
          };
        }
        fail('Unexpected screen query ${call.method}');
      },
    );
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (
      call,
    ) async {
      switch (call.method) {
        case 'getBounds':
          return {
            'x': frame.left,
            'y': frame.top,
            'width': frame.width,
            'height': frame.height,
          };
        case 'setBounds':
          final args = call.arguments as Map;
          frame = Rect.fromLTWH(
            args['x'] ?? frame.left,
            args['y'] ?? frame.top,
            args['width'] ?? frame.width,
            args['height'] ?? frame.height,
          );
          return null;
        case 'isMaximized':
          return maximized;
        case 'maximize':
          maximized = true;
          return null;
        case 'isMinimized':
          return minimized;
        case 'isFullScreen':
          return false;
        default:
          fail('Unexpected window query ${call.method}');
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('screen_retriever'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
  });

  test(
    'first launch is centered on primary even when it is enumerated last',
    () async {
      expect(await restoreWindowPosition(WindowType.Main), isTrue);
      expect(frame, const Rect.fromLTWH(320, 120, 1280, 800));
      expect(bridge.writes, 0);
    },
  );

  test(
    'close flush waits for persistence and records final monitor and size',
    () async {
      await restoreWindowPosition(WindowType.Main);
      frame = const Rect.fromLTWH(-1450, 50, 900, 650);
      await saveWindowPosition(WindowType.Main);
      expect(bridge.writes, 0);
      bridge.writeGate = Completer<void>();
      var finished = false;
      final closeSave = saveWindowPosition(
        WindowType.Main,
        flush: true,
      ).then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      bridge.writeGate!.complete();
      await closeSave;
      final saved = LastWindowPosition.loadFromString(bridge.stored)!;
      expect(saved.frame, frame);
      expect(saved.monitor?.id, 'id:2');
      expect(bridge.writes, 1);
    },
  );

  test('closing maximized retains the last normal frame', () async {
    await restoreWindowPosition(WindowType.Main);
    const normal = Rect.fromLTWH(-1450, 50, 900, 650);
    frame = normal;
    await saveWindowPosition(WindowType.Main);
    maximized = true;
    frame = const Rect.fromLTWH(-1600, 0, 1600, 960);
    await saveWindowPosition(WindowType.Main, flush: true);
    final saved = LastWindowPosition.loadFromString(bridge.stored)!;
    expect(saved.frame, normal);
    expect(saved.isMaximized, isTrue);
    expect(saved.monitor?.id, 'id:2');
  });

  test(
    'saved geometry is clamped into available work area after disconnection',
    () async {
      bridge.stored =
          '{"width":2400,"height":1400,"offsetWidth":4000,"offsetHeight":50}';
      await restoreWindowPosition(WindowType.Main);
      expect(frame, const Rect.fromLTWH(0, 0, 1920, 1040));
    },
  );

  test('closing minimized preserves the normal frame and monitor', () async {
    await restoreWindowPosition(WindowType.Main);
    const normal = Rect.fromLTWH(-1450, 50, 900, 650);
    frame = normal;
    await saveWindowPosition(WindowType.Main, flush: true);
    minimized = true;
    frame = const Rect.fromLTWH(-32000, -32000, 160, 30);
    await saveWindowPosition(WindowType.Main, flush: true);
    final saved = LastWindowPosition.loadFromString(bridge.stored)!;
    expect(saved.frame, normal);
    expect(saved.monitor?.id, 'id:2');
  });

  test(
    'a maximized move saves the new monitor with a normal-sized frame',
    () async {
      await restoreWindowPosition(WindowType.Main);
      frame = const Rect.fromLTWH(-1450, 50, 900, 650);
      await saveWindowPosition(WindowType.Main, flush: true);
      maximized = true;
      frame = const Rect.fromLTWH(0, 0, 1920, 1040);
      await saveWindowPosition(WindowType.Main, flush: true);
      final saved = LastWindowPosition.loadFromString(bridge.stored)!;
      expect(saved.frame, const Rect.fromLTWH(510, 195, 900, 650));
      expect(saved.monitor?.id, 'id:1');
      expect(saved.isMaximized, isTrue);
    },
  );

  test('temporary monitor-query failures retain the saved monitor', () async {
    await restoreWindowPosition(WindowType.Main);
    frame = const Rect.fromLTWH(-1450, 50, 900, 650);
    await saveWindowPosition(WindowType.Main, flush: true);
    screensAvailable = false;
    await saveWindowPosition(WindowType.Main, flush: true);
    final saved = LastWindowPosition.loadFromString(bridge.stored)!;
    expect(saved.frame, frame);
    expect(saved.monitor?.id, 'id:2');
  });

  test(
    'incoming-only restore keeps the content-sized window dimensions',
    () async {
      bridge.incomingOnly = true;
      bridge.stored =
          '{"width":900,"height":650,"offsetWidth":-1450,"offsetHeight":50}';
      frame = const Rect.fromLTWH(0, 0, 400, 300);
      await restoreWindowPosition(WindowType.Main);
      expect(frame, const Rect.fromLTWH(-1450, 50, 400, 300));
    },
  );
}
