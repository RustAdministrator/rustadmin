import 'dart:ui';

/// A desktop display in the coordinate space used by the window manager.
class WindowDisplay {
  const WindowDisplay({
    this.id,
    required this.workArea,
    this.scaleFactor = 1,
    this.isPrimary = false,
  });

  final String? id;
  final Rect workArea;
  final double scaleFactor;
  final bool isPrimary;

  /// Serialize a display for embedding in the existing window-position JSON.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'workArea': <String, dynamic>{
      'l': workArea.left,
      't': workArea.top,
      'r': workArea.right,
      'b': workArea.bottom,
    },
    'scaleFactor': scaleFactor,
    'isPrimary': isPrimary,
  };

  /// Parse untrusted persisted display data.
  static WindowDisplay? fromJson(Object? value) {
    if (value is! Map) return null;

    final rawWorkArea = value['workArea'];
    if (rawWorkArea is! Map) return null;
    final left = _finiteDouble(rawWorkArea['l']);
    final top = _finiteDouble(rawWorkArea['t']);
    final right = _finiteDouble(rawWorkArea['r']);
    final bottom = _finiteDouble(rawWorkArea['b']);
    if (left == null || top == null || right == null || bottom == null) {
      return null;
    }
    final workArea = Rect.fromLTRB(left, top, right, bottom);
    if (!_isValidRect(workArea)) return null;

    final rawScale = value['scaleFactor'];
    final scaleFactor = rawScale == null ? 1.0 : _finiteDouble(rawScale);
    if (scaleFactor == null || scaleFactor <= 0) return null;

    final rawId = value['id'];
    final id = rawId is String && rawId.isNotEmpty ? rawId : null;
    final rawPrimary = value['isPrimary'];

    return WindowDisplay(
      id: id,
      workArea: workArea,
      scaleFactor: scaleFactor,
      isPrimary: rawPrimary is bool && rawPrimary,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is WindowDisplay &&
            id == other.id &&
            workArea == other.workArea &&
            scaleFactor == other.scaleFactor &&
            isPrimary == other.isPrimary);
  }

  @override
  int get hashCode => Object.hash(id, workArea, scaleFactor, isPrimary);
}

/// A restored window frame together with the display it was placed on.
class WindowPlacement {
  const WindowPlacement({required this.frame, required this.display});

  final Rect frame;
  final WindowDisplay display;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is WindowPlacement &&
            frame == other.frame &&
            display == other.display);
  }

  @override
  int get hashCode => Object.hash(frame, display);
}

/// Restore a saved desktop frame on one of the currently available displays.
WindowPlacement? restoreWindowPlacement({
  required List<WindowDisplay> displays,
  required Size defaultSize,
  Rect? savedFrame,
  WindowDisplay? savedDisplay,
  bool scaleDefaultSize = false,
}) {
  final available = _validDisplays(displays);
  if (available.isEmpty) return null;

  final primary = _primaryDisplay(available);
  final validSavedFrame = savedFrame != null && _isValidRect(savedFrame)
      ? savedFrame
      : null;

  if (validSavedFrame == null) {
    final validDefaultSize = _validSize(defaultSize);
    if (validDefaultSize == null) return null;

    final scale = scaleDefaultSize ? primary.scaleFactor : 1.0;
    final scaledSize = _scaleSize(validDefaultSize, scale) ?? validDefaultSize;
    return WindowPlacement(
      frame: _centerFrame(primary, scaledSize),
      display: primary,
    );
  }

  final validStoredDisplay = _validDisplay(savedDisplay);
  if (validStoredDisplay != null) {
    final target = _findStoredDisplay(validStoredDisplay, available);
    if (target != null) {
      final ratio =
          _scaleRatio(target.scaleFactor, validStoredDisplay.scaleFactor) ??
          1.0;
      final size = _scaleSize(validSavedFrame.size, ratio);
      final offset = _scaleOffset(
        validSavedFrame.topLeft - validStoredDisplay.workArea.topLeft,
        ratio,
      );
      if (size != null && offset != null) {
        final mapped = Rect.fromLTWH(
          target.workArea.left + offset.dx,
          target.workArea.top + offset.dy,
          size.width,
          size.height,
        );
        if (_isValidRect(mapped)) {
          return WindowPlacement(
            frame: _clampFrame(mapped, target.workArea),
            display: target,
          );
        }
      }
    }

    // The stored monitor is unavailable, so its old coordinates must not
    // accidentally place the window on an unrelated current monitor.
    return _centerSavedFrame(
      primary,
      validSavedFrame,
      validStoredDisplay.scaleFactor,
    );
  }

  // A frame without a usable monitor is legacy state. Preserve its current
  // display when it overlaps one; otherwise use the primary display and
  // center the saved size there.
  final legacy = _displayWithGreatestOverlap(validSavedFrame, available);
  if (legacy.overlap > 0) {
    return WindowPlacement(
      frame: _clampFrame(validSavedFrame, legacy.display.workArea),
      display: legacy.display,
    );
  }
  return _centerSavedFrame(primary, validSavedFrame, null);
}

/// Find the display with the greatest positive overlap with [frame].
///
/// Invalid displays and an invalid frame are ignored. With no positive
/// overlap, the primary display is returned as the stable fallback.
WindowDisplay? displayForWindow(Rect frame, List<WindowDisplay> displays) {
  final available = _validDisplays(displays);
  if (available.isEmpty) return null;

  final primary = _primaryDisplay(available);
  if (!_isValidRect(frame)) return primary;

  return _displayWithGreatestOverlap(frame, available).display;
}

WindowDisplay _primaryDisplay(List<WindowDisplay> displays) {
  for (final display in displays) {
    if (display.isPrimary) return display;
  }
  return displays.first;
}

List<WindowDisplay> _validDisplays(List<WindowDisplay> displays) {
  return displays.where(_isValidDisplay).toList(growable: false);
}

WindowDisplay? _validDisplay(WindowDisplay? display) {
  return display != null && _isValidDisplay(display) ? display : null;
}

bool _isValidDisplay(WindowDisplay display) {
  return _isValidRect(display.workArea) &&
      display.scaleFactor.isFinite &&
      display.scaleFactor > 0;
}

bool _isValidRect(Rect rect) {
  return rect.isFinite && rect.width > 0 && rect.height > 0;
}

Size? _validSize(Size size) {
  return size.width.isFinite &&
          size.height.isFinite &&
          size.width > 0 &&
          size.height > 0
      ? size
      : null;
}

double? _scaleRatio(double targetScale, double savedScale) {
  final ratio = targetScale / savedScale;
  return ratio.isFinite && ratio > 0 ? ratio : null;
}

Size? _scaleSize(Size size, double scale) {
  if (_validSize(size) == null || !scale.isFinite || scale <= 0) {
    return null;
  }
  final scaled = Size(size.width * scale, size.height * scale);
  return _validSize(scaled);
}

Offset? _scaleOffset(Offset offset, double scale) {
  if (!offset.dx.isFinite ||
      !offset.dy.isFinite ||
      !scale.isFinite ||
      scale <= 0) {
    return null;
  }
  final scaled = Offset(offset.dx * scale, offset.dy * scale);
  return scaled.dx.isFinite && scaled.dy.isFinite ? scaled : null;
}

WindowPlacement _centerSavedFrame(
  WindowDisplay primary,
  Rect savedFrame,
  double? savedScale,
) {
  final ratio = savedScale == null
      ? 1.0
      : _scaleRatio(primary.scaleFactor, savedScale) ?? 1.0;
  final size = _scaleSize(savedFrame.size, ratio) ?? savedFrame.size;
  return WindowPlacement(frame: _centerFrame(primary, size), display: primary);
}

Rect _centerFrame(WindowDisplay display, Size desiredSize) {
  final size = _fitSize(desiredSize, display.workArea);
  return Rect.fromLTWH(
    display.workArea.left + (display.workArea.width - size.width) / 2,
    display.workArea.top + (display.workArea.height - size.height) / 2,
    size.width,
    size.height,
  );
}

Size _fitSize(Size desiredSize, Rect workArea) {
  final width = desiredSize.width > workArea.width
      ? workArea.width
      : desiredSize.width;
  final height = desiredSize.height > workArea.height
      ? workArea.height
      : desiredSize.height;
  return Size(width, height);
}

Rect _clampFrame(Rect frame, Rect workArea) {
  final size = _fitSize(frame.size, workArea);
  final maxLeft = workArea.right - size.width;
  final maxTop = workArea.bottom - size.height;
  final left = _clampDouble(frame.left, workArea.left, maxLeft);
  final top = _clampDouble(frame.top, workArea.top, maxTop);
  return Rect.fromLTWH(left, top, size.width, size.height);
}

double _clampDouble(double value, double min, double max) {
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

_DisplayOverlap _displayWithGreatestOverlap(
  Rect frame,
  List<WindowDisplay> displays,
) {
  final primary = _primaryDisplay(displays);
  WindowDisplay best = primary;
  var bestOverlap = 0.0;
  for (final display in displays) {
    final overlap = _overlapArea(frame, display.workArea);
    if (overlap > bestOverlap) {
      best = display;
      bestOverlap = overlap;
    }
  }
  return _DisplayOverlap(best, bestOverlap);
}

double _overlapArea(Rect first, Rect second) {
  final left = first.left > second.left ? first.left : second.left;
  final top = first.top > second.top ? first.top : second.top;
  final right = first.right < second.right ? first.right : second.right;
  final bottom = first.bottom < second.bottom ? first.bottom : second.bottom;
  if (right <= left || bottom <= top) return 0;
  return (right - left) * (bottom - top);
}

WindowDisplay? _findStoredDisplay(
  WindowDisplay saved,
  List<WindowDisplay> displays,
) {
  final id = saved.id;
  if (id == null || id.isEmpty) {
    final areaMatches = displays
        .where(
          (display) =>
              _sameRect(display.workArea, saved.workArea) &&
              display.scaleFactor == saved.scaleFactor,
        )
        .toList();
    return areaMatches.length == 1 ? areaMatches.single : null;
  }

  final matches = displays.where((display) => display.id == id).toList();
  if (matches.length == 1) return matches.single;

  final areaMatches = matches
      .where((display) => _sameRect(display.workArea, saved.workArea))
      .toList();
  if (areaMatches.isEmpty) return null;
  if (areaMatches.length == 1) return areaMatches.single;

  final scaleMatches = areaMatches
      .where((display) => display.scaleFactor == saved.scaleFactor)
      .toList();
  return scaleMatches.length == 1 ? scaleMatches.single : null;
}

bool _sameRect(Rect first, Rect second) {
  return first.left == second.left &&
      first.top == second.top &&
      first.right == second.right &&
      first.bottom == second.bottom;
}

double? _finiteDouble(Object? value) {
  if (value is! num || !value.isFinite) return null;
  return value.toDouble();
}

class _DisplayOverlap {
  const _DisplayOverlap(this.display, this.overlap);

  final WindowDisplay display;
  final double overlap;
}
