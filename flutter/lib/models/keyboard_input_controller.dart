import '../mobile/mobile_modifier_state.dart';
import 'keyboard_command_queue.dart';
import 'keyboard_dispatcher.dart';
import 'keyboard_intent.dart';
import 'keyboard_modifier_controller.dart';
import 'keyboard_state_machine.dart';

typedef KeyboardDispatchAllowed = bool Function();

class KeyboardInputController {
  KeyboardInputController({
    required KeyboardDispatchAllowed canDispatch,
    required KeyboardHidSink sendHid,
    required KeyboardLegacySink sendLegacy,
    required KeyboardTextSink sendText,
    KeyboardCommandErrorHandler? onError,
  }) : _canDispatch = canDispatch {
    _dispatcher = KeyboardDispatcher(
      canDispatch: canDispatch,
      sendHid: sendHid,
      sendLegacy: sendLegacy,
      sendText: sendText,
      onError: onError,
    );
    _state = KeyboardStateMachine(dispatcher: _dispatcher);
  }

  final KeyboardDispatchAllowed _canDispatch;
  late final KeyboardDispatcher _dispatcher;
  late final KeyboardStateMachine _state;

  MobileModifierState get mobileState => _state.mobileModifierState;
  KeyboardModifiers get physicalModifiers => _state.physicalModifiers;
  KeyboardModifiers get effectiveModifiers => _state.effectiveModifiers;
  Future<void> get idle => _state.idle;
  KeyboardStateDiagnostics get diagnostics => _state.diagnostics;

  bool handle(KeyboardIntent intent, KeyboardRoutingContext context) =>
      _submit(intent, context).$1;

  Future<void> handleAndWait(
    KeyboardIntent intent,
    KeyboardRoutingContext context,
  ) => _submit(intent, context).$2;

  (bool, Future<void>) _submit(
    KeyboardIntent intent,
    KeyboardRoutingContext context,
  ) {
    if (intent is KeyboardResetIntent) {
      return (
        true,
        _state.reset(
          intent.reason,
          invalidatePending: true,
          allowBlockedReleases: true,
        ),
      );
    }
    final canDispatch = _canDispatch();
    final localRelease =
        intent is PhysicalKeyboardIntent &&
        intent.action == KeyboardIntentAction.up;
    if (!canDispatch && !localRelease) {
      return (false, Future<void>.value());
    }
    return (canDispatch, _state.handle(intent, context));
  }

  Future<void> reset(
    KeyboardResetReason reason, {
    bool invalidatePending = false,
    bool allowBlockedReleases = false,
  }) => _state.reset(
    reason,
    invalidatePending: invalidatePending,
    allowBlockedReleases: allowBlockedReleases,
  );

  void setPhysical(MobileModifierKey key, bool value) {
    _state.setLegacyPhysicalModifier(key, value);
  }

  void consumeOneShot() => _state.consumeOneShotModifiers();
}
