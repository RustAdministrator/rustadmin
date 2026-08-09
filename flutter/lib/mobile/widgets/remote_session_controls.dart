import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

const mobileRemoteAccentColor = Color(0xFF0071FF);
const mobileRemoteAccentActiveColor = Color(0xAA0071FF);

Color mobileRemoteToolbarBackgroundColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF424242)
      : const Color(0xFFE0E0E0);
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

enum MobileRemoteToolbarAxis { horizontal, vertical }

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
    this.onKeyboard,
    this.onGestureHelp,
    this.onMobileActions,
    this.chatButton,
  });

  final VoidCallback onDisconnect;
  final VoidCallback onOptions;
  final VoidCallback onMore;
  final bool showInputControls;
  final bool peerIsAndroid;
  final bool touchMode;
  final bool waitForFirstImage;
  final VoidCallback? onKeyboard;
  final VoidCallback? onGestureHelp;
  final VoidCallback? onMobileActions;
  final Widget? chatButton;

  @override
  State<MobileRemoteToolbar> createState() => _MobileRemoteToolbarState();
}

class _MobileRemoteToolbarState extends State<MobileRemoteToolbar> {
  static const _iconSize = 24.0;
  static const _maximumButtonExtent = 48.0;
  static const _dimmedOpacity = 0.2;
  static const _dimDelay = Duration(milliseconds: 1000);
  static const _dimDuration = Duration(milliseconds: 3000);

  var _axis = MobileRemoteToolbarAxis.horizontal;
  var _collapsed = false;
  Offset? _position;
  Timer? _dimTimer;
  var _toolbarOpacity = 1.0;
  var _pointerOverToolbar = false;

  bool get _vertical => _axis == MobileRemoteToolbarAxis.vertical;

  @override
  void initState() {
    super.initState();
    _scheduleDim();
  }

  @override
  void dispose() {
    _dimTimer?.cancel();
    super.dispose();
  }

  void _showToolbarOpaque() {
    _dimTimer?.cancel();
    if (!mounted || _toolbarOpacity == 1.0) return;
    setState(() => _toolbarOpacity = 1.0);
  }

  void _scheduleDim() {
    _dimTimer?.cancel();
    _dimTimer = Timer(_dimDelay, () {
      if (!mounted || _pointerOverToolbar) return;
      setState(() => _toolbarOpacity = _dimmedOpacity);
    });
  }

  Offset _initialPosition(BoxConstraints constraints, Size toolbarSize) {
    final maxLeft = (constraints.maxWidth - toolbarSize.width)
        .clamp(0.0, double.infinity)
        .toDouble();
    final maxTop = (constraints.maxHeight - toolbarSize.height)
        .clamp(0.0, double.infinity)
        .toDouble();
    return Offset(maxLeft / 2, maxTop);
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
    _showToolbarOpaque();
    final currentPosition = _clampPosition(
      _position ?? _initialPosition(constraints, toolbarSize),
      constraints,
      toolbarSize,
    );
    setState(() {
      _position = _clampPosition(
        currentPosition + details.delta,
        constraints,
        toolbarSize,
      );
    });
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
          setState(() {
            _axis = _vertical
                ? MobileRemoteToolbarAxis.horizontal
                : MobileRemoteToolbarAxis.vertical;
          });
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

  List<Widget> _expandedItems(double extent) {
    final items = <Widget>[
      _iconButton(
        extent: extent,
        tooltip: 'Disconnect',
        icon: Icons.clear,
        onPressed: widget.onDisconnect,
      ),
      _iconButton(
        extent: extent,
        tooltip: 'Display and session options',
        icon: Icons.tv,
        onPressed: widget.onOptions,
      ),
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
        tooltip: 'Collapse toolbar',
        icon: _vertical
            ? Icons.keyboard_arrow_right
            : Icons.keyboard_arrow_down,
        onPressed: widget.waitForFirstImage
            ? null
            : () {
                setState(() {
                  _collapsed = true;
                });
              },
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
        final extent = availableExtent.isFinite && availableExtent > 0
            ? (availableExtent / itemCount).clamp(0.0, _maximumButtonExtent)
            : _maximumButtonExtent;
        final items = _collapsed
            ? [
                _iconButton(
                  extent: extent,
                  tooltip: 'Show toolbar',
                  icon: _vertical
                      ? Icons.keyboard_arrow_left
                      : Icons.keyboard_arrow_up,
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
          _position ?? _initialPosition(constraints, toolbarSize),
          constraints,
          toolbarSize,
        );

        return Stack(
          children: [
            Positioned(
              left: position.dx,
              top: position.dy,
              child: Listener(
                onPointerDown: (_) => _showToolbarOpaque(),
                onPointerMove: (_) => _showToolbarOpaque(),
                onPointerUp: (_) {
                  if (!_pointerOverToolbar) _scheduleDim();
                },
                onPointerCancel: (_) {
                  if (!_pointerOverToolbar) _scheduleDim();
                },
                child: MouseRegion(
                  onEnter: (_) {
                    _pointerOverToolbar = true;
                    _showToolbarOpaque();
                  },
                  onExit: (_) {
                    _pointerOverToolbar = false;
                    _scheduleDim();
                  },
                  onHover: (_) => _showToolbarOpaque(),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => _showToolbarOpaque(),
                    onPanUpdate: (details) => _updateToolbarPosition(
                      details,
                      constraints,
                      toolbarSize,
                    ),
                    onPanEnd: (_) {
                      if (!_pointerOverToolbar) _scheduleDim();
                    },
                    onPanCancel: () {
                      if (!_pointerOverToolbar) _scheduleDim();
                    },
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        key: const Key('mobile-remote-toolbar-opacity'),
                        duration: _toolbarOpacity == 1.0
                            ? Duration.zero
                            : _dimDuration,
                        opacity: _toolbarOpacity * (_collapsed ? 0.9 : 1.0),
                        child: Material(
                          key: const Key('mobile-remote-floating-toolbar'),
                          color: mobileRemoteToolbarBackgroundColor(context),
                          elevation: 6,
                          shadowColor: Colors.black54,
                          clipBehavior: Clip.antiAlias,
                          shape: const StadiumBorder(),
                          child: Flex(
                            direction: _vertical
                                ? Axis.vertical
                                : Axis.horizontal,
                            mainAxisSize: MainAxisSize.min,
                            children: items,
                          ),
                        ),
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
    this.labelBuilder,
  });

  final bool ctrlActive;
  final bool altActive;
  final bool shiftActive;
  final bool commandActive;
  final bool functionKeysActive;
  final bool moreKeysActive;
  final bool isMac;
  final bool showWindowsLinuxKeys;
  final List<MobileRemoteQuickKey> quickKeyOrder;
  final VoidCallback onCtrl;
  final VoidCallback onAlt;
  final VoidCallback onShift;
  final VoidCallback onCommand;
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
    bool active = false,
    IconData? icon,
  }) {
    return SizedBox.square(
      dimension: 36,
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: Size.zero,
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          backgroundColor: active
              ? mobileRemoteToolbarActiveBackgroundColor(context)
              : mobileRemoteToolbarBackgroundColor(context),
        ),
        onPressed: onPressed,
        child: icon != null
            ? Icon(
                icon,
                size: 18,
                color: mobileRemoteToolbarForegroundColor(context),
              )
            : Text(
                _label(text),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: mobileRemoteToolbarForegroundColor(context),
                  fontSize: 10,
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const spacing = 2.0;
    final quickButtons = <MobileRemoteQuickKey, Widget>{
      MobileRemoteQuickKey.ctrl: KeyedSubtree(
        key: const Key('mobile-remote-quick-ctrl'),
        child: _button(
          context,
          mobileRemoteQuickKeyLabel(MobileRemoteQuickKey.ctrl, isMac: isMac),
          onCtrl,
          active: ctrlActive,
        ),
      ),
      MobileRemoteQuickKey.alt: KeyedSubtree(
        key: const Key('mobile-remote-quick-alt'),
        child: _button(
          context,
          mobileRemoteQuickKeyLabel(MobileRemoteQuickKey.alt, isMac: isMac),
          onAlt,
          active: altActive,
        ),
      ),
      MobileRemoteQuickKey.shift: KeyedSubtree(
        key: const Key('mobile-remote-quick-shift'),
        child: _button(
          context,
          mobileRemoteQuickKeyLabel(MobileRemoteQuickKey.shift, isMac: isMac),
          onShift,
          active: shiftActive,
        ),
      ),
      MobileRemoteQuickKey.command: KeyedSubtree(
        key: const Key('mobile-remote-quick-command'),
        child: _button(
          context,
          mobileRemoteQuickKeyLabel(MobileRemoteQuickKey.command, isMac: isMac),
          onCommand,
          active: commandActive,
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
        _button(context, 'Tab', () => onKeyPressed('VK_TAB')),
        _button(context, 'Home', () => onKeyPressed('VK_HOME')),
        _button(context, 'End', () => onKeyPressed('VK_END')),
        _button(context, 'Ins', () => onKeyPressed('VK_INSERT')),
        _button(context, 'Del', () => onKeyPressed('VK_DELETE')),
        _button(context, 'PgUp', () => onKeyPressed('VK_PRIOR')),
        _button(context, 'PgDn', () => onKeyPressed('VK_NEXT')),
        if (showWindowsLinuxKeys)
          _button(context, 'PrtScr', () => onKeyPressed('VK_SNAPSHOT')),
        if (showWindowsLinuxKeys)
          _button(context, 'ScrollLock', () => onKeyPressed('VK_SCROLL')),
        if (showWindowsLinuxKeys)
          _button(context, 'Pause', () => onKeyPressed('VK_PAUSE')),
        if (showWindowsLinuxKeys)
          _button(context, 'Menu', () => onKeyPressed('Apps')),
        _button(context, 'Enter', () => onKeyPressed('VK_ENTER')),
        _button(
          context,
          '',
          () => onKeyPressed('VK_LEFT'),
          icon: Icons.keyboard_arrow_left,
        ),
        _button(
          context,
          '',
          () => onKeyPressed('VK_UP'),
          icon: Icons.keyboard_arrow_up,
        ),
        _button(
          context,
          '',
          () => onKeyPressed('VK_DOWN'),
          icon: Icons.keyboard_arrow_down,
        ),
        _button(
          context,
          '',
          () => onKeyPressed('VK_RIGHT'),
          icon: Icons.keyboard_arrow_right,
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
        physics: const NeverScrollableScrollPhysics(),
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

class MobileRemoteActionSection {
  const MobileRemoteActionSection({
    required this.id,
    required this.title,
    required this.actions,
  });

  final String id;
  final Widget title;
  final List<MobileRemoteActionItem> actions;
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
    this.sections = const [],
    this.navigationItems = const [],
  });

  final String title;
  final List<MobileRemoteActionSection> sections;
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
    for (final section in widget.sections) {
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
        for (final section in widget.sections)
          if (section.actions.isNotEmpty)
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
      ],
    );
  }
}

class MobileRemoteOptionsContent extends StatefulWidget {
  const MobileRemoteOptionsContent({
    super.key,
    this.title = 'Display and session options',
    this.header = const [],
    this.radioSections = const [],
    this.toggles = const [],
    this.actions = const [],
    this.footer = const [],
  });

  final String title;
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
  String? _selectedSectionId;
  var _showToggles = false;

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

  MobileRemoteRadioSection? get _selectedSection {
    final id = _selectedSectionId;
    if (id == null) return null;
    for (final section in widget.radioSections) {
      if (section.id == id) return section;
    }
    return null;
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
      title: title,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  Widget _buildRoot(BuildContext context) {
    final children = <Widget>[
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          widget.title,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      const SizedBox(height: 8),
      ...widget.header,
    ];

    for (final section in widget.radioSections) {
      if (section.items.isEmpty) continue;
      children.add(
        _rootMenuItem(
          key: Key('mobile-remote-options-open-${section.id}'),
          title: section.heading ?? Text(section.id),
          onTap: () => setState(() => _selectedSectionId = section.id),
        ),
      );
    }
    for (final action in widget.actions) {
      children.add(
        ListTile(
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          title: action.child,
          trailing: const Icon(Icons.chevron_right),
          onTap: action.onPressed,
        ),
      );
    }
    if (widget.toggles.isNotEmpty) {
      children.add(
        _rootMenuItem(
          key: const Key('mobile-remote-options-open-session-controls'),
          title: const Text('Session controls'),
          onTap: () => setState(() => _showToggles = true),
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

  Widget _buildRadioSection(
    BuildContext context,
    MobileRemoteRadioSection section,
  ) {
    final selectedValue = _radioValues[section.id] ?? section.value;
    final detailsBuilder = section.selectionDetailsBuilder;
    return Column(
      key: Key('mobile-remote-options-submenu-${section.id}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _backHeader(
          context,
          section.heading is Text
              ? ((section.heading as Text).data ?? section.id)
              : section.id,
          () => setState(() => _selectedSectionId = null),
        ),
        RadioGroup<String>(
          groupValue: selectedValue,
          onChanged: (value) {
            if (value == null) return;
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
        if (detailsBuilder != null) detailsBuilder(selectedValue),
      ],
    );
  }

  Widget _buildToggles(BuildContext context) {
    return Column(
      key: const Key('mobile-remote-options-session-controls'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _backHeader(
          context,
          'Session controls',
          () => setState(() => _showToggles = false),
        ),
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
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final section = _selectedSection;
    if (section != null) return _buildRadioSection(context, section);
    if (_showToggles) return _buildToggles(context);
    return _buildRoot(context);
  }
}
