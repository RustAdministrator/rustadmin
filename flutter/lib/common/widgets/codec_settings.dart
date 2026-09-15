import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/codec_preferences.dart';
import 'package:flutter_hbb/common/remote_display_settings.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';

class CodecSettings extends StatefulWidget {
  const CodecSettings({super.key});

  @override
  State<CodecSettings> createState() => _CodecSettingsState();
}

class _CodecSettingsState extends State<CodecSettings> {
  bool _saving = false;

  Future<void> _save(Future<void> Function() write) async {
    setState(() => _saving = true);
    try {
      await write();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic> caps = {};
    try {
      caps = jsonDecode(bind.mainSupportedHwdecodings());
    } catch (_) {}
    final encoder = bind.mainGetOptionSync(key: encoderCodecPreferenceKey);
    final decoder = normalizeDecoderPreference(
      remoteDisplaySettings.read(RemoteDisplaySettingsRegistry.codecPreference),
    );
    final hardware = option2bool(
      kOptionEnableHwcodec,
      bind.mainGetOptionSync(key: kOptionEnableHwcodec),
    );
    return CodecSettingsContent(
      capabilities: caps,
      encoder: encoder.isEmpty ? 'auto' : encoder,
      decoder: decoder,
      preferHardware: hardware,
      onPreferHardware: _saving || isOptionFixed(kOptionEnableHwcodec)
          ? null
          : (value) => _save(() async {
              if (value == null) return;
              await mainSetBoolOption(kOptionEnableHwcodec, value);
            }),
      onEncoder: _saving || isOptionFixed(encoderCodecPreferenceKey)
          ? null
          : (value) => _save(() async {
              await bind.mainSetOption(
                key: encoderCodecPreferenceKey,
                value: value,
              );
            }),
      onDecoder: _saving || isOptionFixed(kOptionCodecPreference)
          ? null
          : (value) => _save(() async {
              await remoteDisplaySettings.write(
                RemoteDisplaySettingsRegistry.codecPreference,
                value,
              );
            }),
    );
  }
}

class CodecSettingsContent extends StatelessWidget {
  const CodecSettingsContent({
    super.key,
    required this.capabilities,
    required this.encoder,
    required this.decoder,
    required this.preferHardware,
    this.onPreferHardware,
    this.onEncoder,
    this.onDecoder,
    this.localize = translate,
  });

  final Map<String, dynamic> capabilities;
  final String encoder;
  final String decoder;
  final bool preferHardware;
  final ValueChanged<bool?>? onPreferHardware;
  final ValueChanged<String>? onEncoder;
  final ValueChanged<String>? onDecoder;
  final String Function(String) localize;

  Future<void> _showAboutCodecs(BuildContext context) => showDialog<void>(
    context: context,
    builder: (dialogContext) {
      void close() => Navigator.of(dialogContext).pop();
      return CustomAlertDialog(
        title: Text(localize('About codecs')),
        content: Text(localize('codec_direction_tip')),
        actions: [TextButton(onPressed: close, child: Text(localize('Close')))],
        onCancel: close,
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: () => _showAboutCodecs(context),
          style: TextButton.styleFrom(padding: EdgeInsets.zero),
          icon: const Icon(Icons.help_outline, size: 18),
          label: Text(localize('About codecs')),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          visualDensity: VisualDensity.compact,
          title: Text(localize('Prefer hardware codec')),
          value: preferHardware,
          onChanged: onPreferHardware,
        ),
        const SizedBox(height: 8),
        CodecPreferenceColumns(
          capabilities: capabilities,
          encoder: encoder,
          decoder: decoder,
          onEncoder: onEncoder,
          onDecoder: onDecoder,
          localize: localize,
        ),
      ],
    );
  }
}

class CodecPreferenceColumns extends StatelessWidget {
  const CodecPreferenceColumns({
    super.key,
    required this.capabilities,
    required this.encoder,
    required this.decoder,
    this.onEncoder,
    this.onDecoder,
    this.localize = translate,
  });
  final Map<String, dynamic> capabilities;
  final String encoder;
  final String decoder;
  final ValueChanged<String>? onEncoder;
  final ValueChanged<String>? onDecoder;
  final String Function(String) localize;

  Widget _column(
    String title,
    List<CodecChoice> choices,
    String selected,
    ValueChanged<String>? onChanged,
  ) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(localize(title)),
        const SizedBox(height: 8),
        RadioGroup<String>(
          groupValue: selected,
          onChanged: (value) {
            if (value != null) onChanged?.call(value);
          },
          child: Column(
            children: [
              for (final choice in choices)
                if (choice.visible(capabilities) || choice.value == selected)
                  RadioListTile<String>(
                    key: ValueKey('$title-${choice.value}'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    value: choice.value,
                    title: Text(localize(choice.label)),
                    enabled: onChanged != null && choice.enabled(capabilities),
                  ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _column('Encoder', encoderCodecChoices, encoder, onEncoder),
      const SizedBox(width: 16),
      _column('Decoder', decoderCodecChoices, decoder, onDecoder),
    ],
  );
}
