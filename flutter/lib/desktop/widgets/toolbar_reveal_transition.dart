import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Hides with a slide but restores hit testing synchronously on reveal.
/// An implicit animation cannot do this: its render transform is not updated
/// until the next frame, after a fast mouse down may have hit the canvas.
class ToolbarRevealTransition extends StatefulWidget {
  const ToolbarRevealTransition({
    super.key,
    required this.visible,
    required this.child,
  });

  final ValueListenable<bool> visible;
  final Widget child;

  @override
  State<ToolbarRevealTransition> createState() =>
      _ToolbarRevealTransitionState();
}

class _ToolbarRevealTransitionState extends State<ToolbarRevealTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hiddenFraction;

  @override
  void initState() {
    super.initState();
    _hiddenFraction = AnimationController(
      vsync: this,
      value: widget.visible.value ? 0 : 1,
      duration: const Duration(milliseconds: 220),
    );
    widget.visible.addListener(_visibilityChanged);
  }

  void _visibilityChanged() {
    if (widget.visible.value) {
      // Updates the render transform now, not in a future animation frame.
      _hiddenFraction.value = 0;
    } else {
      _hiddenFraction.animateTo(1, curve: Curves.easeOutCubic);
    }
  }

  @override
  void didUpdateWidget(ToolbarRevealTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.visible, widget.visible)) return;
    oldWidget.visible.removeListener(_visibilityChanged);
    widget.visible.addListener(_visibilityChanged);
    _visibilityChanged();
  }

  @override
  void dispose() {
    widget.visible.removeListener(_visibilityChanged);
    _hiddenFraction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ToolbarRevealRenderWidget(
    visible: widget.visible,
    hiddenFraction: _hiddenFraction,
    child: widget.child,
  );
}

class _ToolbarRevealRenderWidget extends SingleChildRenderObjectWidget {
  const _ToolbarRevealRenderWidget({
    required this.visible,
    required this.hiddenFraction,
    required super.child,
  });

  final ValueListenable<bool> visible;
  final Animation<double> hiddenFraction;

  @override
  _RenderToolbarReveal createRenderObject(BuildContext context) =>
      _RenderToolbarReveal(visible, hiddenFraction);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderToolbarReveal renderObject,
  ) {
    renderObject.update(visible, hiddenFraction);
  }
}

class _RenderToolbarReveal extends RenderFractionalTranslation {
  _RenderToolbarReveal(this._visible, this._hiddenFraction)
    : super(translation: Offset.zero) {
    _syncTranslation();
  }

  ValueListenable<bool> _visible;
  Animation<double> _hiddenFraction;

  void _syncTranslation() {
    translation = _visible.value
        ? Offset.zero
        : Offset(0, -1.15 * _hiddenFraction.value);
    markNeedsSemanticsUpdate();
  }

  void update(ValueListenable<bool> visible, Animation<double> hiddenFraction) {
    if (identical(visible, _visible) &&
        identical(hiddenFraction, _hiddenFraction)) {
      return;
    }
    if (attached) _unlisten();
    _visible = visible;
    _hiddenFraction = hiddenFraction;
    if (attached) _listen();
    _syncTranslation();
  }

  void _listen() {
    _visible.addListener(_syncTranslation);
    _hiddenFraction.addListener(_syncTranslation);
  }

  void _unlisten() {
    _visible.removeListener(_syncTranslation);
    _hiddenFraction.removeListener(_syncTranslation);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen();
    _syncTranslation();
  }

  @override
  void detach() {
    _unlisten();
    super.detach();
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      _visible.value && super.hitTest(result, position: position);

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_visible.value) super.visitChildrenForSemantics(visitor);
  }
}
