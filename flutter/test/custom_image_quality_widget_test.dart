import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/setting_widgets.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget controls({
    double quality = 50,
    double fps = 30,
    String fpsMode = kCustomFpsModeAdaptive,
    String videoProfile = kVideoProfileStandard,
    Function(double)? setQuality,
    Function(double)? setFps,
    Function(String)? setFpsMode,
    Function(String)? setVideoProfile,
    bool showQuality = true,
    bool showFps = true,
    bool showFpsMode = true,
    bool showVideoProfile = false,
    String fpsLabel = 'FPS',
    double width = 800,
    double textScale = 1,
    String Function(String)? translateText,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: SizedBox(
            width: width,
            child: CustomImageQualityWidget(
              initQuality: quality,
              initFps: fps,
              initFpsMode: fpsMode,
              initVideoProfile: videoProfile,
              setQuality: setQuality,
              setFps: setFps,
              setFpsMode: setFpsMode,
              setVideoProfile: setVideoProfile,
              showFps: showFps,
              showMoreQuality: true,
              showQuality: showQuality,
              showFpsMode: showFpsMode,
              showVideoProfile: showVideoProfile,
              fpsLabel: fpsLabel,
              translateText: translateText ?? (value) => value,
            ),
          ),
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

  testWidgets('manual quality switches Standard and Movie beside FPS', (
    tester,
  ) async {
    final profiles = <String>[];
    await tester.pumpWidget(
      controls(
        fps: 60,
        showVideoProfile: true,
        setVideoProfile: profiles.add,
      ),
    );

    expect(find.byKey(const Key('custom-image-quality-slider')), findsOneWidget);
    expect(find.byKey(const Key('custom-image-fps-slider')), findsOneWidget);
    expect(
      find.byKey(const Key('custom-image-fps-mode-dropdown')),
      findsOneWidget,
    );

    tester
        .widget<SegmentedButton<String>>(
          find.byKey(const Key('custom-image-video-profile-segmented')),
        )
        .onSelectionChanged
        ?.call({kVideoProfileMovie});
    await tester.pump();

    expect(profiles, [kVideoProfileMovie]);
    expect(find.text('Target FPS'), findsOneWidget);
    expect(
      find.byKey(const Key('custom-image-fps-mode-dropdown')),
      findsNothing,
    );
    expect(find.byKey(const Key('custom-image-quality-slider')), findsOneWidget);
  });

  testWidgets('video profile labels stay on one line at large text scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      controls(
        showQuality: false,
        showFps: false,
        showVideoProfile: true,
        setVideoProfile: (_) {},
        width: 320,
        textScale: 2,
        translateText: (value) => switch (value) {
          'Standard' => 'Стандартный',
          'Movie mode' => 'Режим кино',
          _ => value,
        },
      ),
    );

    expect(
      tester
          .getSize(
            find.byKey(const Key('custom-image-video-profile-segmented')),
          )
          .height,
      40,
    );
    for (final label in ['Стандартный', 'Режим кино']) {
      final text = tester.widget<Text>(find.text(label));
      expect(text.maxLines, 1);
      expect(text.softWrap, isFalse);
    }
    expect(tester.takeException(), isNull);
  });
}
