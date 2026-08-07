import 'package:flutter/material.dart';

const mobileRemoteAccentColor = Color(0xFF0071FF);
const mobileRemoteAccentActiveColor = Color(0xAA0071FF);

class MobileRemoteBottomBar extends StatelessWidget {
  const MobileRemoteBottomBar({
    super.key,
    required this.onDisconnect,
    required this.onOptions,
    required this.onMore,
    required this.onHide,
    required this.showInputControls,
    required this.peerIsAndroid,
    required this.touchMode,
    required this.waitForFirstImage,
    this.onKeyboard,
    this.onGestureHelp,
    this.onMobileActions,
    this.chatButton,
  });

  final VoidCallback onDisconnect;
  final VoidCallback onOptions;
  final VoidCallback onMore;
  final VoidCallback onHide;
  final bool showInputControls;
  final bool peerIsAndroid;
  final bool touchMode;
  final bool waitForFirstImage;
  final VoidCallback? onKeyboard;
  final VoidCallback? onGestureHelp;
  final VoidCallback? onMobileActions;
  final Widget? chatButton;

  @override
  Widget build(BuildContext context) {
    return BottomAppBar(
      elevation: 10,
      color: mobileRemoteAccentColor,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Disconnect',
                color: Colors.white,
                icon: const Icon(Icons.clear),
                onPressed: onDisconnect,
              ),
              IconButton(
                tooltip: 'Display and session options',
                color: Colors.white,
                icon: const Icon(Icons.tv),
                onPressed: onOptions,
              ),
              if (showInputControls) ...[
                IconButton(
                  tooltip: 'Keyboard',
                  color: Colors.white,
                  icon: const Icon(Icons.keyboard),
                  onPressed: onKeyboard,
                ),
                if (peerIsAndroid)
                  IconButton(
                    tooltip: 'Android actions',
                    color: Colors.white,
                    icon: const Icon(Icons.build),
                    onPressed: onMobileActions,
                  )
                else
                  IconButton(
                    tooltip: touchMode ? 'Touch mode' : 'Mouse mode',
                    color: Colors.white,
                    icon: Icon(touchMode ? Icons.touch_app : Icons.mouse),
                    onPressed: onGestureHelp,
                  ),
              ],
              if (chatButton != null) chatButton!,
              IconButton(
                tooltip: 'More actions',
                color: Colors.white,
                icon: const Icon(Icons.more_vert),
                onPressed: onMore,
              ),
            ],
          ),
          IconButton(
            tooltip: 'Hide toolbar',
            color: Colors.white,
            icon: const Icon(Icons.expand_more),
            onPressed: waitForFirstImage ? null : onHide,
          ),
        ],
      ),
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

class MobileRemoteKeyHelpTools extends StatelessWidget {
  const MobileRemoteKeyHelpTools({
    super.key,
    required this.keyboardIsVisible,
    required this.ctrlActive,
    required this.altActive,
    required this.shiftActive,
    required this.commandActive,
    required this.functionKeysActive,
    required this.pinned,
    required this.moreKeysActive,
    required this.isMac,
    required this.showWindowsLinuxKeys,
    required this.onCtrl,
    required this.onAlt,
    required this.onShift,
    required this.onCommand,
    required this.onFunctionKeys,
    required this.onPin,
    required this.onMoreKeys,
    required this.onKeyPressed,
    required this.onShortcutPressed,
    this.labelBuilder,
  });

  final bool keyboardIsVisible;
  final bool ctrlActive;
  final bool altActive;
  final bool shiftActive;
  final bool commandActive;
  final bool functionKeysActive;
  final bool pinned;
  final bool moreKeysActive;
  final bool isMac;
  final bool showWindowsLinuxKeys;
  final VoidCallback onCtrl;
  final VoidCallback onAlt;
  final VoidCallback onShift;
  final VoidCallback onCommand;
  final VoidCallback onFunctionKeys;
  final VoidCallback onPin;
  final VoidCallback onMoreKeys;
  final ValueChanged<String> onKeyPressed;
  final ValueChanged<String> onShortcutPressed;
  final String Function(String)? labelBuilder;

  String _label(String value) => labelBuilder?.call(value) ?? value;

  Widget _button(
    String text,
    VoidCallback onPressed, {
    bool active = false,
    IconData? icon,
  }) {
    return TextButton(
      style: TextButton.styleFrom(
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 9.75),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        backgroundColor: active ? mobileRemoteAccentActiveColor : null,
      ),
      onPressed: onPressed,
      child: icon != null
          ? Icon(icon, size: 14, color: Colors.white)
          : Text(
              _label(text),
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final spacing = width > 320 ? 4.0 : 2.0;
    final modifiers = <Widget>[
      _button('Ctrl ', onCtrl, active: ctrlActive),
      _button(' Alt ', onAlt, active: altActive),
      _button('Shift', onShift, active: shiftActive),
      _button(isMac ? ' Cmd ' : ' Win ', onCommand, active: commandActive),
    ];
    final controls = <Widget>[
      _button(' Fn ', onFunctionKeys, active: functionKeysActive),
      _button('', onPin, active: pinned, icon: Icons.push_pin),
      _button(' ... ', onMoreKeys, active: moreKeysActive),
    ];
    final expandedKeys = <Widget>[];
    if (functionKeysActive) {
      for (var index = 1; index <= 12; index++) {
        final name = 'F$index';
        expandedKeys.add(_button(name, () => onKeyPressed('VK_$name')));
      }
    } else if (moreKeysActive) {
      expandedKeys.addAll([
        _button('Esc', () => onKeyPressed('VK_ESCAPE')),
        _button('Tab', () => onKeyPressed('VK_TAB')),
        _button('Home', () => onKeyPressed('VK_HOME')),
        _button('End', () => onKeyPressed('VK_END')),
        _button('Ins', () => onKeyPressed('VK_INSERT')),
        _button('Del', () => onKeyPressed('VK_DELETE')),
        _button('PgUp', () => onKeyPressed('VK_PRIOR')),
        _button('PgDn', () => onKeyPressed('VK_NEXT')),
        if (showWindowsLinuxKeys)
          _button('PrtScr', () => onKeyPressed('VK_SNAPSHOT')),
        if (showWindowsLinuxKeys)
          _button('ScrollLock', () => onKeyPressed('VK_SCROLL')),
        if (showWindowsLinuxKeys)
          _button('Pause', () => onKeyPressed('VK_PAUSE')),
        if (showWindowsLinuxKeys) _button('Menu', () => onKeyPressed('Apps')),
        _button('Enter', () => onKeyPressed('VK_ENTER')),
        const SizedBox(width: 9999),
        _button(
          '',
          () => onKeyPressed('VK_LEFT'),
          icon: Icons.keyboard_arrow_left,
        ),
        _button('', () => onKeyPressed('VK_UP'), icon: Icons.keyboard_arrow_up),
        _button(
          '',
          () => onKeyPressed('VK_DOWN'),
          icon: Icons.keyboard_arrow_down,
        ),
        _button(
          '',
          () => onKeyPressed('VK_RIGHT'),
          icon: Icons.keyboard_arrow_right,
        ),
        _button(isMac ? 'Cmd+C' : 'Ctrl+C', () => onShortcutPressed('VK_C')),
        _button(isMac ? 'Cmd+V' : 'Ctrl+V', () => onShortcutPressed('VK_V')),
        _button(isMac ? 'Cmd+S' : 'Ctrl+S', () => onShortcutPressed('VK_S')),
      ]);
    }

    return Container(
      color: const Color(0xAA000000),
      padding: EdgeInsets.only(top: keyboardIsVisible ? 24 : 4, bottom: 8),
      child: Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          const SizedBox(width: 9999),
          ...modifiers,
          ...controls,
          if (expandedKeys.isNotEmpty) ...[
            const SizedBox(width: 9999),
            ...expandedKeys,
          ],
        ],
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
    this.selectionDetailsBuilder,
    this.dividerAfter = true,
  });

  final String id;
  final String value;
  final List<MobileRemoteRadioItem> items;
  final Widget? heading;
  final Widget Function(String value)? selectionDetailsBuilder;
  final bool dividerAfter;
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

class MobileRemoteActionItem {
  const MobileRemoteActionItem({required this.child, required this.onPressed});

  final Widget child;
  final VoidCallback? onPressed;
}

class MobileRemoteOptionsContent extends StatefulWidget {
  const MobileRemoteOptionsContent({
    super.key,
    this.header = const [],
    this.radioSections = const [],
    this.toggles = const [],
    this.actions = const [],
    this.footer = const [],
  });

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
  late Map<String, String> _radioValues;
  late Map<String, bool> _toggleValues;

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

  void _resetValues() {
    _radioValues = {
      for (final section in widget.radioSections) section.id: section.value,
    };
    _toggleValues = {
      for (final toggle in widget.toggles) toggle.id: toggle.value,
    };
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[...widget.header];

    for (final section in widget.radioSections) {
      if (section.items.isEmpty) {
        continue;
      }
      if (section.heading != null) {
        children.add(
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
              child: section.heading,
            ),
          ),
        );
      }
      final selectedValue = _radioValues[section.id] ?? section.value;
      children.add(
        RadioGroup<String>(
          groupValue: selectedValue,
          onChanged: (value) {
            if (value == null) {
              return;
            }
            final item = section.items.firstWhere(
              (candidate) => candidate.value == value,
            );
            item.onChanged?.call(value);
            if (item.commitSelection && item.onChanged != null) {
              setState(() {
                _radioValues[section.id] = value;
              });
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in section.items)
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
      );
      final detailsBuilder = section.selectionDetailsBuilder;
      if (detailsBuilder != null) {
        children.add(detailsBuilder(selectedValue));
      }
      if (section.dividerAfter) {
        children.add(const Divider());
      }
    }

    for (final action in widget.actions) {
      children.add(
        ListTile(
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          title: action.child,
          onTap: action.onPressed,
        ),
      );
    }
    if (widget.actions.isNotEmpty && widget.toggles.isNotEmpty) {
      children.add(const Divider());
    }
    for (final toggle in widget.toggles) {
      if (toggle.dividerBefore && children.isNotEmpty) {
        children.add(const Divider());
      }
      children.add(
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          value: _toggleValues[toggle.id] ?? toggle.value,
          onChanged: toggle.onChanged == null
              ? null
              : (value) {
                  toggle.onChanged?.call(value);
                  if (value != null) {
                    setState(() {
                      _toggleValues[toggle.id] = value;
                    });
                  }
                },
          title: toggle.child,
        ),
      );
    }
    children.addAll(widget.footer);

    return Column(mainAxisSize: MainAxisSize.min, children: children);
  }
}
