import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:get/get.dart';

import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../models/state_model.dart';
import 'relative_mouse_model.dart';
import 'keyboard_dispatcher.dart';
import 'keyboard_event_normalizer.dart';
import 'keyboard_input_controller.dart';
import 'keyboard_intent.dart';
import 'keyboard_modifier_controller.dart';
import '../common.dart';
import '../consts.dart';
import '../mobile/mobile_modifier_state.dart';
import '../mobile/mobile_viewport.dart';

/// Mouse button enum.
enum MouseButtons { left, right, wheel, back }

const _kMouseEventDown = 'mousedown';
const _kMouseEventUp = 'mouseup';
const _kMouseEventMove = 'mousemove';

class CanvasCoords {
  double x = 0;
  double y = 0;
  double scale = 1.0;
  double scrollX = 0;
  double scrollY = 0;
  ScrollStyle scrollStyle = ScrollStyle.scrollauto;
  Size size = Size.zero;

  CanvasCoords();

  Map<String, dynamic> toJson() {
    return {
      'x': x,
      'y': y,
      'scale': scale,
      'scrollX': scrollX,
      'scrollY': scrollY,
      'scrollStyle': scrollStyle.toJson(),
      'size': {'w': size.width, 'h': size.height},
    };
  }

  static CanvasCoords fromJson(Map<String, dynamic> json) {
    final model = CanvasCoords();
    model.x = json['x'];
    model.y = json['y'];
    model.scale = json['scale'];
    model.scrollX = json['scrollX'];
    model.scrollY = json['scrollY'];
    model.scrollStyle = ScrollStyle.fromJson(
      json['scrollStyle'],
      ScrollStyle.scrollauto,
    );
    model.size = Size(json['size']['w'], json['size']['h']);
    return model;
  }

  static CanvasCoords fromCanvasModel(CanvasModel model) {
    final coords = CanvasCoords();
    coords.x = model.x;
    coords.y = model.y;
    coords.scale = model.scale;
    coords.scrollX = model.scrollX;
    coords.scrollY = model.scrollY;
    coords.scrollStyle = model.scrollStyle;
    coords.size = model.size;
    return coords;
  }
}

class CursorCoords {
  Offset offset = Offset.zero;

  CursorCoords();

  Map<String, dynamic> toJson() {
    return {'offset_x': offset.dx, 'offset_y': offset.dy};
  }

  static CursorCoords fromJson(Map<String, dynamic> json) {
    final model = CursorCoords();
    model.offset = Offset(json['offset_x'], json['offset_y']);
    return model;
  }

  static CursorCoords fromCursorModel(CursorModel model) {
    final coords = CursorCoords();
    coords.offset = model.offset;
    return coords;
  }
}

class RemoteWindowCoords {
  RemoteWindowCoords(
    this.windowRect,
    this.canvas,
    this.cursor,
    this.remoteRect,
  );
  Rect windowRect;
  CanvasCoords canvas;
  CursorCoords cursor;
  Rect remoteRect;
  Offset relativeOffset = Offset.zero;

  Map<String, dynamic> toJson() {
    return {
      'canvas': canvas.toJson(),
      'cursor': cursor.toJson(),
      'windowRect': rectToJson(windowRect),
      'remoteRect': rectToJson(remoteRect),
    };
  }

  static Map<String, dynamic> rectToJson(Rect r) {
    return {'l': r.left, 't': r.top, 'w': r.width, 'h': r.height};
  }

  static Rect rectFromJson(Map<String, dynamic> json) {
    return Rect.fromLTWH(json['l'], json['t'], json['w'], json['h']);
  }

  RemoteWindowCoords.fromJson(Map<String, dynamic> json)
    : windowRect = rectFromJson(json['windowRect']),
      canvas = CanvasCoords.fromJson(json['canvas']),
      cursor = CursorCoords.fromJson(json['cursor']),
      remoteRect = rectFromJson(json['remoteRect']);
}

extension ToString on MouseButtons {
  String get value {
    switch (this) {
      case MouseButtons.left:
        return 'left';
      case MouseButtons.right:
        return 'right';
      case MouseButtons.wheel:
        return 'wheel';
      case MouseButtons.back:
        return 'back';
    }
  }
}

class PointerEventToRust {
  final String kind;
  final String type;
  final dynamic value;

  PointerEventToRust(this.kind, this.type, this.value);

  Map<String, dynamic> toJson() {
    return {
      'k': kind,
      'v': {'t': type, 'v': value},
    };
  }
}

class InputModel {
  final WeakReference<FFI> parent;
  String keyboardMode = '';

  // keyboard
  late final KeyboardInputController _keyboardInput;
  final _flutterKeyboardNormalizer = FlutterKeyboardEventNormalizer();
  final _androidKeyboardNormalizer = AndroidHardwareKeyboardNormalizer();
  final _toolbarKeyboardNormalizer = MobileToolbarKeyboardNormalizer();
  ControllerKeyboardInputMode _keyboardInputMode =
      ControllerKeyboardInputMode.auto;

  // trackpad
  var _trackpadLastDelta = Offset.zero;
  var _stopFling = true;
  var _fling = false;
  Timer? _flingTimer;
  final _flingBaseDelay = 30;
  final _trackpadAdjustPeerLinux = 0.06;
  // This is an experience value.
  final _trackpadAdjustMacToWin = 2.50;
  // Ignore directional locking for very small deltas on both axes (including
  // tiny single-axis movement) to avoid over-filtering near zero.
  static const double _trackpadAxisNoiseThreshold = 0.2;
  // Lock to dominant axis only when one axis is clearly stronger.
  // 1.6 means the dominant axis must be >= 60% larger than the other.
  static const double _trackpadAxisLockRatio = 1.6;
  int _trackpadSpeed = kDefaultTrackpadSpeed;
  double _trackpadSpeedInner = kDefaultTrackpadSpeed / 100.0;
  var _trackpadScrollUnsent = Offset.zero;

  // Mobile relative mouse delta accumulators (for slow/fine movements).
  double _mobileDeltaRemainderX = 0.0;
  double _mobileDeltaRemainderY = 0.0;

  var _lastScale = 1.0;

  bool _pointerMovedAfterEnter = false;
  bool _pointerInsideImage = false;

  // mouse
  final isPhysicalMouse = false.obs;
  int _lastButtons = 0;
  final Set<int> _blockedRemotePointerIds = <int>{};
  Offset lastMousePos = Offset.zero;
  int _lastWheelTsUs = 0;

  // Wheel acceleration thresholds.
  static const int _wheelAccelFastThresholdUs = 40000; // 40ms
  static const int _wheelAccelMediumThresholdUs = 80000; // 80ms
  static const double _wheelBurstVelocityThreshold =
      0.002; // delta units per microsecond
  // Wheel burst acceleration (empirical tuning).
  // Applies only to fast, non-smooth bursts to preserve single-step scrolling.
  // Flutter uses microseconds for dt, so velocity is in delta/us.

  // Relative mouse mode (for games/3D apps).
  final relativeMouseMode = false.obs;
  // Session-scoped ownership for the two-finger virtual-button drag gesture.
  bool mobileSpecialHoldDragActive = false;
  late final RelativeMouseModel _relativeMouse;
  // Callback to cancel external throttle timer when relative mouse mode is disabled.
  VoidCallback? onRelativeMouseModeDisabled;
  // Disposer for the relativeMouseMode observer (to prevent memory leaks).
  Worker? _relativeMouseModeDisposer;

  bool _queryOtherWindowCoords = false;
  Rect? _windowRect;
  List<RemoteWindowCoords> _remoteWindowCoords = [];

  late final SessionID sessionId;

  MobileModifierState get mobileModifierState => _keyboardInput.mobileState;
  Future<void> get keyboardDispatchIdle => _keyboardInput.idle;
  bool get shift => _effectiveModifiers.shift;
  bool get ctrl => _effectiveModifiers.ctrl;
  bool get alt => _effectiveModifiers.alt;
  bool get command => _effectiveModifiers.command;
  set shift(bool value) =>
      _keyboardInput.setPhysical(MobileModifierKey.shift, value);
  set ctrl(bool value) =>
      _keyboardInput.setPhysical(MobileModifierKey.ctrl, value);
  set alt(bool value) =>
      _keyboardInput.setPhysical(MobileModifierKey.alt, value);
  set command(bool value) =>
      _keyboardInput.setPhysical(MobileModifierKey.command, value);

  KeyboardModifiers get _effectiveModifiers =>
      _keyboardInput.effectiveModifiers;

  bool get keyboardPerm => parent.target!.ffiModel.keyboard;
  String get id => parent.target?.id ?? '';
  String? get peerPlatform => parent.target?.ffiModel.pi.platform;
  String get peerVersion => parent.target?.ffiModel.pi.version ?? '';
  bool get isViewOnly => parent.target!.ffiModel.viewOnly;
  bool get showMyCursor => parent.target!.ffiModel.showMyCursor;
  double get devicePixelRatio => parent.target!.canvasModel.devicePixelRatio;
  bool get isViewCamera => parent.target!.connType == ConnType.viewCamera;
  int get trackpadSpeed => _trackpadSpeed;
  bool get useEdgeScroll =>
      !(isMobileClient && isViewCamera) &&
      (parent.target!.canvasModel.scrollStyle == ScrollStyle.scrolledge ||
          parent.target!.canvasModel.scrollStyle ==
              ScrollStyle.scrolledgeaccel);

  /// Check if the connected server supports relative mouse mode.
  bool get isRelativeMouseModeSupported => _relativeMouse.isSupported;

  InputModel(this.parent) {
    sessionId = parent.target!.sessionId;
    _keyboardInput = KeyboardInputController(
      canDispatch: () => keyboardPerm && !isViewOnly && !isViewCamera,
      sendHid: ({required key, required action, required lockMask}) {
        if (key.usagePage != HidKey.keyboardUsagePage) {
          return Future<void>.value();
        }
        return Future<void>.sync(
          () => bind.sessionHandleFlutterKeyEvent(
            sessionId: sessionId,
            character: '',
            usbHid: key.usage,
            lockModes: lockMask,
            downOrUp: action != KeyboardIntentAction.up,
          ),
        );
      },
      sendLegacy: ({required name, required down, required modifiers}) {
        return Future<void>.sync(
          () => bind.sessionInputKey(
            sessionId: sessionId,
            name: name,
            down: down,
            press: false,
            alt: modifiers.alt,
            ctrl: modifiers.ctrl,
            shift: modifiers.shift,
            command: modifiers.command,
          ),
        );
      },
      sendText:
          ({
            required text,
            required deleteBeforeGraphemes,
            required deleteAfterGraphemes,
            required sourceLanguageTag,
            required sourceLayoutType,
          }) {
            if ((sourceLanguageTag.isNotEmpty || sourceLayoutType.isNotEmpty) &&
                deleteBeforeGraphemes == 0 &&
                deleteAfterGraphemes == 0) {
              return Future<void>.sync(
                () => bind.sessionInputTextEditWithSourceLayout(
                  sessionId: sessionId,
                  value: text,
                  sourceLanguageTag: sourceLanguageTag,
                  sourceLayoutType: sourceLayoutType,
                ),
              );
            }
            return Future<void>.sync(
              () => bind.sessionInputTextEdit(
                sessionId: sessionId,
                value: text,
                deleteBeforeGraphemes: deleteBeforeGraphemes,
                deleteAfterGraphemes: deleteAfterGraphemes,
              ),
            );
          },
      onError: (error, stackTrace) {
        debugPrint(
          'Remote keyboard dispatch failed (${error.runtimeType})',
        );
        debugPrintStack(stackTrace: stackTrace);
      },
    );
    _relativeMouse = RelativeMouseModel(
      sessionId: sessionId,
      enabled: relativeMouseMode,
      keyboardPerm: () => keyboardPerm,
      isViewCamera: () => isViewCamera,
      peerVersion: () => peerVersion,
      peerPlatform: () => peerPlatform,
      modify: (msg) => modify(msg),
      getPointerInsideImage: () => _pointerInsideImage,
      setPointerInsideImage: (inside) => _pointerInsideImage = inside,
    );
    _relativeMouse.onDisabled = () => onRelativeMouseModeDisabled?.call();

    // Sync relative mouse mode state to global state for UI components (e.g., tab bar hint).
    _relativeMouseModeDisposer = ever(relativeMouseMode, (bool value) {
      final peerId = id;
      if (peerId.isNotEmpty) {
        stateGlobal.relativeMouseModeState[peerId] = value;
      }
    });
  }

  // https://github.com/flutter/flutter/issues/157241
  // Infer CapsLock state from the character output.
  // This is needed because Flutter's HardwareKeyboard.lockModesEnabled may report
  // incorrect CapsLock state on iOS.
  bool _getIosCapsFromCharacter(KeyEvent e) {
    if (!isIOS) return false;
    final ch = e.character;
    return _getIosCapsFromCharacterImpl(
      ch,
      HardwareKeyboard.instance.isShiftPressed,
    );
  }

  // RawKeyEvent version of _getIosCapsFromCharacter.
  bool _getIosCapsFromRawCharacter(RawKeyEvent e) {
    if (!isIOS) return false;
    final ch = e.character;
    return _getIosCapsFromCharacterImpl(ch, e.isShiftPressed);
  }

  // Shared implementation for inferring CapsLock state from character.
  // Uses Unicode-aware case detection to support non-ASCII letters (e.g., ü/Ü, é/É).
  //
  // Limitations:
  // 1. This inference assumes the client and server use the same keyboard layout.
  //    If layouts differ (e.g., client uses EN, server uses DE), the character output
  //    may not match expectations. For example, ';' on EN layout maps to 'ö' on DE
  //    layout, making it impossible to correctly infer CapsLock state from the
  //    character alone.
  // 2. On iOS, CapsLock+Shift produces uppercase letters (unlike desktop where it
  //    produces lowercase). This method cannot handle that case correctly.
  bool _getIosCapsFromCharacterImpl(String? ch, bool shiftPressed) {
    if (ch == null || ch.length != 1) return false;
    // Use Dart's built-in Unicode-aware case detection
    final upper = ch.toUpperCase();
    final lower = ch.toLowerCase();
    final isUpper = upper == ch && lower != ch;
    final isLower = lower == ch && upper != ch;
    // Skip non-letter characters (e.g., numbers, symbols, CJK characters without case)
    if (!isUpper && !isLower) return false;
    return isUpper != shiftPressed;
  }

  int _buildLockModes(bool iosCapsLock) {
    const capslock = 1;
    const numlock = 2;
    const scrolllock = 3;
    int lockModes = 0;
    if (isIOS) {
      if (iosCapsLock) {
        lockModes |= (1 << capslock);
      }
      // Ignore "NumLock/ScrollLock" on iOS for now.
    } else {
      if (HardwareKeyboard.instance.lockModesEnabled.contains(
        KeyboardLockMode.capsLock,
      )) {
        lockModes |= (1 << capslock);
      }
      if (HardwareKeyboard.instance.lockModesEnabled.contains(
        KeyboardLockMode.numLock,
      )) {
        lockModes |= (1 << numlock);
      }
      if (HardwareKeyboard.instance.lockModesEnabled.contains(
        KeyboardLockMode.scrollLock,
      )) {
        lockModes |= (1 << scrolllock);
      }
    }
    return lockModes;
  }

  ControllerKeyboardMode get _controllerKeyboardMode => switch (keyboardMode) {
    kKeyMapMode => ControllerKeyboardMode.map,
    kKeyTranslateMode => ControllerKeyboardMode.translate,
    _ => ControllerKeyboardMode.legacy,
  };

  KeyboardClientKind get _keyboardClientKind {
    if (isWebDesktop) return KeyboardClientKind.webDesktop;
    if (isDesktop) return KeyboardClientKind.desktop;
    if (isAndroid) return KeyboardClientKind.android;
    if (isIOS) return KeyboardClientKind.ios;
    return KeyboardClientKind.otherMobile;
  }

  KeyboardRoutingContext get _keyboardRoutingContext => KeyboardRoutingContext(
    keyboardMode: _controllerKeyboardMode,
    inputMode: _keyboardInputMode,
    clientKind: _keyboardClientKind,
    peerIsAndroid: peerPlatform == kPeerPlatformAndroid,
    ignoreMeta: isWindows || isLinux,
  );

  Future<void> setKeyboardInputMode(String mode) async {
    final next = switch (mode) {
      kKeyboardInputModeText => ControllerKeyboardInputMode.text,
      kKeyboardInputModePhysical => ControllerKeyboardInputMode.physical,
      _ => ControllerKeyboardInputMode.auto,
    };
    if (next == _keyboardInputMode) return;
    await resetKeyboard(
      KeyboardResetReason.inputModeChange,
      invalidatePending: true,
      allowBlockedReleases: true,
    );
    _keyboardInputMode = next;
  }

  Future<void> resetKeyboard(
    KeyboardResetReason reason, {
    bool invalidatePending = false,
    bool allowBlockedReleases = false,
  }) => _keyboardInput.reset(
    reason,
    invalidatePending: invalidatePending,
    allowBlockedReleases: allowBlockedReleases,
  );

  // This function must be called after the peer info is received.
  // Because `sessionGetKeyboardMode` relies on the peer version.
  Future<void> updateKeyboardMode() async {
    // * Currently mobile does not enable map mode
    if (isDesktop || isWebDesktop) {
      final next =
          await bind.sessionGetKeyboardMode(sessionId: sessionId) ??
          kKeyLegacyMode;
      if (next != keyboardMode) {
        await resetKeyboard(
          KeyboardResetReason.inputModeChange,
          invalidatePending: true,
          allowBlockedReleases: true,
        );
        keyboardMode = next;
      }
    }
  }

  /// Updates the trackpad speed based on the session value.
  ///
  /// The expected format of the retrieved value is a string that can be parsed into a double.
  /// If parsing fails or the value is out of bounds (less than `kMinTrackpadSpeed` or greater
  /// than `kMaxTrackpadSpeed`), the trackpad speed is reset to the default
  /// value (`kDefaultTrackpadSpeed`).
  ///
  /// Bounds:
  /// - Minimum: `kMinTrackpadSpeed`
  /// - Maximum: `kMaxTrackpadSpeed`
  /// - Default: `kDefaultTrackpadSpeed`
  Future<void> updateTrackpadSpeed() async {
    _trackpadSpeed =
        (await bind.sessionGetTrackpadSpeed(sessionId: sessionId) ??
        kDefaultTrackpadSpeed);
    if (_trackpadSpeed < kMinTrackpadSpeed ||
        _trackpadSpeed > kMaxTrackpadSpeed) {
      _trackpadSpeed = kDefaultTrackpadSpeed;
    }
    _trackpadSpeedInner = _trackpadSpeed / 100.0;
  }

  KeyEventResult handleRawKeyEvent(RawKeyEvent e) {
    if (isViewOnly) return KeyEventResult.handled;
    if (isViewCamera) return KeyEventResult.handled;
    if (!isInputSourceFlutter) {
      if (isDesktop) {
        return KeyEventResult.handled;
      } else if (isWeb) {
        return KeyEventResult.ignored;
      }
    }

    if (_relativeMouse.handleRawKeyEvent(e)) {
      return KeyEventResult.handled;
    }

    final iosCapsLock = isIOS && e is RawKeyDownEvent
        ? _getIosCapsFromRawCharacter(e)
        : false;
    final intent = _flutterKeyboardNormalizer.fromRawKeyEvent(
      e,
      lockMask: _buildLockModes(iosCapsLock),
    );
    if (intent != null) {
      _keyboardInput.handle(intent, _keyboardRoutingContext);
    }

    return KeyEventResult.handled;
  }

  KeyEventResult handleKeyEvent(KeyEvent e) {
    if (isViewOnly) return KeyEventResult.handled;
    if (isViewCamera) return KeyEventResult.handled;
    if (!isInputSourceFlutter) {
      if (isDesktop) {
        return KeyEventResult.handled;
      } else if (isWeb) {
        return KeyEventResult.ignored;
      }
    }
    if (_relativeMouse.handleKeyEvent(
      e,
      ctrlPressed: ctrl,
      shiftPressed: shift,
      altPressed: alt,
      commandPressed: command,
    )) {
      return KeyEventResult.handled;
    }

    final iosCapsLock = isIOS && (e is KeyDownEvent || e is KeyRepeatEvent)
        ? _getIosCapsFromCharacter(e)
        : false;
    final intent = _flutterKeyboardNormalizer.fromKeyEvent(
      e,
      lockMask: _buildLockModes(iosCapsLock),
    );
    if (intent != null) {
      _keyboardInput.handle(intent, _keyboardRoutingContext);
    }

    return KeyEventResult.handled;
  }

  Future<void> inputAndroidRemotePhysicalKey(
    int usbHidUsage,
    bool down, {
    bool repeat = false,
    Iterable<int> modifierUsages = const <int>[],
  }) {
    final intent = _androidKeyboardNormalizer.physical(
      usbHidUsage: usbHidUsage,
      down: down,
      repeat: repeat,
      modifierUsages: modifierUsages,
      lockMask: _buildLockModes(false),
    );
    if (intent != null) {
      return _keyboardInput.handleAndWait(intent, _keyboardRoutingContext);
    }
    return Future<void>.value();
  }

  Future<void> inputAndroidRemoteCommittedText(
    String text, {
    required String sourceLanguageTag,
    required String sourceLayoutType,
  }) {
    final intent = _androidKeyboardNormalizer.text(
      text,
      sourceLanguageTag: sourceLanguageTag,
      sourceLayoutType: sourceLayoutType,
    );
    if (intent != null) {
      return _keyboardInput.handleAndWait(intent, _keyboardRoutingContext);
    }
    return Future<void>.value();
  }

  /// Send key stroke event.
  /// [down] indicates the key's state(down or up).
  /// [press] indicates a click event(down and up).
  void inputKey(String name, {bool? down, bool? press}) {
    final Iterable<KeyboardIntent> intents;
    if (press ?? down == null) {
      intents = _toolbarKeyboardNormalizer.click(name);
    } else {
      final intent = _toolbarKeyboardNormalizer.event(
        name,
        action: down == true
            ? KeyboardIntentAction.down
            : KeyboardIntentAction.up,
      );
      intents = intent == null ? const [] : [intent];
    }
    for (final intent in intents) {
      _keyboardInput.handle(intent, _keyboardRoutingContext);
    }
  }

  void inputKeyWithTemporaryMobileModifier(
    String name,
    MobileModifierKey modifier,
  ) {
    if (!_effectiveModifiers.isActive(modifier)) {
      tapMobileModifier(modifier);
    }
    inputKey(name);
  }

  void tapMobileModifier(MobileModifierKey modifier) {
    _keyboardInput.handle(
      _toolbarKeyboardNormalizer.modifier(
        _canonicalModifier(modifier),
        action: SyntheticModifierAction.toggle,
      ),
      _keyboardRoutingContext,
    );
  }

  void lockMobileModifier(MobileModifierKey modifier) {
    _keyboardInput.handle(
      _toolbarKeyboardNormalizer.modifier(
        _canonicalModifier(modifier),
        action: SyntheticModifierAction.lock,
      ),
      _keyboardRoutingContext,
    );
  }

  static CanonicalModifier _canonicalModifier(MobileModifierKey modifier) =>
      switch (modifier) {
        MobileModifierKey.ctrl => CanonicalModifier.control,
        MobileModifierKey.shift => CanonicalModifier.shift,
        MobileModifierKey.alt => CanonicalModifier.alt,
        MobileModifierKey.command => CanonicalModifier.meta,
      };

  void consumeMobileOneShotModifiers() {
    _keyboardInput.consumeOneShot();
  }

  void inputMobileTextEdit({
    required String text,
    required int deleteBeforeGraphemes,
    required int deleteAfterGraphemes,
    bool allowModifierShortcuts = false,
  }) {
    _keyboardInput.handle(
      CommittedTextIntent(
        text: text,
        source: KeyboardInputSource.futureIme,
        deleteBeforeGraphemes: deleteBeforeGraphemes,
        deleteAfterGraphemes: deleteAfterGraphemes,
        allowMobileShortcut: allowModifierShortcuts,
      ),
      _keyboardRoutingContext,
    );
  }

  bool inputCommittedText(
    String text, {
    int deleteBeforeGraphemes = 0,
    int deleteAfterGraphemes = 0,
  }) => _keyboardInput.handle(
    CommittedTextIntent(
      text: text,
      source: KeyboardInputSource.futureIme,
      deleteBeforeGraphemes: deleteBeforeGraphemes,
      deleteAfterGraphemes: deleteAfterGraphemes,
    ),
    _keyboardRoutingContext,
  );

  bool inputString(String text) => _keyboardInput.handle(
    CommittedTextIntent(
      text: text,
      source: KeyboardInputSource.mobileToolbar,
      consumeOneShot: false,
    ),
    _keyboardRoutingContext,
  );

  static Map<String, dynamic> getMouseEventMove() => {
    'type': _kMouseEventMove,
    'buttons': 0,
  };

  Map<String, dynamic> _getMouseEvent(PointerEvent evt, String type) {
    final Map<String, dynamic> out = {};

    bool hasStaleButtonsOnMouseUp =
        type == _kMouseEventUp && evt.buttons == _lastButtons;

    // Check update event type and set buttons to be sent.
    int buttons = _lastButtons;
    if (type == _kMouseEventMove) {
      // flutter may emit move event if one button is pressed and another button
      // is pressing or releasing.
      if (evt.buttons != _lastButtons) {
        // For simplicity
        // Just consider 3 - 1 ((Left + Right buttons) - Left button)
        // Do not consider 2 - 1 (Right button - Left button)
        // or 6 - 5 ((Right + Mid buttons) - (Left + Mid buttons))
        // and so on
        buttons = evt.buttons - _lastButtons;
        if (buttons > 0) {
          type = _kMouseEventDown;
        } else {
          type = _kMouseEventUp;
          buttons = -buttons;
        }
      }
    } else {
      if (evt.buttons != 0) {
        buttons = evt.buttons;
      }
    }
    _lastButtons = hasStaleButtonsOnMouseUp ? 0 : evt.buttons;

    out['buttons'] = buttons;
    out['type'] = type;
    return out;
  }

  /// Send a mouse tap event(down and up).
  Future<void> tap(MouseButtons button) async {
    await sendMouse('down', button);
    await sendMouse('up', button);
  }

  Future<void> tapDown(MouseButtons button) async {
    await sendMouse('down', button);
  }

  Future<void> tapUp(MouseButtons button) async {
    await sendMouse('up', button);
  }

  /// Send scroll event with scroll distance [y].
  Future<void> scroll(int y) async {
    if (isViewCamera) return;
    await bind.sessionSendMouse(
      sessionId: sessionId,
      msg: json.encode(modify({'id': id, 'type': 'wheel', 'y': y.toString()})),
    );
  }

  /// Reset key modifiers to false, including [shift], [ctrl], [alt] and [command].
  void resetModifiers() {
    unawaited(
      resetKeyboard(
        KeyboardResetReason.manual,
        invalidatePending: true,
        allowBlockedReleases: true,
      ),
    );
  }

  void permissionRevoked() {
    unawaited(
      resetKeyboard(
        KeyboardResetReason.permissionRevoked,
        invalidatePending: true,
        allowBlockedReleases: true,
      ),
    );
  }

  /// Modify the given modifier map [evt] based on current modifier key status.
  Map<String, dynamic> modify(Map<String, dynamic> evt) {
    if (ctrl) evt['ctrl'] = 'true';
    if (shift) evt['shift'] = 'true';
    if (alt) evt['alt'] = 'true';
    if (command) evt['command'] = 'true';
    return evt;
  }

  /// Send mouse press event.
  Future<void> sendMouse(String type, MouseButtons button) async {
    if (!keyboardPerm) return;
    if (isViewCamera) return;
    await bind.sessionSendMouse(
      sessionId: sessionId,
      msg: json.encode(modify({'type': type, 'buttons': button.value})),
    );
  }

  void enterOrLeave(bool enter) {
    if (!enter) {
      unawaited(
        resetKeyboard(
          KeyboardResetReason.focusLoss,
          invalidatePending: true,
          allowBlockedReleases: true,
        ),
      );
    }
    _pointerMovedAfterEnter = false;
    _pointerInsideImage = enter;
    _lastWheelTsUs = 0;

    // Fix status
    if (!enter) {
      _blockedRemotePointerIds.clear();
    }
    _relativeMouse.onEnterOrLeaveImage(enter);
    _flingTimer?.cancel();
    if (!isInputSourceFlutter) {
      bind.sessionEnterOrLeave(sessionId: sessionId, enter: enter);
    }
    if (!isWeb && enter) {
      bind.setCurSessionId(sessionId: sessionId);
    }
  }

  /// Send mouse movement event with distance in [x] and [y].
  Future<void> moveMouse(double x, double y) async {
    if (!keyboardPerm) return;
    if (isViewCamera) return;
    var x2 = x.toInt();
    var y2 = y.toInt();
    await bind.sessionSendMouse(
      sessionId: sessionId,
      msg: json.encode(modify({'x': '$x2', 'y': '$y2'})),
    );
  }

  /// Send relative mouse movement for mobile clients (virtual joystick).
  /// This method is for touch-based controls that want to send delta values.
  /// Uses the 'move_relative' type which bypasses absolute position tracking.
  ///
  /// Accumulates fractional deltas to avoid losing slow/fine movements.
  /// Only sends events when relative mouse mode is enabled and supported.
  Future<void> sendMobileRelativeMouseMove(double dx, double dy) async {
    if (!keyboardPerm) return;
    if (isViewCamera) return;
    // Only send relative mouse events when relative mode is enabled and supported.
    if (!isRelativeMouseModeSupported || !relativeMouseMode.value) return;
    _mobileDeltaRemainderX += dx;
    _mobileDeltaRemainderY += dy;
    final x = _mobileDeltaRemainderX.truncate();
    final y = _mobileDeltaRemainderY.truncate();
    _mobileDeltaRemainderX -= x;
    _mobileDeltaRemainderY -= y;
    if (x == 0 && y == 0) return;
    await bind.sessionSendMouse(
      sessionId: sessionId,
      msg: json.encode(modify({'type': 'move_relative', 'x': '$x', 'y': '$y'})),
    );
  }

  /// Update the pointer lock center position based on current window frame.
  Future<void> updatePointerLockCenter({Offset? localCenter}) {
    return _relativeMouse.updatePointerLockCenter(localCenter: localCenter);
  }

  /// Get the current image widget size (for comparison to avoid unnecessary updates).
  Size? get imageWidgetSize => _relativeMouse.imageWidgetSize;

  /// Update the image widget size for center calculation.
  void updateImageWidgetSize(Size size) {
    _relativeMouse.updateImageWidgetSize(size);
  }

  void toggleRelativeMouseMode() {
    _relativeMouse.toggleRelativeMouseMode();
  }

  bool setRelativeMouseMode(bool enabled) {
    return _relativeMouse.setRelativeMouseMode(enabled);
  }

  /// Exit relative mouse mode and release all modifier keys to the remote.
  /// This is called when the user presses the exit shortcut (Ctrl+Alt on Win/Linux, Cmd+G on macOS).
  /// We need to send key-up events for all modifiers because the shortcut itself may have
  /// blocked some key events, leaving the remote in a state where modifiers are stuck.
  void exitRelativeMouseModeWithKeyRelease() {
    if (!_relativeMouse.enabled.value) return;
    unawaited(
      resetKeyboard(
        KeyboardResetReason.relativeMouseExit,
        invalidatePending: true,
        allowBlockedReleases: true,
      ),
    );
    _relativeMouse.setRelativeMouseMode(false);
  }

  void disposeRelativeMouseMode() {
    _relativeMouse.dispose();
    onRelativeMouseModeDisabled = null;
    // Cancel the relative mouse mode observer and clean up global state.
    _relativeMouseModeDisposer?.dispose();
    _relativeMouseModeDisposer = null;
    final peerId = id;
    if (peerId.isNotEmpty) {
      stateGlobal.relativeMouseModeState.remove(peerId);
    }
  }

  void onWindowBlur() {
    unawaited(
      resetKeyboard(
        KeyboardResetReason.focusLoss,
        invalidatePending: true,
        allowBlockedReleases: true,
      ),
    );
    _relativeMouse.onWindowBlur();
  }

  void onWindowFocus() {
    _relativeMouse.onWindowFocus();
  }

  void onPointHoverImage(PointerHoverEvent e) {
    _stopFling = true;
    if (isViewOnly && !showMyCursor) return;
    if (e.kind != ui.PointerDeviceKind.mouse) return;
    if (_isGlobalRemoteInputBlocked(e)) return;

    // May fix https://github.com/rustdesk/rustdesk/issues/13009
    if (isIOS && e.synthesized && e.position == Offset.zero && e.buttons == 0) {
      // iOS may emit a synthesized hover event at (0,0) when the mouse is disconnected.
      // Ignore this event to prevent cursor jumping.
      debugPrint('Ignored synthesized hover at (0,0) on iOS');
      return;
    }

    // Only update pointer region when relative mouse mode is enabled.
    // This avoids unnecessary tracking when not in relative mode.
    if (_relativeMouse.enabled.value) {
      _relativeMouse.updatePointerRegionTopLeftGlobal(e);
    }

    if (!isPhysicalMouse.value) {
      isPhysicalMouse.value = true;
    }
    if (isPhysicalMouse.value) {
      if (!_relativeMouse.handleRelativeMouseMove(e.localPosition)) {
        handleMouse(
          _getMouseEvent(e, _kMouseEventMove),
          e.position,
          edgeScroll: useEdgeScroll,
        );
      }
    }
  }

  void onPointerPanZoomStart(PointerPanZoomStartEvent e) {
    _lastScale = 1.0;
    _stopFling = true;
    if (isViewOnly) return;
    if (isViewCamera) return;
    if (peerPlatform == kPeerPlatformAndroid) {
      handlePointerEvent('touch', kMouseEventTypePanStart, e.position);
    }
  }

  // https://docs.flutter.dev/release/breaking-changes/trackpad-gestures
  void onPointerPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    if (isViewOnly) return;
    if (isViewCamera) return;
    if (peerPlatform != kPeerPlatformAndroid) {
      final scale = ((e.scale - _lastScale) * 1000).toInt();
      _lastScale = e.scale;

      if (scale != 0) {
        bind.sessionSendPointer(
          sessionId: sessionId,
          msg: json.encode(
            PointerEventToRust(kPointerEventKindTouch, 'scale', scale).toJson(),
          ),
        );
        return;
      }
    }

    var delta = e.panDelta * _trackpadSpeedInner;
    if (isMacOS && peerPlatform == kPeerPlatformWindows) {
      delta *= _trackpadAdjustMacToWin;
    }
    delta = _filterTrackpadDeltaAxis(delta);
    _trackpadLastDelta = delta;

    var x = delta.dx.toInt();
    var y = delta.dy.toInt();
    if (peerPlatform == kPeerPlatformLinux) {
      _trackpadScrollUnsent += (delta * _trackpadAdjustPeerLinux);
      x = _trackpadScrollUnsent.dx.truncate();
      y = _trackpadScrollUnsent.dy.truncate();
      _trackpadScrollUnsent -= Offset(x.toDouble(), y.toDouble());
    } else {
      if (x == 0 && y == 0) {
        final thr = 0.1;
        if (delta.dx.abs() > delta.dy.abs()) {
          x = delta.dx > thr ? 1 : (delta.dx < -thr ? -1 : 0);
        } else {
          y = delta.dy > thr ? 1 : (delta.dy < -thr ? -1 : 0);
        }
      }
    }
    if (x != 0 || y != 0) {
      if (peerPlatform == kPeerPlatformAndroid) {
        handlePointerEvent(
          'touch',
          kMouseEventTypePanUpdate,
          Offset(x.toDouble(), y.toDouble()),
        );
      } else {
        if (isViewCamera) return;
        bind.sessionSendMouse(
          sessionId: sessionId,
          msg: '{"type": "trackpad", "x": "$x", "y": "$y"}',
        );
      }
    }
  }

  Offset _filterTrackpadDeltaAxis(Offset delta) {
    final absDx = delta.dx.abs();
    final absDy = delta.dy.abs();
    // Keep diagonal intent when movement is tiny on both axes.
    if (absDx < _trackpadAxisNoiseThreshold &&
        absDy < _trackpadAxisNoiseThreshold) {
      return delta;
    }
    // Dominant-axis lock to reduce accidental cross-axis scrolling noise.
    if (absDy >= absDx * _trackpadAxisLockRatio) {
      return Offset(0, delta.dy);
    }
    if (absDx >= absDy * _trackpadAxisLockRatio) {
      return Offset(delta.dx, 0);
    }
    return delta;
  }

  void _scheduleFling(double x, double y, int delay) {
    if (isViewCamera) return;
    if ((x == 0 && y == 0) || _stopFling) {
      _fling = false;
      return;
    }

    _flingTimer = Timer(Duration(milliseconds: delay), () {
      if (_stopFling) {
        _fling = false;
        return;
      }

      final d = 0.97;
      x *= d;
      y *= d;

      // Try set delta (x,y) and delay.
      var dx = x.toInt();
      var dy = y.toInt();
      if (parent.target?.ffiModel.pi.platform == kPeerPlatformLinux) {
        dx = (x * _trackpadAdjustPeerLinux).toInt();
        dy = (y * _trackpadAdjustPeerLinux).toInt();
      }

      var delay = _flingBaseDelay;

      if (dx == 0 && dy == 0) {
        _fling = false;
        return;
      }

      bind.sessionSendMouse(
        sessionId: sessionId,
        msg: '{"type": "trackpad", "x": "$dx", "y": "$dy"}',
      );
      _scheduleFling(x, y, delay);
    });
  }

  void waitLastFlingDone() {
    if (_fling) {
      _stopFling = true;
    }
    for (var i = 0; i < 5; i++) {
      if (!_fling) {
        break;
      }
      sleep(Duration(milliseconds: 10));
    }
    _flingTimer?.cancel();
  }

  void onPointerPanZoomEnd(PointerPanZoomEndEvent e) {
    if (isViewCamera) return;
    if (peerPlatform == kPeerPlatformAndroid) {
      handlePointerEvent('touch', kMouseEventTypePanEnd, e.position);
      return;
    }

    bind.sessionSendPointer(
      sessionId: sessionId,
      msg: json.encode(
        PointerEventToRust(kPointerEventKindTouch, 'scale', 0).toJson(),
      ),
    );

    waitLastFlingDone();
    _stopFling = false;

    // 2.0 is an experience value
    double minFlingValue = 2.0 * _trackpadSpeedInner;
    if (isMacOS && peerPlatform == kPeerPlatformWindows) {
      minFlingValue *= _trackpadAdjustMacToWin;
    }
    if (_trackpadLastDelta.dx.abs() > minFlingValue ||
        _trackpadLastDelta.dy.abs() > minFlingValue) {
      _fling = true;
      _scheduleFling(
        _trackpadLastDelta.dx,
        _trackpadLastDelta.dy,
        _flingBaseDelay,
      );
    }
    _trackpadLastDelta = Offset.zero;
  }

  // iOS Magic Mouse duplicate event detection.
  // When using Magic Mouse on iPad, iOS may emit both mouse and touch events
  // for the same click in certain areas (like top-left corner).
  int _lastMouseDownTimeMs = 0;
  ui.Offset _lastMouseDownPos = ui.Offset.zero;

  /// Check if a touch tap event should be ignored because it's a duplicate
  /// of a recent mouse event (iOS Magic Mouse issue).
  bool shouldIgnoreTouchTap(ui.Offset pos) {
    if (!isIOS) return false;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dt = nowMs - _lastMouseDownTimeMs;
    final distance = (_lastMouseDownPos - pos).distance;
    // If touch tap is within 2000ms and 80px of the last mouse down,
    // it's likely a duplicate event from the same Magic Mouse click.
    if (dt >= 0 && dt < 2000 && distance < 80.0) {
      debugPrint("shouldIgnoreTouchTap: IGNORED (dt=$dt, dist=$distance)");
      return true;
    }
    return false;
  }

  void onPointDownImage(PointerDownEvent e) {
    debugPrint("onPointDownImage ${e.kind}");
    _stopFling = true;
    if (isDesktop) _queryOtherWindowCoords = true;
    _remoteWindowCoords = [];
    _windowRect = null;
    if (isViewOnly && !showMyCursor) return;
    if (isViewCamera) return;

    if (e.kind == ui.PointerDeviceKind.mouse &&
        _isGlobalRemoteInputBlocked(e)) {
      _blockedRemotePointerIds.add(e.pointer);
      return;
    }

    // Track mouse down events for duplicate detection on iOS.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (e.kind == ui.PointerDeviceKind.mouse) {
      _lastMouseDownTimeMs = nowMs;
      _lastMouseDownPos = e.position;
    }

    if (_relativeMouse.enabled.value) {
      _relativeMouse.updatePointerRegionTopLeftGlobal(e);
    }

    if (e.kind != ui.PointerDeviceKind.mouse) {
      if (isPhysicalMouse.value) {
        isPhysicalMouse.value = false;
      }
    }
    if (isPhysicalMouse.value) {
      // In relative mouse mode, send button events without position.
      // Use _relativeMouse.enabled.value consistently with the guard above.
      if (_relativeMouse.enabled.value) {
        _relativeMouse.sendRelativeMouseButton(
          _getMouseEvent(e, _kMouseEventDown),
        );
      } else {
        handleMouse(_getMouseEvent(e, _kMouseEventDown), e.position);
      }
    }
  }

  void onPointUpImage(PointerUpEvent e) {
    if (isDesktop) _queryOtherWindowCoords = false;
    if (isViewOnly && !showMyCursor) return;
    if (isViewCamera) return;
    if (_blockedRemotePointerIds.remove(e.pointer)) return;

    if (_relativeMouse.enabled.value) {
      _relativeMouse.updatePointerRegionTopLeftGlobal(e);
    }

    if (e.kind != ui.PointerDeviceKind.mouse) return;
    if (isPhysicalMouse.value) {
      // In relative mouse mode, send button events without position.
      // Use _relativeMouse.enabled.value consistently with the guard above.
      if (_relativeMouse.enabled.value) {
        _relativeMouse.sendRelativeMouseButton(
          _getMouseEvent(e, _kMouseEventUp),
        );
      } else {
        handleMouse(_getMouseEvent(e, _kMouseEventUp), e.position);
      }
    }
  }

  void onPointMoveImage(PointerMoveEvent e) {
    if (isViewOnly && !showMyCursor) return;
    if (isViewCamera) return;
    if (e.kind != ui.PointerDeviceKind.mouse) return;
    if (_blockedRemotePointerIds.contains(e.pointer)) return;
    if (e.buttons == 0 && _isGlobalRemoteInputBlocked(e)) return;

    if (_relativeMouse.enabled.value) {
      _relativeMouse.updatePointerRegionTopLeftGlobal(e);
    }

    if (_queryOtherWindowCoords) {
      Future.delayed(Duration.zero, () async {
        _windowRect = await fillRemoteCoordsAndGetCurFrame(_remoteWindowCoords);
      });
      _queryOtherWindowCoords = false;
    }
    if (isPhysicalMouse.value) {
      if (!_relativeMouse.handleRelativeMouseMove(e.localPosition)) {
        handleMouse(
          _getMouseEvent(e, _kMouseEventMove),
          e.position,
          edgeScroll: useEdgeScroll,
        );
      }
    }
  }

  static Future<Rect?> fillRemoteCoordsAndGetCurFrame(
    List<RemoteWindowCoords> remoteWindowCoords,
  ) async {
    final coords = await rustDeskWinManager
        .getOtherRemoteWindowCoordsFromMain();
    final wc = WindowController.fromWindowId(kWindowId!);
    try {
      final frame = await wc.getFrame();
      for (final c in coords) {
        c.relativeOffset = Offset(
          c.windowRect.left - frame.left,
          c.windowRect.top - frame.top,
        );
        remoteWindowCoords.add(c);
      }
      return frame;
    } catch (e) {
      // Unreachable code
      debugPrint("Failed to get frame of window $kWindowId, it may be hidden");
    }
    return null;
  }

  /// Handle scroll/wheel events.
  /// Note: Scroll events intentionally use absolute positioning even in relative mouse mode.
  /// This is because scroll events don't need relative positioning - they represent
  /// scroll deltas that are independent of cursor position. Games and 3D applications
  /// handle scroll events the same way regardless of mouse mode.
  void onPointerSignalImage(PointerSignalEvent e) {
    if (isViewOnly) return;
    if (isViewCamera) return;
    if (_isGlobalRemoteInputBlocked(e)) return;
    if (e is PointerScrollEvent) {
      final rawDx = e.scrollDelta.dx;
      final rawDy = e.scrollDelta.dy;
      final dominantDelta = rawDx.abs() > rawDy.abs()
          ? rawDx.abs()
          : rawDy.abs();
      final isSmooth = dominantDelta < 1;
      final nowUs = DateTime.now().microsecondsSinceEpoch;
      final dtUs = _lastWheelTsUs == 0 ? 0 : nowUs - _lastWheelTsUs;
      _lastWheelTsUs = nowUs;
      int accel = 1;
      if (!isSmooth &&
          dtUs > 0 &&
          dtUs <= _wheelAccelMediumThresholdUs &&
          (isWindows || isLinux) &&
          peerPlatform == kPeerPlatformMacOS) {
        final velocity = dominantDelta / dtUs;
        if (velocity >= _wheelBurstVelocityThreshold) {
          if (dtUs < _wheelAccelFastThresholdUs) {
            accel = 3;
          } else {
            accel = 2;
          }
        }
      }
      var dx = rawDx.toInt();
      var dy = rawDy.toInt();
      if (rawDx.abs() > rawDy.abs()) {
        dy = 0;
      } else {
        dx = 0;
      }
      if (dx > 0) {
        dx = -accel;
      } else if (dx < 0) {
        dx = accel;
      }
      if (dy > 0) {
        dy = -accel;
      } else if (dy < 0) {
        dy = accel;
      }
      bind.sessionSendMouse(
        sessionId: sessionId,
        msg: '{"type": "wheel", "x": "$dx", "y": "$dy"}',
      );
    }
  }

  void onPointCancelImage(PointerCancelEvent e) {
    _blockedRemotePointerIds.remove(e.pointer);
  }

  bool _isGlobalRemoteInputBlocked(PointerEvent e) {
    return parent.target?.cursorModel.shouldBlockGlobal(
          e.position.dx,
          e.position.dy,
        ) ??
        false;
  }

  void refreshMousePos() => handleMouse(
    {'buttons': 0, 'type': _kMouseEventMove},
    lastMousePos,
    edgeScroll: useEdgeScroll,
  );

  void refreshMousePosAfterViewportScroll() {
    if (isViewOnly || isViewCamera || !keyboardPerm) {
      return;
    }
    handleMouse(
      {'buttons': 0, 'type': _kMouseEventMove},
      lastMousePos,
      moveCanvas: false,
      edgeScroll: false,
    );
  }

  void tryMoveEdgeOnExit(Offset pos) =>
      handleMouse({'buttons': 0, 'type': _kMouseEventMove}, pos, onExit: true);

  static double tryGetNearestRange(double v, double min, double max, double n) {
    if (v < min && v >= min - n) {
      v = min;
    }
    if (v > max && v <= max + n) {
      v = max;
    }
    return v;
  }

  Offset setNearestEdge(double x, double y, Rect rect) {
    double left = x - rect.left;
    double right = rect.right - 1 - x;
    double top = y - rect.top;
    double bottom = rect.bottom - 1 - y;
    if (left < right && left < top && left < bottom) {
      x = rect.left;
    }
    if (right < left && right < top && right < bottom) {
      x = rect.right - 1;
    }
    if (top < left && top < right && top < bottom) {
      y = rect.top;
    }
    if (bottom < left && bottom < right && bottom < top) {
      y = rect.bottom - 1;
    }
    return Offset(x, y);
  }

  void handlePointerEvent(String kind, String type, Offset offset) {
    double x = offset.dx;
    double y = offset.dy;
    if (_checkPeerControlProtected(x, y)) {
      return;
    }
    // Only touch events are handled for now. So we can just ignore buttons.
    // to-do: handle mouse events

    late final dynamic evtValue;
    if (type == kMouseEventTypePanUpdate) {
      evtValue = {'x': x.toInt(), 'y': y.toInt()};
    } else {
      final isMoveTypes = [kMouseEventTypePanStart, kMouseEventTypePanEnd];
      final pos = handlePointerDevicePos(
        kPointerEventKindTouch,
        x,
        y,
        isMoveTypes.contains(type),
        type,
      );
      if (pos == null) {
        return;
      }
      evtValue = {'x': pos.x.toInt(), 'y': pos.y.toInt()};
    }

    final evt = PointerEventToRust(kind, type, evtValue).toJson();
    if (isViewCamera) return;
    bind.sessionSendPointer(
      sessionId: sessionId,
      msg: json.encode(modify(evt)),
    );
  }

  bool _checkPeerControlProtected(double x, double y) {
    final cursorModel = parent.target!.cursorModel;
    if (cursorModel.isPeerControlProtected) {
      lastMousePos = ui.Offset(x, y);
      return true;
    }

    if (!cursorModel.gotMouseControl) {
      bool selfGetControl =
          (x - lastMousePos.dx).abs() > kMouseControlDistance ||
          (y - lastMousePos.dy).abs() > kMouseControlDistance;
      if (selfGetControl) {
        cursorModel.gotMouseControl = true;
      } else {
        lastMousePos = ui.Offset(x, y);
        return true;
      }
    }
    lastMousePos = ui.Offset(x, y);
    return false;
  }

  Map<String, dynamic>? processEventToPeer(
    Map<String, dynamic> evt,
    Offset offset, {
    bool onExit = false,
    bool moveCanvas = true,
    bool edgeScroll = false,
  }) {
    if (isViewCamera) return null;
    double x = offset.dx;
    double y = max(0.0, offset.dy);
    if (_checkPeerControlProtected(x, y)) {
      return null;
    }

    var type = kMouseEventTypeDefault;
    var isMove = false;
    switch (evt['type']) {
      case _kMouseEventDown:
        type = kMouseEventTypeDown;
        break;
      case _kMouseEventUp:
        type = kMouseEventTypeUp;
        break;
      case _kMouseEventMove:
        _pointerMovedAfterEnter = true;
        isMove = true;
        break;
      default:
        return null;
    }
    evt['type'] = type;

    if (type == kMouseEventTypeDown && !_pointerMovedAfterEnter) {
      // Move mouse to the position of the down event first.
      lastMousePos = ui.Offset(x, y);
      refreshMousePos();
    }

    final pos = handlePointerDevicePos(
      kPointerEventKindMouse,
      x,
      y,
      isMove,
      type,
      onExit: onExit,
      buttons: evt['buttons'],
      moveCanvas: moveCanvas,
      edgeScroll: edgeScroll,
    );
    if (pos == null) {
      return null;
    }
    if (type != '') {
      evt['x'] = '0';
      evt['y'] = '0';
    } else {
      evt['x'] = '${pos.x.toInt()}';
      evt['y'] = '${pos.y.toInt()}';
    }

    final buttons = evt['buttons'];
    if (buttons is int) {
      evt['buttons'] = mouseButtonsToPeer(buttons);
    } else {
      // Log warning if buttons exists but is not an int (unexpected caller).
      // Keep empty string fallback for missing buttons to preserve move/hover behavior.
      if (buttons != null) {
        debugPrint(
          '[InputModel] processEventToPeer: unexpected buttons type: ${buttons.runtimeType}, value: $buttons',
        );
      }
      evt['buttons'] = '';
    }
    return evt;
  }

  Map<String, dynamic>? handleMouse(
    Map<String, dynamic> evt,
    Offset offset, {
    bool onExit = false,
    bool moveCanvas = true,
    bool edgeScroll = false,
  }) {
    final evtToPeer = processEventToPeer(
      evt,
      offset,
      onExit: onExit,
      moveCanvas: moveCanvas,
      edgeScroll: edgeScroll,
    );
    if (evtToPeer != null) {
      bind.sessionSendMouse(
        sessionId: sessionId,
        msg: json.encode(modify(evtToPeer)),
      );
    }
    return evtToPeer;
  }

  Point? handlePointerDevicePos(
    String kind,
    double x,
    double y,
    bool isMove,
    String evtType, {
    bool onExit = false,
    int buttons = kPrimaryMouseButton,
    bool moveCanvas = true,
    bool edgeScroll = false,
  }) {
    final ffiModel = parent.target!.ffiModel;
    CanvasCoords canvas = CanvasCoords.fromCanvasModel(
      parent.target!.canvasModel,
    );
    Rect? rect = ffiModel.rect;

    if (isMove) {
      if (_remoteWindowCoords.isNotEmpty &&
          _windowRect != null &&
          !_isInCurrentWindow(x, y)) {
        final coords = findRemoteCoords(
          x,
          y,
          _remoteWindowCoords,
          devicePixelRatio,
        );
        if (coords != null) {
          isMove = false;
          canvas = coords.canvas;
          rect = coords.remoteRect;
          x -= isWindows
              ? coords.relativeOffset.dx / devicePixelRatio
              : coords.relativeOffset.dx;
          y -= isWindows
              ? coords.relativeOffset.dy / devicePixelRatio
              : coords.relativeOffset.dy;
        }
      }
    }

    y -= CanvasModel.topToEdge;
    x -= CanvasModel.leftToEdge;
    final mobileView = ui.PlatformDispatcher.instance.implicitView;
    if (isMobileClient && mobileView != null) {
      x -= mobileView.padding.left / mobileView.devicePixelRatio;
      y -= mobileView.padding.top / mobileView.devicePixelRatio;
    }
    if (isMove) {
      final canvasModel = parent.target!.canvasModel;

      if (edgeScroll) {
        canvasModel.edgeScrollMouse(x, y);
      } else if (moveCanvas) {
        canvasModel.moveDesktopMouse(x, y);
      }

      canvasModel.updateLocalCursor(x, y);
    }

    return _handlePointerDevicePos(
      kind,
      x,
      y,
      isMove,
      canvas,
      rect,
      evtType,
      onExit: onExit,
      buttons: buttons,
    );
  }

  bool _isInCurrentWindow(double x, double y) {
    var w = _windowRect!.width;
    var h = _windowRect!.height;
    if (isWindows) {
      w /= devicePixelRatio;
      h /= devicePixelRatio;
    }
    return x >= 0 && y >= 0 && x <= w && y <= h;
  }

  static RemoteWindowCoords? findRemoteCoords(
    double x,
    double y,
    List<RemoteWindowCoords> remoteWindowCoords,
    double devicePixelRatio,
  ) {
    if (isWindows) {
      x *= devicePixelRatio;
      y *= devicePixelRatio;
    }
    for (final c in remoteWindowCoords) {
      if (x >= c.relativeOffset.dx &&
          y >= c.relativeOffset.dy &&
          x <= c.relativeOffset.dx + c.windowRect.width &&
          y <= c.relativeOffset.dy + c.windowRect.height) {
        return c;
      }
    }
    return null;
  }

  Point? _handlePointerDevicePos(
    String kind,
    double x,
    double y,
    bool moveInCanvas,
    CanvasCoords canvas,
    Rect? rect,
    String evtType, {
    bool onExit = false,
    int buttons = kPrimaryMouseButton,
  }) {
    if (rect == null) {
      return null;
    }

    final nearThr = 3;
    var nearRight = (canvas.size.width - x) < nearThr;
    var nearBottom = (canvas.size.height - y) < nearThr;
    final imageWidth = rect.width * canvas.scale;
    final imageHeight = rect.height * canvas.scale;
    if (isMobileClient) {
      final texturePosition = mobileRemoteTexturePositionFromViewport(
        viewportPosition: Offset(x, y),
        canvasOffset: Offset(canvas.x, canvas.y),
        scale: canvas.scale,
      );
      x = texturePosition.dx;
      y = texturePosition.dy;
    } else if (canvas.scrollStyle != ScrollStyle.scrollauto) {
      x += imageWidth * canvas.scrollX;
      y += imageHeight * canvas.scrollY;

      // boxed size is a center widget
      if (canvas.size.width > imageWidth) {
        x -= ((canvas.size.width - imageWidth) / 2);
      }
      if (canvas.size.height > imageHeight) {
        y -= ((canvas.size.height - imageHeight) / 2);
      }
      x /= canvas.scale;
      y /= canvas.scale;
    } else {
      x -= canvas.x;
      y -= canvas.y;
      x /= canvas.scale;
      y /= canvas.scale;
    }
    if (canvas.scale > 0 && canvas.scale < 1) {
      final step = 1.0 / canvas.scale - 1;
      if (nearRight) {
        x += step;
      }
      if (nearBottom) {
        y += step;
      }
    }
    x += rect.left;
    y += rect.top;

    if (onExit) {
      final pos = setNearestEdge(x, y, rect);
      x = pos.dx;
      y = pos.dy;
    }

    return InputModel.getPointInRemoteRect(
      true,
      peerPlatform,
      kind,
      evtType,
      x,
      y,
      rect,
      buttons: buttons,
    );
  }

  static Point<double>? getPointInRemoteRect(
    bool isLocalDesktop,
    String? peerPlatform,
    String kind,
    String evtType,
    double evtX,
    double evtY,
    Rect rect, {
    int buttons = kPrimaryMouseButton,
  }) {
    double minX = rect.left;
    // https://github.com/rustdesk/rustdesk/issues/6678
    // For Windows, [0,maxX], [0,maxY] should be set to enable window snapping.
    double maxX =
        (rect.left + rect.width) -
        (peerPlatform == kPeerPlatformWindows ? 0 : 1);
    double minY = rect.top;
    double maxY =
        (rect.top + rect.height) -
        (peerPlatform == kPeerPlatformWindows ? 0 : 1);
    evtX = InputModel.tryGetNearestRange(evtX, minX, maxX, 5);
    evtY = InputModel.tryGetNearestRange(evtY, minY, maxY, 5);
    if (isLocalDesktop) {
      if (kind == kPointerEventKindMouse) {
        if (evtX < minX || evtY < minY || evtX > maxX || evtY > maxY) {
          // If left mouse up, no early return.
          if (!(buttons == kPrimaryMouseButton &&
              evtType == kMouseEventTypeUp)) {
            return null;
          }
        }
      }
    } else {
      bool evtXInRange = evtX >= minX && evtX <= maxX;
      bool evtYInRange = evtY >= minY && evtY <= maxY;
      if (!(evtXInRange || evtYInRange)) {
        return null;
      }
      if (evtX < minX) {
        evtX = minX;
      } else if (evtX > maxX) {
        evtX = maxX;
      }
      if (evtY < minY) {
        evtY = minY;
      } else if (evtY > maxY) {
        evtY = maxY;
      }
    }

    return Point(evtX, evtY);
  }

  /// Web only
  void listenToMouse(bool yesOrNo) {
    if (yesOrNo) {
      platformFFI.startDesktopWebListener();
    } else {
      platformFFI.stopDesktopWebListener();
    }
  }

  void onMobileBack() {
    final minBackButtonVersion = "1.3.8";
    final peerVersion =
        parent.target?.ffiModel.pi.version ?? minBackButtonVersion;
    var btn = MouseButtons.back;
    // For compatibility with old versions
    if (versionCmp(peerVersion, minBackButtonVersion) < 0) {
      btn = MouseButtons.right;
    }
    tap(btn);
  }

  void onMobileHome() => tap(MouseButtons.wheel);
  Future<void> onMobileApps() async {
    sendMouse('down', MouseButtons.wheel);
    await Future.delayed(const Duration(milliseconds: 500));
    sendMouse('up', MouseButtons.wheel);
  }

  // Simulate a key press event.
  // `usbHidUsage` is the USB HID usage code of the key.
  Future<void> tapHidKey(int usbHidUsage) async {
    final down = _toolbarKeyboardNormalizer.hidEvent(
      usbHidUsage,
      action: KeyboardIntentAction.down,
    );
    final up = _toolbarKeyboardNormalizer.hidEvent(
      usbHidUsage,
      action: KeyboardIntentAction.up,
    );
    if (down == null || up == null) return;
    _keyboardInput.handle(down, _keyboardRoutingContext);
    await Future.delayed(Duration(milliseconds: 100));
    _keyboardInput.handle(up, _keyboardRoutingContext);
    await keyboardDispatchIdle;
  }

  Future<void> onMobileVolumeUp() async =>
      await tapHidKey(PhysicalKeyboardKey.audioVolumeUp.usbHidUsage);
  Future<void> onMobileVolumeDown() async =>
      await tapHidKey(PhysicalKeyboardKey.audioVolumeDown.usbHidUsage);
  Future<void> onMobilePower() async =>
      await tapHidKey(PhysicalKeyboardKey.power.usbHidUsage);
}
