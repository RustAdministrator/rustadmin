import 'package:flutter/material.dart';

/// The hidden editor used by the remote session's software keyboard.
class MobileRemoteTextInput extends StatelessWidget {
  const MobileRemoteTextInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onEnter,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onEnter;

  @override
  Widget build(BuildContext context) => TextFormField(
    // A submit action is distinct from editing/pasting a literal newline.
    // On iOS, the default multiline Return instead inserts '\n' into the text.
    textInputAction: TextInputAction.done,
    autocorrect: false,
    // Keep the existing Android suggestion policy: disabling suggestions can
    // select a secure keyboard (Flutter issues #139143 and #146540).
    autofocus: true,
    focusNode: focusNode,
    controller: controller,
    maxLines: null,
    keyboardType: TextInputType.multiline,
    // Flush any pending composition through the controller listener before
    // Enter is queued, but do not unfocus or dismiss the remote keyboard.
    onEditingComplete: controller.clearComposing,
    onFieldSubmitted: (_) => onEnter(),
  );
}
