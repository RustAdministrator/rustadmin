import 'package:flutter/material.dart';

import '../session_peer_settings.dart';

const localLanguageShortcutOptionValues = <String>[
  kLocalLanguageShortcutsAuto,
  kLocalLanguageShortcutsEnabled,
  kLocalLanguageShortcutsDisabled,
];

const localLanguageShortcutGlobalExplanation =
    'Keep language switching available locally while forwarding keys remotely. '
    'Auto applies in Map mode; Enabled applies in all modes. Requires Input '
    'source 1. Supports configured Alt+Shift/Ctrl+Shift and Win+Space cycling '
    'without the Windows chooser.';

const localLanguageShortcutPeerExplanation =
    'Auto follows the global setting. Enabled also switches language locally; '
    'Disabled keeps shortcuts remote-only. Requires Input source 1.';

const localLanguageShortcutInputSourceRequirement =
    'Requires Input source 1. Input source 2 keeps its existing OS handling.';

String localLanguageShortcutOptionLabel(String value) => switch (value) {
  kLocalLanguageShortcutsEnabled => 'Enabled',
  kLocalLanguageShortcutsDisabled => 'Disabled',
  _ => 'Auto',
};

String localLanguageShortcutOptionDescription(
  String value, {
  bool peerOverride = false,
}) {
  if (peerOverride && value == kLocalLanguageShortcutsAuto) {
    return 'Follow the global setting.';
  }
  return switch (value) {
    kLocalLanguageShortcutsEnabled =>
      'Enable local language switching in all keyboard modes.',
    kLocalLanguageShortcutsDisabled => 'Keep language shortcuts remote-only.',
    _ => 'Enable local language switching in Map mode.',
  };
}

typedef LocalLanguageShortcutValueReader = String Function();
typedef LocalLanguageShortcutValueWriter = Future<void> Function(String value);
typedef LocalLanguageShortcutTranslator = String Function(String value);

String _identityLocalLanguageShortcutText(String value) => value;

String _readGlobalLocalLanguageShortcuts() => remoteAppLocalSettings.read(
  RemoteAppLocalSettingsRegistry.localLanguageShortcuts,
);

Future<void> _writeGlobalLocalLanguageShortcuts(String value) =>
    remoteAppLocalSettings.write(
      RemoteAppLocalSettingsRegistry.localLanguageShortcuts,
      value,
    );

class LocalLanguageShortcutSettings extends StatefulWidget {
  LocalLanguageShortcutSettings({
    super.key,
    this.enabled = true,
    LocalLanguageShortcutValueReader? readValue,
    LocalLanguageShortcutValueWriter? writeValue,
    LocalLanguageShortcutTranslator? translateText,
  }) : readValue = readValue ?? _readGlobalLocalLanguageShortcuts,
       writeValue = writeValue ?? _writeGlobalLocalLanguageShortcuts,
       translateText = translateText ?? _identityLocalLanguageShortcutText;

  final bool enabled;
  final LocalLanguageShortcutValueReader readValue;
  final LocalLanguageShortcutValueWriter writeValue;
  final LocalLanguageShortcutTranslator translateText;

  @override
  State<LocalLanguageShortcutSettings> createState() =>
      _LocalLanguageShortcutSettingsState();
}

class _LocalLanguageShortcutSettingsState
    extends State<LocalLanguageShortcutSettings> {
  late String _value;

  String _normalize(String value) =>
      RemoteAppLocalSettingsRegistry.localLanguageShortcuts.codec.decode(value);

  @override
  void initState() {
    super.initState();
    _value = _normalize(widget.readValue());
  }

  Future<void> _onChanged(String? value) async {
    if (value == null || value == _value || !widget.enabled) return;
    setState(() => _value = value);
    await widget.writeValue(value);
    if (!mounted) return;
    setState(() => _value = _normalize(widget.readValue()));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.translateText('Local language shortcuts'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 8, top: 4),
          child: Text(
            widget.translateText(localLanguageShortcutGlobalExplanation),
          ),
        ),
        RadioGroup<String>(
          groupValue: _value,
          onChanged: _onChanged,
          child: Column(
            children: [
              ...localLanguageShortcutOptionValues.map(
                (option) => RadioListTile<String>(
                  key: ValueKey('local-language-shortcut-$option'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: option,
                  enabled: widget.enabled,
                  title: Text(
                    widget.translateText(
                      localLanguageShortcutOptionLabel(option),
                    ),
                  ),
                  subtitle: Text(
                    widget.translateText(
                      localLanguageShortcutOptionDescription(option),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
