import 'package:flutter/material.dart';

const kHostResourceModeOption = 'host-resource-mode';
const kViewerResourceModeOption = 'viewer-resource-mode';
const kRemoteResourceModeOption = 'remote-resource-mode';
const kSupportResourceModePlatformAddition = 'support_resource_mode';

const kResourceModeNormal = 'normal';
const kResourceModeLowPower = 'low-power';
const kResourceModeMinimizeGpu = 'minimize-gpu';

const kResourceModeExplanation =
    'Low power limits video work. Minimize GPU uses software codecs and can '
    'increase CPU use. Displaying the session can still use the GPU.';

class ResourceModeChoice {
  const ResourceModeChoice({required this.value, required this.label});

  final String value;
  final String label;
}

const resourceModeChoices = <ResourceModeChoice>[
  ResourceModeChoice(value: kResourceModeNormal, label: 'Normal'),
  ResourceModeChoice(value: kResourceModeLowPower, label: 'Low power'),
  ResourceModeChoice(value: kResourceModeMinimizeGpu, label: 'Minimize GPU'),
];

const resourceModeValues = <String>{
  kResourceModeNormal,
  kResourceModeLowPower,
  kResourceModeMinimizeGpu,
};

String normalizeResourceMode(Object? value) => switch (
  value is String ? value.trim().toLowerCase() : ''
) {
  kResourceModeNormal => kResourceModeNormal,
  kResourceModeLowPower => kResourceModeLowPower,
  kResourceModeMinimizeGpu => kResourceModeMinimizeGpu,
  _ => kResourceModeNormal,
};

ResourceModeChoice resourceModeChoice(String value) {
  final normalized = normalizeResourceMode(value);
  return resourceModeChoices.firstWhere((choice) => choice.value == normalized);
}

bool supportsRemoteResourceMode(Map<String, dynamic> platformAdditions) =>
    platformAdditions[kSupportResourceModePlatformAddition] == true;

/// Focus is intentionally not part of this decision: an unfocused visible
/// window still owns a live view. Recording also keeps video active even when
/// its tab is hidden or its window is minimized.
bool shouldKeepRemoteVideoVisible({
  required bool activeTab,
  required bool windowMinimized,
  required bool recording,
}) => recording || (activeTab && !windowMinimized);

typedef VideoVisibilityWriter = Future<void> Function(bool? visible);

/// Serializes visibility transitions and lets a connection-scoped owner be
/// unregistered with a null value. The native bridge remains authoritative for
/// the resulting connection policy.
class VideoVisibilityReporter {
  VideoVisibilityReporter(this._write);

  final VideoVisibilityWriter _write;
  Future<void> _pending = Future<void>.value();
  bool _hasReported = false;
  bool? _lastReported;

  Future<void> update(bool? visible) {
    if (_hasReported && visible == _lastReported) return _pending;
    _hasReported = true;
    _lastReported = visible;
    _pending = _pending.catchError((_) {}).then<void>((_) => _write(visible));
    return _pending;
  }

  /// Starts a new reporting epoch after native session state resets.
  void reset() {
    _hasReported = false;
    _lastReported = null;
  }
}

String _identity(String value) => value;

class ResourceModeRadioGroup extends StatelessWidget {
  const ResourceModeRadioGroup({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.groupKey = 'resource-mode',
    this.localize = _identity,
  });

  final String value;
  final ValueChanged<String>? onChanged;
  final String? title;
  final String groupKey;
  final String Function(String) localize;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[Text(title!), const SizedBox(height: 4)],
        RadioGroup<String>(
          groupValue: normalizeResourceMode(value),
          onChanged: (next) {
            if (next != null) onChanged?.call(next);
          },
          child: Column(
            children: [
              for (final choice in resourceModeChoices)
                RadioListTile<String>(
                  key: ValueKey('$groupKey-${choice.value}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  minTileHeight: 28,
                  minVerticalPadding: 2,
                  visualDensity: VisualDensity.compact,
                  value: choice.value,
                  title: Text(localize(choice.label)),
                  enabled: onChanged != null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
