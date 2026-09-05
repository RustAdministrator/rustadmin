import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../common/quality_monitor_settings.dart';
import '../../consts.dart';

const mobileRemoteAccentColor = Color(0xFF0071FF);
const mobileRemoteAccentActiveColor = Color(0xAA0071FF);

Color mobileRemoteToolbarBackgroundColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? Colors.black
      : Colors.white;
}

Color mobileRemoteToolbarForegroundColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? Colors.white
      : Colors.black87;
}

Color mobileRemoteToolbarActiveBackgroundColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF616161)
      : const Color(0xFFBDBDBD);
}

Color mobileRemoteQuickKeyStripBackgroundColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0x80000000)
      : const Color(0x80FFFFFF);
}

Color mobileRemoteQuickKeyButtonBackgroundColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF424242)
      : const Color(0xFFE0E0E0);
}

enum MobileRemoteToolbarAxis { horizontal, vertical }

@immutable
class MobileRemoteToolbarPlacementSettings {
  const MobileRemoteToolbarPlacementSettings({
    required this.axis,
    required this.horizontalPosition,
    required this.verticalPosition,
  });

  static const defaults = MobileRemoteToolbarPlacementSettings(
    axis: MobileRemoteToolbarAxis.horizontal,
    horizontalPosition: 0.5,
    verticalPosition: 1.0,
  );

  final MobileRemoteToolbarAxis axis;
  final double horizontalPosition;
  final double verticalPosition;

  factory MobileRemoteToolbarPlacementSettings.fromStored(
    String value, {
    MobileRemoteToolbarPlacementSettings fallback = defaults,
  }) {
    final fields = value.split(',');
    if (fields.length != 3) return fallback;
    final axis = switch (fields[0]) {
      'vertical' => MobileRemoteToolbarAxis.vertical,
      'horizontal' => MobileRemoteToolbarAxis.horizontal,
      _ => fallback.axis,
    };
    final horizontalPosition = double.tryParse(fields[1]);
    final verticalPosition = double.tryParse(fields[2]);
    return MobileRemoteToolbarPlacementSettings(
      axis: axis,
      horizontalPosition: _normalizedPosition(
        horizontalPosition,
        fallback.horizontalPosition,
      ),
      verticalPosition: _normalizedPosition(
        verticalPosition,
        fallback.verticalPosition,
      ),
    );
  }

  static double _normalizedPosition(double? value, double fallback) {
    if (value == null || !value.isFinite) return fallback;
    return value.clamp(0.0, 1.0).toDouble();
  }

  String get storedValue =>
      '${axis == MobileRemoteToolbarAxis.vertical ? 'vertical' : 'horizontal'},'
      '${horizontalPosition.toStringAsFixed(6)},'
      '${verticalPosition.toStringAsFixed(6)}';

  MobileRemoteToolbarPlacementSettings copyWith({
    MobileRemoteToolbarAxis? axis,
    double? horizontalPosition,
    double? verticalPosition,
  }) => MobileRemoteToolbarPlacementSettings(
    axis: axis ?? this.axis,
    horizontalPosition: horizontalPosition ?? this.horizontalPosition,
    verticalPosition: verticalPosition ?? this.verticalPosition,
  );

  @override
  bool operator ==(Object other) =>
      other is MobileRemoteToolbarPlacementSettings &&
      other.axis == axis &&
      other.horizontalPosition == horizontalPosition &&
      other.verticalPosition == verticalPosition;

  @override
  int get hashCode => Object.hash(axis, horizontalPosition, verticalPosition);
}

@immutable
class MobileRemoteToolbarMonitor {
  const MobileRemoteToolbarMonitor({
    required this.value,
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
    this.allDisplays = false,
  });

  final int value;
  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback onPressed;
  final bool allDisplays;
}

@immutable
class MobileRemoteToolbarTransparencySettings {
  const MobileRemoteToolbarTransparencySettings({
    required this.overlapOpacityPercent,
  });

  static const defaults = MobileRemoteToolbarTransparencySettings(
    overlapOpacityPercent: kDefaultMobileRemoteToolbarOverlapOpacityPercent,
  );

  static const opacityPresets = <int>[10, 20, 40, 60, 80, 100];

  final int overlapOpacityPercent;

  double get overlapOpacity => overlapOpacityPercent / 100;

  factory MobileRemoteToolbarTransparencySettings.fromStored({
    required String overlapOpacityPercent,
    MobileRemoteToolbarTransparencySettings fallback = defaults,
  }) {
    final opacity = int.tryParse(overlapOpacityPercent);
    return MobileRemoteToolbarTransparencySettings(
      overlapOpacityPercent: (opacity ?? fallback.overlapOpacityPercent)
          .clamp(
            kMinMobileRemoteToolbarOverlapOpacityPercent,
            kMaxMobileRemoteToolbarOverlapOpacityPercent,
          )
          .toInt(),
    );
  }

  MobileRemoteToolbarTransparencySettings copyWith({
    int? overlapOpacityPercent,
  }) => MobileRemoteToolbarTransparencySettings(
    overlapOpacityPercent: overlapOpacityPercent ?? this.overlapOpacityPercent,
  );

  @override
  bool operator ==(Object other) =>
      other is MobileRemoteToolbarTransparencySettings &&
      other.overlapOpacityPercent == overlapOpacityPercent;

  @override
  int get hashCode => overlapOpacityPercent.hashCode;
}

@immutable
class MobileCursorInertiaSettings {
  const MobileCursorInertiaSettings({required this.durationMs});

  static const defaults = MobileCursorInertiaSettings(
    durationMs: kDefaultMobileCursorInertiaDurationMs,
  );

  final int durationMs;

  factory MobileCursorInertiaSettings.fromStored(
    String durationMs, {
    MobileCursorInertiaSettings fallback = defaults,
  }) {
    final duration = int.tryParse(durationMs);
    return MobileCursorInertiaSettings(
      durationMs: (duration ?? fallback.durationMs)
          .clamp(
            kMinMobileCursorInertiaDurationMs,
            kMaxMobileCursorInertiaDurationMs,
          )
          .toInt(),
    );
  }

  MobileCursorInertiaSettings copyWith({int? durationMs}) =>
      MobileCursorInertiaSettings(durationMs: durationMs ?? this.durationMs);

  @override
  bool operator ==(Object other) =>
      other is MobileCursorInertiaSettings && other.durationMs == durationMs;

  @override
  int get hashCode => durationMs.hashCode;
}

String normalizeMobileRemoteScrollStyle(String value) => switch (value) {
  kRemoteScrollStyleEdge => kRemoteScrollStyleEdge,
  kRemoteScrollStyleEdgeAcceleration => kRemoteScrollStyleEdgeAcceleration,
  _ => kRemoteScrollStyleAuto,
};

String mobileRemoteToolbarOpacityLabel(int percent) =>
    percent == 100 ? '100% (transparency disabled)' : '$percent%';

String mobileCursorInertiaDurationLabel(int durationMs) => '$durationMs ms';

class MobileCursorInertiaControl extends StatefulWidget {
  const MobileCursorInertiaControl({
    super.key,
    required this.durationMs,
    this.onChanged,
    this.onChangeEnd,
  });

  static const int stepMs = 50;

  final int durationMs;
  final ValueChanged<int>? onChanged;
  final ValueChanged<int>? onChangeEnd;

  @override
  State<MobileCursorInertiaControl> createState() =>
      _MobileCursorInertiaControlState();
}

class MobileRemoteIntegerSlider extends StatefulWidget {
  const MobileRemoteIntegerSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.unit,
    this.onChanged,
    this.onChangeEnd,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final int step;
  final String unit;
  final ValueChanged<int>? onChanged;
  final ValueChanged<int>? onChangeEnd;

  @override
  State<MobileRemoteIntegerSlider> createState() =>
      _MobileRemoteIntegerSliderState();
}

class _MobileRemoteIntegerSliderState extends State<MobileRemoteIntegerSlider> {
  late int _value = _normalize(widget.value);

  int _normalize(int value) {
    final clamped = value.clamp(widget.min, widget.max).toInt();
    final step = widget.step <= 0 ? 1 : widget.step;
    final snapped =
        widget.min + (((clamped - widget.min) / step).round() * step);
    return snapped.clamp(widget.min, widget.max).toInt();
  }

  String _valueLabel(int value) => '$value${widget.unit}';

  @override
  void didUpdateWidget(covariant MobileRemoteIntegerSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value ||
        oldWidget.min != widget.min ||
        oldWidget.max != widget.max ||
        oldWidget.step != widget.step) {
      _value = _normalize(widget.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.step <= 0 ? 1 : widget.step;
    final divisions = widget.max > widget.min
        ? ((widget.max - widget.min) / step).round()
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Text(widget.label)),
              const SizedBox(width: 8),
              Text(
                _valueLabel(_value),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
          Slider(
            value: _value.toDouble(),
            min: widget.min.toDouble(),
            max: widget.max.toDouble(),
            divisions: divisions,
            label: _valueLabel(_value),
            semanticFormatterCallback: (value) =>
                _valueLabel(_normalize(value.round())),
            onChanged: widget.onChanged == null
                ? null
                : (value) {
                    final normalized = _normalize(value.round());
                    setState(() => _value = normalized);
                    widget.onChanged?.call(normalized);
                  },
            onChangeEnd: widget.onChangeEnd == null
                ? null
                : (value) =>
                      widget.onChangeEnd?.call(_normalize(value.round())),
          ),
        ],
      ),
    );
  }
}

class MobileOverlayAppearanceControls extends StatefulWidget {
  const MobileOverlayAppearanceControls({
    super.key,
    required this.toolbarTitle,
    required this.toolbarOpacityLabel,
    required this.qualityMonitorTitle,
    required this.inactiveOpacityLabel,
    required this.fadeDelayLabel,
    required this.fadeDurationLabel,
    required this.toolbarSettings,
    required this.qualityMonitorSettings,
    required this.onToolbarChanged,
    required this.onToolbarChangeEnd,
    required this.onQualityMonitorChanged,
    required this.onQualityMonitorChangeEnd,
    this.toolbarEnabled = true,
    this.qualityMonitorOpacityEnabled = true,
    this.qualityMonitorDelayEnabled = true,
    this.qualityMonitorDurationEnabled = true,
  });

  final String toolbarTitle;
  final String toolbarOpacityLabel;
  final String qualityMonitorTitle;
  final String inactiveOpacityLabel;
  final String fadeDelayLabel;
  final String fadeDurationLabel;
  final MobileRemoteToolbarTransparencySettings toolbarSettings;
  final QualityMonitorFadeSettings qualityMonitorSettings;
  final ValueChanged<MobileRemoteToolbarTransparencySettings> onToolbarChanged;
  final ValueChanged<MobileRemoteToolbarTransparencySettings>
  onToolbarChangeEnd;
  final ValueChanged<QualityMonitorFadeSettings> onQualityMonitorChanged;
  final ValueChanged<QualityMonitorFadeSettings> onQualityMonitorChangeEnd;
  final bool toolbarEnabled;
  final bool qualityMonitorOpacityEnabled;
  final bool qualityMonitorDelayEnabled;
  final bool qualityMonitorDurationEnabled;

  @override
  State<MobileOverlayAppearanceControls> createState() =>
      _MobileOverlayAppearanceControlsState();
}

class _MobileOverlayAppearanceControlsState
    extends State<MobileOverlayAppearanceControls> {
  late var _toolbarSettings = widget.toolbarSettings;
  late var _qualityMonitorSettings = widget.qualityMonitorSettings;

  @override
  void didUpdateWidget(covariant MobileOverlayAppearanceControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.toolbarSettings != widget.toolbarSettings) {
      _toolbarSettings = widget.toolbarSettings;
    }
    if (oldWidget.qualityMonitorSettings != widget.qualityMonitorSettings) {
      _qualityMonitorSettings = widget.qualityMonitorSettings;
    }
  }

  void _updateToolbar(int opacityPercent, {required bool commit}) {
    final settings = _toolbarSettings.copyWith(
      overlapOpacityPercent: opacityPercent,
    );
    setState(() => _toolbarSettings = settings);
    if (commit) {
      widget.onToolbarChangeEnd(settings);
    } else {
      widget.onToolbarChanged(settings);
    }
  }

  void _updateQualityMonitor(
    QualityMonitorFadeSettings settings, {
    required bool commit,
  }) {
    setState(() => _qualityMonitorSettings = settings);
    if (commit) {
      widget.onQualityMonitorChangeEnd(settings);
    } else {
      widget.onQualityMonitorChanged(settings);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.toolbarTitle,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        MobileRemoteIntegerSlider(
          key: const Key('mobile-toolbar-opacity-slider'),
          label: widget.toolbarOpacityLabel,
          value: _toolbarSettings.overlapOpacityPercent,
          min: kMinMobileRemoteToolbarOverlapOpacityPercent,
          max: kMaxMobileRemoteToolbarOverlapOpacityPercent,
          step: 5,
          unit: '%',
          onChanged: widget.toolbarEnabled
              ? (value) => _updateToolbar(value, commit: false)
              : null,
          onChangeEnd: widget.toolbarEnabled
              ? (value) => _updateToolbar(value, commit: true)
              : null,
        ),
        const Divider(),
        Text(
          widget.qualityMonitorTitle,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        MobileRemoteIntegerSlider(
          key: const Key('mobile-quality-monitor-opacity-slider'),
          label: widget.inactiveOpacityLabel,
          value: _qualityMonitorSettings.opacityPercent,
          min: kMinQualityMonitorInactiveOpacityPercent,
          max: kMaxQualityMonitorInactiveOpacityPercent,
          step: 5,
          unit: '%',
          onChanged: widget.qualityMonitorOpacityEnabled
              ? (value) => _updateQualityMonitor(
                  _qualityMonitorSettings.copyWith(opacityPercent: value),
                  commit: false,
                )
              : null,
          onChangeEnd: widget.qualityMonitorOpacityEnabled
              ? (value) => _updateQualityMonitor(
                  _qualityMonitorSettings.copyWith(opacityPercent: value),
                  commit: true,
                )
              : null,
        ),
        MobileRemoteIntegerSlider(
          key: const Key('mobile-quality-monitor-delay-slider'),
          label: widget.fadeDelayLabel,
          value: _qualityMonitorSettings.delayMs,
          min: kMinQualityMonitorDimDelayMs,
          max: kMaxQualityMonitorDimDelayMs,
          step: 100,
          unit: ' ms',
          onChanged: widget.qualityMonitorDelayEnabled
              ? (value) => _updateQualityMonitor(
                  _qualityMonitorSettings.copyWith(delayMs: value),
                  commit: false,
                )
              : null,
          onChangeEnd: widget.qualityMonitorDelayEnabled
              ? (value) => _updateQualityMonitor(
                  _qualityMonitorSettings.copyWith(delayMs: value),
                  commit: true,
                )
              : null,
        ),
        MobileRemoteIntegerSlider(
          key: const Key('mobile-quality-monitor-duration-slider'),
          label: widget.fadeDurationLabel,
          value: _qualityMonitorSettings.durationMs,
          min: kMinQualityMonitorDimDurationMs,
          max: kMaxQualityMonitorDimDurationMs,
          step: 100,
          unit: ' ms',
          onChanged: widget.qualityMonitorDurationEnabled
              ? (value) => _updateQualityMonitor(
                  _qualityMonitorSettings.copyWith(durationMs: value),
                  commit: false,
                )
              : null,
          onChangeEnd: widget.qualityMonitorDurationEnabled
              ? (value) => _updateQualityMonitor(
                  _qualityMonitorSettings.copyWith(durationMs: value),
                  commit: true,
                )
              : null,
        ),
      ],
    );
  }
}

class _MobileCursorInertiaControlState
    extends State<MobileCursorInertiaControl> {
  late int _durationMs = _normalized(widget.durationMs);

  int _normalized(int value) => value
      .clamp(
        kMinMobileCursorInertiaDurationMs,
        kMaxMobileCursorInertiaDurationMs,
      )
      .toInt();

  @override
  void didUpdateWidget(covariant MobileCursorInertiaControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.durationMs != widget.durationMs) {
      _durationMs = _normalized(widget.durationMs);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Text(mobileCursorInertiaDurationLabel(_durationMs)),
        ),
        Semantics(
          label: 'Cursor inertia time',
          value: mobileCursorInertiaDurationLabel(_durationMs),
          child: Slider(
            key: const Key('mobile-cursor-inertia-slider'),
            value: _durationMs.toDouble(),
            min: kMinMobileCursorInertiaDurationMs.toDouble(),
            max: kMaxMobileCursorInertiaDurationMs.toDouble(),
            divisions:
                (kMaxMobileCursorInertiaDurationMs -
                    kMinMobileCursorInertiaDurationMs) ~/
                MobileCursorInertiaControl.stepMs,
            label: mobileCursorInertiaDurationLabel(_durationMs),
            semanticFormatterCallback: (value) =>
                mobileCursorInertiaDurationLabel(value.round()),
            onChanged: widget.onChanged == null
                ? null
                : (value) {
                    final durationMs = value.round();
                    setState(() => _durationMs = durationMs);
                    widget.onChanged!(durationMs);
                  },
            onChangeEnd: widget.onChangeEnd == null
                ? null
                : (value) => widget.onChangeEnd!(value.round()),
          ),
        ),
      ],
    );
  }
}

Rect mobileRemoteToolbarOverlapRect({
  required Rect toolbarRect,
  required double toolbarThickness,
}) => toolbarRect.inflate(toolbarThickness.clamp(0.0, double.infinity) / 2);

class MobileRemoteToolbar extends StatefulWidget {
  const MobileRemoteToolbar({
    super.key,
    required this.onDisconnect,
    required this.onOptions,
    required this.onMore,
    required this.showInputControls,
    required this.peerIsAndroid,
    required this.touchMode,
    required this.waitForFirstImage,
    required this.qualityMonitorVisible,
    required this.onQualityMonitor,
    this.onKeyboard,
    this.onGestureHelp,
    this.onMobileActions,
    this.chatButton,
    this.monitors = const [],
    this.cursorPosition,
    this.transparencySettings =
        MobileRemoteToolbarTransparencySettings.defaults,
    this.placementSettings = MobileRemoteToolbarPlacementSettings.defaults,
    this.onPlacementChanged,
    this.qualityMonitorTooltip = 'Quality monitor',
  });

  final VoidCallback onDisconnect;
  final VoidCallback onOptions;
  final VoidCallback onMore;
  final bool showInputControls;
  final bool peerIsAndroid;
  final bool touchMode;
  final bool waitForFirstImage;
  final bool qualityMonitorVisible;
  final VoidCallback onQualityMonitor;
  final VoidCallback? onKeyboard;
  final VoidCallback? onGestureHelp;
  final VoidCallback? onMobileActions;
  final Widget? chatButton;
  final List<MobileRemoteToolbarMonitor> monitors;
  final Offset? cursorPosition;
  final MobileRemoteToolbarTransparencySettings transparencySettings;
  final MobileRemoteToolbarPlacementSettings placementSettings;
  final ValueChanged<MobileRemoteToolbarPlacementSettings>? onPlacementChanged;
  final String qualityMonitorTooltip;

  @override
  State<MobileRemoteToolbar> createState() => _MobileRemoteToolbarState();
}

class _MobileRemoteToolbarState extends State<MobileRemoteToolbar> {
  static const _iconSize = 24.0;
  static const _maximumButtonExtent = 48.0;
  static const _maximumVerticalButtonExtent =
      _iconSize + (_maximumButtonExtent - _iconSize) * 0.5;

  var _collapsed = false;
  late var _placementSettings = widget.placementSettings;

  bool get _vertical =>
      _placementSettings.axis == MobileRemoteToolbarAxis.vertical;

  bool get _collapseTowardPositiveEdge => _vertical
      ? _placementSettings.horizontalPosition >= 0.5
      : _placementSettings.verticalPosition >= 0.5;

  IconData get _collapseIcon {
    if (_vertical) {
      return _collapseTowardPositiveEdge
          ? Icons.keyboard_arrow_right
          : Icons.keyboard_arrow_left;
    }
    return _collapseTowardPositiveEdge
        ? Icons.keyboard_arrow_down
        : Icons.keyboard_arrow_up;
  }

  IconData get _expandIcon {
    if (_vertical) {
      return _collapseTowardPositiveEdge
          ? Icons.keyboard_arrow_left
          : Icons.keyboard_arrow_right;
    }
    return _collapseTowardPositiveEdge
        ? Icons.keyboard_arrow_up
        : Icons.keyboard_arrow_down;
  }

  @override
  void didUpdateWidget(covariant MobileRemoteToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.placementSettings != widget.placementSettings &&
        widget.placementSettings != _placementSettings) {
      _placementSettings = widget.placementSettings;
    }
  }

  Offset _position(BoxConstraints constraints, Size toolbarSize) {
    final maxLeft = (constraints.maxWidth - toolbarSize.width)
        .clamp(0.0, double.infinity)
        .toDouble();
    final maxTop = (constraints.maxHeight - toolbarSize.height)
        .clamp(0.0, double.infinity)
        .toDouble();
    return Offset(
      maxLeft * _placementSettings.horizontalPosition,
      maxTop * _placementSettings.verticalPosition,
    );
  }

  Offset _clampPosition(
    Offset position,
    BoxConstraints constraints,
    Size toolbarSize,
  ) {
    final maxLeft = (constraints.maxWidth - toolbarSize.width)
        .clamp(0.0, double.infinity)
        .toDouble();
    final maxTop = (constraints.maxHeight - toolbarSize.height)
        .clamp(0.0, double.infinity)
        .toDouble();
    return Offset(
      position.dx.clamp(0.0, maxLeft).toDouble(),
      position.dy.clamp(0.0, maxTop).toDouble(),
    );
  }

  void _updateToolbarPosition(
    DragUpdateDetails details,
    BoxConstraints constraints,
    Size toolbarSize,
  ) {
    final currentPosition = _clampPosition(
      _position(constraints, toolbarSize),
      constraints,
      toolbarSize,
    );
    final nextPosition = _clampPosition(
      currentPosition + details.delta,
      constraints,
      toolbarSize,
    );
    final maxLeft = (constraints.maxWidth - toolbarSize.width)
        .clamp(0.0, double.infinity)
        .toDouble();
    final maxTop = (constraints.maxHeight - toolbarSize.height)
        .clamp(0.0, double.infinity)
        .toDouble();
    setState(() {
      _placementSettings = _placementSettings.copyWith(
        horizontalPosition: maxLeft == 0
            ? _placementSettings.horizontalPosition
            : nextPosition.dx / maxLeft,
        verticalPosition: maxTop == 0
            ? _placementSettings.verticalPosition
            : nextPosition.dy / maxTop,
      );
    });
  }

  void _commitPlacement() {
    widget.onPlacementChanged?.call(_placementSettings);
  }

  Widget _iconButton({
    required double extent,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return SizedBox.square(
      dimension: extent,
      child: IconButton(
        tooltip: tooltip,
        color: mobileRemoteToolbarForegroundColor(context),
        iconSize: _iconSize,
        padding: EdgeInsets.zero,
        splashRadius: extent / 2,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    );
  }

  Widget _itemSlot(Widget child, double extent) {
    return SizedBox.square(
      dimension: extent,
      child: IconButtonTheme(
        data: IconButtonThemeData(
          style: ButtonStyle(
            fixedSize: WidgetStatePropertyAll(Size.square(extent)),
            padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            iconSize: const WidgetStatePropertyAll(_iconSize),
            foregroundColor: WidgetStatePropertyAll(
              mobileRemoteToolbarForegroundColor(context),
            ),
          ),
        ),
        child: child,
      ),
    );
  }

  Widget _orientationButton(double extent) {
    return SizedBox.square(
      dimension: extent,
      child: IconButton(
        tooltip: _vertical ? 'Horizontal toolbar' : 'Vertical toolbar',
        color: mobileRemoteToolbarForegroundColor(context),
        padding: EdgeInsets.zero,
        splashRadius: extent / 2,
        onPressed: () {
          final placementSettings = _placementSettings.copyWith(
            axis: _vertical
                ? MobileRemoteToolbarAxis.horizontal
                : MobileRemoteToolbarAxis.vertical,
          );
          setState(() {
            _placementSettings = placementSettings;
          });
          widget.onPlacementChanged?.call(placementSettings);
        },
        icon: Text(
          _vertical ? 'V' : 'H',
          style: TextStyle(
            color: mobileRemoteToolbarForegroundColor(context),
            fontWeight: FontWeight.w700,
            fontSize: 15,
            height: 1,
          ),
        ),
      ),
    );
  }

  Widget _monitorButton(MobileRemoteToolbarMonitor monitor, double extent) {
    final foreground = monitor.selected
        ? mobileRemoteAccentColor
        : mobileRemoteToolbarForegroundColor(context);
    return SizedBox.square(
      dimension: extent,
      child: IconButton(
        key: ValueKey('mobile-remote-monitor-${monitor.value}'),
        tooltip: monitor.tooltip,
        color: foreground,
        iconSize: _iconSize,
        padding: EdgeInsets.zero,
        splashRadius: extent / 2,
        onPressed: monitor.onPressed,
        icon: monitor.allDisplays
            ? const Icon(Icons.grid_view)
            : Stack(
                alignment: Alignment.center,
                children: [
                  const Icon(Icons.desktop_windows_outlined, size: 27),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: SizedBox(
                      width: 14,
                      height: 10,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          monitor.label,
                          key: ValueKey(
                            'mobile-remote-monitor-label-${monitor.value}',
                          ),
                          style: TextStyle(
                            color: foreground,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _qualityMonitorButton(double extent) {
    final foreground = widget.qualityMonitorVisible
        ? mobileRemoteAccentColor
        : mobileRemoteToolbarForegroundColor(context);
    return Semantics(
      button: true,
      toggled: widget.qualityMonitorVisible,
      label: widget.qualityMonitorTooltip,
      child: SizedBox.square(
        dimension: extent,
        child: IconButton(
          key: const Key('mobile-remote-quality-monitor'),
          tooltip: widget.qualityMonitorTooltip,
          color: foreground,
          padding: EdgeInsets.zero,
          splashRadius: extent / 2,
          onPressed: widget.onQualityMonitor,
          icon: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1,
            child: Text(
              'QM',
              style: TextStyle(
                color: foreground,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _expandedItems(double extent) {
    final items = <Widget>[
      _iconButton(
        extent: extent,
        tooltip: 'Collapse toolbar',
        icon: _collapseIcon,
        onPressed: widget.waitForFirstImage
            ? null
            : () {
                setState(() {
                  _collapsed = true;
                });
              },
      ),
      _iconButton(
        extent: extent,
        tooltip: 'Display and session options',
        icon: Icons.tv,
        onPressed: widget.onOptions,
      ),
      _qualityMonitorButton(extent),
      for (final monitor in widget.monitors) _monitorButton(monitor, extent),
    ];
    if (widget.showInputControls) {
      items.add(
        _iconButton(
          extent: extent,
          tooltip: 'Keyboard',
          icon: Icons.keyboard,
          onPressed: widget.onKeyboard,
        ),
      );
      items.add(
        _iconButton(
          extent: extent,
          tooltip: widget.peerIsAndroid
              ? 'Android actions'
              : (widget.touchMode ? 'Touch mode' : 'Mouse mode'),
          icon: widget.peerIsAndroid
              ? Icons.build
              : (widget.touchMode ? Icons.touch_app : Icons.mouse),
          onPressed: widget.peerIsAndroid
              ? widget.onMobileActions
              : widget.onGestureHelp,
        ),
      );
    }
    final chatButton = widget.chatButton;
    if (chatButton != null) {
      items.add(_itemSlot(chatButton, extent));
    }
    items.addAll([
      _iconButton(
        extent: extent,
        tooltip: 'More actions',
        icon: Icons.more_vert,
        onPressed: widget.onMore,
      ),
      _orientationButton(extent),
      _iconButton(
        extent: extent,
        tooltip: 'Disconnect',
        icon: Icons.clear,
        onPressed: widget.onDisconnect,
      ),
    ]);
    return items;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemCount = _collapsed ? 1 : _expandedItems(1).length;
        final availableExtent = _vertical
            ? constraints.maxHeight
            : constraints.maxWidth;
        final maximumExtent = _vertical
            ? _maximumVerticalButtonExtent
            : _maximumButtonExtent;
        final extent = availableExtent.isFinite && availableExtent > 0
            ? (availableExtent / itemCount).clamp(0.0, maximumExtent)
            : maximumExtent;
        final items = _collapsed
            ? [
                _iconButton(
                  extent: extent,
                  tooltip: 'Show toolbar',
                  icon: _expandIcon,
                  onPressed: () {
                    setState(() {
                      _collapsed = false;
                    });
                  },
                ),
              ]
            : _expandedItems(extent);
        final toolbarSize = _vertical
            ? Size(extent, extent * itemCount)
            : Size(extent * itemCount, extent);
        final position = _clampPosition(
          _position(constraints, toolbarSize),
          constraints,
          toolbarSize,
        );
        final toolbarRect = position & toolbarSize;
        final toolbarOverlapRect = mobileRemoteToolbarOverlapRect(
          toolbarRect: toolbarRect,
          toolbarThickness: extent,
        );
        final qualityMonitorButtonOffset = _vertical
            ? Offset(0, extent * 2)
            : Offset(extent * 2, 0);
        final qualityMonitorButtonRect =
            (position + qualityMonitorButtonOffset) & Size.square(extent);
        final cursorOverlapsActiveQualityMonitor =
            widget.qualityMonitorVisible &&
            widget.cursorPosition != null &&
            qualityMonitorButtonRect.contains(widget.cursorPosition!);
        final cursorOverlapsToolbar =
            widget.cursorPosition != null &&
            toolbarOverlapRect.contains(widget.cursorPosition!) &&
            !cursorOverlapsActiveQualityMonitor;
        final toolbarOpacity = cursorOverlapsToolbar
            ? widget.transparencySettings.overlapOpacity
            : 1.0;

        return Stack(
          children: [
            Positioned(
              left: position.dx,
              top: position.dy,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (details) =>
                    _updateToolbarPosition(details, constraints, toolbarSize),
                onPanEnd: (_) => _commitPlacement(),
                onPanCancel: _commitPlacement,
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    key: const Key('mobile-remote-toolbar-opacity'),
                    duration: Duration.zero,
                    opacity: toolbarOpacity,
                    child: Material(
                      key: const Key('mobile-remote-floating-toolbar'),
                      color: mobileRemoteToolbarBackgroundColor(context),
                      elevation: 6,
                      shadowColor: Colors.black54,
                      clipBehavior: Clip.antiAlias,
                      shape: StadiumBorder(
                        side: BorderSide(
                          color: mobileRemoteToolbarForegroundColor(context),
                        ),
                      ),
                      child: Flex(
                        direction: _vertical ? Axis.vertical : Axis.horizontal,
                        mainAxisSize: MainAxisSize.min,
                        children: items,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class MobileRemoteAndroidActionsBar extends StatelessWidget {
  const MobileRemoteAndroidActionsBar({
    super.key,
    required this.scale,
    this.onBack,
    this.onHome,
    this.onRecent,
    this.onHide,
    this.splashRadius,
  });

  final double scale;
  final VoidCallback? onBack;
  final VoidCallback? onHome;
  final VoidCallback? onRecent;
  final VoidCallback? onHide;
  final double? splashRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: mobileRemoteAccentColor.withValues(alpha: 0.4),
        borderRadius: BorderRadius.all(Radius.circular(4 * scale)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          IconButton(
            tooltip: 'Back',
            color: Colors.white,
            onPressed: onBack,
            splashRadius: splashRadius,
            icon: const Icon(Icons.arrow_back),
            iconSize: 24 * scale,
          ),
          IconButton(
            tooltip: 'Home',
            color: Colors.white,
            onPressed: onHome,
            splashRadius: splashRadius,
            icon: const Icon(Icons.home),
            iconSize: 24 * scale,
          ),
          IconButton(
            tooltip: 'Recent apps',
            color: Colors.white,
            onPressed: onRecent,
            splashRadius: splashRadius,
            icon: const Icon(Icons.more_horiz),
            iconSize: 24 * scale,
          ),
          const VerticalDivider(
            width: 0,
            thickness: 2,
            indent: 10,
            endIndent: 10,
          ),
          IconButton(
            tooltip: 'Hide Android actions',
            color: Colors.white,
            onPressed: onHide,
            splashRadius: splashRadius,
            icon: const Icon(Icons.keyboard_arrow_down),
            iconSize: 24 * scale,
          ),
        ],
      ),
    );
  }
}

enum MobileRemoteQuickKey {
  ctrl,
  alt,
  shift,
  command,
  functionKeys,
  extendedKeys,
}

const mobileRemoteDefaultQuickKeyOrder = <MobileRemoteQuickKey>[
  MobileRemoteQuickKey.ctrl,
  MobileRemoteQuickKey.alt,
  MobileRemoteQuickKey.shift,
  MobileRemoteQuickKey.command,
  MobileRemoteQuickKey.functionKeys,
  MobileRemoteQuickKey.extendedKeys,
];

String mobileRemoteQuickKeyLabel(
  MobileRemoteQuickKey key, {
  required bool isMac,
}) {
  return switch (key) {
    MobileRemoteQuickKey.ctrl => 'Ctrl',
    MobileRemoteQuickKey.alt => 'Alt',
    MobileRemoteQuickKey.shift => 'Shift',
    MobileRemoteQuickKey.command => isMac ? 'Cmd' : 'Win',
    MobileRemoteQuickKey.functionKeys => 'Fn',
    MobileRemoteQuickKey.extendedKeys => '...',
  };
}

class MobileRemoteKeyHelpTools extends StatelessWidget {
  const MobileRemoteKeyHelpTools({
    super.key,
    required this.ctrlActive,
    required this.altActive,
    required this.shiftActive,
    required this.commandActive,
    required this.functionKeysActive,
    required this.moreKeysActive,
    required this.isMac,
    required this.showWindowsLinuxKeys,
    required this.quickKeyOrder,
    required this.onCtrl,
    required this.onAlt,
    required this.onShift,
    required this.onCommand,
    required this.onFunctionKeys,
    required this.onMoreKeys,
    required this.onKeyPressed,
    required this.onShortcutPressed,
    this.ctrlLocked = false,
    this.altLocked = false,
    this.shiftLocked = false,
    this.commandLocked = false,
    this.onCtrlDoubleTap,
    this.onAltDoubleTap,
    this.onShiftDoubleTap,
    this.onCommandDoubleTap,
    this.labelBuilder,
  });

  final bool ctrlActive;
  final bool altActive;
  final bool shiftActive;
  final bool commandActive;
  final bool ctrlLocked;
  final bool altLocked;
  final bool shiftLocked;
  final bool commandLocked;
  final bool functionKeysActive;
  final bool moreKeysActive;
  final bool isMac;
  final bool showWindowsLinuxKeys;
  final List<MobileRemoteQuickKey> quickKeyOrder;
  final VoidCallback onCtrl;
  final VoidCallback onAlt;
  final VoidCallback onShift;
  final VoidCallback onCommand;
  final VoidCallback? onCtrlDoubleTap;
  final VoidCallback? onAltDoubleTap;
  final VoidCallback? onShiftDoubleTap;
  final VoidCallback? onCommandDoubleTap;
  final VoidCallback onFunctionKeys;
  final VoidCallback onMoreKeys;
  final ValueChanged<String> onKeyPressed;
  final ValueChanged<String> onShortcutPressed;
  final String Function(String)? labelBuilder;

  String _label(String value) => labelBuilder?.call(value) ?? value;

  Widget _button(
    BuildContext context,
    String text,
    VoidCallback onPressed, {
    bool? active,
    bool locked = false,
    VoidCallback? onDoublePressed,
    IconData? icon,
    double iconSize = 18,
    String? svgAsset,
    String? semanticLabel,
  }) {
    assert(!locked || active == true);
    assert(icon == null || svgAsset == null);
    final label = _label(semanticLabel ?? text);
    final foregroundColor = locked
        ? Colors.white
        : mobileRemoteToolbarForegroundColor(context);
    final Widget content;
    if (icon != null) {
      content = Icon(
        icon,
        size: iconSize,
        color: foregroundColor,
        // Physical key directions must not mirror with the local UI language.
        textDirection: TextDirection.ltr,
      );
    } else if (svgAsset != null) {
      content = SvgPicture.asset(
        svgAsset,
        width: 18,
        height: 18,
        colorFilter: ColorFilter.mode(foregroundColor, BlendMode.srcIn),
        excludeFromSemantics: true,
      );
    } else {
      content = Text(
        _label(text),
        textAlign: TextAlign.center,
        style: TextStyle(color: foregroundColor, fontSize: 10),
      );
    }
    return SizedBox.square(
      dimension: 36 * 1.1,
      child: Semantics(
        label: label,
        button: true,
        toggled: active,
        value: locked ? _label('Locked') : null,
        onTap: onPressed,
        excludeSemantics: true,
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: Material(
            color: locked
                ? mobileRemoteAccentColor
                : active == true
                ? mobileRemoteToolbarActiveBackgroundColor(context)
                : mobileRemoteQuickKeyButtonBackgroundColor(context),
            borderRadius: BorderRadius.circular(4),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              onDoubleTap: onDoublePressed,
              child: Center(child: content),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const spacing = 4.0;
    final quickButtons = <MobileRemoteQuickKey, Widget>{
      MobileRemoteQuickKey.ctrl: KeyedSubtree(
        key: const Key('mobile-remote-quick-ctrl'),
        child: _button(
          context,
          mobileRemoteQuickKeyLabel(MobileRemoteQuickKey.ctrl, isMac: isMac),
          onCtrl,
          active: ctrlActive,
          locked: ctrlLocked,
          onDoublePressed: onCtrlDoubleTap,
          icon: isMac ? Icons.keyboard_control_key : null,
          semanticLabel: 'Control',
        ),
      ),
      MobileRemoteQuickKey.alt: KeyedSubtree(
        key: const Key('mobile-remote-quick-alt'),
        child: _button(
          context,
          mobileRemoteQuickKeyLabel(MobileRemoteQuickKey.alt, isMac: isMac),
          onAlt,
          active: altActive,
          locked: altLocked,
          onDoublePressed: onAltDoubleTap,
          icon: isMac ? Icons.keyboard_option_key : null,
          semanticLabel: isMac ? 'Option' : 'Alt',
        ),
      ),
      MobileRemoteQuickKey.shift: KeyedSubtree(
        key: const Key('mobile-remote-quick-shift'),
        child: _button(
          context,
          mobileRemoteQuickKeyLabel(MobileRemoteQuickKey.shift, isMac: isMac),
          onShift,
          active: shiftActive,
          locked: shiftLocked,
          onDoublePressed: onShiftDoubleTap,
          svgAsset: 'assets/keyboard_shift.svg',
        ),
      ),
      MobileRemoteQuickKey.command: KeyedSubtree(
        key: const Key('mobile-remote-quick-command'),
        child: _button(
          context,
          mobileRemoteQuickKeyLabel(MobileRemoteQuickKey.command, isMac: isMac),
          onCommand,
          active: commandActive,
          locked: commandLocked,
          onDoublePressed: onCommandDoubleTap,
          icon: isMac ? Icons.keyboard_command_key : null,
          svgAsset: isMac ? null : 'assets/win.svg',
          semanticLabel: isMac ? 'Command' : 'Windows',
        ),
      ),
      MobileRemoteQuickKey.functionKeys: KeyedSubtree(
        key: const Key('mobile-remote-quick-function-keys'),
        child: _button(
          context,
          mobileRemoteQuickKeyLabel(
            MobileRemoteQuickKey.functionKeys,
            isMac: isMac,
          ),
          onFunctionKeys,
          active: functionKeysActive,
          semanticLabel: 'Function keys',
        ),
      ),
      MobileRemoteQuickKey.extendedKeys: KeyedSubtree(
        key: const Key('mobile-remote-quick-extended-keys'),
        child: _button(
          context,
          mobileRemoteQuickKeyLabel(
            MobileRemoteQuickKey.extendedKeys,
            isMac: isMac,
          ),
          onMoreKeys,
          active: moreKeysActive,
          semanticLabel: 'More keys',
        ),
      ),
    };
    final expandedKeys = <Widget>[];
    if (functionKeysActive) {
      for (var index = 1; index <= 12; index++) {
        final name = 'F$index';
        expandedKeys.add(
          _button(context, name, () => onKeyPressed('VK_$name')),
        );
      }
    } else if (moreKeysActive) {
      expandedKeys.addAll([
        _button(context, 'Esc', () => onKeyPressed('VK_ESCAPE')),
        _button(
          context,
          'Tab',
          () => onKeyPressed('VK_TAB'),
          icon: Icons.keyboard_tab,
        ),
        _button(
          context,
          'Home',
          () => onKeyPressed('VK_HOME'),
          icon: Icons.first_page,
        ),
        _button(
          context,
          'End',
          () => onKeyPressed('VK_END'),
          icon: Icons.last_page,
        ),
        _button(context, 'Ins', () => onKeyPressed('VK_INSERT')),
        _button(context, 'Del', () => onKeyPressed('VK_DELETE')),
        _button(
          context,
          'PgUp',
          () => onKeyPressed('VK_PRIOR'),
          icon: Icons.keyboard_double_arrow_up,
          semanticLabel: 'Page Up',
        ),
        _button(
          context,
          'PgDn',
          () => onKeyPressed('VK_NEXT'),
          icon: Icons.keyboard_double_arrow_down,
          semanticLabel: 'Page Down',
        ),
        if (showWindowsLinuxKeys)
          _button(context, 'PrtScr', () => onKeyPressed('VK_SNAPSHOT')),
        if (showWindowsLinuxKeys)
          _button(context, 'ScrollLock', () => onKeyPressed('VK_SCROLL')),
        if (showWindowsLinuxKeys)
          _button(context, 'Pause', () => onKeyPressed('VK_PAUSE')),
        if (showWindowsLinuxKeys)
          _button(context, 'Menu', () => onKeyPressed('Apps')),
        _button(
          context,
          'Enter',
          () => onKeyPressed('VK_ENTER'),
          icon: Icons.keyboard_return,
        ),
        _button(
          context,
          'Left',
          () => onKeyPressed('VK_LEFT'),
          icon: Icons.arrow_left,
          // Filled triangles occupy less of the font's box than other icons.
          iconSize: 28,
        ),
        _button(
          context,
          'Up',
          () => onKeyPressed('VK_UP'),
          icon: Icons.arrow_drop_up,
          iconSize: 28,
        ),
        _button(
          context,
          'Down',
          () => onKeyPressed('VK_DOWN'),
          icon: Icons.arrow_drop_down,
          iconSize: 28,
        ),
        _button(
          context,
          'Right',
          () => onKeyPressed('VK_RIGHT'),
          icon: Icons.arrow_right,
          iconSize: 28,
        ),
        _button(
          context,
          isMac ? 'Cmd+C' : 'Ctrl+C',
          () => onShortcutPressed('VK_C'),
        ),
        _button(
          context,
          isMac ? 'Cmd+V' : 'Ctrl+V',
          () => onShortcutPressed('VK_V'),
        ),
        _button(
          context,
          isMac ? 'Cmd+S' : 'Ctrl+S',
          () => onShortcutPressed('VK_S'),
        ),
      ]);
    }

    final allButtons = <Widget>[
      for (final key in quickKeyOrder) quickButtons[key]!,
      ...expandedKeys,
    ];
    return Container(
      key: const Key('mobile-remote-key-help-strip'),
      color: mobileRemoteQuickKeyStripBackgroundColor(context),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: _MobileKeyHelpScrollStrip(buttons: allButtons, spacing: spacing),
    );
  }
}

class _MobileKeyHelpScrollStrip extends StatefulWidget {
  const _MobileKeyHelpScrollStrip({
    required this.buttons,
    required this.spacing,
  });

  final List<Widget> buttons;
  final double spacing;

  @override
  State<_MobileKeyHelpScrollStrip> createState() =>
      _MobileKeyHelpScrollStripState();
}

class _MobileKeyHelpScrollStripState extends State<_MobileKeyHelpScrollStrip> {
  final ScrollController _controller = ScrollController();
  int? _dragPointer;
  Offset? _lastPointerPosition;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    _dragPointer = event.pointer;
    _lastPointerPosition = event.position;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _dragPointer || !_controller.hasClients) return;
    final last = _lastPointerPosition;
    _lastPointerPosition = event.position;
    if (last == null) return;
    final position = _controller.position;
    final target = (position.pixels - (event.position.dx - last.dx))
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    _controller.jumpTo(target);
  }

  void _onPointerEnd(PointerEvent event) {
    if (event.pointer != _dragPointer) return;
    _dragPointer = null;
    _lastPointerPosition = null;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    final position = _controller.position;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    final target = (position.pixels + delta)
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    _controller.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      onPointerSignal: _onPointerSignal,
      child: SingleChildScrollView(
        key: const Key('mobile-remote-key-help-scroll'),
        controller: _controller,
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < widget.buttons.length; index++) ...[
              if (index > 0) SizedBox(width: widget.spacing),
              widget.buttons[index],
            ],
          ],
        ),
      ),
    );
  }
}

class MobileRemoteMenuItem {
  const MobileRemoteMenuItem({
    required this.child,
    required this.onPressed,
    this.dividerBefore = false,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final bool dividerBefore;
}

Future<void> showMobileRemotePopupMenu(
  BuildContext context,
  List<MobileRemoteMenuItem> items,
) async {
  final size = MediaQuery.sizeOf(context);
  const x = 120.0;
  final menuEntries = <PopupMenuEntry<int>>[];
  final callbacks = <VoidCallback?>[];

  for (final item in items) {
    if (item.dividerBefore && menuEntries.isNotEmpty) {
      menuEntries.add(const PopupMenuDivider());
    }
    final index = callbacks.length;
    callbacks.add(item.onPressed);
    menuEntries.add(
      PopupMenuItem<int>(
        value: index,
        enabled: item.onPressed != null,
        child: item.child,
      ),
    );
  }

  if (menuEntries.isEmpty) {
    return;
  }
  final selected = await showMenu<int>(
    context: context,
    position: RelativeRect.fromLTRB(x, size.height, x, size.height),
    items: menuEntries,
    elevation: 8,
  );
  if (selected != null && selected < callbacks.length) {
    callbacks[selected]?.call();
  }
}

class MobileRemoteRadioItem {
  const MobileRemoteRadioItem({
    required this.value,
    required this.child,
    required this.onChanged,
    this.commitSelection = true,
  });

  final String value;
  final Widget child;
  final ValueChanged<String?>? onChanged;
  final bool commitSelection;
}

class MobileRemoteRadioSection {
  const MobileRemoteRadioSection({
    required this.id,
    required this.value,
    required this.items,
    this.heading,
    this.submenuId,
    this.selectionDetailsBuilder,
    this.content,
    this.dividerAfter = true,
  }) : assert(items.length > 0 || content != null);

  final String id;
  final String value;
  final List<MobileRemoteRadioItem> items;
  final Widget? heading;
  final String? submenuId;
  final Widget Function(String value)? selectionDetailsBuilder;
  final Widget? content;
  final bool dividerAfter;

  String get resolvedSubmenuId => submenuId ?? id;
}

class MobileRemoteToggleItem {
  const MobileRemoteToggleItem({
    required this.id,
    required this.value,
    required this.child,
    required this.onChanged,
    this.dividerBefore = false,
  });

  final String id;
  final bool value;
  final Widget child;
  final ValueChanged<bool?>? onChanged;
  final bool dividerBefore;
}

bool mobileVmPhysicalInputEnabled(String storedValue) =>
    storedValue.toUpperCase() != 'N';

String mobileVmPhysicalInputOption(bool enabled) => enabled ? 'Y' : 'N';

String mobileKeyboardInputV2Mode(String storedValue, String legacyPhysical) {
  switch (storedValue.toLowerCase()) {
    case kKeyboardInputModeText:
    case kKeyboardInputModePhysical:
    case kKeyboardInputModeAuto:
      return storedValue.toLowerCase();
    default:
      return mobileVmPhysicalInputEnabled(legacyPhysical)
          ? kKeyboardInputModeAuto
          : kKeyboardInputModeText;
  }
}

class MobileCommittedTextEdit {
  const MobileCommittedTextEdit({
    required this.text,
    required this.deleteBeforeGraphemes,
    this.deleteAfterGraphemes = 0,
  });

  final String text;
  final int deleteBeforeGraphemes;
  final int deleteAfterGraphemes;

  bool get isEmpty =>
      text.isEmpty && deleteBeforeGraphemes == 0 && deleteAfterGraphemes == 0;
}

MobileCommittedTextEdit mobileCommittedTextEdit(
  String oldValue,
  String newValue, {
  bool replacedByClipboard = false,
}) {
  final oldGraphemes = (replacedByClipboard ? '' : oldValue).characters.toList(
    growable: false,
  );
  final newGraphemes = newValue.characters.toList(growable: false);
  var commonPrefix = 0;
  while (commonPrefix < oldGraphemes.length &&
      commonPrefix < newGraphemes.length &&
      oldGraphemes[commonPrefix] == newGraphemes[commonPrefix]) {
    commonPrefix += 1;
  }
  return MobileCommittedTextEdit(
    text: newGraphemes.skip(commonPrefix).join(),
    deleteBeforeGraphemes: oldGraphemes.length - commonPrefix,
  );
}

class MobileRemoteActionItem {
  const MobileRemoteActionItem({required this.child, required this.onPressed});

  final Widget child;
  final VoidCallback? onPressed;
}

class MobileRemoteActionSection {
  const MobileRemoteActionSection({
    required this.id,
    required this.title,
    this.actions = const [],
    this.content,
  }) : assert(actions.length > 0 || content != null);

  final String id;
  final Widget title;
  final List<MobileRemoteActionItem> actions;
  final Widget? content;
}

class MobileRemoteNavigationItem {
  const MobileRemoteNavigationItem({
    required this.id,
    required this.child,
    required this.onPressed,
  });

  final String id;
  final Widget child;
  final VoidCallback onPressed;
}

class MobileRemoteActionsContent extends StatefulWidget {
  const MobileRemoteActionsContent({
    super.key,
    this.title = 'More actions',
    this.primarySections = const [],
    this.sections = const [],
    this.actions = const [],
    this.navigationItems = const [],
  });

  final String title;
  final List<MobileRemoteActionSection> primarySections;
  final List<MobileRemoteActionSection> sections;
  final List<MobileRemoteActionItem> actions;
  final List<MobileRemoteNavigationItem> navigationItems;

  @override
  State<MobileRemoteActionsContent> createState() =>
      _MobileRemoteActionsContentState();
}

class _MobileRemoteActionsContentState
    extends State<MobileRemoteActionsContent> {
  String? _sectionId;

  MobileRemoteActionSection? get _section {
    final id = _sectionId;
    if (id == null) return null;
    for (final section in [...widget.primarySections, ...widget.sections]) {
      if (section.id == id) return section;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final section = _section;
    if (section != null) {
      return Column(
        key: Key('mobile-remote-actions-${section.id}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                key: const Key('mobile-remote-actions-back'),
                tooltip: 'Back to actions',
                style: IconButton.styleFrom(
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  shape: const CircleBorder(),
                ),
                onPressed: () => setState(() => _sectionId = null),
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 8),
              Expanded(child: section.title),
            ],
          ),
          const SizedBox(height: 8),
          if (section.content != null)
            section.content!
          else
            for (final action in section.actions)
              ListTile(
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                title: action.child,
                onTap: action.onPressed,
              ),
        ],
      );
    }

    return Column(
      key: const Key('mobile-remote-actions-root'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            widget.title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 8),
        for (final section in widget.primarySections)
          if (section.actions.isNotEmpty || section.content != null)
            ListTile(
              key: Key('mobile-remote-actions-open-${section.id}'),
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              title: section.title,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => _sectionId = section.id),
            ),
        for (final item in widget.navigationItems)
          ListTile(
            key: Key('mobile-remote-actions-open-${item.id}'),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: item.child,
            trailing: const Icon(Icons.chevron_right),
            onTap: item.onPressed,
          ),
        for (final section in widget.sections)
          if (section.actions.isNotEmpty || section.content != null)
            ListTile(
              key: Key('mobile-remote-actions-open-${section.id}'),
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              title: section.title,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => _sectionId = section.id),
            ),
        for (final action in widget.actions)
          ListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: action.child,
            onTap: action.onPressed,
          ),
      ],
    );
  }
}

class MobileRemoteKeyboardSettingsContent extends StatefulWidget {
  const MobileRemoteKeyboardSettingsContent({
    super.key,
    required this.mode,
    required this.modes,
    this.inputMode,
    this.inputModes = const [],
    this.toggles = const [],
    this.actions = const [],
    this.modeHeading = 'Keyboard mode',
    this.inputModeHeading = 'Input mode',
  });

  final String mode;
  final List<MobileRemoteRadioItem> modes;
  final String? inputMode;
  final List<MobileRemoteRadioItem> inputModes;
  final List<MobileRemoteToggleItem> toggles;
  final List<MobileRemoteActionItem> actions;
  final String modeHeading;
  final String inputModeHeading;

  @override
  State<MobileRemoteKeyboardSettingsContent> createState() =>
      _MobileRemoteKeyboardSettingsContentState();
}

class _MobileRemoteKeyboardSettingsContentState
    extends State<MobileRemoteKeyboardSettingsContent> {
  late String _mode;
  String? _inputMode;
  late Map<String, bool> _toggleValues;

  @override
  void initState() {
    super.initState();
    _resetValues();
  }

  @override
  void didUpdateWidget(
    covariant MobileRemoteKeyboardSettingsContent oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode ||
        oldWidget.inputMode != widget.inputMode ||
        oldWidget.toggles != widget.toggles) {
      _resetValues();
    }
  }

  void _resetValues() {
    _mode = widget.mode;
    _inputMode = widget.inputMode;
    _toggleValues = {
      for (final toggle in widget.toggles) toggle.id: toggle.value,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('mobile-remote-keyboard-settings'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.modes.isNotEmpty) ...[
          Text(
            widget.modeHeading,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          RadioGroup<String>(
            groupValue: _mode,
            onChanged: (value) {
              if (value == null) return;
              final item = widget.modes.firstWhere(
                (candidate) => candidate.value == value,
              );
              item.onChanged?.call(value);
              if (item.commitSelection && item.onChanged != null) {
                setState(() => _mode = value);
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in widget.modes)
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    value: item.value,
                    enabled: item.onChanged != null,
                    title: item.child,
                  ),
              ],
            ),
          ),
        ],
        if (widget.inputModes.isNotEmpty && _inputMode != null) ...[
          if (widget.modes.isNotEmpty) const Divider(),
          Text(
            widget.inputModeHeading,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          RadioGroup<String>(
            groupValue: _inputMode,
            onChanged: (value) {
              if (value == null) return;
              final item = widget.inputModes.firstWhere(
                (candidate) => candidate.value == value,
              );
              item.onChanged?.call(value);
              if (item.commitSelection && item.onChanged != null) {
                setState(() => _inputMode = value);
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in widget.inputModes)
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    value: item.value,
                    enabled: item.onChanged != null,
                    title: item.child,
                  ),
              ],
            ),
          ),
        ],
        if ((widget.modes.isNotEmpty || widget.inputModes.isNotEmpty) &&
            (widget.toggles.isNotEmpty || widget.actions.isNotEmpty))
          const Divider(),
        for (final toggle in widget.toggles) ...[
          if (toggle.dividerBefore) const Divider(),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            value: _toggleValues[toggle.id] ?? toggle.value,
            onChanged: toggle.onChanged == null
                ? null
                : (value) {
                    toggle.onChanged?.call(value);
                    if (value != null) {
                      setState(() => _toggleValues[toggle.id] = value);
                    }
                  },
            title: toggle.child,
          ),
        ],
        for (final action in widget.actions)
          ListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: action.child,
            trailing: const Icon(Icons.chevron_right),
            onTap: action.onPressed,
          ),
      ],
    );
  }
}

class MobileRemoteOptionsContent extends StatefulWidget {
  const MobileRemoteOptionsContent({
    super.key,
    this.title = 'Display and session options',
    this.showTitle = true,
    this.header = const [],
    this.radioSections = const [],
    this.toggles = const [],
    this.actions = const [],
    this.footer = const [],
  });

  final String title;
  final bool showTitle;
  final List<Widget> header;
  final List<MobileRemoteRadioSection> radioSections;
  final List<MobileRemoteToggleItem> toggles;
  final List<MobileRemoteActionItem> actions;
  final List<Widget> footer;

  @override
  State<MobileRemoteOptionsContent> createState() =>
      _MobileRemoteOptionsContentState();
}

class _MobileRemoteOptionsContentState
    extends State<MobileRemoteOptionsContent> {
  final _scrollController = ScrollController();
  late Map<String, String> _radioValues;
  late Map<String, bool> _toggleValues;
  String? _selectedSectionId;

  @override
  void initState() {
    super.initState();
    _resetValues();
  }

  @override
  void didUpdateWidget(covariant MobileRemoteOptionsContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.radioSections != widget.radioSections ||
        oldWidget.toggles != widget.toggles) {
      _resetValues();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _resetValues() {
    _radioValues = {
      for (final section in widget.radioSections) section.id: section.value,
    };
    _toggleValues = {
      for (final toggle in widget.toggles) toggle.id: toggle.value,
    };
  }

  List<MobileRemoteRadioSection> get _selectedSections {
    final id = _selectedSectionId;
    if (id == null) return const [];
    return [
      for (final section in widget.radioSections)
        if (section.resolvedSubmenuId == id) section,
    ];
  }

  void _showView({String? sectionId}) {
    setState(() {
      _selectedSectionId = sectionId;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(0);
    });
  }

  Widget _navigationChevron() {
    return const SizedBox(
      width: 32,
      height: 32,
      child: Icon(Icons.chevron_right, size: 20),
    );
  }

  Widget _rowTitle(BuildContext context, Widget child) {
    return DefaultTextStyle.merge(
      style: Theme.of(context).textTheme.bodyLarge,
      child: child,
    );
  }

  Widget _backHeader(BuildContext context, String title, VoidCallback onBack) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          IconButton(
            key: const Key('mobile-remote-options-back'),
            tooltip: 'Back to options',
            style: IconButton.styleFrom(
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest,
              shape: const CircleBorder(),
            ),
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
        ],
      ),
    );
  }

  Widget _rootMenuItem({
    required Key key,
    required Widget title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      title: _rowTitle(context, title),
      trailing: _navigationChevron(),
      onTap: onTap,
    );
  }

  Widget _buildRoot(BuildContext context) {
    final children = <Widget>[
      if (widget.showTitle) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            widget.title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 8),
      ],
      ...widget.header,
    ];

    final addedSubmenus = <String>{};
    for (final section in widget.radioSections) {
      if (section.items.isEmpty && section.content == null) continue;
      final submenuId = section.resolvedSubmenuId;
      if (!addedSubmenus.add(submenuId)) continue;
      children.add(
        _rootMenuItem(
          key: Key('mobile-remote-options-open-$submenuId'),
          title: section.heading ?? Text(section.id),
          onTap: () => _showView(sectionId: submenuId),
        ),
      );
    }
    for (final action in widget.actions) {
      children.add(
        ListTile(
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          title: _rowTitle(context, action.child),
          trailing: _navigationChevron(),
          onTap: action.onPressed,
        ),
      );
    }
    for (final toggle in widget.toggles) {
      if (toggle.dividerBefore) children.add(const Divider());
      children.add(
        CheckboxListTile(
          key: Key('mobile-remote-options-toggle-${toggle.id}'),
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          value: _toggleValues[toggle.id] ?? toggle.value,
          onChanged: toggle.onChanged == null
              ? null
              : (value) {
                  toggle.onChanged?.call(value);
                  if (value != null) {
                    setState(() => _toggleValues[toggle.id] = value);
                  }
                },
          title: toggle.child,
        ),
      );
    }
    children.addAll(widget.footer);
    return Column(
      key: const Key('mobile-remote-options-root'),
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _buildRadioSections(
    BuildContext context,
    List<MobileRemoteRadioSection> sections,
  ) {
    final firstSection = sections.first;
    return Column(
      key: Key(
        'mobile-remote-options-submenu-${firstSection.resolvedSubmenuId}',
      ),
      mainAxisSize: MainAxisSize.min,
      children: [
        _backHeader(
          context,
          firstSection.heading is Text
              ? ((firstSection.heading as Text).data ?? firstSection.id)
              : firstSection.id,
          _showView,
        ),
        for (var index = 0; index < sections.length; index++) ...[
          if (index > 0) ...[
            const Divider(),
            Align(
              alignment: Alignment.centerLeft,
              child: DefaultTextStyle.merge(
                style: Theme.of(context).textTheme.titleSmall,
                child: sections[index].heading ?? Text(sections[index].id),
              ),
            ),
            const SizedBox(height: 4),
          ],
          if (sections[index].items.isNotEmpty)
            RadioGroup<String>(
              groupValue:
                  _radioValues[sections[index].id] ?? sections[index].value,
              onChanged: (value) {
                if (value == null) return;
                final section = sections[index];
                final item = section.items.firstWhere(
                  (candidate) => candidate.value == value,
                );
                item.onChanged?.call(value);
                if (item.commitSelection && item.onChanged != null) {
                  setState(() => _radioValues[section.id] = value);
                }
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in sections[index].items)
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      value: item.value,
                      enabled: item.onChanged != null,
                      title: item.child,
                    ),
                ],
              ),
            ),
          if (sections[index].content != null) sections[index].content!,
          if (sections[index].selectionDetailsBuilder != null)
            sections[index].selectionDetailsBuilder!(
              _radioValues[sections[index].id] ?? sections[index].value,
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sections = _selectedSections;
    final content = sections.isNotEmpty
        ? _buildRadioSections(context, sections)
        : _buildRoot(context);
    return SingleChildScrollView(
      key: const Key('mobile-remote-options-scroll'),
      controller: _scrollController,
      primary: false,
      physics: const ClampingScrollPhysics(),
      child: content,
    );
  }
}
