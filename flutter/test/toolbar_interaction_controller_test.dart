import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/desktop/widgets/toolbar_interaction_controller.dart';
import 'package:flutter_hbb/desktop/widgets/toolbar_menu_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

class _Harness {
  _Harness({bool pinned = false}) {
    menus = ToolbarMenuCoordinator<String>(
      isGroupOpen: () => open,
      closeGroup: () {
        if (open) menus.menuClosing('display');
      },
      scheduleCallback: callbacks.add,
    );
    menus.registerMenu(
      'display',
      ToolbarMenuHandle(
        isOpen: () => open,
        open: () {
          openCalls++;
          if (!deferOpen) {
            open = true;
            menus.menuOpened('display');
          }
        },
      ),
    );
    controller = ToolbarInteractionController(
      menus: menus,
      onMenuFocusChanged: focus.add,
      scheduleAfterFrame: callbacks.add,
      pinned: pinned,
      hidden: false,
      hideDelay: const Duration(seconds: 5),
      dimDelay: const Duration(seconds: 2),
      dimDuration: const Duration(milliseconds: 300),
      dimOpacity: 0.4,
    );
  }

  late final ToolbarMenuCoordinator<String> menus;
  late final ToolbarInteractionController<String> controller;
  final callbacks = <VoidCallback>[];
  final focus = <bool>[];
  bool open = false;
  bool deferOpen = false;
  int openCalls = 0;

  void closeAcknowledged() {
    open = false;
    menus.menuClosed('display');
  }

  void flush() {
    var count = 0;
    while (callbacks.isNotEmpty) {
      expect(++count, lessThan(100));
      callbacks.removeAt(0)();
    }
  }

  void dispose() {
    controller.dispose();
    menus.dispose();
  }
}

void main() {
  test('one visibility projection hides and synchronously reveals', () {
    fakeAsync((time) {
      final h = _Harness();
      addTearDown(h.dispose);
      time.elapse(const Duration(seconds: 5));
      expect(h.controller.visibility.value, isFalse);
      var observed = false;
      h.controller.visibility.addListener(
        () => observed = h.controller.visibility.value,
      );
      h.controller.windowPointer(inRevealZone: true);
      expect(observed, isTrue);
      expect(h.controller.value.opacity, 1);
      time.elapse(const Duration(minutes: 1));
      expect(h.controller.value.visible, isTrue);
      h.controller.windowPointer(inRevealZone: false);
      time.elapse(const Duration(seconds: 5));
      expect(h.controller.value.visible, isFalse);
    });
  });

  test('pinned fade ignores remote hover and restores on toolbar hover', () {
    fakeAsync((time) {
      final h = _Harness(pinned: true);
      addTearDown(h.dispose);
      time.elapse(const Duration(seconds: 1));
      h.controller.windowPointer(inRevealZone: true);
      time.elapse(const Duration(seconds: 1));
      expect(h.controller.value.visible, isTrue);
      expect(h.controller.value.opacity, 0.4);
      h.controller.toolbarHover(true);
      expect(h.controller.value.opacity, 1);
      time.elapse(const Duration(minutes: 1));
      expect(h.controller.value.opacity, 1);
    });
  });

  for (final pinned in [false, true]) {
    test('held pointers block idle transitions (pinned: $pinned)', () {
      fakeAsync((time) {
        final h = _Harness(pinned: pinned);
        addTearDown(h.dispose);
        h.controller.pointerDown(1);
        h.controller.pointerDown(2);
        h.controller.toolbarHover(false);
        h.controller.windowPointer(inRevealZone: false);
        h.controller.pointerEnded(1);
        time.elapse(const Duration(minutes: 1));
        expect(h.controller.value.visible, isTrue);
        expect(h.controller.value.opacity, 1);
        h.controller.pointerEnded(2);
        time.elapse(const Duration(seconds: 5));
        expect(h.controller.value.visible, pinned);
        expect(h.controller.value.opacity, pinned ? 0.4 : 0);
      });
    });
  }

  test(
    'opening and closing protect interaction until overlay acknowledges',
    () {
      fakeAsync((time) {
        final h = _Harness()..deferOpen = true;
        addTearDown(h.dispose);
        h.controller.activateMenuFromButton('display');
        time.elapse(const Duration(minutes: 1));
        expect(h.controller.value.visible, isTrue);
        expect(h.focus, [true]);
        h.open = true;
        h.menus.menuOpened('display');
        h.controller.menuHover(true);
        h.menus.closeAll();
        time.elapse(const Duration(minutes: 1));
        expect(h.controller.value.visible, isTrue);
        h.closeAcknowledged();
        expect(h.focus, [true, false]);
        time.elapse(const Duration(seconds: 5));
        // No menu-exit callback is needed when the overlay disappears.
        expect(h.controller.value.visible, isFalse);
      });
    },
  );

  test('pin changes retire both kinds of stale idle timers', () {
    fakeAsync((time) {
      final h = _Harness();
      addTearDown(h.dispose);
      time.elapse(const Duration(seconds: 4));
      h.controller.setPinned(true);
      time.elapse(const Duration(seconds: 1));
      expect(h.controller.value.visible, isTrue);
      h.controller.setPinned(false);
      time.elapse(const Duration(seconds: 1));
      expect(h.controller.value.opacity, 1);
      time.elapse(const Duration(seconds: 4));
      expect(h.controller.value.visible, isFalse);
    });
  });

  test('explicit hiding wins over menu callbacks and pending pointers', () {
    fakeAsync((time) {
      final h = _Harness();
      addTearDown(h.dispose);
      h.controller.activateMenuFromButton('display');
      h.controller.pointerDown(1);
      h.controller.menuPointerDown('display', 1);
      h.controller.setHidden(true);
      h.closeAcknowledged();
      h.controller.menuPointerUp('display', 1);
      h.controller.windowPointer(inRevealZone: true);
      time.elapse(const Duration(minutes: 1));
      expect(h.controller.value.visible, isFalse);
      expect(h.openCalls, 1);
      h.controller.setHidden(false);
      expect(h.controller.value.visible, isTrue);
    });
  });

  test('settings retime idle and update dimmed opacity', () {
    fakeAsync((time) {
      final h = _Harness(pinned: true);
      addTearDown(h.dispose);
      time.elapse(const Duration(seconds: 2));
      h.controller.updateSettings(
        hideDelay: const Duration(seconds: 1),
        dimDelay: const Duration(seconds: 1),
        dimDuration: Duration.zero,
        dimOpacity: 0.7,
      );
      expect(h.controller.value.opacity, 0.7);
      h.controller.setPinned(false);
      time.elapse(const Duration(seconds: 1));
      expect(h.controller.value.visible, isFalse);
    });
  });

  test('drag state is published and prevents hiding', () {
    fakeAsync((time) {
      final h = _Harness();
      addTearDown(h.dispose);
      h.controller.dragging(true);
      expect(h.controller.value.dragging, isTrue);
      time.elapse(const Duration(minutes: 1));
      expect(h.controller.value.visible, isTrue);
      h.controller.dragging(false);
      expect(h.controller.value.dragging, isFalse);
      time.elapse(const Duration(seconds: 5));
      expect(h.controller.value.visible, isFalse);
    });
  });

  test('mouse activates once and keyboard activation remains available', () {
    fakeAsync((_) {
      final h = _Harness();
      addTearDown(h.dispose);
      h.controller.menuPointerDown('display', 1);
      h.controller.menuPointerUp('display', 2);
      expect(h.openCalls, 0);
      h.controller.menuPointerUp('display', 1);
      h.controller.menuPointerUp('display', 1);
      h.controller.activateMenuFromButton('display');
      expect(h.openCalls, 1);
      expect(h.menus.phase, ToolbarMenuPhase.open);
      h.flush();
      h.controller.activateMenuFromButton('display');
      expect(h.menus.phase, ToolbarMenuPhase.closing);
      h.closeAcknowledged();
      h.controller.activateMenuFromButton('display');
      expect(h.openCalls, 2);
    });
  });

  test('cancelled pointer does not activate or block keyboard', () {
    fakeAsync((_) {
      final h = _Harness();
      addTearDown(h.dispose);
      h.controller.menuPointerDown('display', 1);
      h.controller.cancelMenuPointer('display');
      h.controller.menuPointerUp('display', 1);
      expect(h.openCalls, 0);
      h.controller.activateMenuFromButton('display');
      expect(h.openCalls, 1);
    });
  });

  test('dispose cancels idle and deferred activation work', () {
    fakeAsync((time) {
      final h = _Harness();
      h.controller.menuPointerDown('display', 1);
      h.controller.menuPointerUp('display', 1);
      h.dispose();
      h.flush();
      time.elapse(const Duration(minutes: 1));
      expect(time.pendingTimers, isEmpty);
      expect(h.focus, [true, false]);
    });
  });
}
