final _windowsDisplayName = RegExp(
  r'^\\\\\.\\DISPLAY([1-9][0-9]*)\x00*$',
  caseSensitive: false,
);

/// Labels are parallel to the capture list; never sort that list for display.
/// Windows GDI names are useful numbering metadata, not stable display IDs or
/// a guaranteed match for Settings > Identify on every driver/topology.
List<String> monitorLabelsForDisplays(
  Iterable<String> displayNames, {
  required bool isWindows,
}) {
  final names = displayNames.toList(growable: false);
  final fallback = List.generate(names.length, (index) => '${index + 1}');
  if (!isWindows) return fallback;

  final labels = <String>[];
  final seen = <int>{};
  for (final name in names) {
    final match = name.length <= 256
        ? _windowsDisplayName.firstMatch(name)
        : null;
    final number = match == null ? null : int.tryParse(match.group(1)!);
    // Fall back as a set: mixing native and ordinal numbers can create duplicate
    // labels when an old peer, virtual display, or clone lacks a unique name.
    if (number == null || number > 0x7fffffff || !seen.add(number)) {
      return fallback;
    }
    labels.add('$number');
  }
  return labels;
}
