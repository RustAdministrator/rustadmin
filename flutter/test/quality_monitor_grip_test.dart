import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/overlay.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

class _TestRustadminImpl implements Rustadmin {
  final options = <String, String>{};
  final writes = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #translate) {
      return invocation.namedArguments[#name] as String;
    }
    if (invocation.memberName == #mainGetUserDefaultOption ||
        invocation.memberName == #mainGetLocalOption ||
        invocation.memberName == #getLocalFlutterOption ||
        invocation.memberName == #mainSupportedInputSource ||
        invocation.memberName == #mainGetDisplays) {
      return '';
    }
    if (invocation.memberName == #isDisableAb ||
        invocation.memberName == #isDisableAccount ||
        invocation.memberName == #isDisableGroupPanel ||
        invocation.memberName == #mainCurrentIsWayland ||
        invocation.memberName == #mainHasFileClipboard ||
        invocation.memberName == #sessionGetToggleOptionSync) {
      return false;
    }
    if (invocation.memberName == #versionToNumber ||
        invocation.memberName == #peerGetSessionsCount) {
      return 0;
    }
    if (invocation.memberName == #mainGetVersion) {
      return Future<String>.value('2.0.5 rev test');
    }
    if (invocation.memberName == #sessionGetToggleOption) {
      return Future<bool?>.value(true);
    }
    if (invocation.memberName == #sessionGetOption) {
      final name = invocation.namedArguments[#arg] as String;
      return Future<String?>.value(options[name] ?? '');
    }
    if (invocation.memberName == #sessionPeerOption) {
      writes[invocation.namedArguments[#name] as String] =
          invocation.namedArguments[#value] as String;
      return Future<void>.value();
    }
    if (invocation.memberName == #mainSetOption ||
        invocation.memberName == #mainSetLocalOption ||
        invocation.memberName == #setLocalFlutterOption ||
        invocation.memberName == #mainInitInputSource) {
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  late _TestRustadminImpl testImpl;

  setUpAll(() {
    isTest = true;
    testImpl = _TestRustadminImpl();
    platformFFI.initForTest(testImpl);
  });

  setUp(() {
    testImpl.options.clear();
    testImpl.writes.clear();
  });

  Future<FFI> createMonitorFfi(
      {String details = kQualityMonitorDetailsExtended,
      String size = '',
      String floatingPosition = ''}) async {
    testImpl.options[kOptionQualityMonitorDetails] = details;
    testImpl.options[kOptionQualityMonitorFloatingSize] = size;
    testImpl.options[kOptionQualityMonitorFloatingPosition] = floatingPosition;
    testImpl.options[kOptionQualityMonitorPosition] =
        kQualityMonitorPositionTopRight;
    final ffi = FFI(null)..id = 'quality-monitor-test-peer';
    await ffi.qualityMonitorModel.checkShowQualityMonitor(ffi.sessionId);
    return ffi;
  }

  Widget monitorApp(FFI ffi, {Size viewport = const Size(600, 500)}) =>
      MaterialApp(
          home: Scaffold(
              body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                      width: viewport.width,
                      height: viewport.height,
                      child: Stack(children: [
                        PositionedQualityMonitor(
                            qualityMonitorModel: ffi.qualityMonitorModel)
                      ])))));

  testWidgets('advanced quality monitor resizes, scrolls, and persists size',
      (tester) async {
    final ffi = await createMonitorFfi(size: '240,420');
    await tester.pumpWidget(monitorApp(ffi));
    await tester.pump();

    final window = find.byKey(const Key('quality-monitor-window'));
    final handle = find.byKey(const Key('quality-monitor-resize-handle'));
    expect(tester.getSize(window), const Size(240, 420));
    expect(handle, findsOneWidget);

    await tester.drag(handle, const Offset(-50, -250));
    await tester.pump();
    expect(tester.getSize(window), const Size(190, 170));
    expect(testImpl.writes[kOptionQualityMonitorFloatingSize], '190,170');

    final scrollable = find.descendant(
        of: window, matching: find.byType(Scrollable));
    final scrollState = tester.state<ScrollableState>(scrollable);
    expect(scrollState.position.pixels, 0);
    await tester.drag(scrollable, const Offset(0, -160));
    await tester.pump();
    final scrolledOffset = scrollState.position.pixels;
    expect(scrolledOffset, greaterThan(0));

    ffi.qualityMonitorModel.updateConnectionInfo('QUIC/UDP', true);
    await tester.pump();
    expect(scrollState.position.pixels, scrolledOffset);
  });

  testWidgets('advanced quality monitor clamps persisted geometry to viewport',
      (tester) async {
    final ffi = await createMonitorFfi(
        size: '900,900', floatingPosition: '500,500');
    await tester.pumpWidget(
        monitorApp(ffi, viewport: const Size(300, 220)));
    await tester.pump();

    final rect =
        tester.getRect(find.byKey(const Key('quality-monitor-window')));
    expect(rect.width, lessThanOrEqualTo(280));
    expect(rect.height, lessThanOrEqualTo(200));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(300));
    expect(rect.bottom, lessThanOrEqualTo(220));
  });

  testWidgets('basic quality monitor remains fixed and non-resizable',
      (tester) async {
    final ffi = await createMonitorFfi(
        details: kQualityMonitorDetailsBasic, size: '190,170');
    await tester.pumpWidget(monitorApp(ffi));
    await tester.pump();

    expect(find.byKey(const Key('quality-monitor-resize-handle')), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const Key('quality-monitor-window')),
            matching: find.byType(Scrollable)),
        findsNothing);
  });

  testWidgets('mobile advanced quality monitor keeps a usable resize target',
      (tester) async {
    final previousIsMobile = isMobile;
    isMobile = true;
    addTearDown(() => isMobile = previousIsMobile);
    final ffi = await createMonitorFfi(size: '196,420');
    await tester
        .pumpWidget(monitorApp(ffi, viewport: const Size(320, 220)));
    await tester.pump();

    final window = find.byKey(const Key('quality-monitor-window'));
    final handle = find.byKey(const Key('quality-monitor-resize-handle'));
    expect(tester.getSize(window).height, lessThanOrEqualTo(200));
    expect(tester.getSize(handle), const Size(28, 28));
    expect(
        find.descendant(of: window, matching: find.byType(Scrollable)),
        findsOneWidget);
  });

  testWidgets('quality monitor header switches details from its context menu',
      (tester) async {
    String? selected;
    DragUpdateDetails? dragUpdate;
    var dragEndCount = 0;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: QualityMonitorHeader(
            details: kQualityMonitorDetailsBasic,
            onPanUpdate: (details) => dragUpdate = details,
            onPanEnd: (_) => dragEndCount++,
            onDetailsChanged: (details) async => selected = details,
          ),
        ),
      ),
    ));

    final header = find.byType(QualityMonitorHeader);
    await tester.tap(header,
        kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('Basic'), findsOneWidget);
    expect(find.text('Extended'), findsOneWidget);

    final extendedItem = find.widgetWithText(PopupMenuItem<String>, 'Extended');
    expect(tester.getSize(extendedItem).height, 32);
    await tester.tap(extendedItem);
    await tester.pumpAndSettle();
    expect(selected, kQualityMonitorDetailsExtended);

    await tester.drag(header, const Offset(8, 6));
    await tester.pumpAndSettle();
    expect(dragUpdate, isNotNull);
    expect(dragEndCount, 1);
  });

  testWidgets('quality monitor details toggle switches STD and ADV',
      (tester) async {
    String? selected;

    Future<void> pumpToggle(String details) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: QualityMonitorDetailsToggle(
                details: details,
                onDetailsChanged: (value) async => selected = value,
              ),
            ),
          ),
        ));

    await pumpToggle(kQualityMonitorDetailsBasic);
    expect(find.text('STD'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('quality-monitor-details-toggle')),
    );
    await tester.pump();
    expect(selected, kQualityMonitorDetailsExtended);

    selected = null;
    await pumpToggle(kQualityMonitorDetailsExtended);
    expect(find.text('ADV'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('quality-monitor-details-toggle')),
    );
    await tester.pump();
    expect(selected, kQualityMonitorDetailsBasic);
  });

  testWidgets('quality monitor details toggle remains visible in light theme',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.light(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: QualityMonitorDetailsToggle(
            details: kQualityMonitorDetailsExtended,
            onDetailsChanged: (_) async {},
          ),
        ),
      ),
    ));

    final toggle = find.byKey(const Key('quality-monitor-details-toggle'));
    final label = tester.widget<Text>(find.descendant(
      of: toggle,
      matching: find.text('ADV'),
    ));
    final container = tester.widget<Container>(find.descendant(
      of: toggle,
      matching: find.byType(Container),
    ));
    final decoration = container.decoration as BoxDecoration;

    expect(label.style?.color, isNot(Colors.white));
    expect(decoration.color?.a, greaterThan(0));
    expect(decoration.border, isA<Border>());
    final border = decoration.border! as Border;
    expect(border.top.style, BorderStyle.solid);
    expect(border.right.style, BorderStyle.solid);
    expect(border.bottom.style, BorderStyle.solid);
    expect(border.left.style, BorderStyle.solid);
  });

  testWidgets('quality monitor details toggle blocks pointer passthrough',
      (tester) async {
    var backgroundDownCount = 0;
    String? selected;

    await tester.pumpWidget(MaterialApp(
      home: Stack(
        children: [
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => backgroundDownCount++,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: 20,
            top: 20,
            child: QualityMonitorDetailsToggle(
              details: kQualityMonitorDetailsBasic,
              onDetailsChanged: (value) async => selected = value,
            ),
          ),
        ],
      ),
    ));

    await tester.tap(
      find.byKey(const Key('quality-monitor-details-toggle')),
    );
    await tester.pump();

    expect(selected, kQualityMonitorDetailsExtended);
    expect(backgroundDownCount, 0);
  });

  testWidgets('quality monitor resize handle blocks pointer passthrough',
      (tester) async {
    var backgroundDownCount = 0;
    var resizeUpdateCount = 0;

    await tester.pumpWidget(MaterialApp(
      home: Stack(
        children: [
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => backgroundDownCount++,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: 20,
            top: 20,
            child: QualityMonitorResizeHandle(
              onPanUpdate: (_) => resizeUpdateCount++,
            ),
          ),
        ],
      ),
    ));

    final handle = find.byKey(const Key('quality-monitor-resize-handle'));
    await tester.drag(handle, const Offset(20, 20));
    await tester.pump();

    expect(resizeUpdateCount, greaterThan(0));
    expect(backgroundDownCount, 0);
  });

  testWidgets('quality monitor toggle taps and header-style drags stay distinct',
      (tester) async {
    String? selected;
    var dragUpdateCount = 0;
    var dragEndCount = 0;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 190,
            child: QualityMonitorHeader(
              details: kQualityMonitorDetailsBasic,
              onPanUpdate: (_) => dragUpdateCount++,
              onPanEnd: (_) => dragEndCount++,
              onDetailsChanged: (value) async => selected = value,
            ),
          ),
        ),
      ),
    ));

    final toggle = find.byKey(const Key('quality-monitor-details-toggle'));
    await tester.tap(toggle);
    await tester.pump();
    expect(selected, kQualityMonitorDetailsExtended);
    expect(dragUpdateCount, 0);
    expect(dragEndCount, 0);

    selected = null;
    final drag = await tester.startGesture(tester.getCenter(toggle));
    await drag.moveBy(const Offset(24, 12));
    await tester.pump();
    await drag.moveBy(const Offset(24, 12));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    expect(selected, isNull);
    expect(dragUpdateCount, greaterThan(0));
    expect(dragEndCount, 1);
  });

  testWidgets('quality monitor header blocks remote pointer passthrough',
      (tester) async {
    var backgroundDownCount = 0;
    var backgroundMoveCount = 0;
    var backgroundUpCount = 0;
    var headerMoveCount = 0;
    const settings = QualityMonitorFadeSettings(
      opacity: 0.5,
      delay: Duration(milliseconds: 1000),
      duration: Duration(milliseconds: 3000),
    );

    await tester.pumpWidget(MaterialApp(
      home: Stack(
        children: [
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => backgroundDownCount++,
              onPointerMove: (_) => backgroundMoveCount++,
              onPointerUp: (_) => backgroundUpCount++,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: 20,
            top: 20,
            child: QualityMonitorHoverFade(
              settingsProvider: () => settings,
              child: SizedBox(
                width: 190,
                child: QualityMonitorHeader(
                  details: kQualityMonitorDetailsBasic,
                  onPanUpdate: (_) => headerMoveCount++,
                  onDetailsChanged: (_) async {},
                ),
              ),
            ),
          ),
        ],
      ),
    ));

    final header = find.byType(QualityMonitorHeader);
    final gesture = await tester.startGesture(
      tester.getCenter(header),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(8, 6));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(headerMoveCount, greaterThan(0));
    expect(backgroundDownCount, 0);
    expect(backgroundMoveCount, 0);
    expect(backgroundUpCount, 0);
  });

  testWidgets('quality monitor fades without blocking remote hover',
      (tester) async {
    var backgroundHoverCount = 0;
    final settingsChanges = StreamController<QualityMonitorFadeSettings>();
    addTearDown(settingsChanges.close);
    var settings = const QualityMonitorFadeSettings(
      opacity: 0.5,
      delay: Duration(milliseconds: 1000),
      duration: Duration(milliseconds: 3000),
    );

    await tester.pumpWidget(MaterialApp(
      home: Stack(
        children: [
          Positioned.fill(
            child: MouseRegion(
              onHover: (_) => backgroundHoverCount++,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: 20,
            top: 20,
            child: QualityMonitorHoverFade(
              settingsProvider: () => settings,
              settingsStream: settingsChanges.stream,
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ],
      ),
    ));

    AnimatedOpacity opacityWidget() =>
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));

    expect(opacityWidget().opacity, 1.0);
    await tester.pump(settings.delay);
    expect(opacityWidget().opacity, settings.opacity);
    expect(opacityWidget().duration, settings.duration);
    await tester.pump(settings.duration);

    settings = const QualityMonitorFadeSettings(
      opacity: 0.35,
      delay: Duration(milliseconds: 250),
      duration: Duration(milliseconds: 750),
    );
    settingsChanges.add(settings);
    await tester.pump();
    expect(opacityWidget().opacity, settings.opacity);
    expect(opacityWidget().duration, QualityMonitorHoverFade.restoreDuration);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(250, 250));
    await tester.pump();
    backgroundHoverCount = 0;
    await mouse.moveTo(const Offset(50, 50));
    await tester.pump();

    expect(backgroundHoverCount, greaterThan(0));
    expect(opacityWidget().opacity, 1.0);
    expect(opacityWidget().duration, QualityMonitorHoverFade.restoreDuration);

    await mouse.moveTo(const Offset(250, 250));
    await tester.pump();
    await tester.pump(settings.delay);
    expect(opacityWidget().opacity, settings.opacity);
    expect(opacityWidget().duration, settings.duration);
  });
}
