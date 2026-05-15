import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_svg/flutter_svg.dart';

enum ToolbarLabShape {
  compact,
  expanded,
}

class _LabToolbarTheme {
  static const Color blueColor = MyTheme.button;
  static const Color hoverBlueColor = MyTheme.accent;
  static const Color redColor = Colors.redAccent;
  static const Color hoverRedColor = Colors.red;
  static const double buttonSize = 32;
  static const double buttonHMargin = 2;
  static const double buttonVMargin = 6;
  static const double iconRadius = 8;
  static const double elevation = 3;
  static const double compactHeight = 20;

  static Color inactiveColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? Colors.grey[700]!
        : Colors.grey[800]!;
  }

  static Color hoverInactiveColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? Colors.grey[600]!
        : Colors.grey[850]!;
  }

  static Color borderColor(BuildContext context) {
    return MyTheme.color(context).border3 ?? MyTheme.border;
  }

  static Color backgroundColor(BuildContext context) {
    return Theme.of(context)
            .menuBarTheme
            .style
            ?.backgroundColor
            ?.resolve(WidgetState.values.toSet()) ??
        Theme.of(context).cardColor;
  }
}

class ToolbarLabPage extends StatefulWidget {
  const ToolbarLabPage({super.key});

  @override
  State<ToolbarLabPage> createState() => _ToolbarLabPageState();
}

class _ToolbarLabPageState extends State<ToolbarLabPage> {
  static const double _toolbarTop = 20;
  static const double _toolbarHoverPadding = 28;

  ToolbarLabShape _shape = ToolbarLabShape.compact;
  bool _visible = false;
  bool _pinned = false;
  bool _fullscreen = false;
  bool _showRevealZone = true;
  double _activationZoneHeight = 36;
  double _hideDelayMs = 300;
  double _compactWidth = 316;
  double _expandedWidth = 1080;
  Offset _pointer = const Offset(-1000, -1000);
  Size _viewport = Size.zero;
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          _viewport = Size(constraints.maxWidth, constraints.maxHeight);
          return MouseRegion(
            onHover: (event) => _handlePointer(event.localPosition),
            onExit: (_) => _handlePointer(const Offset(-1000, -1000)),
            child: Stack(
              children: [
                Positioned.fill(child: _ToolbarLabBackdrop(pointer: _pointer)),
                if (_showRevealZone)
                  Positioned(
                    left: 24,
                    right: 24,
                    top: 12,
                    height: _activationZoneHeight,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4.0),
                          border: Border.all(
                            color: scheme.primary.withValues(alpha: 0.28),
                          ),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              scheme.primary.withValues(alpha: 0.18),
                              scheme.primary.withValues(alpha: 0.04),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              'Reveal zone',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(
                                    color: scheme.primary,
                                    letterSpacing: 0.3,
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                _buildPrototypeToolbar(context),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Toolbar lab',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Move the pointer near the top edge to reveal the toolbar. '
                                'Pin keeps the current toolbar shape visible; expand/collapse simulates '
                                'the merged helper + full toolbar concept.',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(height: 1.35),
                              ),
                              const SizedBox(height: 18),
                              _buildSwitch(
                                context,
                                value: _pinned,
                                title: 'Pinned toolbar',
                                subtitle:
                                    'Keeps the current toolbar shape visible, whether compact or expanded.',
                                onChanged: (value) {
                                  setState(() {
                                    _pinned = value;
                                    if (_pinned && !_visible) {
                                      _visible = true;
                                    }
                                  });
                                },
                              ),
                              _buildSwitch(
                                context,
                                value: _showRevealZone,
                                title: 'Show reveal zone',
                                subtitle:
                                    'Visualize the mouse activation band that brings the toolbar back.',
                                onChanged: (value) {
                                  setState(() {
                                    _showRevealZone = value;
                                  });
                                },
                              ),
                              const SizedBox(height: 8),
                              _buildSlider(
                                context,
                                label: 'Reveal zone',
                                value: _activationZoneHeight,
                                min: 36,
                                max: 180,
                                suffix: 'px',
                                onChanged: (value) {
                                  setState(() {
                                    _activationZoneHeight = value;
                                  });
                                },
                              ),
                              _buildSlider(
                                context,
                                label: 'Hide delay',
                                value: _hideDelayMs,
                                min: 150,
                                max: 2000,
                                suffix: 'ms',
                                onChanged: (value) {
                                  setState(() {
                                    _hideDelayMs = value;
                                  });
                                },
                              ),
                              _buildSlider(
                                context,
                                label: 'Compact width',
                                value: _compactWidth,
                                min: 240,
                                max: 420,
                                suffix: 'px',
                                onChanged: (value) {
                                  setState(() {
                                    _compactWidth = value;
                                  });
                                },
                              ),
                              _buildSlider(
                                context,
                                label: 'Expanded width',
                                value: _expandedWidth,
                                min: 760,
                                max: 1360,
                                suffix: 'px',
                                onChanged: (value) {
                                  setState(() {
                                    _expandedWidth = value;
                                  });
                                },
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton(
                                    onPressed: _hideToolbar,
                                    child: const Text('Hide'),
                                  ),
                                  OutlinedButton(
                                    onPressed: () =>
                                        _showToolbar(ToolbarLabShape.compact),
                                    child: const Text('Show compact'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        _showToolbar(ToolbarLabShape.expanded),
                                    child: const Text('Show expanded'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              Divider(
                                  color: isDark ? null : scheme.outlineVariant),
                              const SizedBox(height: 12),
                              _buildMetricRow('Visibility',
                                  _visible ? 'VISIBLE' : 'HIDDEN'),
                              _buildMetricRow(
                                  'Shape', _shape.name.toUpperCase()),
                              _buildMetricRow(
                                  'Pointer',
                                  _pointer.dx < 0
                                      ? 'outside'
                                      : '${_pointer.dx.toStringAsFixed(0)}, ${_pointer.dy.toStringAsFixed(0)}'),
                              _buildMetricRow('Pin mode',
                                  _pinned ? 'LOCKED VISIBLE' : 'AUTO HIDE'),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildPrototypeToolbar(BuildContext context) {
    final toolbarRect = _toolbarRect(_shape);
    final expanded = _shape == ToolbarLabShape.expanded;
    final borderRadius = expanded
        ? const BorderRadius.all(Radius.circular(4.0))
        : const BorderRadius.vertical(bottom: Radius.circular(4.0));

    return Positioned(
      left: toolbarRect.left,
      top: _toolbarTop,
      width: toolbarRect.width,
      child: IgnorePointer(
        ignoring: !_visible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          offset: _visible ? Offset.zero : const Offset(0, -1.15),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: _visible ? 1 : 0,
            child: MouseRegion(
              onEnter: (_) => _cancelHide(),
              onExit: (_) => _scheduleHide(),
              child: Material(
                elevation: _LabToolbarTheme.elevation,
                shadowColor: MyTheme.color(context).shadow,
                borderRadius: borderRadius,
                color: _LabToolbarTheme.backgroundColor(context),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: expanded
                      ? _buildExpandedContent(context, borderRadius)
                      : _buildCompactContent(context, borderRadius),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactContent(BuildContext context, BorderRadius borderRadius) {
    final iconColor = Theme.of(context).iconTheme.color;
    return _buildCompactBarShell(
      context,
      key: const ValueKey('compact'),
      borderRadius: borderRadius,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildDragHandle(context),
          _CompactIconButton(
            tooltip: _pinned ? 'Unpin toolbar' : 'Pin toolbar',
            onPressed: () {
              setState(() {
                _pinned = !_pinned;
                if (_pinned && !_visible) {
                  _visible = true;
                }
              });
            },
            child: SvgPicture.asset(
              _pinned ? 'assets/pinned.svg' : 'assets/unpinned.svg',
              width: 20,
              height: 20,
              colorFilter: ColorFilter.mode(
                _pinned
                    ? _LabToolbarTheme.blueColor
                    : (iconColor ?? Colors.black87),
                BlendMode.srcIn,
              ),
            ),
          ),
          _CompactIconButton(
            tooltip: _fullscreen ? 'Exit fullscreen' : 'Fullscreen',
            onPressed: () {
              setState(() {
                _fullscreen = !_fullscreen;
              });
            },
            child: Icon(
              _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              size: 20,
            ),
          ),
          _CompactIconButton(
            tooltip: 'Expand toolbar',
            onPressed: () => _showToolbar(ToolbarLabShape.expanded),
            child: const Icon(Icons.expand_more, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandedContent(
      BuildContext context, BorderRadius borderRadius) {
    return AnimatedContainer(
      key: const ValueKey('expanded'),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: _LabToolbarTheme.backgroundColor(context),
        border: Border.all(
          color: _LabToolbarTheme.borderColor(context),
          width: 1,
        ),
        borderRadius: borderRadius,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const SizedBox(width: _LabToolbarTheme.buttonHMargin * 2),
            _buildRemoteIdPill(context),
            const SizedBox(width: 6),
            _ExpandedDivider(color: MyTheme.color(context).divider),
            _LabToolbarButton(
              tooltip: _pinned ? 'Unpin toolbar' : 'Pin toolbar',
              assetName: _pinned ? 'assets/pinned.svg' : 'assets/unpinned.svg',
              color: _pinned
                  ? _LabToolbarTheme.blueColor
                  : _LabToolbarTheme.inactiveColor(context),
              hoverColor: _pinned
                  ? _LabToolbarTheme.hoverBlueColor
                  : _LabToolbarTheme.hoverInactiveColor(context),
              onPressed: () {
                setState(() {
                  _pinned = !_pinned;
                });
              },
            ),
            _LabToolbarButton(
              tooltip: 'Select monitor',
              assetName: 'assets/screen.svg',
              color: _LabToolbarTheme.blueColor,
              hoverColor: _LabToolbarTheme.hoverBlueColor,
              onPressed: () {},
            ),
            _LabToolbarButton(
              tooltip: 'Control actions',
              assetName: 'assets/actions.svg',
              color: _LabToolbarTheme.blueColor,
              hoverColor: _LabToolbarTheme.hoverBlueColor,
              onPressed: () {},
            ),
            _LabToolbarButton(
              tooltip: 'Display settings',
              assetName: 'assets/display.svg',
              color: _LabToolbarTheme.blueColor,
              hoverColor: _LabToolbarTheme.hoverBlueColor,
              onPressed: () {},
            ),
            _LabToolbarButton(
              tooltip: 'Keyboard and mouse',
              assetName: 'assets/keyboard_mouse.svg',
              color: _LabToolbarTheme.blueColor,
              hoverColor: _LabToolbarTheme.hoverBlueColor,
              onPressed: () {},
            ),
            _LabToolbarButton(
              tooltip: 'Chat',
              assetName: 'assets/chat.svg',
              color: _LabToolbarTheme.blueColor,
              hoverColor: _LabToolbarTheme.hoverBlueColor,
              onPressed: () {},
            ),
            _LabToolbarButton(
              tooltip: 'Voice call',
              assetName: 'assets/voice_call.svg',
              color: _LabToolbarTheme.blueColor,
              hoverColor: _LabToolbarTheme.hoverBlueColor,
              onPressed: () {},
            ),
            _LabToolbarButton(
              tooltip: 'Record',
              assetName: 'assets/rec.svg',
              color: _LabToolbarTheme.blueColor,
              hoverColor: _LabToolbarTheme.hoverBlueColor,
              onPressed: () {},
            ),
            _ExpandedDivider(color: MyTheme.color(context).divider),
            _LabToolbarButton(
              tooltip: _fullscreen ? 'Exit fullscreen' : 'Fullscreen',
              icon: Icon(
                _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                size: _LabToolbarTheme.buttonSize,
                color: Colors.white,
              ),
              color: _LabToolbarTheme.blueColor,
              hoverColor: _LabToolbarTheme.hoverBlueColor,
              onPressed: () {
                setState(() {
                  _fullscreen = !_fullscreen;
                });
              },
            ),
            _LabToolbarButton(
              tooltip: 'Collapse toolbar',
              icon: const Icon(
                Icons.expand_less,
                size: _LabToolbarTheme.buttonSize,
                color: Colors.white,
              ),
              color: _LabToolbarTheme.inactiveColor(context),
              hoverColor: _LabToolbarTheme.hoverInactiveColor(context),
              onPressed: () => _showToolbar(ToolbarLabShape.compact),
            ),
            _LabToolbarButton(
              tooltip: 'Close',
              assetName: 'assets/close.svg',
              color: _LabToolbarTheme.redColor,
              hoverColor: _LabToolbarTheme.hoverRedColor,
              onPressed: () {},
            ),
            const SizedBox(width: _LabToolbarTheme.buttonHMargin * 2),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactBarShell(
    BuildContext context, {
    required Key key,
    required BorderRadius borderRadius,
    required Widget child,
  }) {
    return Container(
      key: key,
      decoration: BoxDecoration(
        color: _LabToolbarTheme.backgroundColor(context),
        border: Border.all(
          color: _LabToolbarTheme.borderColor(context),
          width: 1,
        ),
        borderRadius: borderRadius,
      ),
      child: SizedBox(
        height: _LabToolbarTheme.compactHeight,
        child: child,
      ),
    );
  }

  Widget _buildDragHandle(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Icon(
        Icons.drag_indicator,
        size: 20,
        color: MyTheme.color(context).drag_indicator,
      ),
    );
  }

  Widget _buildRemoteIdPill(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: MyTheme.accent50,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '192.168.11.2',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }

  Widget _buildSwitch(
    BuildContext context, {
    required bool value,
    required String title,
    required String subtitle,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile.adaptive(
      value: value,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }

  Widget _buildSlider(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required String suffix,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text('${value.toStringAsFixed(0)}$suffix'),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          label: '${value.toStringAsFixed(0)}$suffix',
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildMetricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  void _handlePointer(Offset position) {
    final nearRevealZone = _isPointerInRevealZone(position);
    final nearToolbar =
        _toolbarRect(_shape).inflate(_toolbarHoverPadding).contains(position);

    if (mounted) {
      setState(() {
        _pointer = position;
      });
    }

    if (nearRevealZone || nearToolbar) {
      _cancelHide();
      if (!_visible) {
        _showToolbar(_shape, scheduleHide: false);
      }
    } else if (_visible) {
      _scheduleHide();
    }
  }

  bool _isPointerInRevealZone(Offset position) {
    return position.dx >= 0 &&
        position.dy >= 0 &&
        position.dy <= _activationZoneHeight;
  }

  void _showToolbar(ToolbarLabShape next, {bool scheduleHide = true}) {
    _cancelHide();
    if (!mounted) return;
    setState(() {
      _shape = next;
      _visible = true;
    });
    if (scheduleHide && !_pinned && !_isPointerInRevealZone(_pointer)) {
      _scheduleHide();
    }
  }

  void _hideToolbar() {
    _cancelHide();
    if (!mounted) return;
    setState(() {
      _visible = false;
    });
  }

  void _scheduleHide() {
    if (_pinned || !_visible) {
      return;
    }
    _hideTimer?.cancel();
    _hideTimer = Timer(
      Duration(milliseconds: _hideDelayMs.round()),
      () {
        if (!mounted) return;
        final stillNearRevealZone = _isPointerInRevealZone(_pointer);
        final stillNearToolbar = _toolbarRect(_shape)
            .inflate(_toolbarHoverPadding)
            .contains(_pointer);
        if (!stillNearRevealZone && !stillNearToolbar) {
          setState(() {
            _visible = false;
          });
        }
      },
    );
  }

  void _cancelHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  Rect _toolbarRect(ToolbarLabShape shape) {
    final compactWidth = _compactWidth.clamp(240, _maxToolbarWidth).toDouble();
    final expandedWidth =
        _expandedWidth.clamp(760, _maxToolbarWidth).toDouble();
    final width =
        shape == ToolbarLabShape.expanded ? expandedWidth : compactWidth;
    final height = shape == ToolbarLabShape.expanded ? 46.0 : 22.0;
    final left = (_viewport.width - width) / 2;
    return Rect.fromLTWH(left, _toolbarTop, width, height);
  }

  double get _maxToolbarWidth {
    if (_viewport.width <= 64) {
      return _expandedWidth;
    }
    return _viewport.width - 48;
  }
}

class _CompactIconButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback onPressed;
  final Widget child;

  const _CompactIconButton({
    required this.tooltip,
    required this.onPressed,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final buttonStyle = ButtonStyle(
      minimumSize: WidgetStateProperty.all(const Size(0, 0)),
      padding: WidgetStateProperty.all(EdgeInsets.zero),
    );

    return TextButton(
      onPressed: onPressed,
      style: buttonStyle.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) {
            return _LabToolbarTheme.blueColor.withValues(alpha: 0.15);
          }
          return Colors.transparent;
        }),
      ),
      child: Tooltip(message: tooltip, child: child),
    );
  }
}

class _ExpandedDivider extends StatelessWidget {
  final Color? color;

  const _ExpandedDivider({this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 12,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: color ?? Theme.of(context).dividerColor,
    );
  }
}

class _LabToolbarButton extends StatefulWidget {
  final String tooltip;
  final String? assetName;
  final Widget? icon;
  final Color color;
  final Color hoverColor;
  final VoidCallback onPressed;

  const _LabToolbarButton({
    required this.tooltip,
    this.assetName,
    this.icon,
    required this.color,
    required this.hoverColor,
    required this.onPressed,
  }) : assert(assetName != null || icon != null);

  @override
  State<_LabToolbarButton> createState() => _LabToolbarButtonState();
}

class _LabToolbarButtonState extends State<_LabToolbarButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final child = widget.icon ??
        SvgPicture.asset(
          widget.assetName!,
          colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
          width: _LabToolbarTheme.buttonSize,
          height: _LabToolbarTheme.buttonSize,
        );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: _LabToolbarTheme.buttonHMargin,
        vertical: _LabToolbarTheme.buttonVMargin,
      ),
      child: Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(_LabToolbarTheme.iconRadius),
            child: Ink(
              width: _LabToolbarTheme.buttonSize,
              height: _LabToolbarTheme.buttonSize,
              decoration: BoxDecoration(
                borderRadius:
                    BorderRadius.circular(_LabToolbarTheme.iconRadius),
                color: _hover ? widget.hoverColor : widget.color,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarLabBackdrop extends StatelessWidget {
  final Offset pointer;

  const _ToolbarLabBackdrop({required this.pointer});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? const [
                  Color(0xFF0F131A),
                  Color(0xFF111926),
                  Color(0xFF151E2B),
                ]
              : const [
                  Color(0xFFF5F7FA),
                  Color(0xFFE9EEF5),
                  Color(0xFFE3EAF3),
                ],
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _BackdropGridPainter(
                  lineColor: scheme.outlineVariant.withValues(
                    alpha: isDark ? 0.16 : 0.3,
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(84, 120, 84, 120),
              child: Row(
                children: const [
                  Expanded(
                    flex: 7,
                    child: _MockMonitorCard(
                      label: 'Primary display',
                      accent: Color(0xFF2C8CFF),
                    ),
                  ),
                  SizedBox(width: 20),
                  Expanded(
                    flex: 4,
                    child: _MockMonitorCard(
                      label: 'Secondary display',
                      accent: Color(0xFF34C38F),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (pointer.dx >= 0 && pointer.dy >= 0)
            Positioned(
              left: pointer.dx - 10,
              top: pointer.dy - 10,
              child: IgnorePointer(
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary.withValues(alpha: 0.16),
                    border: Border.all(color: scheme.primary, width: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MockMonitorCard extends StatelessWidget {
  final String label;
  final Color accent;

  const _MockMonitorCard({
    required this.label,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AspectRatio(
      aspectRatio: 16 / 10,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4.0),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.white.withValues(alpha: 0.7),
            width: 1.4,
          ),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              accent.withValues(alpha: isDark ? 0.24 : 0.14),
              accent.withValues(alpha: isDark ? 0.1 : 0.05),
              isDark ? const Color(0xFF1A2230) : Colors.white,
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.24 : 0.08),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const Spacer(),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: const [
                  _MockChip(label: 'Remote desktop'),
                  _MockChip(label: '1440 x 900'),
                  _MockChip(label: 'Adaptive scale'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MockChip extends StatelessWidget {
  final String label;

  const _MockChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Text(label),
    );
  }
}

class _BackdropGridPainter extends CustomPainter {
  final Color lineColor;

  const _BackdropGridPainter({required this.lineColor});

  @override
  void paint(Canvas canvas, Size size) {
    const step = 40.0;
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;

    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BackdropGridPainter oldDelegate) {
    return oldDelegate.lineColor != lineColor;
  }
}
