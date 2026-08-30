import 'package:flutter/foundation.dart';

typedef ToolbarMenuCallbackScheduler = void Function(VoidCallback callback);

enum ToolbarMenuPhase { closed, opening, open, closing }

class ToolbarMenuHandle {
  const ToolbarMenuHandle({required this.isOpen, required this.open});

  final bool Function() isOpen;
  final VoidCallback open;
}

/// Serializes top-level toolbar menu intent independently of Flutter's overlay
/// callback ordering.
///
/// [activeMenuId], [pendingMenuId], and [phase] are the logical source of
/// truth. The group and per-anchor values supplied by Flutter are used only to
/// acknowledge that an overlay transition has completed.
class ToolbarMenuCoordinator<T extends Object> extends ChangeNotifier {
  factory ToolbarMenuCoordinator({
    required bool Function() isGroupOpen,
    required VoidCallback closeGroup,
    required ToolbarMenuCallbackScheduler scheduleCallback,
  }) {
    return ToolbarMenuCoordinator._(isGroupOpen, closeGroup, scheduleCallback);
  }

  ToolbarMenuCoordinator._(
    this._isGroupOpen,
    this._closeGroup,
    this._scheduleCallback,
  );

  final bool Function() _isGroupOpen;
  final VoidCallback _closeGroup;
  final ToolbarMenuCallbackScheduler _scheduleCallback;
  final Map<T, ToolbarMenuHandle> _menus = <T, ToolbarMenuHandle>{};

  T? _activeMenuId;
  T? _pendingMenuId;
  ToolbarMenuPhase _phase = ToolbarMenuPhase.closed;
  int _generation = 0;
  int? _openingGeneration;
  int? _scheduledGeneration;
  int _openingRetries = 0;
  bool _disposed = false;

  T? get activeMenuId => _activeMenuId;
  T? get pendingMenuId => _pendingMenuId;
  ToolbarMenuPhase get phase => _phase;
  int get generation => _generation;
  bool get isInteractionActive => _phase != ToolbarMenuPhase.closed;

  void registerMenu(T id, ToolbarMenuHandle handle) {
    if (_disposed) return;
    _menus[id] = handle;
  }

  void unregisterMenu(T id, ToolbarMenuHandle handle) {
    if (_disposed || !identical(_menus[id], handle)) return;
    _menus.remove(id);

    var changed = false;
    if (_pendingMenuId == id) {
      _pendingMenuId = null;
      changed = true;
    }
    if (_activeMenuId == id) {
      _activeMenuId = null;
      _openingGeneration = null;
      changed = true;
    }
    if (!changed) return;

    _generation += 1;
    _phase = _isGroupOpen()
        ? ToolbarMenuPhase.closing
        : ToolbarMenuPhase.closed;
    final generation = _generation;
    _scheduleCallback(() {
      if (_disposed || generation != _generation) return;
      _publish();
      _reconcile(generation);
    });
  }

  void activate(T id) {
    if (_disposed || !_menus.containsKey(id)) return;

    _generation += 1;

    // A repeated activation toggles a pending open back off while another
    // anchor is closing.
    if (_pendingMenuId == id) {
      _pendingMenuId = null;
      _beginClose();
      return;
    }

    // The visible or opening target is toggled closed.
    if (_activeMenuId == id &&
        (_phase == ToolbarMenuPhase.open ||
            _phase == ToolbarMenuPhase.opening)) {
      _pendingMenuId = null;
      _beginClose();
      return;
    }

    if (_phase != ToolbarMenuPhase.closed ||
        _activeMenuId != null ||
        _isGroupOpen()) {
      // Latest intent wins. It is never discarded while the current overlay
      // finishes closing.
      _pendingMenuId = id;
      _beginClose();
      return;
    }

    _openMenu(id);
  }

  void closeAll() {
    if (_disposed) return;
    _generation += 1;
    _pendingMenuId = null;

    if (_phase == ToolbarMenuPhase.closed &&
        _activeMenuId == null &&
        !_isGroupOpen()) {
      return;
    }
    _beginClose();
  }

  void menuOpened(T id) {
    if (_disposed || !_menus.containsKey(id)) return;

    final expected =
        _phase == ToolbarMenuPhase.opening &&
        _activeMenuId == id &&
        _openingGeneration == _generation;
    if (!expected) {
      // An obsolete open callback must not replace newer user intent. Close
      // the actual overlay while preserving any pending target.
      _activeMenuId = id;
      _openingGeneration = null;
      _phase = ToolbarMenuPhase.closing;
      _publish();
      _closeGroup();
      _scheduleReconcile();
      return;
    }

    _activeMenuId = id;
    if (_pendingMenuId == id) {
      _pendingMenuId = null;
    }
    _openingGeneration = null;
    _openingRetries = 0;
    _phase = ToolbarMenuPhase.open;
    _publish();
  }

  void menuClosing(T id) {
    if (_disposed || !_menus.containsKey(id)) return;
    if (_activeMenuId == null) {
      _activeMenuId = id;
    }
    if (_activeMenuId != id) return;
    _phase = ToolbarMenuPhase.closing;
    _publish();
    _scheduleReconcile();
  }

  void menuClosed(T id) {
    if (_disposed) return;

    // MenuController.open() can synchronously close a stale anchor and then
    // reopen it. Preserve the opening intent until the matching onOpen or the
    // generation-scoped reconciliation callback arrives.
    if (_phase == ToolbarMenuPhase.opening && _activeMenuId == id) {
      _scheduleReconcile();
      return;
    }

    if (_activeMenuId == id) {
      _activeMenuId = null;
      _openingGeneration = null;
    }

    if (_activeMenuId != null) {
      _phase = ToolbarMenuPhase.open;
      _publish();
      return;
    }

    _phase = _pendingMenuId == null && !_isGroupOpen()
        ? ToolbarMenuPhase.closed
        : ToolbarMenuPhase.closing;
    _publish();
    _reconcile(_generation);
  }

  void _beginClose() {
    _phase = ToolbarMenuPhase.closing;
    _publish();
    _closeGroup();
    _reconcile(_generation);
    _scheduleReconcile();
  }

  void _openMenu(T id) {
    final handle = _menus[id];
    if (handle == null) {
      _activeMenuId = null;
      _pendingMenuId = null;
      _openingGeneration = null;
      _phase = ToolbarMenuPhase.closed;
      _publish();
      return;
    }

    _activeMenuId = id;
    _pendingMenuId = null;
    _phase = ToolbarMenuPhase.opening;
    _openingGeneration = _generation;
    _openingRetries = 0;
    _publish();
    handle.open();
    _scheduleReconcile();
  }

  void _reconcile(int generation) {
    if (_disposed || generation != _generation) return;

    final groupOpen = _isGroupOpen();
    if (_phase == ToolbarMenuPhase.opening) {
      final id = _activeMenuId;
      final handle = id == null ? null : _menus[id];
      if (groupOpen && handle?.isOpen() == true) {
        _openingGeneration = null;
        _phase = ToolbarMenuPhase.open;
        _openingRetries = 0;
        _publish();
        return;
      }
      if (groupOpen) {
        _pendingMenuId = id;
        _activeMenuId = null;
        _openingGeneration = null;
        _phase = ToolbarMenuPhase.closing;
        _publish();
        _closeGroup();
        return;
      }
      if (id != null && handle != null && _openingRetries == 0) {
        _openingRetries += 1;
        handle.open();
        _scheduleReconcile();
        return;
      }
      _activeMenuId = null;
      _openingGeneration = null;
      _phase = ToolbarMenuPhase.closed;
      _publish();
      return;
    }

    if (_phase != ToolbarMenuPhase.closing || groupOpen) return;

    _activeMenuId = null;
    _openingGeneration = null;
    final next = _pendingMenuId;
    if (next == null) {
      _phase = ToolbarMenuPhase.closed;
      _publish();
      return;
    }
    _pendingMenuId = null;
    _openMenu(next);
  }

  void _scheduleReconcile() {
    if (_disposed || _scheduledGeneration == _generation) return;
    final generation = _generation;
    _scheduledGeneration = generation;
    _scheduleCallback(() {
      if (_scheduledGeneration == generation) {
        _scheduledGeneration = null;
      }
      _reconcile(generation);
    });
  }

  void _publish() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
    _scheduledGeneration = null;
    _activeMenuId = null;
    _pendingMenuId = null;
    _openingGeneration = null;
    _phase = ToolbarMenuPhase.closed;
    _menus.clear();
    super.dispose();
  }
}
