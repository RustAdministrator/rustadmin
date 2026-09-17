import 'dart:async';

import 'package:flutter/foundation.dart';

import 'toolbar_menu_coordinator.dart';

@immutable
class ToolbarPresentation {
  const ToolbarPresentation({
    this.visible = true,
    this.opacity = 1,
    this.dragging = false,
    this.duration = const Duration(milliseconds: 180),
  });

  final bool visible;
  final double opacity;
  final bool dragging;
  final Duration duration;
}

/// Owns interaction policy; widgets only report events and project presentation.
/// Menu intent remains owned by [menus], never inferred from painted opacity.
class ToolbarInteractionController<T extends Object> extends ChangeNotifier
    implements ValueListenable<ToolbarPresentation> {
  ToolbarInteractionController({
    required this.menus,
    required this.onMenuFocusChanged,
    required this.scheduleAfterFrame,
    required bool pinned,
    required bool hidden,
    required Duration hideDelay,
    required Duration dimDelay,
    required Duration dimDuration,
    required double dimOpacity,
  }) : _pinned = pinned,
       _hidden = hidden,
       _hideDelay = hideDelay,
       _dimDelay = dimDelay,
       _dimDuration = dimDuration,
       _dimOpacity = dimOpacity,
       _value = ToolbarPresentation(visible: !hidden) {
    visibility = _ToolbarVisibility(this);
    menus.addListener(_menuChanged);
    _reconcile();
  }

  final ToolbarMenuCoordinator<T> menus;
  final ValueChanged<bool> onMenuFocusChanged;
  final ToolbarMenuCallbackScheduler scheduleAfterFrame;
  late final ValueListenable<bool> visibility;
  ToolbarPresentation _value;
  @override
  ToolbarPresentation get value => _value;

  bool _pinned;
  bool _hidden;
  bool _overToolbar = false;
  bool _inRevealZone = false;
  bool _dragging = false;
  int _menuHoverDepth = 0;
  final Set<int> _pressedPointers = {};
  final Map<T, int> _menuPresses = {};
  final Map<T, int> _suppressedButtonActivations = {};
  int _activationGeneration = 0;
  ToolbarMenuPhase _lastMenuPhase = ToolbarMenuPhase.closed;
  Duration _hideDelay;
  Duration _dimDelay;
  Duration _dimDuration;
  double _dimOpacity;
  Timer? _idleTimer;
  int _timerGeneration = 0;
  bool _disposed = false;

  bool get _protected =>
      _overToolbar ||
      _menuHoverDepth > 0 ||
      _dragging ||
      _pressedPointers.isNotEmpty ||
      menus.isInteractionActive;
  bool get _idleEligible =>
      !_hidden && value.visible && !_protected && (_pinned || !_inRevealZone);

  void _publish(bool visible, double opacity, Duration duration) {
    if (_disposed ||
        (value.visible == visible &&
            value.opacity == opacity &&
            value.duration == duration &&
            value.dragging == _dragging)) {
      return;
    }
    _value = ToolbarPresentation(
      visible: visible,
      opacity: opacity,
      duration: duration,
      dragging: _dragging,
    );
    // Render hit testing listens directly, before a widget frame can run.
    notifyListeners();
  }

  void _cancelIdle() {
    _timerGeneration++;
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _reconcile({bool restartIdle = false, bool reveal = false}) {
    if (_disposed) return;
    if (_hidden) {
      _cancelIdle();
      _publish(false, 0, const Duration(milliseconds: 180));
      return;
    }
    if (restartIdle) _cancelIdle();
    if (reveal || _protected || (!_pinned && _inRevealZone)) {
      _publish(true, 1, const Duration(milliseconds: 180));
    }
    if (!_idleEligible) {
      _cancelIdle();
      return;
    }
    if (_pinned && value.opacity == _dimOpacity) return;
    if (_idleTimer != null) return;
    final generation = ++_timerGeneration;
    _idleTimer = Timer(_pinned ? _dimDelay : _hideDelay, () {
      if (_disposed || generation != _timerGeneration) return;
      _idleTimer = null;
      if (!_idleEligible) return;
      if (_pinned) {
        _publish(true, _dimOpacity, _dimDuration);
      } else {
        _publish(false, 0, const Duration(milliseconds: 180));
      }
    });
  }

  void windowPointer({required bool inRevealZone}) {
    _inRevealZone = inRevealZone;
    _reconcile(restartIdle: !_pinned);
  }

  void toolbarHover(bool inside) {
    _overToolbar = inside;
    _reconcile();
  }

  void menuHover(bool inside) {
    if (inside) {
      _menuHoverDepth++;
    } else if (_menuHoverDepth > 0) {
      _menuHoverDepth--;
    }
    _reconcile();
  }

  void pointerDown(int pointer) {
    _pressedPointers.add(pointer);
    _reconcile(reveal: true);
  }

  void pointerEnded(int pointer) {
    _pressedPointers.remove(pointer);
    _reconcile(reveal: true);
  }

  void dragging(bool dragging) {
    _dragging = dragging;
    if (dragging) menus.closeAll();
    _reconcile(reveal: true);
    _publish(value.visible, value.opacity, value.duration);
  }

  void setPinned(bool pinned) {
    if (_pinned == pinned) return;
    _pinned = pinned;
    _reconcile(restartIdle: true, reveal: true);
  }

  void setHidden(bool hidden) {
    if (_hidden == hidden) return;
    _hidden = hidden;
    _overToolbar = false;
    _menuHoverDepth = 0;
    _pressedPointers.clear();
    _menuPresses.clear();
    _suppressedButtonActivations.clear();
    if (hidden) menus.closeAll();
    _reconcile(restartIdle: true, reveal: !hidden);
  }

  void updateSettings({
    required Duration hideDelay,
    required Duration dimDelay,
    required Duration dimDuration,
    required double dimOpacity,
  }) {
    final wasDimmed = _pinned && value.opacity < 1;
    _hideDelay = hideDelay;
    _dimDelay = dimDelay;
    _dimDuration = dimDuration;
    _dimOpacity = dimOpacity;
    if (wasDimmed && _idleEligible) {
      _publish(true, _dimOpacity, const Duration(milliseconds: 180));
    }
    _reconcile(restartIdle: true);
  }

  void _menuChanged() {
    final phase = menus.phase;
    final previous = _lastMenuPhase;
    _lastMenuPhase = phase;
    // Closing overlays can disappear without a matching mouse exit.
    if (phase == ToolbarMenuPhase.closing || phase == ToolbarMenuPhase.closed) {
      _menuHoverDepth = 0;
    }
    if ((previous != ToolbarMenuPhase.closed) != menus.isInteractionActive) {
      onMenuFocusChanged(menus.isInteractionActive);
    }
    _reconcile();
  }

  void menuPointerDown(T id, int pointer) {
    if (_disposed || _hidden) return;
    _menuPresses[id] = pointer;
    _suppressedButtonActivations[id] = ++_activationGeneration;
  }

  void menuPointerUp(T id, int pointer) {
    if (_disposed || _menuPresses[id] != pointer) return;
    _menuPresses.remove(id);
    final generation = _suppressedButtonActivations[id];
    menus.activate(id);
    // TextButton may also dispatch this mouse gesture. Keyboard/semantics
    // activation remains available after this frame, without toggling twice.
    scheduleAfterFrame(() {
      if (_disposed || _suppressedButtonActivations[id] != generation) return;
      _suppressedButtonActivations.remove(id);
    });
  }

  void cancelMenuPointer(T id) {
    _menuPresses.remove(id);
    _suppressedButtonActivations.remove(id);
  }

  void activateMenuFromButton(T id) {
    if (_disposed || _hidden || _suppressedButtonActivations.containsKey(id)) {
      return;
    }
    menus.activate(id);
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelIdle();
    menus.removeListener(_menuChanged);
    if (menus.isInteractionActive) onMenuFocusChanged(false);
    super.dispose();
  }
}

/// A read-only projection, not a second visibility store.
class _ToolbarVisibility implements ValueListenable<bool> {
  const _ToolbarVisibility(this.controller);
  final ToolbarInteractionController controller;
  @override
  bool get value => controller.value.visible;
  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);
}
