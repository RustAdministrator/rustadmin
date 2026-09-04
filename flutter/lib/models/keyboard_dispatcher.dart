import 'dart:async';

import '../consts.dart';
import 'keyboard_command_queue.dart';
import 'keyboard_intent.dart';
import 'keyboard_modifier_controller.dart';

enum KeyboardPhysicalTransport { hid, legacy }

enum ControllerKeyboardMode { legacy, map, translate }

enum ControllerKeyboardInputMode { auto, text, physical }

enum KeyboardClientKind { desktop, webDesktop, android, ios, otherMobile }

class KeyboardRoutingContext {
  const KeyboardRoutingContext({
    required this.keyboardMode,
    required this.inputMode,
    required this.clientKind,
    required this.peerIsAndroid,
    this.ignoreMeta = false,
  });

  final ControllerKeyboardMode keyboardMode;
  final ControllerKeyboardInputMode inputMode;
  final KeyboardClientKind clientKind;
  final bool peerIsAndroid;
  final bool ignoreMeta;
}

bool shouldUseDesktopMapMode({
  required bool isDesktop,
  required bool isWebDesktop,
  required ControllerKeyboardMode keyboardMode,
}) => (isDesktop || isWebDesktop) && keyboardMode == ControllerKeyboardMode.map;

sealed class KeyboardDispatchAction {
  const KeyboardDispatchAction();
}

final class PhysicalKeyboardDispatch extends KeyboardDispatchAction {
  const PhysicalKeyboardDispatch({
    required this.key,
    required this.action,
    required this.transport,
    required this.modifiers,
    required this.source,
    this.lockMask = 0,
    this.legacyName,
  });

  final HidKey key;
  final KeyboardIntentAction action;
  final KeyboardPhysicalTransport transport;
  final KeyboardModifiers modifiers;
  final KeyboardInputSource source;
  final int lockMask;
  final String? legacyName;
}

final class CommittedTextDispatch extends KeyboardDispatchAction {
  const CommittedTextDispatch({
    required this.text,
    required this.source,
    this.deleteBeforeGraphemes = 0,
    this.deleteAfterGraphemes = 0,
    this.sourceLanguageTag = '',
    this.sourceLayoutType = '',
  });

  final String text;
  final KeyboardInputSource source;
  final int deleteBeforeGraphemes;
  final int deleteAfterGraphemes;
  final String sourceLanguageTag;
  final String sourceLayoutType;
}

typedef KeyboardCanDispatch = bool Function();
typedef KeyboardHidSink =
    FutureOr<void> Function({
      required HidKey key,
      required KeyboardIntentAction action,
      required int lockMask,
    });
typedef KeyboardLegacySink =
    FutureOr<void> Function({
      required String name,
      required bool down,
      required KeyboardModifiers modifiers,
    });
typedef KeyboardTextSink =
    FutureOr<void> Function({
      required String text,
      required int deleteBeforeGraphemes,
      required int deleteAfterGraphemes,
      required String sourceLanguageTag,
      required String sourceLayoutType,
    });

class KeyboardDispatchDiagnostics {
  int ignoredLegacyKeys = 0;
  int retiredCommands = 0;
}

class KeyboardDispatcher {
  KeyboardDispatcher({
    required KeyboardCanDispatch canDispatch,
    required KeyboardHidSink sendHid,
    required KeyboardLegacySink sendLegacy,
    required KeyboardTextSink sendText,
    KeyboardCommandErrorHandler? onError,
  }) : _canDispatch = canDispatch,
       _sendHid = sendHid,
       _sendLegacy = sendLegacy,
       _sendText = sendText,
       _queue = KeyboardCommandQueue(onError: onError);

  final KeyboardCanDispatch _canDispatch;
  final KeyboardHidSink _sendHid;
  final KeyboardLegacySink _sendLegacy;
  final KeyboardTextSink _sendText;
  final KeyboardCommandQueue _queue;
  final diagnostics = KeyboardDispatchDiagnostics();

  Future<void> get idle => _queue.idle;

  KeyboardPhysicalTransport selectPhysicalTransport(
    PhysicalKeyboardIntent intent,
    KeyboardRoutingContext context,
  ) {
    if (intent.key.usagePage != HidKey.keyboardUsagePage) {
      return KeyboardPhysicalTransport.legacy;
    }
    if (intent.source == KeyboardInputSource.androidHardwareKeyboard) {
      return KeyboardPhysicalTransport.hid;
    }
    if (intent.source == KeyboardInputSource.syntheticModifier) {
      return KeyboardPhysicalTransport.hid;
    }
    if (intent.source == KeyboardInputSource.mobileToolbar) {
      return intent.legacyFallbackName == null
          ? KeyboardPhysicalTransport.hid
          : KeyboardPhysicalTransport.legacy;
    }

    final desktopMap = shouldUseDesktopMapMode(
      isDesktop: context.clientKind == KeyboardClientKind.desktop,
      isWebDesktop: context.clientKind == KeyboardClientKind.webDesktop,
      keyboardMode: context.keyboardMode,
    );
    if (desktopMap) return KeyboardPhysicalTransport.hid;

    if (!context.peerIsAndroid) {
      if (context.clientKind == KeyboardClientKind.ios) {
        return KeyboardPhysicalTransport.hid;
      }
      if (context.clientKind == KeyboardClientKind.android &&
          intent.key.usage != 0x28 &&
          intent.key.usage != 0x2a) {
        return KeyboardPhysicalTransport.hid;
      }
    }
    return KeyboardPhysicalTransport.legacy;
  }

  Future<void> dispatchAll(Iterable<KeyboardDispatchAction> actions) {
    Future<void> tail = _queue.idle;
    for (final action in actions) {
      tail = _queue.enqueue(() => _dispatch(action));
    }
    return tail;
  }

  void invalidatePending() {
    _queue.cancelPending();
    diagnostics.retiredCommands += 1;
  }

  Future<void> dispatchRecoveryReleases(
    Iterable<PhysicalKeyboardDispatch> releases,
  ) {
    Future<void> tail = _queue.idle;
    for (final release in releases) {
      if (release.action != KeyboardIntentAction.up) continue;
      tail = _queue.enqueue(
        () => _dispatch(release, allowBlockedRelease: true),
      );
    }
    return tail;
  }

  Future<void> _dispatch(
    KeyboardDispatchAction action, {
    bool allowBlockedRelease = false,
  }) async {
    final isRelease =
        action is PhysicalKeyboardDispatch &&
        action.action == KeyboardIntentAction.up;
    if (!_canDispatch() && !(allowBlockedRelease && isRelease)) return;
    switch (action) {
      case PhysicalKeyboardDispatch():
        await _dispatchPhysical(action);
      case CommittedTextDispatch():
        if (action.text.isEmpty &&
            action.deleteBeforeGraphemes == 0 &&
            action.deleteAfterGraphemes == 0) {
          return;
        }
        await Future<void>.sync(
          () => _sendText(
            text: action.text,
            deleteBeforeGraphemes: action.deleteBeforeGraphemes,
            deleteAfterGraphemes: action.deleteAfterGraphemes,
            sourceLanguageTag: action.sourceLanguageTag,
            sourceLayoutType: action.sourceLayoutType,
          ),
        );
    }
  }

  Future<void> _dispatchPhysical(PhysicalKeyboardDispatch action) async {
    if (action.transport == KeyboardPhysicalTransport.hid) {
      await Future<void>.sync(
        () => _sendHid(
          key: action.key,
          action: action.action,
          lockMask: action.lockMask,
        ),
      );
      return;
    }

    final legacyName =
        physicalKeyMap[action.key.flutterUsage] ??
        canonicalLegacyKeyNamesByFlutterUsage[action.key.flutterUsage] ??
        action.legacyName;
    if (legacyName == null) {
      diagnostics.ignoredLegacyKeys += 1;
      return;
    }
    await Future<void>.sync(
      () => _sendLegacy(
        name: legacyName,
        down: action.action != KeyboardIntentAction.up,
        modifiers: action.modifiers,
      ),
    );
  }
}
