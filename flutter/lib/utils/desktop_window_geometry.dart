import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';

import 'window_placement.dart';

/// Uses the same top-left desktop coordinates as window_manager. Windows
/// persists physical pixels; macOS and Linux persist native logical coordinates.
WindowDisplay? windowDisplayFromScreen(
  Display screen, {
  required bool physicalPixels,
  bool isPrimary = false,
}) {
  final origin = screen.visiblePosition;
  final size = screen.visibleSize ?? screen.size;
  final scale = physicalPixels ? (screen.scaleFactor ?? 1).toDouble() : 1.0;
  if (origin == null || !scale.isFinite || scale <= 0) return null;
  final area = Rect.fromLTWH(
    origin.dx * scale,
    origin.dy * scale,
    size.width * scale,
    size.height * scale,
  );
  if (!area.isFinite || area.isEmpty) return null;
  // Windows/Linux plugins return id=0 for every display. Their name is useful
  // only when unique; the placement policy resolves duplicates by geometry.
  final name = screen.name;
  final id = screen.id != 0
      ? 'id:${screen.id}'
      : (name == null || name.isEmpty ? null : 'name:$name');
  return WindowDisplay(
    id: id,
    workArea: area,
    scaleFactor: scale,
    isPrimary: isPrimary,
  );
}

Future<List<WindowDisplay>> getDesktopWindowDisplays({
  required bool physicalPixels,
}) async {
  List<Display> screens = [];
  try {
    screens = await screenRetriever.getAllDisplays();
  } catch (error) {
    debugPrint('Display enumeration unavailable: $error');
  }
  WindowDisplay? primary;
  try {
    primary = windowDisplayFromScreen(
      await screenRetriever.getPrimaryDisplay(),
      physicalPixels: physicalPixels,
      isPrimary: true,
    );
  } catch (error) {
    debugPrint('Primary display unavailable: $error');
  }
  final displays = <WindowDisplay>[];
  for (final screen in screens) {
    final display = windowDisplayFromScreen(
      screen,
      physicalPixels: physicalPixels,
    );
    if (display == null) continue;
    // Compare work areas as well as IDs: identical Linux monitor models can
    // share a name, and Windows supplies no numeric display identity.
    final isPrimary =
        primary != null &&
        display.id == primary.id &&
        display.workArea == primary.workArea;
    displays.add(
      WindowDisplay(
        id: display.id,
        workArea: display.workArea,
        scaleFactor: display.scaleFactor,
        isPrimary: isPrimary,
      ),
    );
  }
  if (displays.isEmpty && primary != null) displays.add(primary);
  return displays;
}
