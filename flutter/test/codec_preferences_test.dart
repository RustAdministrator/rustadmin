import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/codec_preferences.dart';
import 'package:flutter_hbb/common/remote_display_settings.dart';
import 'package:flutter_hbb/common/session_peer_settings.dart';
import 'package:flutter_hbb/common/widgets/codec_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'encoder choices expose independent hardware and software capabilities',
    () {
      final hardware = encoderCodecChoices.singleWhere(
        (c) => c.value == 'h264',
      );
      final software = encoderCodecChoices.singleWhere(
        (c) => c.value == 'h264-sw',
      );
      final av1Hardware = encoderCodecChoices.singleWhere(
        (c) => c.value == 'av1-hw',
      );
      final av1Software = encoderCodecChoices.singleWhere(
        (c) => c.value == 'av1-sw',
      );
      expect(hardware.label, 'H264 HW');
      expect(hardware.enabled({'encH264Hw': true, 'h264Hw': false}), isTrue);
      expect(hardware.enabled({'encH264': true, 'encH264Sw': true}), isFalse);
      expect(software.visible({'encH264Hw': true}), isFalse);
      expect(software.enabled({'encH264Sw': true, 'h264Sw': false}), isTrue);
      expect(av1Hardware.enabled({'encAv1Hw': true, 'av1Hw': false}), isTrue);
      expect(
        av1Software.enabled({'encAv1Sw': true, 'encAv1Hw': false}),
        isTrue,
      );
      for (final choice in encoderCodecChoices) {
        expect(normalizeEncoderPreference(choice.value), choice.value);
      }
      expect(normalizeEncoderPreference('h264-hw'), 'h264');
      expect(normalizeEncoderPreference('unknown'), 'auto');
    },
  );

  testWidgets('hardware preference does not disable explicit local choices', (
    tester,
  ) async {
    for (final preferHardware in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CodecSettingsContent(
                localize: (s) => s,
                capabilities: const {
                  'encAv1Hw': true,
                  'encAv1Sw': true,
                  'av1Hw': true,
                  'av1Sw': true,
                },
                encoder: 'av1-sw',
                decoder: 'av1-hw',
                preferHardware: preferHardware,
                onEncoder: (_) {},
                onDecoder: (_) {},
              ),
            ),
          ),
        ),
      );
      for (final key in [
        'Encoder-av1-hw',
        'Encoder-av1-sw',
        'Decoder-av1-hw',
        'Decoder-av1-sw',
      ]) {
        expect(
          tester
              .widget<RadioListTile<String>>(find.byKey(ValueKey(key)))
              .enabled,
          isTrue,
        );
      }
    }
  });

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
    expect(normalizeDecoderPreference('h264-hq'), 'h264-hq');
    expect(normalizeDecoderPreference('h264-hw'), 'h264');
    expect(normalizeDecoderPreference('h265-hq'), 'h265-hq');
    expect(normalizeDecoderPreference('h265-hw'), 'h265');
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
      expect(find.byKey(const ValueKey('Decoder-h264-sw')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'H26x labels have four choices in the requested order with software support',
    () {
      final visible = visibleDecoderCodecChoices({
        'h264Hw': true,
        'h264Sw': true,
        'h265Hw': true,
        'h265Sw': true,
      }).toList();
      for (final format in ['h264', 'h265']) {
        expect(
          visible.where((c) => c.value.startsWith(format)).map((c) => c.label),
          [
            '${format.toUpperCase()} SW',
            '${format.toUpperCase()} HQ SW',
            format.toUpperCase(),
            '${format.toUpperCase()} HQ',
          ],
        );
      }
    },
  );

  test(
    'HQ aliases reuse decoder capability and check the host profile separately',
    () {
      for (final format in ['h264', 'h265']) {
        for (final software in [false, true]) {
          final normal = decoderCodecChoices.singleWhere(
            (c) => c.value == '$format${software ? '-sw' : ''}',
          );
          final hq = decoderCodecChoices.singleWhere(
            (c) => c.value == '$format-hq${software ? '-sw' : ''}',
          );
          expect(hq.capability, normal.capability);
          final caps = <String, dynamic>{normal.capability!: true};
          expect(hq.enabled(caps), isTrue); // Defaults have no host yet.
          caps[hq.requestCapability!] = false;
          expect(normal.enabled(caps), isTrue);
          expect(hq.enabled(caps), isFalse);
          caps[hq.requestCapability!] = true;
          expect(hq.enabled(caps), isTrue);
          caps[normal.capability!] = false;
          expect(hq.enabled(caps), isFalse);
        }
      }
    },
  );

  test(
    'software visibility depends on the local build, not the host encoder',
    () {
      final hardwareOnly = visibleDecoderCodecChoices({
        'h264Hw': true,
      }).toList();
      expect(
        hardwareOnly
            .where((c) => c.value.startsWith('h264'))
            .map((c) => c.label),
        ['H264', 'H264 HQ'],
      );
      final incompatibleHost = visibleDecoderCodecChoices({
        'local-h264Sw': true,
        'h264Sw': false,
        'requestH264Hq': false,
      }).where((c) => c.value.startsWith('h264')).toList();
      expect(incompatibleHost.map((c) => c.label), [
        'H264 SW',
        'H264 HQ SW',
        'H264',
        'H264 HQ',
      ]);
      final saved = visibleDecoderCodecChoices({}, selected: 'h264-hq-sw');
      expect(saved.any((c) => c.value == 'h264-hq-sw'), isTrue);
      expect(
        saved.singleWhere((c) => c.value == 'h264-hq-sw').enabled({}),
        isFalse,
      );
    },
  );

  testWidgets(
    'HQ SW selects only the decoder column and survives normalization',
    (tester) async {
      String? encoder;
      String? decoder;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CodecPreferenceColumns(
                localize: (value) => value,
                capabilities: const {'h264Sw': true, 'h264Hw': true},
                encoder: 'auto',
                decoder: 'h264',
                onEncoder: (value) => encoder = value,
                onDecoder: (value) => decoder = value,
              ),
            ),
          ),
        ),
      );
      final target = find.byKey(const ValueKey('Decoder-h264-hq-sw'));
      await tester.ensureVisible(target);
      await tester.tap(target);
      expect(decoder, 'h264-hq-sw');
      expect(normalizeDecoderPreference(decoder!), 'h264-hq-sw');
      expect(encoder, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
