import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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
  Map<String, dynamic> _capabilities = {};
  Timer? _capabilityTimer;

  @override
  void initState() {
    super.initState();
    _capabilities = _readCapabilities();
    // Probing is asynchronous. Refresh this projection while settings are
    // mounted so opening the page before the probe finishes cannot freeze it.
    _capabilityTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final capabilities = _readCapabilities();
      if (!mapEquals(_capabilities, capabilities)) {
        setState(() => _capabilities = capabilities);
      }
    });
  }

  Map<String, dynamic> _readCapabilities() {
    try {
      return Map<String, dynamic>.from(
        jsonDecode(bind.mainSupportedHwdecodings()),
      );
    } catch (_) {
      return _capabilities;
    }
  }

  @override
  void dispose() {
    _capabilityTimer?.cancel();
    super.dispose();
  }

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
    final encoder = normalizeEncoderPreference(
      bind.mainGetOptionSync(key: encoderCodecPreferenceKey),
    );
    final decoder = normalizeDecoderPreference(
      remoteDisplaySettings.read(RemoteDisplaySettingsRegistry.codecPreference),
    );
    final hardware = option2bool(
      kOptionEnableHwcodec,
      bind.mainGetOptionSync(key: kOptionEnableHwcodec),
    );
    return CodecSettingsContent(
      capabilities: _capabilities,
      encoder: encoder,
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
                    // Keep the 16 px radio glyph; halve the former 24 px
                    // vertical gap from the 40 px compact rows.
                    minTileHeight: 28,
                    minVerticalPadding: 2,
                    visualDensity: VisualDensity.compact,
                    value: choice.value,
                    title: Text(
                      localize(
                        title == 'Decoder'
                            ? decoderSettingsLabel(choice)
                            : choice.label,
                      ),
                    ),
                    enabled: onChanged != null && choice.enabled(capabilities),
                  ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final radioTheme = RadioTheme.of(context);
    return RadioTheme(
      data: radioTheme.copyWith(
        visualDensity: VisualDensity(
          horizontal:
              radioTheme.visualDensity?.horizontal ??
              Theme.of(context).visualDensity.horizontal,
          vertical: -3,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _column('Encoder', encoderCodecChoices, encoder, onEncoder),
          const SizedBox(width: 16),
          _column('Decoder', decoderCodecChoices, decoder, onDecoder),
        ],
      ),
    );
  }
}
