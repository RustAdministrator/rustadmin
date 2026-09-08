import '../mobile/mobile_modifier_state.dart';
import 'keyboard_dispatcher.dart';
import 'keyboard_event_normalizer.dart';
import 'keyboard_intent.dart';
import 'keyboard_modifier_controller.dart';
import 'keyboard_text_policy.dart';

enum ActiveKeyRoute { physical, text, ignored }

// Reported modifiers and explicit keys are owners in the same route table.
typedef _KeyOwner = ({HidKey key, KeyboardInputOrigin origin, bool reported});

_KeyOwner _owner(PhysicalKeyboardIntent intent) =>
    (key: intent.key, origin: intent.origin, reported: false);

_KeyOwner _reportedOwner(HidKey key) =>
    (key: key, origin: KeyboardInputOrigin.unknown, reported: true);

class KeyboardStateDiagnostics {
  int unknownKeyUps = 0;
  int duplicateDowns = 0;
  int ignoredIntents = 0;
  int resets = 0;
}

class _ActiveRoute {
  const _ActiveRoute({
    required this.route,
    required this.lease,
    required this.source,
    required this.lockMask,
    this.sourceLanguageTag = '',
    this.sourceLayoutType = '',
    this.legacyName,
  });

  final ActiveKeyRoute route;
  final KeyboardPhysicalDispatchLease lease;
  final KeyboardInputSource source;
  final int lockMask;
  final String sourceLanguageTag;
  final String sourceLayoutType;
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
  final Map<_KeyOwner, _ActiveRoute> _activeRoutes = {};
  final Map<HidKey, KeyboardPhysicalDispatchLease> _syntheticModifierLeases =
      <HidKey, KeyboardPhysicalDispatchLease>{};
  final Set<HidKey> _reportedSyntheticModifiers = <HidKey>{};
  final Map<_KeyOwner, Set<HidKey>> _reportedModifiersByKey = {};
  final diagnostics = KeyboardStateDiagnostics();
  int _resetGeneration = 0;
  Future<void> _lastDispatch = Future<void>.value();

  MobileModifierState get mobileModifierState => _mobileModifiers.state;
  KeyboardModifiers get physicalModifiers => _physicalModifiers.snapshot;
  KeyboardModifiers get effectiveModifiers =>
      physicalModifiers.merge(_mobileModifiers.snapshot);
  Set<HidKey> get physicallyPressedKeys =>
      Set<HidKey>.unmodifiable(_activeRoutes.keys.map((owner) => owner.key));
  Set<HidKey> get physicallyDispatchedKeys => Set<HidKey>.unmodifiable(
    _activeRoutes.entries
        .where((entry) => entry.value.route == ActiveKeyRoute.physical)
        .map((entry) => entry.key.key),
  );
  int get activeRouteCount => _activeRoutes.length;
  int get resetGeneration => _resetGeneration;
  Future<void> get idle => _dispatcher.idle;

  ActiveKeyRoute? routeFor(HidKey key, {KeyboardInputOrigin? origin}) {
    for (final entry in _activeRoutes.entries) {
      if (entry.key.key == key &&
          (origin == null || entry.key.origin == origin)) {
        return entry.value.route;
      }
    }
    return null;
  }

  _ActiveRoute? _physicalRouteFor(HidKey key) {
    for (final entry in _activeRoutes.entries) {
      if (entry.key.key == key &&
          entry.value.route == ActiveKeyRoute.physical) {
        return entry.value;
      }
    }
    return null;
  }

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
      case PhysicalKeyPressBatchIntent():
        _handlePressBatch(intent, context);
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

  bool _queueActions(Iterable<KeyboardDispatchAction> actions) {
    final result = _dispatcher.tryDispatchAll(actions);
    _lastDispatch = result.completion;
    return result.accepted;
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
    if (_syntheticModifierLeases.containsKey(key)) return;
    final canonicalIntent = PhysicalKeyboardIntent(
      key: key,
      action: KeyboardIntentAction.down,
      source: KeyboardInputSource.syntheticModifier,
      synthetic: true,
    );
    final active = _physicalRouteFor(key);
    final lease = active != null
        ? active.lease
        : KeyboardPhysicalDispatchLease(
            key: key,
            transport: _dispatcher.selectPhysicalTransport(
              canonicalIntent,
              context,
            ),
          );
    _syntheticModifierLeases[key] = lease;
    if (active != null) return;
    _queueActions([
      PhysicalKeyboardDispatch(
        lease: lease,
        action: KeyboardIntentAction.down,
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
    final lease = _syntheticModifierLeases.remove(key);
    if (lease == null) return;

    if (_physicalRouteFor(key) != null) return;
    _queueActions([
      PhysicalKeyboardDispatch(
        lease: lease,
        action: KeyboardIntentAction.up,
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
        _syntheticModifierLeases.isNotEmpty ||
        _reportedSyntheticModifiers.isNotEmpty ||
        _reportedModifiersByKey.isNotEmpty ||
        physicalModifiers.alt ||
        physicalModifiers.ctrl ||
        physicalModifiers.shift ||
        physicalModifiers.command ||
        mobileModifierState.hasActive;
    if (!hadState) return idle;

    final keys = physicallyDispatchedKeys.toList(growable: false)
      ..sort((left, right) => left.compareTo(right));
    final releases = <PhysicalKeyboardDispatch>[];
    for (final key in keys.where((key) => !key.isModifier)) {
      final active = _physicalRouteFor(key);
      if (active == null || active.route != ActiveKeyRoute.physical) continue;
      releases.add(
        PhysicalKeyboardDispatch(
          lease: active.lease,
          action: KeyboardIntentAction.up,
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
      ..._syntheticModifierLeases.keys,
    }.toList()..sort();
    for (final key in modifierKeys) {
      final active = _physicalRouteFor(key);
      _physicalModifiers.setPressed(key, false);
      final lease = active?.lease ?? _syntheticModifierLeases[key];
      if (lease == null) continue;
      releases.add(
        PhysicalKeyboardDispatch(
          lease: lease,
          action: KeyboardIntentAction.up,
          modifiers: physicalModifiers,
          source: active?.source ?? KeyboardInputSource.syntheticModifier,
          lockMask: active?.lockMask ?? 0,
          legacyName: active?.legacyName,
        ),
      );
    }

    _activeRoutes.clear();
    _syntheticModifierLeases.clear();
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

  void _handlePressBatch(
    PhysicalKeyPressBatchIntent batch,
    KeyboardRoutingContext context,
  ) {
    if (batch.count < 1 || batch.count > PhysicalKeyPressBatchIntent.maxCount) {
      diagnostics.ignoredIntents += 1;
      return;
    }
    PhysicalKeyboardIntent event(KeyboardIntentAction action) =>
        PhysicalKeyboardIntent(
          key: batch.key,
          action: action,
          source: batch.source,
          origin: batch.origin,
          textCandidate: batch.textCandidate,
          sourceLanguageTag: batch.sourceLanguageTag,
          sourceLayoutType: batch.sourceLayoutType,
          synthetic: true,
          lockMask: batch.lockMask,
          reportedModifiers: batch.reportedModifiers,
        );
    final down = event(KeyboardIntentAction.down);
    final active =
        _activeRoutes[_owner(down)] ??
        (_selectRoute(down, context) == ActiveKeyRoute.physical
            ? _physicalRouteFor(batch.key)
            : null);
    if (active != null) {
      if (active.route == ActiveKeyRoute.ignored ||
          (active.route == ActiveKeyRoute.text &&
              batch.textCandidate == null)) {
        diagnostics.ignoredIntents += 1;
        return;
      }
      // Borrow additional reported modifiers without replacing a held key's
      // route or consuming its real key-up.
      if (!batch.key.isModifier && active.route == ActiveKeyRoute.physical) {
        _reconcileReportedModifiers({
          ..._reportedModifierUnion(),
          ...batch.reportedModifiers,
        }, context);
      }
      try {
        for (var i = 0; i < batch.count; i++) {
          _repeat(event(KeyboardIntentAction.repeat), active);
          if (!batch.key.isModifier &&
              active.route == ActiveKeyRoute.physical) {
            _mobileModifiers.consumeOneShot();
          }
        }
      } finally {
        if (!batch.key.isModifier && active.route == ActiveKeyRoute.physical) {
          _reconcileReportedModifiers(_reportedModifierUnion(), context);
        }
      }
      return;
    }
    for (var i = 0; i < batch.count; i++) {
      _handlePhysical(event(KeyboardIntentAction.down), context);
      _handlePhysical(event(KeyboardIntentAction.up), context);
    }
  }

  void _handlePhysical(
    PhysicalKeyboardIntent intent,
    KeyboardRoutingContext context,
  ) {
    final owner = _owner(intent);
    final existing = _activeRoutes[owner];
    if (intent.action == KeyboardIntentAction.down && existing != null) {
      diagnostics.duplicateDowns += 1;
      return;
    }
    final reconcileAndroidModifiers =
        intent.source == KeyboardInputSource.androidHardwareKeyboard &&
        !intent.key.isModifier;
    if (reconcileAndroidModifiers &&
        (existing?.route ?? _selectRoute(intent, context)) ==
            ActiveKeyRoute.physical &&
        (intent.action == KeyboardIntentAction.down ||
            (intent.action == KeyboardIntentAction.repeat &&
                !_reportedModifiersByKey.containsKey(owner)))) {
      _reportedModifiersByKey[owner] = intent.reportedModifiers;
      _reconcileReportedModifiers(_reportedModifierUnion(), context);
    }

    switch (intent.action) {
      case KeyboardIntentAction.down:
        _start(intent, context, KeyboardIntentAction.down);
      case KeyboardIntentAction.repeat:
        if (existing == null) {
          _start(intent, context, KeyboardIntentAction.repeat);
        } else {
          _repeat(intent, existing);
        }
      case KeyboardIntentAction.up:
        _finish(intent);
    }

    if (reconcileAndroidModifiers && intent.action == KeyboardIntentAction.up) {
      _reportedModifiersByKey.remove(owner);
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
      _finish(
        PhysicalKeyboardIntent(
          key: key,
          action: KeyboardIntentAction.up,
          source: KeyboardInputSource.androidHardwareKeyboard,
          synthetic: true,
        ),
        owner: _reportedOwner(key),
      );
    }
    for (final key in added) {
      _reportedSyntheticModifiers.add(key);
      _start(
        PhysicalKeyboardIntent(
          key: key,
          action: KeyboardIntentAction.down,
          source: KeyboardInputSource.androidHardwareKeyboard,
          synthetic: true,
        ),
        context,
        KeyboardIntentAction.down,
        owner: _reportedOwner(key),
      );
    }
  }

  void _start(
    PhysicalKeyboardIntent intent,
    KeyboardRoutingContext context,
    KeyboardIntentAction action, {
    _KeyOwner? owner,
  }) {
    final route = _selectRoute(intent, context);
    if (route != ActiveKeyRoute.ignored) {
      _physicalModifiers.setPressed(intent.key, true);
    }
    final transport = _dispatcher.selectPhysicalTransport(intent, context);
    final shared = _physicalRouteFor(intent.key);
    final lease =
        _syntheticModifierLeases[intent.key] ??
        shared?.lease ??
        KeyboardPhysicalDispatchLease(key: intent.key, transport: transport);
    final active = _ActiveRoute(
      route: route,
      lease: lease,
      source: intent.source,
      lockMask: intent.lockMask,
      sourceLanguageTag: intent.sourceLanguageTag,
      sourceLayoutType: intent.sourceLayoutType,
      legacyName: shared != null
          ? shared.legacyName
          : intent.legacyFallbackName ?? intent.textCandidate,
    );
    _activeRoutes[owner ?? _owner(intent)] = active;

    switch (route) {
      case ActiveKeyRoute.physical:
        if (!_syntheticModifierLeases.containsKey(intent.key) &&
            (shared == null || !intent.key.isModifier)) {
          _queueActions([
            PhysicalKeyboardDispatch(
              lease: lease,
              action: shared == null ? action : KeyboardIntentAction.repeat,
              modifiers: effectiveModifiers,
              source: intent.source,
              lockMask: intent.lockMask,
              legacyName: active.legacyName,
            ),
          ]);
        }
      case ActiveKeyRoute.text:
        final text = intent.textCandidate;
        if (text != null && text.isNotEmpty) {
          final accepted = _queueActions([
            CommittedTextDispatch(
              text: text,
              source: active.source,
              sourceLanguageTag: active.sourceLanguageTag,
              sourceLayoutType: active.sourceLayoutType,
            ),
          ]);
          if (accepted) _mobileModifiers.consumeOneShot();
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
            lease: active.lease,
            action: KeyboardIntentAction.repeat,
            modifiers: effectiveModifiers,
            source: active.source,
            lockMask: intent.lockMask,
            legacyName: active.legacyName,
          ),
        ]);
      case ActiveKeyRoute.text:
        final text = intent.textCandidate;
        if (text != null && text.isNotEmpty) {
          final accepted = _queueActions([
            CommittedTextDispatch(
              text: text,
              source: active.source,
              sourceLanguageTag: active.sourceLanguageTag,
              sourceLayoutType: active.sourceLayoutType,
            ),
          ]);
          if (accepted) _mobileModifiers.consumeOneShot();
        }
      case ActiveKeyRoute.ignored:
        diagnostics.ignoredIntents += 1;
    }
  }

  void _finish(PhysicalKeyboardIntent intent, {_KeyOwner? owner}) {
    final active = _activeRoutes.remove(owner ?? _owner(intent));
    if (active == null) {
      diagnostics.unknownKeyUps += 1;
      return;
    }

    final lastPhysical = _physicalRouteFor(intent.key) == null;
    if (lastPhysical) _physicalModifiers.setPressed(intent.key, false);
    if (active.route == ActiveKeyRoute.physical && lastPhysical) {
      if (!_syntheticModifierLeases.containsKey(intent.key)) {
        _queueActions([
          PhysicalKeyboardDispatch(
            lease: active.lease,
            action: KeyboardIntentAction.up,
            modifiers: effectiveModifiers,
            source: active.source,
            lockMask: intent.lockMask,
            legacyName: active.legacyName,
          ),
        ]);
      }
    }
    if (!intent.key.isModifier && active.route == ActiveKeyRoute.physical) {
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
    final accepted = _queueActions([
      CommittedTextDispatch(
        text: intent.text,
        literal: context.inputMode != ControllerKeyboardInputMode.physical,
        source: intent.source,
        deleteBeforeGraphemes: intent.deleteBeforeGraphemes,
        deleteAfterGraphemes: intent.deleteAfterGraphemes,
        sourceLanguageTag: intent.sourceLanguageTag,
        sourceLayoutType: intent.sourceLayoutType,
      ),
    ]);
    if (accepted && intent.consumeOneShot) {
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
        (context.inputMode == ControllerKeyboardInputMode.text ||
            (context.inputMode == ControllerKeyboardInputMode.auto &&
                intent.origin == KeyboardInputOrigin.ime &&
                !mobileModifierState.hasActive)) &&
        _mayRouteCandidateAsText(intent.key, text) &&
        !modifiers.ctrl &&
        !modifiers.alt &&
        !modifiers.command &&
        !intent.reportedModifiers.any(
          (key) =>
              key.modifier == CanonicalModifier.control ||
              key.modifier == CanonicalModifier.alt ||
              key.modifier == CanonicalModifier.meta,
        );
    return maySendText ? ActiveKeyRoute.text : ActiveKeyRoute.physical;
  }

  static bool _mayRouteCandidateAsText(HidKey key, String? text) {
    if (text == null || text.isEmpty) return false;
    final usage = key.usage;
    if (key.usagePage == HidKey.keyboardUsagePage &&
        ((usage >= 0x28 && usage <= 0x2b) ||
            (usage >= 0x39 && usage <= 0x53) ||
            usage == 0x58 ||
            usage == 0x65 ||
            (usage >= 0x68 && usage <= 0x73))) {
      return false;
    }
    // Invalid or oversized text stays on the text route so admission reports
    // refusal; it must not silently turn into a physical fallback.
    if (KeyboardTextPolicy.inspect(text).rejection != null) return true;
    return !text.runes.any(
      (scalar) =>
          scalar < 0x20 ||
          (scalar >= 0x7f && scalar <= 0x9f) ||
          scalar == 0x2028 ||
          scalar == 0x2029,
    );
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
