import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';

class EdgeThicknessControl extends StatefulWidget {
  const EdgeThicknessControl({
    super.key,
    required this.value,
    this.onChanged,
    this.colorScheme,
  });

  static const double kMin = kMinEdgeScrollEdgeThickness * 1.0;
  static const double kMax = kMaxEdgeScrollEdgeThickness * 1.0;

  final double value;
  final ValueChanged<double>? onChanged;
  final ColorScheme? colorScheme;

  @override
  State<EdgeThicknessControl> createState() => _EdgeThicknessControlState();
}

class _EdgeThicknessControlState extends State<EdgeThicknessControl> {
  late double _value = _normalized(widget.value);

  double _normalized(double value) =>
      value.clamp(EdgeThicknessControl.kMin, EdgeThicknessControl.kMax);

  @override
  void didUpdateWidget(covariant EdgeThicknessControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _value = _normalized(widget.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.colorScheme ?? Theme.of(context).colorScheme;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: colorScheme.primary,
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: 0.1),
        showValueIndicator: ShowValueIndicator.never,
        thumbShape: const _EdgeThicknessThumbShape(),
      ),
      child: Semantics(
        label: 'Edge size',
        value: '${_value.round()}px',
        child: Slider(
          key: const Key('edge-thickness-slider'),
          value: _value,
          min: EdgeThicknessControl.kMin,
          max: EdgeThicknessControl.kMax,
          divisions: (EdgeThicknessControl.kMax - EdgeThicknessControl.kMin)
              .round(),
          semanticFormatterCallback: (value) => '${value.round()}px',
          onChanged: widget.onChanged == null
              ? null
              : (value) {
                  setState(() => _value = value);
                  widget.onChanged!(value);
                },
        ),
      ),
    );
  }
}

class _EdgeThicknessThumbShape extends SliderComponentShape {
  const _EdgeThicknessThumbShape();

  static const _size = Size(52, 24);

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => _size;

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final fillColor =
        ColorTween(
          begin: sliderTheme.disabledThumbColor,
          end: sliderTheme.thumbColor,
        ).evaluate(enableAnimation) ??
        sliderTheme.thumbColor ??
        Colors.blueAccent;
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: _size.width, height: _size.height),
      const Radius.circular(4),
    );
    context.canvas.drawRRect(rect, Paint()..color = fillColor);

    final displayValue =
        (EdgeThicknessControl.kMin +
                value * (EdgeThicknessControl.kMax - EdgeThicknessControl.kMin))
            .round();
    final painter = TextPainter(
      text: TextSpan(
        text: '${displayValue}px',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: textDirection,
    )..layout(maxWidth: _size.width - 4);
    painter.paint(
      context.canvas,
      Offset(center.dx - painter.width / 2, center.dy - painter.height / 2),
    );
  }
}
