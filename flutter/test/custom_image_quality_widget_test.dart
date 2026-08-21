import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/setting_widgets.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget controls({
    double quality = 50,
    double fps = 30,
    String fpsMode = kCustomFpsModeAdaptive,
    Function(double)? setQuality,
    Function(double)? setFps,
    Function(String)? setFpsMode,
    bool showQuality = true,
    bool showFpsMode = true,
    String fpsLabel = 'FPS',
  }) {
    return MaterialApp(
      home: Scaffold(
        body: CustomImageQualityWidget(
          initQuality: quality,
          initFps: fps,
          initFpsMode: fpsMode,
          setQuality: setQuality,
          setFps: setFps,
          setFpsMode: setFpsMode,
          showFps: true,
          showMoreQuality: true,
          showQuality: showQuality,
          showFpsMode: showFpsMode,
          fpsLabel: fpsLabel,
          translateText: (value) => value,
        ),
      ),
    );
  }

  testWidgets('debounces custom quality changes', (tester) async {
    final values = <double>[];
    await tester.pumpWidget(controls(setQuality: values.add));

    final slider = tester.widget<Slider>(
      find.byKey(const Key('custom-image-quality-slider')),
    );
    slider.onChanged?.call(85);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 999));
    expect(values, isEmpty);

    await tester.pump(const Duration(milliseconds: 1));
    expect(values, [85]);
  });

  testWidgets('profile switch cancels pending custom callbacks', (
    tester,
  ) async {
    final qualityValues = <double>[];
    final fpsValues = <double>[];
    await tester.pumpWidget(
      controls(setQuality: qualityValues.add, setFps: fpsValues.add),
    );

    tester
        .widget<Slider>(find.byKey(const Key('custom-image-quality-slider')))
        .onChanged
        ?.call(90);
    tester
        .widget<Slider>(find.byKey(const Key('custom-image-fps-slider')))
        .onChanged
        ?.call(60);
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(seconds: 2));

    expect(qualityValues, isEmpty);
    expect(fpsValues, isEmpty);
  });

  testWidgets('reopening custom restores the supplied values', (tester) async {
    Future<void> pumpCustom() => tester.pumpWidget(
      controls(quality: 125, fps: 15, fpsMode: kCustomFpsModeFixed),
    );

    await pumpCustom();
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('custom-image-quality-slider')))
          .value,
      125,
    );
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('custom-image-fps-slider')))
          .value,
      15,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await pumpCustom();
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const Key('custom-image-fps-mode-dropdown')),
          )
          .value,
      kCustomFpsModeFixed,
    );
  });

  testWidgets('controlled value updates do not emit user callbacks', (
    tester,
  ) async {
    final qualityValues = <double>[];
    await tester.pumpWidget(
      controls(quality: 50, setQuality: qualityValues.add),
    );

    await tester.pumpWidget(
      controls(quality: 100, setQuality: qualityValues.add),
    );
    await tester.pump(const Duration(seconds: 2));

    expect(
      tester
          .widget<Slider>(find.byKey(const Key('custom-image-quality-slider')))
          .value,
      100,
    );
    expect(qualityValues, isEmpty);

    tester
        .widget<Slider>(find.byKey(const Key('custom-image-quality-slider')))
        .onChanged
        ?.call(50);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(qualityValues, [50]);
  });

  testWidgets('Movie target-only controls hide quality and FPS mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      controls(
        fps: 60,
        showQuality: false,
        showFpsMode: false,
        fpsLabel: 'Target FPS',
      ),
    );

    expect(find.byKey(const Key('custom-image-quality-slider')), findsNothing);
    expect(find.byKey(const Key('custom-image-fps-slider')), findsOneWidget);
    expect(
      find.byKey(const Key('custom-image-fps-mode-dropdown')),
      findsNothing,
    );
    expect(find.text('Target FPS'), findsOneWidget);
  });
}
