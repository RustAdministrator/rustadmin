import '../mobile/mobile_modifier_state.dart';
import 'keyboard_dispatcher.dart';
import 'keyboard_event_normalizer.dart';
import 'keyboard_intent.dart';
import 'keyboard_modifier_controller.dart';

enum ActiveKeyRoute { physical, text, ignored }

class KeyboardStateDiagnostics {
  int unknownKeyUps = 0;
  int duplicateDowns = 0;
  int ignoredIntents = 0;
  int resets = 0;
}

class _ActiveRoute {
  const _ActiveRoute({
    required this.route,
    required this.transport,
    required this.source,
    required this.lockMask,
    this.legacyName,
  });

  final ActiveKeyRoute route;
  final KeyboardPhysicalTransport transport;
  final KeyboardInputSource source;
  final int lockMask;
  final String? legacyName;
}

class KeyboardStateMachine {
  KeyboardStateMachine({required KeyboardDispatcher dispatcher})
    : _dispatcher = dispatcher {
    _mobileModifiers = MobileKeyboardModifierController(
      onRelease: (modifier, remaining) {
        _releaseSyntheticModifier(modifier, remaining);
      },
    );
  }

  final KeyboardDispatcher _dispatcher;
  final SideSpecificModifierState _physicalModifiers =
      SideSpecificModifierState();
  late final MobileKeyboardModifierController _mobileModifiers;
  final Map<HidKey, _ActiveRoute> _activeRoutes = <HidKey, _ActiveRoute>{};
  final Set<HidKey> _physicallyPressedKeys = <HidKey>{};
  final Set<HidKey> _physicallyDispatchedKeys = <HidKey>{};
  final Map<HidKey, KeyboardPhysicalTransport> _syntheticModifierTransports =
      <HidKey, KeyboardPhysicalTransport>{};
  final Set<HidKey> _explicitModifierKeys = <HidKey>{};
  final Set<HidKey> _reportedSyntheticModifiers = <HidKey>{};
  final Map<HidKey, Set<HidKey>> _reportedModifiersByKey =
      <HidKey, Set<HidKey>>{};
  final diagnostics = KeyboardStateDiagnostics();
  int _resetGeneration = 0;
  Future<void> _lastDispatch = Future<void>.value();

  MobileModifierState get mobileModifierState => _mobileModifiers.state;
  KeyboardModifiers get physicalModifiers => _physicalModifiers.snapshot;
  KeyboardModifiers get effectiveModifiers =>
      physicalModifiers.merge(_mobileModifiers.snapshot);
  Set<HidKey> get physicallyPressedKeys =>
      Set<HidKey>.unmodifiable(_physicallyPressedKeys);
  Set<HidKey> get physicallyDispatchedKeys =>
      Set<HidKey>.unmodifiable(_physicallyDispatchedKeys);
  int get activeRouteCount => _activeRoutes.length;
  int get resetGeneration => _resetGeneration;
  Future<void> get idle => _dispatcher.idle;

  ActiveKeyRoute? routeFor(HidKey key) => _activeRoutes[key]?.route;

  void setLegacyPhysicalModifier(MobileModifierKey modifier, bool pressed) {
    _physicalModifiers.setAggregate(modifier, pressed);
  }

  void consumeOneShotModifiers() {
    _mobileModifiers.consumeOneShot();
  }

  Future<void> handle(KeyboardIntent intent, KeyboardRoutingContext context) {
    _lastDispatch = Future<void>.value();
    switch (intent) {
      case PhysicalKeyboardIntent():
        _handlePhysical(intent, context);
      case CommittedTextIntent():
        _handleCommittedText(intent, context);
      case KeyboardResetIntent():
        reset(
          intent.reason,
          invalidatePending: true,
          allowBlockedReleases: true,
        );
      case SyntheticModifierIntent():
        _handleSyntheticModifier(intent, context);
    }
    return _lastDispatch;
  }

  Future<void> _queueActions(Iterable<KeyboardDispatchAction> actions) {
    _lastDispatch = _dispatcher.dispatchAll(actions);
    return _lastDispatch;
  }

  void _handleSyntheticModifier(
    SyntheticModifierIntent intent,
    KeyboardRoutingContext context,
  ) {
    final modifier = _mobileModifier(intent.modifier);
    final wasActive = mobileModifierState.isActive(modifier);
    switch (intent.action) {
      case SyntheticModifierAction.toggle:
        mobileModifierState.tap(modifier);
      case SyntheticModifierAction.lock:
        mobileModifierState.lock(modifier);
      case SyntheticModifierAction.release:
        if (mobileModifierState.isActive(modifier)) {
          mobileModifierState.tap(modifier);
        }
    }
    if (!wasActive && mobileModifierState.isActive(modifier)) {
      _pressSyntheticModifier(modifier, context);
    }
  }

  void _pressSyntheticModifier(
    MobileModifierKey modifier,
    KeyboardRoutingContext context,
  ) {
    final key = _leftModifierKey(modifier);
    if (_syntheticModifierTransports.containsKey(key)) return;
    final canonicalIntent = PhysicalKeyboardIntent(
      key: key,
      action: KeyboardIntentAction.down,
      source: KeyboardInputSource.syntheticModifier,
      synthetic: true,
    );
    final active = _activeRoutes[key];
    final transport =
        _physicallyDispatchedKeys.contains(key) &&
            active?.route == ActiveKeyRoute.physical
        ? active!.transport
        : _dispatcher.selectPhysicalTransport(canonicalIntent, context);
    _syntheticModifierTransports[key] = transport;
    if (_physicallyDispatchedKeys.contains(key)) return;
    _queueActions([
      PhysicalKeyboardDispatch(
        key: key,
        action: KeyboardIntentAction.down,
        transport: transport,
        modifiers: effectiveModifiers,
        source: KeyboardInputSource.syntheticModifier,
      ),
    ]);
  }

  void _releaseSyntheticModifier(
    MobileModifierKey modifier,
    KeyboardModifiers remaining,
  ) {
    final key = _leftModifierKey(modifier);
    final transport = _syntheticModifierTransports.remove(key);
    if (transport == null) return;

    final active = _activeRoutes[key];
    if (_physicallyPressedKeys.contains(key) &&
        active?.route == ActiveKeyRoute.physical) {
      if (!_physicallyDispatchedKeys.contains(key)) {
        _activeRoutes[key] = _ActiveRoute(
          route: active!.route,
          transport: transport,
          source: active.source,
          lockMask: active.lockMask,
          legacyName: active.legacyName,
        );
      }
      _physicallyDispatchedKeys.add(key);
      return;
    }
    _queueActions([
      PhysicalKeyboardDispatch(
        key: key,
        action: KeyboardIntentAction.up,
        transport: transport,
        modifiers: physicalModifiers.merge(remaining),
        source: KeyboardInputSource.syntheticModifier,
      ),
    ]);
  }

  Future<void> reset(
    KeyboardResetReason reason, {
    bool invalidatePending = false,
    bool allowBlockedReleases = false,
  }) {
    if (invalidatePending) {
      _dispatcher.invalidatePending();
    }
    final hadState =
        _activeRoutes.isNotEmpty ||
        _physicallyPressedKeys.isNotEmpty ||
        _physicallyDispatchedKeys.isNotEmpty ||
        _syntheticModifierTransports.isNotEmpty ||
        _explicitModifierKeys.isNotEmpty ||
        _reportedSyntheticModifiers.isNotEmpty ||
        _reportedModifiersByKey.isNotEmpty ||
        physicalModifiers.alt ||
        physicalModifiers.ctrl ||
        physicalModifiers.shift ||
        physicalModifiers.command ||
        mobileModifierState.hasActive;
    if (!hadState) return idle;

    final keys = _physicallyDispatchedKeys.toList(growable: false)
      ..sort((left, right) => left.compareTo(right));
    final releases = <PhysicalKeyboardDispatch>[];
    for (final key in keys.where((key) => !key.isModifier)) {
      final active = _activeRoutes[key];
      if (active == null || active.route != ActiveKeyRoute.physical) continue;
      releases.add(
        PhysicalKeyboardDispatch(
          key: key,
          action: KeyboardIntentAction.up,
          transport: active.transport,
          modifiers: effectiveModifiers,
          source: active.source,
          lockMask: active.lockMask,
          legacyName: active.legacyName,
        ),
      );
    }

    _mobileModifiers.reset(notifyReleases: false);

    final modifierKeys = <HidKey>{
      ...keys.where((key) => key.isModifier),
      ..._syntheticModifierTransports.keys,
    }.toList()..sort();
    for (final key in modifierKeys) {
      final active = _activeRoutes[key];
      _physicalModifiers.setPressed(key, false);
      releases.add(
        PhysicalKeyboardDispatch(
          key: key,
          action: KeyboardIntentAction.up,
          transport:
              active != null &&
                  active.route == ActiveKeyRoute.physical &&
                  _physicallyDispatchedKeys.contains(key)
              ? active.transport
              : _syntheticModifierTransports[key] ??
                    KeyboardPhysicalTransport.hid,
          modifiers: physicalModifiers,
          source: active?.source ?? KeyboardInputSource.syntheticModifier,
          lockMask: active?.lockMask ?? 0,
          legacyName: active?.legacyName,
        ),
      );
    }

    _activeRoutes.clear();
    _physicallyPressedKeys.clear();
    _physicallyDispatchedKeys.clear();
    _syntheticModifierTransports.clear();
    _explicitModifierKeys.clear();
    _reportedSyntheticModifiers.clear();
    _reportedModifiersByKey.clear();
    _physicalModifiers.clear();
    if (allowBlockedReleases) {
      _lastDispatch = _dispatcher.dispatchRecoveryReleases(releases);
    } else {
      _lastDispatch = _dispatcher.dispatchAll(releases);
    }
    _resetGeneration += 1;
    diagnostics.resets += 1;
    return _lastDispatch;
  }

  void invalidatePending() {
    _dispatcher.invalidatePending();
  }

  void _handlePhysical(
    PhysicalKeyboardIntent intent,
    KeyboardRoutingContext context,
  ) {
    final reconcileAndroidModifiers =
        intent.source == KeyboardInputSource.androidHardwareKeyboard &&
        !intent.key.isModifier;
    if (reconcileAndroidModifiers &&
        (intent.action == KeyboardIntentAction.down ||
            (intent.action == KeyboardIntentAction.repeat &&
                !_reportedModifiersByKey.containsKey(intent.key)))) {
      _reportedModifiersByKey[intent.key] = intent.reportedModifiers;
      _reconcileReportedModifiers(_reportedModifierUnion(), context);
    }

    if (intent.key.isModifier && !intent.synthetic) {
      if (intent.action == KeyboardIntentAction.down) {
        if (!_explicitModifierKeys.add(intent.key)) {
          diagnostics.duplicateDowns += 1;
          return;
        }
        if (_activeRoutes.containsKey(intent.key)) return;
      } else if (intent.action == KeyboardIntentAction.repeat) {
        _explicitModifierKeys.add(intent.key);
      } else if (intent.action == KeyboardIntentAction.up) {
        if (!_explicitModifierKeys.remove(intent.key)) {
          diagnostics.unknownKeyUps += 1;
          return;
        }
        if (_reportedSyntheticModifiers.contains(intent.key)) return;
      }
    }

    switch (intent.action) {
      case KeyboardIntentAction.down:
        final existing = _activeRoutes[intent.key];
        if (existing != null) {
          diagnostics.duplicateDowns += 1;
          return;
        }
        _start(intent, context, KeyboardIntentAction.down);
      case KeyboardIntentAction.repeat:
        final existing = _activeRoutes[intent.key];
        if (existing == null) {
          _start(intent, context, KeyboardIntentAction.repeat);
        } else {
          _repeat(intent, existing);
        }
      case KeyboardIntentAction.up:
        _finish(intent);
    }

    if (reconcileAndroidModifiers && intent.action == KeyboardIntentAction.up) {
      _reportedModifiersByKey.remove(intent.key);
      _reconcileReportedModifiers(_reportedModifierUnion(), context);
    }
  }

  Set<HidKey> _reportedModifierUnion() => <HidKey>{
    for (final modifiers in _reportedModifiersByKey.values) ...modifiers,
  };

  void _reconcileReportedModifiers(
    Set<HidKey> reported,
    KeyboardRoutingContext context,
  ) {
    final removed = _reportedSyntheticModifiers.difference(reported).toList()
      ..sort();
    final added = reported.difference(_reportedSyntheticModifiers).toList()
      ..sort();

    for (final key in removed) {
      _reportedSyntheticModifiers.remove(key);
      if (_explicitModifierKeys.contains(key)) continue;
      _finish(
        PhysicalKeyboardIntent(
          key: key,
          action: KeyboardIntentAction.up,
          source: KeyboardInputSource.androidHardwareKeyboard,
          synthetic: true,
        ),
      );
    }
    for (final key in added) {
      _reportedSyntheticModifiers.add(key);
      if (_explicitModifierKeys.contains(key) ||
          _activeRoutes.containsKey(key)) {
        continue;
      }
      _start(
        PhysicalKeyboardIntent(
          key: key,
          action: KeyboardIntentAction.down,
          source: KeyboardInputSource.androidHardwareKeyboard,
          synthetic: true,
        ),
        context,
        KeyboardIntentAction.down,
      );
    }
  }

  void _start(
    PhysicalKeyboardIntent intent,
    KeyboardRoutingContext context,
    KeyboardIntentAction action,
  ) {
    _physicallyPressedKeys.add(intent.key);
    final route = _selectRoute(intent, context);
    if (route != ActiveKeyRoute.ignored) {
      _physicalModifiers.setPressed(intent.key, true);
    }
    final transport = _dispatcher.selectPhysicalTransport(intent, context);
    final active = _ActiveRoute(
      route: route,
      transport: transport,
      source: intent.source,
      lockMask: intent.lockMask,
      legacyName: intent.legacyFallbackName ?? intent.textCandidate,
    );
    _activeRoutes[intent.key] = active;

    switch (route) {
      case ActiveKeyRoute.physical:
        if (!_syntheticModifierTransports.containsKey(intent.key)) {
          _physicallyDispatchedKeys.add(intent.key);
          _queueActions([
            PhysicalKeyboardDispatch(
              key: intent.key,
              action: action,
              transport: transport,
              modifiers: effectiveModifiers,
              source: intent.source,
              lockMask: intent.lockMask,
              legacyName: intent.legacyFallbackName ?? intent.textCandidate,
            ),
          ]);
        }
      case ActiveKeyRoute.text:
        final text = intent.textCandidate;
        if (text != null && text.isNotEmpty) {
          _queueActions([
            CommittedTextDispatch(text: text, source: intent.source),
          ]);
          _mobileModifiers.consumeOneShot();
        }
      case ActiveKeyRoute.ignored:
        diagnostics.ignoredIntents += 1;
    }
  }

  void _repeat(PhysicalKeyboardIntent intent, _ActiveRoute active) {
    switch (active.route) {
      case ActiveKeyRoute.physical:
        _queueActions([
          PhysicalKeyboardDispatch(
            key: intent.key,
            action: KeyboardIntentAction.repeat,
            transport: active.transport,
            modifiers: effectiveModifiers,
            source: active.source,
            lockMask: intent.lockMask,
            legacyName: active.legacyName,
          ),
        ]);
      case ActiveKeyRoute.text:
        final text = intent.textCandidate;
        if (text != null && text.isNotEmpty) {
          _queueActions([
            CommittedTextDispatch(text: text, source: intent.source),
          ]);
        }
      case ActiveKeyRoute.ignored:
        diagnostics.ignoredIntents += 1;
    }
  }

  void _finish(PhysicalKeyboardIntent intent) {
    final active = _activeRoutes.remove(intent.key);
    if (active == null) {
      diagnostics.unknownKeyUps += 1;
      return;
    }

    _physicallyPressedKeys.remove(intent.key);
    _physicalModifiers.setPressed(intent.key, false);
    if (active.route == ActiveKeyRoute.physical &&
        _physicallyDispatchedKeys.remove(intent.key)) {
      if (!_syntheticModifierTransports.containsKey(intent.key)) {
        _queueActions([
          PhysicalKeyboardDispatch(
            key: intent.key,
            action: KeyboardIntentAction.up,
            transport: active.transport,
            modifiers: effectiveModifiers,
            source: active.source,
            lockMask: intent.lockMask,
            legacyName: active.legacyName,
          ),
        ]);
      }
    }
    if (!intent.key.isModifier) {
      _mobileModifiers.consumeOneShot();
    }
  }

  void _handleCommittedText(
    CommittedTextIntent intent,
    KeyboardRoutingContext context,
  ) {
    if (intent.text.isEmpty &&
        intent.deleteBeforeGraphemes == 0 &&
        intent.deleteAfterGraphemes == 0) {
      return;
    }
    if (intent.allowMobileShortcut && mobileModifierState.hasActive) {
      final keys = const MobileToolbarKeyboardNormalizer().modifiedTextEdit(
        intent,
      );
      if (keys.isNotEmpty) {
        for (final key in keys) {
          _handlePhysical(key, context);
        }
        return;
      }
    }
    _queueActions([
      CommittedTextDispatch(
        text: intent.text,
        source: intent.source,
        deleteBeforeGraphemes: intent.deleteBeforeGraphemes,
        deleteAfterGraphemes: intent.deleteAfterGraphemes,
        sourceLanguageTag: intent.sourceLanguageTag,
        sourceLayoutType: intent.sourceLayoutType,
      ),
    ]);
    if (intent.consumeOneShot) {
      _mobileModifiers.consumeOneShot();
    }
  }

  ActiveKeyRoute _selectRoute(
    PhysicalKeyboardIntent intent,
    KeyboardRoutingContext context,
  ) {
    if (context.ignoreMeta && intent.key.modifier == CanonicalModifier.meta) {
      return ActiveKeyRoute.ignored;
    }
    if (intent.key.isModifier) return ActiveKeyRoute.physical;

    final modifiers = effectiveModifiers;
    final text = intent.textCandidate;
    final maySendText =
        context.inputMode == ControllerKeyboardInputMode.text &&
        text != null &&
        text.isNotEmpty &&
        !modifiers.ctrl &&
        !modifiers.alt &&
        !modifiers.command;
    return maySendText ? ActiveKeyRoute.text : ActiveKeyRoute.physical;
  }

  static HidKey _leftModifierKey(MobileModifierKey modifier) =>
      switch (modifier) {
        MobileModifierKey.ctrl => HidKey.controlLeft,
        MobileModifierKey.shift => HidKey.shiftLeft,
        MobileModifierKey.alt => HidKey.altLeft,
        MobileModifierKey.command => HidKey.metaLeft,
      };

  static MobileModifierKey _mobileModifier(CanonicalModifier modifier) =>
      switch (modifier) {
        CanonicalModifier.control => MobileModifierKey.ctrl,
        CanonicalModifier.shift => MobileModifierKey.shift,
        CanonicalModifier.alt => MobileModifierKey.alt,
        CanonicalModifier.meta => MobileModifierKey.command,
      };
}
