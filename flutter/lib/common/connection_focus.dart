const kConnectionFocusArgument = 'focus_on_open';

bool resolveConnectionFocus({bool? override, bool defaultValue = true}) =>
    override ?? defaultValue;

bool connectionFocusFromArguments(Map<dynamic, dynamic> arguments) =>
    resolveConnectionFocus(
      override: arguments[kConnectionFocusArgument] is bool
          ? arguments[kConnectionFocusArgument] as bool
          : null,
    );

bool shouldSelectNewConnectionTab({
  required bool focusOnOpen,
  required bool hasTabs,
}) => focusOnOpen || !hasTabs;
