import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/codec_preferences.dart';
import 'package:flutter_hbb/common/remote_display_settings.dart';
import 'package:flutter_hbb/common/session_peer_settings.dart';
import 'package:flutter_hbb/common/widgets/codec_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decoder defaults and peer overrides preserve all backend choices', () {
    for (final choice in decoderCodecChoices) {
      expect(
        RemoteDisplaySettingsRegistry.codecPreference.codec.decode(
          choice.value,
        ),
        choice.value,
      );
      expect(
        SessionPeerSettingsRegistry.codecPreference.codec.decode(choice.value),
        choice.value,
      );
    }
    expect(normalizeDecoderPreference('h264-hq'), 'h264');
    expect(normalizeDecoderPreference('h265-hq'), 'h265');
    expect(normalizeDecoderPreference('unknown'), 'auto');
    expect(normalizeDecoderPreference('av1'), 'av1');
  });

  test('decoder hardware choice does not require a local hardware encoder', () {
    final hardwareAv1 = decoderCodecChoices.singleWhere(
      (choice) => choice.value == 'av1-hw',
    );
    expect(hardwareAv1.enabled({'av1Hw': true, 'encAv1': false}), isTrue);
    expect(hardwareAv1.enabled({'av1Hw': false, 'encAv1': true}), isFalse);
    final softwareH264 = decoderCodecChoices.singleWhere(
      (choice) => choice.value == 'h264-sw',
    );
    expect(softwareH264.enabled({'h264Hw': true}), isFalse);
  });

  for (final width in [320.0, 800.0]) {
    testWidgets('encoder and decoder columns are independent at width $width', (
      tester,
    ) async {
      String? encoder;
      String? decoder;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: SingleChildScrollView(
                  child: CodecPreferenceColumns(
                    localize: (value) => value,
                    capabilities: const {
                      'encAv1': true,
                      'av1': true,
                      'av1Hw': true,
                      'av1Sw': true,
                    },
                    encoder: 'auto',
                    decoder: 'auto',
                    onEncoder: (value) => encoder = value,
                    onDecoder: (value) => decoder = value,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('Encoder-av1')));
      expect(encoder, 'av1');
      expect(decoder, isNull);
      await tester.tap(find.byKey(const ValueKey('Decoder-av1-hw')));
      expect(decoder, 'av1-hw');
      expect(encoder, 'av1');
      expect(
        tester
            .widget<RadioListTile<String>>(
              find.byKey(const ValueKey('Decoder-h264-sw')),
            )
            .enabled,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
