import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/widgets/codec_settings.dart';
import 'package:flutter_test/flutter_test.dart';

final _explanation = List.filled(
  12,
  'Encoder is the hosting default. Decoder is the viewing default. '
  'Hardware and software implementations can be used independently.',
).join(' ');

String _localize(String value) =>
    value == 'codec_direction_tip' ? _explanation : value;

Widget _settings({
  double textScale = 1,
  Brightness brightness = Brightness.light,
  ValueChanged<bool?>? onPreferHardware,
  ValueChanged<String>? onEncoder,
  ValueChanged<String>? onDecoder,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15),
        child: CodecSettingsContent(
          localize: _localize,
          capabilities: const {
            'encAv1': true,
            'av1': true,
            'av1Hw': true,
            'av1Sw': true,
            'h264Hw': true,
            'h264Sw': true,
            'h265Hw': true,
            'h265Sw': true,
          },
          encoder: 'auto',
          decoder: 'auto',
          preferHardware: false,
          onPreferHardware: onPreferHardware,
          onEncoder: onEncoder,
          onDecoder: onDecoder,
        ),
      ),
    ),
  ),
);

void main() {
  for (final width in [320.0, 540.0]) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        'codec settings fit $width at text scale $textScale with modal help',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 600));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          bool? preferHardware;
          String? encoder;
          String? decoder;
          await tester.pumpWidget(
            _settings(
              textScale: textScale,
              brightness: textScale == 1 ? Brightness.light : Brightness.dark,
              onPreferHardware: (value) => preferHardware = value,
              onEncoder: (value) => encoder = value,
              onDecoder: (value) => decoder = value,
            ),
          );

          final checkbox = find.byType(Checkbox);
          final hardwareLabel = find.text('Prefer hardware codec');
          final encoderHeader = tester.getRect(find.text('Encoder'));
          final decoderHeader = tester.getRect(find.text('Decoder'));
          final encoderAuto = tester.getRect(
            find.byKey(const ValueKey('Encoder-auto')),
          );
          final decoderAuto = tester.getRect(
            find.byKey(const ValueKey('Decoder-auto')),
          );
          expect(
            tester.getCenter(checkbox).dx,
            lessThan(tester.getTopLeft(hardwareLabel).dx),
          );
          expect(
            tester.getCenter(checkbox).dx,
            tester
                .getCenter(
                  find.descendant(
                    of: find.byKey(const ValueKey('Encoder-auto')),
                    matching: find.byType(Radio<String>),
                  ),
                )
                .dx,
          );
          expect(encoderHeader.left, 15);
          expect(encoderHeader.top, decoderHeader.top);
          expect(encoderAuto.width, decoderAuto.width);
          expect(decoderAuto.left - encoderAuto.right, 16);
          expect(decoderAuto.right, width - 15);
          expect(tester.takeException(), isNull);

          await tester.tap(hardwareLabel);
          expect(preferHardware, isTrue);
          final encoderChoice = find.byKey(const ValueKey('Encoder-av1'));
          await tester.ensureVisible(encoderChoice);
          await tester.tap(encoderChoice);
          expect(encoder, 'av1');
          expect(decoder, isNull);
          final decoderChoice = find.byKey(
            const ValueKey('Decoder-h264-hq-sw'),
          );
          await tester.ensureVisible(decoderChoice);
          await tester.tap(decoderChoice);
          expect(decoder, 'h264-hq-sw');
          expect(encoder, 'av1');

          expect(find.text(_explanation), findsNothing);
          final help = find.text('About codecs');
          await tester.ensureVisible(help);
          await tester.tap(help);
          await tester.pumpAndSettle();
          expect(find.text(_explanation), findsOneWidget);
          expect(
            tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
            isTrue,
          );
          expect(find.text('Close').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();
          expect(find.text(_explanation), findsNothing);
          expect(preferHardware, isTrue);
          expect(encoder, 'av1');
          expect(decoder, 'h264-hq-sw');
        },
      );
    }
  }

  testWidgets('codec help can be dismissed without changing fixed settings', (
    tester,
  ) async {
    await tester.pumpWidget(_settings());
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
    for (final dismissal in ['outside', 'escape', 'back']) {
      await tester.tap(find.text('About codecs'));
      await tester.pumpAndSettle();
      expect(find.text(_explanation), findsOneWidget);
      switch (dismissal) {
        case 'outside':
          await tester.tapAt(const Offset(1, 1));
        case 'escape':
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        case 'back':
          await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(_explanation), findsNothing);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      expect(tester.takeException(), isNull);
    }
  });
}
