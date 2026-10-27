import 'package:flutter/material.dart';

const kConnectionFocusCheckboxLabel = 'Focus connection window';

class ConnectionFocusCheckbox extends StatelessWidget {
  const ConnectionFocusCheckbox({
    super.key,
    this.value = true,
    required this.onChanged,
    this.label = kConnectionFocusCheckboxLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(label),
      value: value,
      onChanged: onChanged == null
          ? null
          : (next) {
              if (next != null) onChanged!(next);
            },
    );
  }
}
