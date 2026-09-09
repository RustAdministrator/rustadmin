import 'dart:async';

import '../consts.dart';
import 'keyboard_command_queue.dart';
import 'keyboard_intent.dart';
import 'keyboard_modifier_controller.dart';
import 'keyboard_text_policy.dart';

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

// Owned by one state-machine route (shared by coalesced modifier owners).
// It records a transport attempt, not an acknowledgement from the peer.
class KeyboardPhysicalDispatchLease {
  KeyboardPhysicalDispatchLease({required this.key, required this.transport});

  final HidKey key;
  final KeyboardPhysicalTransport transport;
  bool _downStarted = false;
}

final class PhysicalKeyboardDispatch extends KeyboardDispatchAction {
  const PhysicalKeyboardDispatch({
    required this.lease,
    required this.action,
    required this.modifiers,
    required this.source,
    this.lockMask = 0,
    this.legacyName,
  });

  final KeyboardPhysicalDispatchLease lease;
  HidKey get key => lease.key;
  final KeyboardIntentAction action;
  KeyboardPhysicalTransport get transport => lease.transport;
  final KeyboardModifiers modifiers;
  final KeyboardInputSource source;
  final int lockMask;
  final String? legacyName;
}

final class CommittedTextDispatch extends KeyboardDispatchAction {
  const CommittedTextDispatch({
    required this.text,
    required this.source,
    this.literal = true,
    this.deadKeyAccent,
    this.deleteBeforeGraphemes = 0,
    this.deleteAfterGraphemes = 0,
    this.sourceLanguageTag = '',
    this.sourceLayoutType = '',
  });

  final String text;
  final bool literal;
  final int? deadKeyAccent;
  final KeyboardInputSource source;
  final int deleteBeforeGraphemes;
  final int deleteAfterGraphemes;
  final String sourceLanguageTag;
  final String sourceLayoutType;
}

typedef KeyboardCanDispatch = bool Function();
typedef KeyboardDeadKeyComposer = FutureOr<int?> Function(int accent, int base);
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
      required bool literal,
      required int deleteBeforeGraphemes,
      required int deleteAfterGraphemes,
      required String sourceLanguageTag,
      required String sourceLayoutType,
    });

class KeyboardDispatchDiagnostics {
  int ignoredLegacyKeys = 0;
  int retiredCommands = 0;
  int rejectedTextOperations = 0;
  int deadKeyFallbacks = 0;
}

class KeyboardDispatcher {
  KeyboardDispatcher({
    required KeyboardCanDispatch canDispatch,
    required KeyboardHidSink sendHid,
    required KeyboardLegacySink sendLegacy,
    required KeyboardTextSink sendText,
    KeyboardDeadKeyComposer? composeDeadKey,
    KeyboardCommandErrorHandler? onError,
    KeyboardInputRejectionHandler? onInputRejected,
  }) : _canDispatch = canDispatch,
       _sendHid = sendHid,
       _sendLegacy = sendLegacy,
       _sendText = sendText,
       _composeDeadKey = composeDeadKey,
       _queue = KeyboardCommandQueue(onError: onError),
       _onInputRejected = onInputRejected;

  final KeyboardCanDispatch _canDispatch;
  final KeyboardHidSink _sendHid;
  final KeyboardLegacySink _sendLegacy;
  final KeyboardTextSink _sendText;
  final KeyboardDeadKeyComposer? _composeDeadKey;
  final KeyboardCommandQueue _queue;
  final KeyboardInputRejectionHandler? _onInputRejected;
  int _pendingTextBytes = 0;
  int _pendingTextOperations = 0;
  int _pendingEditGraphemes = 0;
  final diagnostics = KeyboardDispatchDiagnostics();

  Future<void> get idle => _queue.idle;
  int get pendingTextBytes => _pendingTextBytes;
  int get pendingTextOperations => _pendingTextOperations;
  int get pendingEditGraphemes => _pendingEditGraphemes;

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

  Future<void> dispatchAll(Iterable<KeyboardDispatchAction> actions) =>
      tryDispatchAll(actions).completion;

  ({bool accepted, Future<void> completion}) tryDispatchAll(
    Iterable<KeyboardDispatchAction> actions,
  ) {
    final batch = actions.toList(growable: false);
    final costs = <int>[];
    var bytes = 0;
    var operations = 0;
    var edits = 0;
    for (final action in batch) {
      if (action is! CommittedTextDispatch) {
        costs.add(0);
        continue;
      }
      final checked = KeyboardTextPolicy.inspect(action.text);
      final rejection = checked.rejection;
      if (rejection != null) return _rejectText(rejection);
      final accent = action.deadKeyAccent;
      if (accent != null &&
          (!action.literal || !KeyboardTextPolicy.isPrintableScalar(accent))) {
        return _rejectText(KeyboardInputRejection.invalidText);
      }
      // Reserve the uncomposed fallback, including a supplementary accent.
      final byteCost = checked.bytes + (accent == null ? 0 : 4);
      if (byteCost > KeyboardTextPolicy.maxOperationBytes) {
        return _rejectText(KeyboardInputRejection.textTooLarge);
      }
      final editCost =
          action.deleteBeforeGraphemes + action.deleteAfterGraphemes;
      if (action.deleteBeforeGraphemes < 0 ||
          action.deleteAfterGraphemes < 0 ||
          editCost > KeyboardTextPolicy.maxEditGraphemes) {
        return _rejectText(KeyboardInputRejection.invalidText);
      }
      edits += editCost;
      bytes += byteCost;
      operations++;
      costs.add(byteCost);
    }
    if (_pendingTextBytes + bytes > KeyboardTextPolicy.maxPendingBytes ||
        _pendingEditGraphemes + edits > KeyboardTextPolicy.maxEditGraphemes ||
        _pendingTextOperations + operations >
            KeyboardTextPolicy.maxPendingOperations) {
      return _rejectText(KeyboardInputRejection.textQueueFull);
    }
    _pendingTextBytes += bytes;
    _pendingTextOperations += operations;
    _pendingEditGraphemes += edits;
    Future<void> tail = _queue.idle;
    for (var index = 0; index < batch.length; index++) {
      final action = batch[index];
      final release =
          action is PhysicalKeyboardDispatch &&
          action.action == KeyboardIntentAction.up;
      tail = _queue.enqueue(() => _dispatch(action), keepOnCancel: release);
      if (action is CommittedTextDispatch) {
        final cost = costs[index];
        tail = tail.whenComplete(() {
          _pendingTextBytes -= cost;
          _pendingTextOperations--;
          _pendingEditGraphemes -=
              action.deleteBeforeGraphemes + action.deleteAfterGraphemes;
        });
      }
    }
    return (accepted: true, completion: tail);
  }

  ({bool accepted, Future<void> completion}) _rejectText(
    KeyboardInputRejection reason,
  ) {
    diagnostics.rejectedTextOperations++;
    _onInputRejected?.call(reason);
    return (accepted: false, completion: Future<void>.value());
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
      tail = _queue.enqueue(() => _dispatch(release), keepOnCancel: true);
    }
    return tail;
  }

  Future<void> _dispatch(KeyboardDispatchAction action) async {
    final ownedRelease =
        action is PhysicalKeyboardDispatch &&
        action.action == KeyboardIntentAction.up &&
        action.lease._downStarted;
    if (!_canDispatch() && !ownedRelease) return;
    switch (action) {
      case PhysicalKeyboardDispatch():
        await _dispatchPhysical(action);
      case CommittedTextDispatch():
        if (action.text.isEmpty &&
            action.deleteBeforeGraphemes == 0 &&
            action.deleteAfterGraphemes == 0) {
          return;
        }
        final generation = _queue.generation;
        var text = action.text;
        final accent = action.deadKeyAccent;
        if (accent != null) {
          int? composed;
          final scalars = text.runes;
          if (_composeDeadKey != null && scalars.length == 1) {
            try {
              composed = await Future<int?>.sync(
                () => _composeDeadKey(accent, scalars.first),
              ).timeout(const Duration(seconds: 1));
            } catch (_) {
              // Unsupported platforms and failed native calls keep both scalars.
            }
          }
          if (generation != _queue.generation || !_canDispatch()) return;
          if (composed != null &&
              KeyboardTextPolicy.isPrintableScalar(composed)) {
            text = String.fromCharCode(composed);
          } else {
            diagnostics.deadKeyFallbacks++;
            text = String.fromCharCode(accent) + text;
          }
        }
        await Future<void>.sync(
          () => _sendText(
            text: text,
            literal: action.literal,
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
      if (!_beginPhysicalAttempt(action)) return;
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
    if (!_beginPhysicalAttempt(action)) return;
    await Future<void>.sync(
      () => _sendLegacy(
        name: legacyName,
        down: action.action != KeyboardIntentAction.up,
        modifiers: action.modifiers,
      ),
    );
  }

  bool _beginPhysicalAttempt(PhysicalKeyboardDispatch action) {
    if (action.action == KeyboardIntentAction.up) {
      if (!action.lease._downStarted) return false;
      action.lease._downStarted = false;
    } else {
      // A failed call may still have delivered its down. Keep the paired up.
      action.lease._downStarted = true;
    }
    return true;
  }
}
