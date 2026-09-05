import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Carries edit provenance while the session's synchronous listener runs.
class MobileRemoteTextEditingController extends TextEditingController {
  MobileRemoteTextEditingController({super.text});

  bool get isLiteralEdit => _literalEditDepth != 0;
  int _literalEditDepth = 0;
  // Baseline after a native Return, before any coalesced subsequent typing.
  String? get returnEchoBaseline => _returnEchoBaseline;
  String? _returnEchoBaseline;

  void _literalEdit(VoidCallback edit) {
    _literalEditDepth++;
    try {
      edit();
    } finally {
      _literalEditDepth--;
    }
  }
}

/// Recognizes the editing echo of an explicitly received iOS Return action.
/// Keep that echo in the native buffer, but exclude it from the remote diff.
class _MobileRemoteReturnTracker {
  TextEditingValue? _beforeReturn;
  int _pendingReturns = 0;

  void expectReturn(TextEditingValue value) {
    _beforeReturn ??= value;
    _pendingReturns++;
  }

  String? consume(TextEditingValue newValue) {
    final before = _beforeReturn;
    if (before == null || newValue.text == before.text) return null;
    _beforeReturn = null;
    final count = _pendingReturns;
    _pendingReturns = 0;
    final selection = before.selection;
    if (!selection.isValid || selection.end > before.text.length) {
      return null;
    }
    final prefix = before.text.substring(0, selection.start);
    final suffix = before.text.substring(selection.end);
    final inserted = '\n' * count;
    if (!newValue.text.startsWith('$prefix$inserted') ||
        !newValue.text.endsWith(suffix)) {
      return null;
    }
    return '$prefix$inserted$suffix';
  }
}

/// Hidden editor that handles native Return without submitting literal text.
class MobileRemoteTextInput extends StatelessWidget {
  const MobileRemoteTextInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onEnter,
  });

  final MobileRemoteTextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onEnter;

  @override
  Widget build(BuildContext context) => _RemoteEditableText(
    controller: controller,
    focusNode: focusNode,
    onEnter: onEnter,
  );
}

class _RemoteEditableText extends EditableText {
  _RemoteEditableText({
    required super.controller,
    required super.focusNode,
    required this.onEnter,
  }) : super(
         style: const TextStyle(color: Colors.transparent, fontSize: 14),
         cursorColor: Colors.transparent,
         backgroundCursorColor: Colors.transparent,
         showCursor: false,
         textInputAction: defaultTargetPlatform == TargetPlatform.iOS
             ? TextInputAction.newline
             : TextInputAction.done,
         autocorrect: false,
         autofocus: true,
         maxLines: null,
         keyboardType: TextInputType.multiline,
         onEditingComplete: controller.clearComposing,
         onSubmitted: (_) => onEnter(),
       );

  final VoidCallback onEnter;

  @override
  EditableTextState createState() => _RemoteEditableTextState();
}

class _RemoteEditableTextState extends EditableTextState {
  var _returnTracker = _MobileRemoteReturnTracker();
  bool _wasComposing = false;

  _RemoteEditableText get _input => widget as _RemoteEditableText;

  @override
  void didUpdateWidget(covariant _RemoteEditableText oldWidget) {
    if (oldWidget.controller != widget.controller) {
      _returnTracker = _MobileRemoteReturnTracker();
      _wasComposing = false;
    }
    super.didUpdateWidget(oldWidget);
  }

  void _asLiteral(VoidCallback edit) {
    final controller = widget.controller;
    if (controller is MobileRemoteTextEditingController) {
      controller._literalEdit(edit);
    } else {
      edit();
    }
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    final controller = widget.controller as MobileRemoteTextEditingController;
    final composing = value.composing.isValid && !value.composing.isCollapsed;
    controller._returnEchoBaseline = _returnTracker.consume(value);
    try {
      if (composing || _wasComposing) {
        _asLiteral(() => super.updateEditingValue(value));
      } else {
        super.updateEditingValue(value);
      }
    } finally {
      controller._returnEchoBaseline = null;
    }
    _wasComposing = composing;
  }

  @override
  Future<void> pasteText(SelectionChangedCause cause) async {
    final controller = widget.controller;
    if (controller is! MobileRemoteTextEditingController) {
      return super.pasteText(cause);
    }
    controller._literalEditDepth++;
    try {
      await super.pasteText(cause);
    } finally {
      controller._literalEditDepth--;
    }
  }

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline) {
      // Flutter's iOS engine reports the action before inserting '\n'.
      // Android IME actions do not promise a subsequent insertion.
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        _returnTracker.expectReturn(widget.controller.value);
      }
      _asLiteral(widget.controller.clearComposing);
      _wasComposing = false;
      _input.onEnter();
      return;
    }
    _asLiteral(() => super.performAction(action));
  }
}
