import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/desktop/widgets/toolbar_menu_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeMenu {
  _FakeMenu(this.id, this.owner);

  final String id;
  final _MenuHarness owner;
  bool isOpen = false;
  bool deferOpen = false;
  int openCalls = 0;

  late final ToolbarMenuHandle handle = ToolbarMenuHandle(
    isOpen: () => isOpen,
    open: open,
  );

  void open() {
    openCalls += 1;
    if (deferOpen) return;
    completeOpen();
  }

  void completeOpen() {
    if (isOpen) {
      owner.coordinator.menuClosed(id);
    }
    isOpen = true;
    owner.groupOpen = true;
    owner.coordinator.menuOpened(id);
  }
}

class _MenuHarness {
  _MenuHarness() {
    coordinator = ToolbarMenuCoordinator<String>(
      isGroupOpen: () => groupOpen,
      closeGroup: _closeGroup,
      scheduleCallback: scheduled.add,
    );
    for (final id in const ['display', 'keyboard', 'chat']) {
      final menu = _FakeMenu(id, this);
      menus[id] = menu;
      coordinator.registerMenu(id, menu.handle);
    }
  }

  late final ToolbarMenuCoordinator<String> coordinator;
  final Map<String, _FakeMenu> menus = <String, _FakeMenu>{};
  final List<VoidCallback> scheduled = <VoidCallback>[];
  bool groupOpen = false;
  int closeGroupCalls = 0;

  _FakeMenu menu(String id) => menus[id]!;

  void _closeGroup() {
    closeGroupCalls += 1;
    for (final menu in menus.values.where((menu) => menu.isOpen)) {
      coordinator.menuClosing(menu.id);
    }
  }

  void completeClose(String id) {
    menu(id).isOpen = false;
    groupOpen = menus.values.any((menu) => menu.isOpen);
    coordinator.menuClosed(id);
  }

  void flushScheduled() {
    var callbacksRun = 0;
    while (scheduled.isNotEmpty) {
      final callbacks = List<VoidCallback>.of(scheduled);
      scheduled.clear();
      for (final callback in callbacks) {
        callback();
        callbacksRun += 1;
        if (callbacksRun > 50) {
          fail('toolbar menu reconciliation did not converge');
        }
      }
    }
  }
}

void main() {
  test('one activation opens a closed menu and the next closes it', () {
    final harness = _MenuHarness();
    addTearDown(harness.coordinator.dispose);

    harness.coordinator.activate('display');

    expect(harness.coordinator.activeMenuId, 'display');
    expect(harness.coordinator.pendingMenuId, isNull);
    expect(harness.coordinator.phase, ToolbarMenuPhase.open);
    expect(harness.menu('display').openCalls, 1);

    harness.coordinator.activate('display');

    expect(harness.coordinator.phase, ToolbarMenuPhase.closing);
    expect(harness.coordinator.pendingMenuId, isNull);
    harness.completeClose('display');
    harness.flushScheduled();
    expect(harness.coordinator.phase, ToolbarMenuPhase.closed);
  });

  test('one activation switches sibling menus after close acknowledgement', () {
    final harness = _MenuHarness();
    addTearDown(harness.coordinator.dispose);
    harness.coordinator.activate('display');

    harness.coordinator.activate('keyboard');

    expect(harness.coordinator.phase, ToolbarMenuPhase.closing);
    expect(harness.coordinator.pendingMenuId, 'keyboard');
    expect(harness.menu('keyboard').openCalls, 0);

    harness.completeClose('display');
    harness.flushScheduled();

    expect(harness.coordinator.activeMenuId, 'keyboard');
    expect(harness.coordinator.pendingMenuId, isNull);
    expect(harness.coordinator.phase, ToolbarMenuPhase.open);
    expect(harness.menu('keyboard').openCalls, 1);
  });

  test('activation during a real close reopens without a second click', () {
    final harness = _MenuHarness();
    addTearDown(harness.coordinator.dispose);
    harness.coordinator.activate('display');

    harness.coordinator.menuClosing('display');
    harness.coordinator.activate('display');

    expect(harness.coordinator.pendingMenuId, 'display');
    harness.completeClose('display');
    harness.flushScheduled();

    expect(harness.coordinator.activeMenuId, 'display');
    expect(harness.coordinator.phase, ToolbarMenuPhase.open);
    expect(harness.menu('display').openCalls, 2);
  });

  test('stale private open state cannot consume the first activation', () {
    final harness = _MenuHarness();
    addTearDown(harness.coordinator.dispose);
    harness.menu('display').isOpen = true;
    harness.groupOpen = false;

    harness.coordinator.activate('display');
    harness.flushScheduled();

    expect(harness.menu('display').openCalls, 1);
    expect(harness.coordinator.activeMenuId, 'display');
    expect(harness.coordinator.phase, ToolbarMenuPhase.open);
  });

  test('latest rapid activation wins and obsolete callbacks are ignored', () {
    final harness = _MenuHarness();
    addTearDown(harness.coordinator.dispose);
    harness.coordinator.activate('display');

    harness.coordinator.activate('keyboard');
    harness.coordinator.activate('chat');
    harness.completeClose('display');
    harness.flushScheduled();

    expect(harness.coordinator.activeMenuId, 'chat');
    expect(harness.menu('keyboard').openCalls, 0);
    expect(harness.menu('chat').openCalls, 1);
  });

  test('repeating a pending activation cancels it', () {
    final harness = _MenuHarness();
    addTearDown(harness.coordinator.dispose);
    harness.coordinator.activate('display');

    harness.coordinator.activate('keyboard');
    harness.coordinator.activate('keyboard');
    harness.completeClose('display');
    harness.flushScheduled();

    expect(harness.coordinator.activeMenuId, isNull);
    expect(harness.coordinator.pendingMenuId, isNull);
    expect(harness.coordinator.phase, ToolbarMenuPhase.closed);
    expect(harness.menu('keyboard').openCalls, 0);
  });

  test('dispose cancels pending work and stale callbacks', () {
    final harness = _MenuHarness();
    harness.coordinator.activate('display');
    harness.coordinator.activate('keyboard');

    harness.coordinator.dispose();
    harness.completeClose('display');
    harness.flushScheduled();

    expect(harness.coordinator.phase, ToolbarMenuPhase.closed);
    expect(harness.menu('keyboard').openCalls, 0);
  });

  test('a delayed open callback cannot revive an obsolete generation', () {
    final harness = _MenuHarness();
    addTearDown(harness.coordinator.dispose);
    harness.menu('display').deferOpen = true;

    harness.coordinator.activate('display');
    harness.coordinator.closeAll();
    harness.menu('display').completeOpen();

    expect(harness.coordinator.phase, ToolbarMenuPhase.closing);
    harness.completeClose('display');
    harness.flushScheduled();

    expect(harness.coordinator.activeMenuId, isNull);
    expect(harness.coordinator.pendingMenuId, isNull);
    expect(harness.coordinator.phase, ToolbarMenuPhase.closed);
  });
}
