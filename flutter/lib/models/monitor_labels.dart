import 'dart:ui' show Offset;

/// Presentation order only. Never reorder the capture list: its indices route
/// display selection, video, and input. Number left-to-right, then top-to-bottom
/// when monitors share an x coordinate; mirrored positions retain capture order.
List<int> monitorOrderForDisplays(Iterable<Offset> displayOrigins) {
  final origins = displayOrigins.toList(growable: false);
  final order = List.generate(origins.length, (index) => index);
  if (origins.any((origin) => !origin.dx.isFinite || !origin.dy.isFinite)) {
    return order;
  }
  return order..sort((a, b) {
    final horizontal = origins[a].dx.compareTo(origins[b].dx);
    if (horizontal != 0) return horizontal;
    final vertical = origins[a].dy.compareTo(origins[b].dy);
    return vertical != 0 ? vertical : a.compareTo(b);
  });
}

/// Labels remain parallel to the original capture list, not presentation order.
List<String> monitorLabelsForDisplays(Iterable<Offset> displayOrigins) {
  final order = monitorOrderForDisplays(displayOrigins);
  final labels = List.filled(order.length, '');
  for (var rank = 0; rank < order.length; rank++) {
    labels[order[rank]] = '${rank + 1}';
  }
  return labels;
}
