import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:flutter_hbb/common/widgets/edge_thickness_control.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/widgets/floating_mouse.dart';
import 'package:flutter_hbb/mobile/widgets/floating_mouse_widgets.dart';
import 'package:flutter_hbb/mobile/widgets/gesture_help.dart';
import 'package:flutter_hbb/mobile/widgets/remote_session_controls.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../common/widgets/overlay.dart';
import '../../common/widgets/dialog.dart';
import '../../common/widgets/remote_input.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../utils/image.dart';
import '../android_vpn_controller.dart';
import '../mobile_modifier_state.dart';
import '../mobile_viewport.dart';
import '../widgets/custom_image_quality_widget.dart';
import '../widgets/dialog.dart';

final initText = '1' * 1024;

MobileRemoteToolbarTransparencySettings
_toolbarTransparencySettingsFromUserDefaults() {
  return MobileRemoteToolbarTransparencySettings.fromStored(
    overlapOpacityPercent: bind.mainGetUserDefaultOption(
      key: kOptionMobileRemoteToolbarOverlapOpacityPercent,
    ),
  );
}

MobileCursorInertiaSettings _cursorInertiaSettingsFromUserDefaults() {
  return MobileCursorInertiaSettings.fromStored(
    bind.mainGetUserDefaultOption(key: kOptionMobileCursorInertiaDurationMs),
  );
}

MobileRemoteToolbarPlacementSettings _toolbarPlacementFromLocalOption() {
  return MobileRemoteToolbarPlacementSettings.fromStored(
    bind.mainGetLocalOption(key: kOptionMobileRemoteToolbarPlacement),
  );
}

bool _showMonitorsInMobileToolbarFromUserDefaults() =>
    bind.mainGetUserDefaultOption(key: kKeyShowMonitorsToolbar) == 'Y';

// Workaround for Android (default input method, Microsoft SwiftKey keyboard) when using physical keyboard.
// When connecting a physical keyboard, `KeyEvent.physicalKey.usbHidUsage` are wrong is using Microsoft SwiftKey keyboard.
// https://github.com/flutter/flutter/issues/159384
// https://github.com/flutter/flutter/issues/159383
void _disableAndroidSoftKeyboard({bool? isKeyboardVisible}) {
  if (isAndroid) {
    if (isKeyboardVisible != true) {
      // `enable_soft_keyboard` will be set to `true` when clicking the keyboard icon, in `openKeyboard()`.
      gFFI.invokeMethod("enable_soft_keyboard", false);
    }
  }
}

class RemotePage extends StatefulWidget {
  RemotePage({
    Key? key,
    required this.id,
    this.password,
    this.isSharedPassword,
    this.forceRelay,
  }) : super(key: key);

  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;

  @override
  State<RemotePage> createState() => _RemotePageState(id);
}

class _RemotePageState extends State<RemotePage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  Timer? _timer;
  bool _showGestureHelp = false;
  String _value = '';
  Orientation? _currentOrientation;
  final _uniqueKey = UniqueKey();
  Timer? _iosKeyboardWorkaroundTimer;
  StreamSubscription<AndroidOutgoingSessionClosedEvent>?
  _outgoingSessionClosedSubscription;
  bool _backgroundReconnectPending = false;
  bool _backgroundReconnectInProgress = false;
  bool _manualDisconnect = false;
  Future<void>? _backgroundCloseFuture;

  final _blockableOverlayState = BlockableOverlayState();

  final keyboardVisibilityController = KeyboardVisibilityController();
  late final StreamSubscription<bool> keyboardSubscription;
  final FocusNode _mobileFocusNode = FocusNode();
  final FocusNode _physicalFocusNode = FocusNode();
  final GlobalKey _mobileRemoteInputRegionKey = GlobalKey();
  var _showEdit = false; // use soft keyboard
  var _showCustomButtonEditor = false;
  var _toolbarTransparencySettings =
      MobileRemoteToolbarTransparencySettings.defaults;
  var _toolbarPlacementSettings = MobileRemoteToolbarPlacementSettings.defaults;
  var _cursorInertiaSettings = MobileCursorInertiaSettings.defaults;
  var _showMonitorsInToolbar = false;
  var _physicalKeyInput = true;
  var _quickKeyOrder = List<MobileRemoteQuickKey>.of(
    mobileRemoteDefaultQuickKeyOrder,
  );

  InputModel get inputModel => gFFI.inputModel;
  SessionID get sessionId => gFFI.sessionId;

  final TextEditingController _textController = TextEditingController(
    text: initText,
  );

  _RemotePageState(String id) {
    initSharedStates(id);
    gFFI.chatModel.voiceCallStatus.value = VoiceCallStatus.notStarted;
    gFFI.dialogManager.loadMobileActionsOverlayVisible();
  }

  @override
  void initState() {
    super.initState();
    _toolbarTransparencySettings =
        _toolbarTransparencySettingsFromUserDefaults();
    _toolbarPlacementSettings = _toolbarPlacementFromLocalOption();
    _cursorInertiaSettings = _cursorInertiaSettingsFromUserDefaults();
    _showMonitorsInToolbar = _showMonitorsInMobileToolbarFromUserDefaults();
    gFFI.canvasModel.initializeEdgeScrollFallback(this);
    gFFI.ffiModel.updateEventListener(sessionId, widget.id);
    if (isAndroid) {
      _outgoingSessionClosedSubscription = AndroidVpnSessionCoordinator
          .instance
          .sessionClosedEvents
          .listen(_handleOutgoingSessionClosed);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      gFFI.dialogManager.showLoading(
        translate('Connecting...'),
        onCancel: closeConnection,
      );
      unawaited(_startConnection());
    });
    WakelockManager.enable(_uniqueKey);
    _physicalFocusNode.requestFocus();
    gFFI.inputModel.listenToMouse(true);
    keyboardSubscription = keyboardVisibilityController.onChange.listen(
      onSoftKeyboardChanged,
    );
    gFFI.chatModel.changeCurrentKey(
      MessageKey(widget.id, ChatModel.clientModeID),
    );
    _blockableOverlayState.applyFfi(gFFI);
    gFFI.imageModel.addCallbackOnFirstImage((String peerId) {
      gFFI.recordingModel.updateStatus(
        bind.sessionGetIsRecording(sessionId: gFFI.sessionId),
      );
      if (gFFI.recordingModel.start) {
        showToast(translate('Automatically record outgoing sessions'));
      }
      _disableAndroidSoftKeyboard(
        isKeyboardVisible: keyboardVisibilityController.isVisible,
      );
    });
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _startConnection() async {
    try {
      await _connectCurrentSession();
    } catch (e, stackTrace) {
      debugPrint('Failed to start mobile session: $e\n$stackTrace');
      if (!mounted) return;
      gFFI.dialogManager.dismissAll();
      showToast(translate('Failed to connect'));
      closeConnection();
    }
  }

  Future<void> _connectCurrentSession() async {
    await gFFI.start(
      widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
    );
    if (!mounted || gFFI.closed) return;
    await _refreshMobileInputSettings();
    unawaited(gFFI.qualityMonitorModel.checkShowQualityMonitor(sessionId));
  }

  void _handleOutgoingSessionClosed(AndroidOutgoingSessionClosedEvent event) {
    if (_manualDisconnect || !mounted) return;
    if (event.reason == 'notification-disconnect') {
      _manualDisconnect = true;
      closeConnection();
      return;
    }
    if (event.reason != 'background-timeout' &&
        event.reason != 'background-native-disconnect' &&
        event.reason != 'foreground-unhealthy' &&
        event.reason != 'foreground-service-timeout') {
      return;
    }
    _backgroundReconnectPending = true;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      unawaited(_restartAfterBackground());
    }
  }

  Future<void> _restartAfterBackground() async {
    if (!mounted ||
        _manualDisconnect ||
        !_backgroundReconnectPending ||
        _backgroundReconnectInProgress) {
      return;
    }
    _backgroundReconnectInProgress = true;
    _backgroundReconnectPending = false;
    gFFI.dialogManager.dismissAll();
    gFFI.dialogManager.showLoading(
      translate('Reconnecting...'),
      onCancel: _requestDisconnect,
    );
    try {
      final backgroundClose = _backgroundCloseFuture;
      if (backgroundClose != null) await backgroundClose;
      await gFFI.resetMobileSessionForReconnect(closeSession: false);
      if (isAndroid && widget.forceRelay != true) {
        final coordinator = AndroidVpnSessionCoordinator.instance;
        if (await coordinator.isEnabled(widget.id)) {
          final prepared = await coordinator.prepare(widget.id);
          if (!prepared.proceed) {
            throw StateError(prepared.message);
          }
        }
      }
      await _connectCurrentSession();
    } catch (error, stackTrace) {
      debugPrint(
        'Failed to reconnect mobile background session: '
        '$error\n$stackTrace',
      );
      if (mounted) {
        gFFI.dialogManager.dismissAll();
        showToast(translate('Failed to reconnect'));
        closeConnection();
      }
    } finally {
      _backgroundReconnectInProgress = false;
    }
  }

  Future<void> _closeIosSessionForBackground() async {
    if (!isIOS ||
        _manualDisconnect ||
        _backgroundReconnectPending ||
        gFFI.closed) {
      return;
    }
    _backgroundReconnectPending = true;
    final closeFuture = gFFI.resetMobileSessionForReconnect(closeSession: true);
    _backgroundCloseFuture = closeFuture;
    try {
      await closeFuture;
    } finally {
      if (identical(_backgroundCloseFuture, closeFuture)) {
        _backgroundCloseFuture = null;
      }
    }
  }

  void _requestDisconnect() {
    clientClose(sessionId, gFFI);
  }

  Future<void> _refreshMobileInputSettings() async {
    final toolbarDefaults = _toolbarTransparencySettingsFromUserDefaults();
    final inertiaDefaults = _cursorInertiaSettingsFromUserDefaults();
    try {
      final stored = await Future.wait([
        bind.sessionGetPeerOption(
          sessionId: sessionId,
          name: kOptionMobileRemoteToolbarOverlapOpacityPercent,
        ),
        bind.sessionGetPeerOption(
          sessionId: sessionId,
          name: kOptionMobileCursorInertiaDurationMs,
        ),
        bind.sessionGetPeerOption(
          sessionId: sessionId,
          name: kOptionMobilePhysicalKeyInput,
        ),
      ]);
      final toolbarSettings =
          MobileRemoteToolbarTransparencySettings.fromStored(
            overlapOpacityPercent: stored[0].isEmpty
                ? toolbarDefaults.overlapOpacityPercent.toString()
                : stored[0],
            fallback: toolbarDefaults,
          );
      final inertiaSettings = MobileCursorInertiaSettings.fromStored(
        stored[1].isEmpty ? inertiaDefaults.durationMs.toString() : stored[1],
        fallback: inertiaDefaults,
      );
      final physicalKeyInput = mobileVmPhysicalInputEnabled(stored[2]);
      if (mounted &&
          (toolbarSettings != _toolbarTransparencySettings ||
              inertiaSettings != _cursorInertiaSettings ||
              physicalKeyInput != _physicalKeyInput)) {
        setState(() {
          _toolbarTransparencySettings = toolbarSettings;
          _cursorInertiaSettings = inertiaSettings;
          _physicalKeyInput = physicalKeyInput;
        });
      }
    } catch (error) {
      debugPrint('Failed to load mobile input settings: $error');
    }
  }

  @override
  Future<void> dispose() async {
    _manualDisconnect = true;
    WidgetsBinding.instance.removeObserver(this);
    await _outgoingSessionClosedSubscription?.cancel();
    gFFI.canvasModel.disposeEdgeScrollFallback();
    unawaited(bind.sessionClose(sessionId: gFFI.sessionId));
    // https://github.com/flutter/flutter/issues/64935
    super.dispose();
    gFFI.dialogManager.hideMobileActionsOverlay(store: false);
    gFFI.inputModel.listenToMouse(false);
    gFFI.imageModel.disposeImage();
    gFFI.cursorModel.disposeImages();
    await gFFI.invokeMethod("enable_soft_keyboard", true);
    _mobileFocusNode.dispose();
    _physicalFocusNode.dispose();
    await gFFI.close();
    _timer?.cancel();
    _iosKeyboardWorkaroundTimer?.cancel();
    gFFI.dialogManager.dismissAll();
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    WakelockManager.disable(_uniqueKey);
    await keyboardSubscription.cancel();
    removeSharedStates(widget.id);
    // `on_voice_call_closed` should be called when the connection is ended.
    // The inner logic of `on_voice_call_closed` will check if the voice call is active.
    // Only one client is considered here for now.
    gFFI.chatModel.onVoiceCallClosed("End connetion");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      trySyncClipboard();
      if (_backgroundReconnectPending) {
        unawaited(_restartAfterBackground());
      }
    } else if (state == AppLifecycleState.paused && isIOS) {
      unawaited(_closeIosSessionForBackground());
    }
  }

  // For client side
  // When swithing from other app to this app, try to sync clipboard.
  void trySyncClipboard() {
    gFFI.invokeMethod("try_sync_clipboard");
  }

  // to-do: It should be better to use transparent color instead of the bgColor.
  // But for now, the transparent color will cause the canvas to be white.
  // I'm sure that the white color is caused by the Overlay widget in BlockableOverlay.
  // But I don't know why and how to fix it.
  Widget emptyOverlay(Color bgColor) => BlockableOverlay(
    /// the Overlay key will be set with _blockableOverlayState in BlockableOverlay
    /// see override build() in [BlockableOverlay]
    state: _blockableOverlayState,
    underlying: Container(color: bgColor),
  );

  void onSoftKeyboardChanged(bool visible) {
    if (gFFI.dialogManager.hasOpenDialogs) {
      _timer?.cancel();
      _iosKeyboardWorkaroundTimer?.cancel();
      _iosKeyboardWorkaroundTimer = null;
      return;
    }

    if (!visible) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      // [pi.version.isNotEmpty] -> check ready or not, avoid login without soft-keyboard
      if (gFFI.chatModel.chatWindowOverlayEntry == null &&
          gFFI.ffiModel.pi.version.isNotEmpty) {
        gFFI.invokeMethod("enable_soft_keyboard", false);
      }

      // Workaround for iOS: physical keyboard input fails after virtual keyboard is hidden
      // https://github.com/flutter/flutter/issues/39900
      // https://github.com/rustdesk/rustdesk/discussions/11843#discussioncomment-13499698 - Virtual keyboard issue
      if (isIOS) {
        _iosKeyboardWorkaroundTimer?.cancel();
        _iosKeyboardWorkaroundTimer = Timer(Duration(milliseconds: 100), () {
          if (!mounted) return;
          _physicalFocusNode.unfocus();
          _iosKeyboardWorkaroundTimer = Timer(Duration(milliseconds: 50), () {
            if (!mounted) return;
            _physicalFocusNode.requestFocus();
          });
        });
      }
    } else {
      _iosKeyboardWorkaroundTimer?.cancel();
      _iosKeyboardWorkaroundTimer = null;
      _timer?.cancel();
      _timer = Timer(kMobileDelaySoftKeyboardFocus, () {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
        _requestMobileSoftKeyboard();
      });
    }
    // update for Scaffold
    setState(() {});
  }

  void _handleIOSSoftKeyboardInput(String newValue) {
    var oldValue = _value;
    _value = newValue;
    var i = newValue.length - 1;
    for (; i >= 0 && newValue[i] != '1'; --i) {}
    var j = oldValue.length - 1;
    for (; j >= 0 && oldValue[j] != '1'; --j) {}
    if (i < j) j = i;
    var subNewValue = newValue.substring(j + 1);
    var subOldValue = oldValue.substring(j + 1);

    // get common prefix of subNewValue and subOldValue
    var common = 0;
    for (
      ;
      common < subOldValue.length &&
          common < subNewValue.length &&
          subNewValue[common] == subOldValue[common];
      ++common
    ) {}

    // get newStr from subNewValue
    var newStr = "";
    if (subNewValue.length > common) {
      newStr = subNewValue.substring(common);
    }

    // Set the value to the old value and early return if is still composing. (1 && 2)
    // 1. The composing range is valid
    // 2. The new string is shorter than the composing range.
    if (_textController.value.isComposingRangeValid) {
      final composingLength =
          _textController.value.composing.end -
          _textController.value.composing.start;
      if (composingLength > newStr.length) {
        _value = oldValue;
        return;
      }
    }

    // Delete the different part in the old value.
    for (i = 0; i < subOldValue.length - common; ++i) {
      inputModel.inputKey('VK_BACK');
    }

    // Input the new string.
    if (newStr.length > 1) {
      _inputMobileString(newStr);
    } else {
      inputChar(newStr);
    }
  }

  void _handleNonIOSSoftKeyboardInput(String newValue) {
    var oldValue = _value;
    _value = newValue;
    if (oldValue.isNotEmpty &&
        newValue.isNotEmpty &&
        oldValue[0] == '1' &&
        newValue[0] != '1') {
      // clipboard
      oldValue = '';
    }
    if (newValue.length == oldValue.length) {
      // ?
    } else if (newValue.length < oldValue.length) {
      final char = 'VK_BACK';
      inputModel.inputKey(char);
    } else {
      final content = newValue.substring(oldValue.length);
      if (content.length > 1) {
        if (oldValue != '' &&
            content.length == 2 &&
            (content == '""' ||
                content == '()' ||
                content == '[]' ||
                content == '<>' ||
                content == "{}" ||
                content == '”“' ||
                content == '《》' ||
                content == '（）' ||
                content == '【】')) {
          // can not only input content[0], because when input ], [ are also auo insert, which cause ] never be input
          _inputMobileString(content);
          openKeyboard();
          return;
        }
        _inputMobileString(content);
      } else {
        inputChar(content);
      }
    }
  }

  // handle mobile virtual keyboard
  void handleSoftKeyboardInput(String newValue) {
    if (isIOS) {
      _handleIOSSoftKeyboardInput(newValue);
    } else {
      _handleNonIOSSoftKeyboardInput(newValue);
    }
  }

  void inputChar(String char) {
    if (char == '\n') {
      char = 'VK_RETURN';
    } else if (_physicalKeyInput &&
        char.length == 1 &&
        !inputModel.ctrl &&
        !inputModel.alt &&
        !inputModel.shift &&
        !inputModel.command) {
      _inputMobileString(char);
      return;
    } else if (char == ' ') {
      char = 'VK_SPACE';
    }
    inputModel.inputKey(char);
  }

  void _inputMobileString(String value) {
    bind.sessionInputString(sessionId: sessionId, value: value);
    inputModel.consumeMobileOneShotModifiers();
  }

  void _requestMobileSoftKeyboard() {
    if (!mounted || !_showEdit) return;
    _mobileFocusNode.requestFocus();
    if (!isIOS) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_showEdit || !_mobileFocusNode.hasFocus) return;
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    });
  }

  void openKeyboard() {
    gFFI.invokeMethod("enable_soft_keyboard", true);
    // destroy first, so that our _value trick can work
    _value = initText;
    _textController.text = _value;
    setState(() => _showEdit = false);
    _timer?.cancel();
    _timer = Timer(kMobileDelaySoftKeyboard, () {
      // show now, and sleep a while to requestFocus to
      // make sure edit ready, so that keyboard won't show/hide/show/hide happen
      setState(() => _showEdit = true);
      _timer?.cancel();
      _timer = Timer(kMobileDelaySoftKeyboardFocus, () {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
        _requestMobileSoftKeyboard();
      });
    });
  }

  Widget _bottomWidget() =>
      _showGestureHelp ? getGestureHelp() : const Offstage();

  @override
  Widget build(BuildContext context) {
    final keyboardIsVisible =
        keyboardVisibilityController.isVisible && _showEdit;
    final showActionButton = keyboardIsVisible || _showGestureHelp;

    return WillPopScope(
      onWillPop: () async {
        _requestDisconnect();
        return false;
      },
      child: Scaffold(
        // workaround for https://github.com/rustdesk/rustdesk/issues/3131
        floatingActionButtonLocation: keyboardIsVisible
            ? FABLocation(FloatingActionButtonLocation.endFloat, 0, -35)
            : null,
        floatingActionButton: !showActionButton
            ? null
            : FloatingActionButton(
                mini: !keyboardIsVisible,
                child: Icon(Icons.expand_more, color: Colors.white),
                backgroundColor: MyTheme.accent,
                onPressed: () {
                  setState(() {
                    if (keyboardIsVisible) {
                      _showEdit = false;
                      gFFI.invokeMethod("enable_soft_keyboard", false);
                      _mobileFocusNode.unfocus();
                      _physicalFocusNode.requestFocus();
                    } else if (_showGestureHelp) {
                      _showGestureHelp = false;
                    }
                  });
                },
              ),
        bottomNavigationBar: Obx(
          () => Stack(
            alignment: Alignment.bottomCenter,
            children: [
              gFFI.ffiModel.pi.isSet.isTrue &&
                      gFFI.ffiModel.waitForFirstImage.isTrue
                  ? emptyOverlay(MyTheme.canvasColor)
                  : () {
                      gFFI.ffiModel.tryShowAndroidActionsOverlay();
                      return Offstage();
                    }(),
              _bottomWidget(),
              gFFI.ffiModel.pi.isSet.isFalse
                  ? emptyOverlay(MyTheme.canvasColor)
                  : Offstage(),
            ],
          ),
        ),
        body: Obx(
          () => Stack(
            children: [
              Positioned.fill(
                child: getRawPointerAndKeyBody(
                  Overlay(
                    initialEntries: [
                      OverlayEntry(
                        builder: (context) {
                          return Container(
                            color: kColorCanvas,
                            child: isWebDesktop
                                ? getBodyForDesktopWithListener()
                                : SafeArea(
                                    child: OrientationBuilder(
                                      builder: (ctx, orientation) {
                                        if (_currentOrientation !=
                                            orientation) {
                                          Timer(
                                            const Duration(milliseconds: 200),
                                            () {
                                              gFFI.dialogManager
                                                  .resetMobileActionsOverlay(
                                                    ffi: gFFI,
                                                  );
                                              _currentOrientation = orientation;
                                              gFFI.canvasModel
                                                  .updateViewStyle();
                                            },
                                          );
                                        }
                                        final inputBody = Container(
                                          color: MyTheme.canvasColor,
                                          child: getBodyForMobile(),
                                        );
                                        return KeyedSubtree(
                                          key: _mobileRemoteInputRegionKey,
                                          child:
                                              inputModel.isPhysicalMouse.value
                                              ? inputBody
                                              : RawTouchGestureDetectorRegion(
                                                  child: inputBody,
                                                  ffi: gFFI,
                                                  cursorInertiaDurationMs:
                                                      _cursorInertiaSettings
                                                          .durationMs,
                                                ),
                                        );
                                      },
                                    ),
                                  ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              if (!isWebDesktop)
                SafeArea(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: KeyHelpTools(
                      keyboardIsVisible: keyboardIsVisible,
                      showGestureHelp: _showGestureHelp,
                      quickKeyOrder: _quickKeyOrder,
                      remoteInputRegionKey: _mobileRemoteInputRegionKey,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget getRawPointerAndKeyBody(Widget child) {
    final ffiModel = Provider.of<FfiModel>(context);
    return RawPointerMouseRegion(
      cursor: ffiModel.keyboard ? SystemMouseCursors.none : MouseCursor.defer,
      inputModel: inputModel,
      // Disable RawKeyFocusScope before the connecting is established.
      // The "Delete" key on the soft keyboard may be grabbed when inputting the password dialog.
      child: gFFI.ffiModel.pi.isSet.isTrue
          ? RawKeyFocusScope(
              focusNode: _physicalFocusNode,
              inputModel: inputModel,
              child: child,
            )
          : child,
    );
  }

  Future<void> _toggleQualityMonitor() async {
    await bind.sessionToggleOption(
      sessionId: sessionId,
      value: 'show-quality-monitor',
    );
    await gFFI.qualityMonitorModel.checkShowQualityMonitor(sessionId);
  }

  Widget getFloatingToolbar() {
    final ffiModel = Provider.of<FfiModel>(context);
    final cursorModel = Provider.of<CursorModel>(context);
    final chatButton = isWeb
        ? null
        : futureBuilder(
            future: gFFI.invokeMethod("get_value", "KEY_IS_SUPPORT_VOICE_CALL"),
            hasData: (isSupportVoiceCall) => IconButton(
              tooltip: translate('Chat'),
              color: mobileRemoteToolbarForegroundColor(context),
              icon: isAndroid && isSupportVoiceCall
                  ? SvgPicture.asset(
                      'assets/chat.svg',
                      colorFilter: ColorFilter.mode(
                        mobileRemoteToolbarForegroundColor(context),
                        BlendMode.srcIn,
                      ),
                    )
                  : Icon(Icons.message),
              onPressed: () => isAndroid && isSupportVoiceCall
                  ? showChatOptions(widget.id)
                  : onPressedTextChat(widget.id),
            ),
          );
    return ListenableBuilder(
      listenable: gFFI.qualityMonitorModel.showListenable,
      builder: (context, _) => Obx(() {
        final pi = ffiModel.pi;
        final currentDisplay = CurrentDisplayState.find(widget.id).value;
        final monitors = !_showMonitorsInToolbar || pi.displays.length <= 1
            ? const <MobileRemoteToolbarMonitor>[]
            : <MobileRemoteToolbarMonitor>[
                for (var index = 0; index < pi.displays.length; index++)
                  MobileRemoteToolbarMonitor(
                    value: index,
                    label: '${index + 1}',
                    tooltip: '#${index + 1} ${translate('Monitor')}',
                    selected: currentDisplay == index,
                    onPressed: () {
                      if (currentDisplay != index) {
                        openMonitorInTheSameTab(index, gFFI, pi);
                      }
                    },
                  ),
                if (!isWeb && pi.isSupportMultiDisplay)
                  MobileRemoteToolbarMonitor(
                    value: kAllDisplayValue,
                    label: translate('All'),
                    tooltip: translate('all monitors'),
                    selected: currentDisplay == kAllDisplayValue,
                    allDisplays: true,
                    onPressed: () {
                      if (currentDisplay != kAllDisplayValue) {
                        openMonitorInTheSameTab(kAllDisplayValue, gFFI, pi);
                      }
                    },
                  ),
              ];
        return MobileRemoteToolbar(
          onDisconnect: _requestDisconnect,
          onOptions: () {
            setState(() => _showEdit = false);
            showOptions(
              context,
              widget.id,
              gFFI.dialogManager,
              toolbarTransparencySettings: _toolbarTransparencySettings,
              onToolbarTransparencySettingsChanged: (settings) {
                if (mounted) {
                  setState(() => _toolbarTransparencySettings = settings);
                }
              },
              showMonitorsInToolbar: _showMonitorsInToolbar,
              onShowMonitorsInToolbarChanged: (value) {
                if (mounted) {
                  setState(() => _showMonitorsInToolbar = value);
                }
              },
              cursorInertiaSettings: _cursorInertiaSettings,
              onCursorInertiaSettingsChanged: (settings) {
                if (mounted) {
                  setState(() => _cursorInertiaSettings = settings);
                }
              },
            );
          },
          onKeyboard: openKeyboard,
          onMobileActions: () =>
              gFFI.dialogManager.toggleMobileActionsOverlay(ffi: gFFI),
          onGestureHelp: () =>
              setState(() => _showGestureHelp = !_showGestureHelp),
          onMore: () {
            setState(() => _showEdit = false);
            showActions(widget.id);
          },
          showInputControls:
              !isWebDesktop && !ffiModel.viewOnly && ffiModel.keyboard,
          peerIsAndroid: ffiModel.isPeerAndroid,
          touchMode: ffiModel.touchMode,
          waitForFirstImage: ffiModel.waitForFirstImage.isTrue,
          qualityMonitorVisible: gFFI.qualityMonitorModel.showListenable.value,
          onQualityMonitor: () => unawaited(_toggleQualityMonitor()),
          qualityMonitorTooltip: translate('Quality monitor'),
          chatButton: chatButton,
          monitors: monitors,
          cursorPosition:
              cursorModel.mobileViewportPosition - const Offset(8, 8),
          transparencySettings: _toolbarTransparencySettings,
          placementSettings: _toolbarPlacementSettings,
          onPlacementChanged: (settings) {
            if (mounted) {
              setState(() => _toolbarPlacementSettings = settings);
            }
            unawaited(
              bind.mainSetLocalOption(
                key: kOptionMobileRemoteToolbarPlacement,
                value: settings.storedValue,
              ),
            );
          },
        );
      }),
    );
  }

  bool get showCursorPaint =>
      !gFFI.ffiModel.isPeerAndroid &&
      !gFFI.canvasModel.cursorEmbedded &&
      !gFFI.inputModel.relativeMouseMode.value;

  Widget getBodyForMobile() {
    final keyboardIsVisible = keyboardVisibilityController.isVisible;
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
        final factor = math.exp(-event.scrollDelta.dy / 200);
        gFFI.canvasModel.updateScale(factor, event.localPosition);
      },
      child: Container(
        color: MyTheme.canvasColor,
        child: Stack(
          children: () {
            final paints = [
              const ImagePaint(),
              PositionedQualityMonitor(
                qualityMonitorModel: gFFI.qualityMonitorModel,
              ),
              SizedBox(
                width: 0,
                height: 0,
                child: !_showEdit
                    ? Container()
                    : TextFormField(
                        textInputAction: TextInputAction.newline,
                        autocorrect: false,
                        // Flutter 3.16.9 Android.
                        // `enableSuggestions` causes secure keyboard to be shown.
                        // https://github.com/flutter/flutter/issues/139143
                        // https://github.com/flutter/flutter/issues/146540
                        // enableSuggestions: false,
                        autofocus: true,
                        focusNode: _mobileFocusNode,
                        maxLines: null,
                        controller: _textController,
                        // trick way to make backspace work always
                        keyboardType: TextInputType.multiline,
                        // `onChanged` may be called depending on the input method if this widget is wrapped in
                        // `Focus(onKeyEvent: ..., child: ...)`
                        // For `Backspace` button in the soft keyboard:
                        // en/fr input method:
                        //      1. The button will not trigger `onKeyEvent` if the text field is not empty.
                        //      2. The button will trigger `onKeyEvent` if the text field is empty.
                        // ko/zh/ja input method: the button will trigger `onKeyEvent`
                        //                     and the event will not popup if `KeyEventResult.handled` is returned.
                        onChanged: handleSoftKeyboardInput,
                      ).workaroundFreezeLinuxMint(),
              ),
            ];
            if (showCursorPaint) {
              paints.add(mobileRemoteCursorOverlay(widget.id));
            }
            if (gFFI.ffiModel.touchMode) {
              paints.add(FloatingMouse(ffi: gFFI));
            } else {
              paints.add(FloatingMouseWidgets(ffi: gFFI));
            }
            if (gFFI.ffiModel.pi.displays.isNotEmpty) {
              paints.add(
                Positioned.fill(
                  child: Visibility(
                    visible: !keyboardIsVisible,
                    maintainState: true,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: getFloatingToolbar(),
                    ),
                  ),
                ),
              );
            }
            if (_showCustomButtonEditor) {
              paints.add(
                Positioned.fill(child: _buildCustomButtonEditor(context)),
              );
            }
            return paints;
          }(),
        ),
      ),
    );
  }

  Widget getBodyForDesktopWithListener() {
    final ffiModel = Provider.of<FfiModel>(context);
    var paints = <Widget>[const ImagePaint()];
    if (showCursorPaint) {
      final cursor = bind.sessionGetToggleOptionSync(
        sessionId: sessionId,
        arg: 'show-remote-cursor',
      );
      if (ffiModel.keyboard || cursor) {
        paints.add(mobileRemoteCursorOverlay(widget.id));
      }
    }
    return Container(
      color: MyTheme.canvasColor,
      child: Stack(children: paints),
    );
  }

  List<TTextMenu> _getMobileActionMenus() {
    if (gFFI.ffiModel.pi.platform != kPeerPlatformAndroid ||
        !gFFI.ffiModel.keyboard) {
      return [];
    }
    final enabled = versionCmp(gFFI.ffiModel.pi.version, '1.2.7') >= 0;
    if (!enabled) return [];
    return [
      TTextMenu(
        child: Text(translate('Back')),
        onPressed: () => gFFI.inputModel.onMobileBack(),
      ),
      TTextMenu(
        child: Text(translate('Home')),
        onPressed: () => gFFI.inputModel.onMobileHome(),
      ),
      TTextMenu(
        child: Text(translate('Apps')),
        onPressed: () => gFFI.inputModel.onMobileApps(),
      ),
      TTextMenu(
        child: Text(translate('Volume up')),
        onPressed: () => gFFI.inputModel.onMobileVolumeUp(),
      ),
      TTextMenu(
        child: Text(translate('Volume down')),
        onPressed: () => gFFI.inputModel.onMobileVolumeDown(),
      ),
      TTextMenu(
        child: Text(translate('Power')),
        onPressed: () => gFFI.inputModel.onMobilePower(),
      ),
    ];
  }

  void showActions(String id) async {
    final mobileActionMenus = _getMobileActionMenus();
    final menus = toolbarControls(context, id, gFFI);
    final keyboardToggles = toolbarKeyboardToggles(gFFI);
    final currentKeyboardMode =
        await bind.sessionGetKeyboardMode(sessionId: gFFI.sessionId) ??
        kKeyLegacyMode;
    final physicalKeyInput = mobileVmPhysicalInputEnabled(
      await bind.sessionGetPeerOption(
        sessionId: gFFI.sessionId,
        name: kOptionMobilePhysicalKeyInput,
      ),
    );
    final physicalKeyInputSupported =
        gFFI.ffiModel.pi.platform == kPeerPlatformWindows &&
        bind.sessionIsKeyboardModeSupported(
          sessionId: gFFI.sessionId,
          mode: kKeyTranslateMode,
        );
    const keyboardModeLabels = <String, String>{
      kKeyLegacyMode: 'Legacy mode',
      kKeyMapMode: 'Map mode',
      kKeyTranslateMode: 'Translate mode',
    };
    final keyboardModes = <MobileRemoteRadioItem>[
      for (final entry in keyboardModeLabels.entries)
        if ((gFFI.ffiModel.isPeerAndroid
            ? entry.key == kKeyLegacyMode
            : bind.sessionIsKeyboardModeSupported(
                sessionId: gFFI.sessionId,
                mode: entry.key,
              )))
          MobileRemoteRadioItem(
            value: entry.key,
            child: Text(
              translate(entry.value) +
                  (entry.key == kKeyTranslateMode ? ' beta' : ''),
            ),
            onChanged: gFFI.ffiModel.viewOnly
                ? null
                : (value) async {
                    if (value == null) return;
                    await bind.sessionSetKeyboardMode(
                      sessionId: gFFI.sessionId,
                      value: value,
                    );
                    await gFFI.inputModel.updateKeyboardMode();
                  },
          ),
    ];
    if (!mounted) return;
    gFFI.dialogManager
        .show(
          (setDialogState, close, dialogContext) {
            MobileRemoteActionItem actionItem(TTextMenu menu) =>
                MobileRemoteActionItem(
                  child: menu.getChild(),
                  onPressed: menu.onPressed == null
                      ? null
                      : () {
                          close();
                          Future<void>.delayed(Duration.zero, menu.onPressed!);
                        },
                );

            return CustomAlertDialog(
              contentBoxConstraints: BoxConstraints(
                maxWidth: 500,
                maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.9,
              ),
              content: MobileRemoteActionsContent(
                primarySections: [
                  if (gFFI.ffiModel.keyboard)
                    MobileRemoteActionSection(
                      id: 'keyboard',
                      title: Text(translate('Keyboard Settings')),
                      content: MobileRemoteKeyboardSettingsContent(
                        mode: currentKeyboardMode,
                        modes: keyboardModes,
                        modeHeading: translate('Keyboard mode'),
                        toggles: [
                          if (physicalKeyInputSupported)
                            MobileRemoteToggleItem(
                              id: 'physical-key-input',
                              value: physicalKeyInput,
                              child: Text(
                                translate(
                                  'Physical key input (VM compatibility)',
                                ),
                              ),
                              onChanged: gFFI.ffiModel.viewOnly
                                  ? null
                                  : (value) {
                                      if (value == null) return;
                                      setState(() => _physicalKeyInput = value);
                                      unawaited(
                                        bind.sessionPeerOption(
                                          sessionId: gFFI.sessionId,
                                          name: kOptionMobilePhysicalKeyInput,
                                          value: mobileVmPhysicalInputOption(
                                            value,
                                          ),
                                        ),
                                      );
                                    },
                            ),
                          for (var i = 0; i < keyboardToggles.length; i++)
                            MobileRemoteToggleItem(
                              id: 'keyboard-$i',
                              value: keyboardToggles[i].value,
                              child: keyboardToggles[i].child,
                              onChanged: keyboardToggles[i].onChanged,
                            ),
                        ],
                        actions: [
                          if (!gFFI.ffiModel.viewOnly)
                            MobileRemoteActionItem(
                              child: Text(translate('Trackpad speed')),
                              onPressed: () {
                                close();
                                Future<void>.delayed(Duration.zero, () {
                                  trackpadSpeedDialog(gFFI.sessionId, gFFI);
                                });
                              },
                            ),
                        ],
                      ),
                    ),
                ],
                sections: [
                  if (mobileActionMenus.isNotEmpty)
                    MobileRemoteActionSection(
                      id: 'android',
                      title: Text(translate('Android device actions')),
                      actions: [
                        for (final menu in mobileActionMenus) actionItem(menu),
                      ],
                    ),
                ],
                actions: [for (final menu in menus) actionItem(menu)],
                navigationItems: [
                  if (!gFFI.ffiModel.viewOnly)
                    MobileRemoteNavigationItem(
                      id: 'custom-buttons',
                      child: Text(translate('Customize keyboard buttons')),
                      onPressed: () {
                        close();
                        setState(() => _showCustomButtonEditor = true);
                      },
                    ),
                ],
              ),
            );
          },
          clickMaskDismiss: true,
          backDismiss: true,
        )
        .then((_) {
          _disableAndroidSoftKeyboard();
        });
  }

  Widget _buildCustomButtonEditor(BuildContext context) {
    final isMac = gFFI.ffiModel.pi.platform == kPeerPlatformMacOS;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('mobile-remote-custom-buttons-back'),
                    tooltip: translate('Back'),
                    style: IconButton.styleFrom(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      shape: const CircleBorder(),
                    ),
                    onPressed: () =>
                        setState(() => _showCustomButtonEditor = false),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      translate('Customize keyboard buttons'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('mobile-remote-custom-buttons-reset'),
                    onPressed: () => setState(() {
                      _quickKeyOrder = List<MobileRemoteQuickKey>.of(
                        mobileRemoteDefaultQuickKeyOrder,
                      );
                    }),
                    icon: const Icon(Icons.restart_alt),
                    label: Text(translate('Reset')),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ReorderableListView.builder(
                key: const Key('mobile-remote-custom-buttons-list'),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: _quickKeyOrder.length,
                onReorderItem: (oldIndex, newIndex) {
                  setState(() {
                    final item = _quickKeyOrder.removeAt(oldIndex);
                    _quickKeyOrder.insert(newIndex, item);
                  });
                },
                itemBuilder: (context, index) {
                  final item = _quickKeyOrder[index];
                  return Card(
                    key: ValueKey(item),
                    child: ListTile(
                      leading: const Icon(Icons.drag_handle),
                      title: Text(
                        mobileRemoteQuickKeyLabel(item, isMac: isMac),
                      ),
                      subtitle: Text(translate('Drag to reorder')),
                      trailing: Text('${index + 1}'),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  onPressedTextChat(String id) {
    gFFI.chatModel.changeCurrentKey(MessageKey(id, ChatModel.clientModeID));
    gFFI.chatModel.toggleChatOverlay();
  }

  showChatOptions(String id) async {
    onPressVoiceCall() => bind.sessionRequestVoiceCall(sessionId: sessionId);
    onPressEndVoiceCall() => bind.sessionCloseVoiceCall(sessionId: sessionId);

    makeTextMenu(
      String label,
      Widget icon,
      VoidCallback onPressed, {
      TextStyle? labelStyle,
    }) => TTextMenu(
      child: Text(translate(label), style: labelStyle),
      trailingIcon: Transform.scale(
        scale: (isDesktop || isWebDesktop) ? 0.8 : 1,
        child: IgnorePointer(child: IconButton(onPressed: null, icon: icon)),
      ),
      onPressed: onPressed,
    );

    final isInVoice = [
      VoiceCallStatus.waitingForResponse,
      VoiceCallStatus.connected,
    ].contains(gFFI.chatModel.voiceCallStatus.value);
    final menus = [
      makeTextMenu(
        'Text chat',
        Icon(Icons.message, color: MyTheme.accent),
        () => onPressedTextChat(widget.id),
      ),
      isInVoice
          ? makeTextMenu(
              'End voice call',
              SvgPicture.asset(
                'assets/call_wait.svg',
                colorFilter: ColorFilter.mode(
                  Colors.redAccent,
                  BlendMode.srcIn,
                ),
              ),
              onPressEndVoiceCall,
              labelStyle: TextStyle(color: Colors.redAccent),
            )
          : makeTextMenu(
              'Voice call',
              SvgPicture.asset(
                'assets/call_wait.svg',
                colorFilter: ColorFilter.mode(MyTheme.accent, BlendMode.srcIn),
              ),
              onPressVoiceCall,
            ),
    ];

    Future.delayed(Duration.zero, () async {
      await showMobileRemotePopupMenu(context, [
        for (final menu in menus)
          MobileRemoteMenuItem(
            child: menu.getChild(),
            onPressed: menu.onPressed,
          ),
      ]);
    });
  }

  /// aka changeTouchMode
  BottomAppBar getGestureHelp() {
    return BottomAppBar(
      child: SingleChildScrollView(
        controller: ScrollController(),
        padding: EdgeInsets.symmetric(vertical: 10),
        child: GestureHelp(
          touchMode: gFFI.ffiModel.touchMode,
          onTouchModeChange: (t) {
            gFFI.ffiModel.toggleTouchMode();
            final v = gFFI.ffiModel.touchMode ? 'Y' : 'N';
            unawaited(bind.mainSetLocalOption(key: kOptionTouchMode, value: v));
          },
          virtualMouseMode: gFFI.ffiModel.virtualMouseMode,
          inputModel: gFFI.inputModel,
        ),
      ),
    );
  }
}

class KeyHelpTools extends StatefulWidget {
  final bool keyboardIsVisible;
  final bool showGestureHelp;
  final List<MobileRemoteQuickKey> quickKeyOrder;
  final GlobalKey remoteInputRegionKey;

  /// need to show by external request, etc [keyboardIsVisible] or [changeTouchMode]
  bool get requestShow => keyboardIsVisible || showGestureHelp;

  const KeyHelpTools({
    required this.keyboardIsVisible,
    required this.showGestureHelp,
    required this.quickKeyOrder,
    required this.remoteInputRegionKey,
  });

  @override
  State<KeyHelpTools> createState() => _KeyHelpToolsState();
}

class _KeyHelpToolsState extends State<KeyHelpTools> {
  var _more = true;
  var _fn = false;
  final _key = GlobalKey();

  InputModel get inputModel => gFFI.inputModel;

  void _scheduleRectUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateRect();
    });
  }

  _updateRect() {
    RenderObject? renderObject = _key.currentContext?.findRenderObject();
    if (renderObject == null) {
      return;
    }
    if (renderObject is RenderBox) {
      final size = renderObject.size;
      final globalPosition = renderObject.localToGlobal(Offset.zero);
      final globalRect = globalPosition & size;
      final inputRenderObject = widget.remoteInputRegionKey.currentContext
          ?.findRenderObject();
      final inputRect =
          inputRenderObject is RenderBox && inputRenderObject.attached
          ? mobileRemoteInputLocalRect(
              globalRect: globalRect,
              inputRegionGlobalOrigin: inputRenderObject.localToGlobal(
                Offset.zero,
              ),
            )
          : globalRect;
      gFFI.cursorModel.keyHelpToolsVisibilityChanged(
        inputRect,
        globalRect,
        widget.keyboardIsVisible,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: inputModel.mobileModifierState,
      builder: (context, child) => _buildTools(context),
    );
  }

  Widget _buildTools(BuildContext context) {
    final hasModifierOn =
        inputModel.ctrl ||
        inputModel.alt ||
        inputModel.shift ||
        inputModel.command;

    if (!hasModifierOn && !widget.requestShow) {
      gFFI.cursorModel.keyHelpToolsVisibilityChanged(
        null,
        null,
        widget.keyboardIsVisible,
      );
      return Offstage();
    }

    final pi = gFFI.ffiModel.pi;
    final isMac = pi.platform == kPeerPlatformMacOS;
    final isWin = pi.platform == kPeerPlatformWindows;
    final isLinux = pi.platform == kPeerPlatformLinux;
    final modifiers = inputModel.mobileModifierState;
    _scheduleRectUpdate();
    return MobileRemoteKeyHelpTools(
      key: _key,
      ctrlActive: inputModel.ctrl,
      altActive: inputModel.alt,
      shiftActive: inputModel.shift,
      commandActive: inputModel.command,
      ctrlLocked:
          modifiers.modeFor(MobileModifierKey.ctrl) ==
          MobileModifierMode.locked,
      altLocked:
          modifiers.modeFor(MobileModifierKey.alt) == MobileModifierMode.locked,
      shiftLocked:
          modifiers.modeFor(MobileModifierKey.shift) ==
          MobileModifierMode.locked,
      commandLocked:
          modifiers.modeFor(MobileModifierKey.command) ==
          MobileModifierMode.locked,
      functionKeysActive: _fn,
      moreKeysActive: _more,
      isMac: isMac,
      showWindowsLinuxKeys: isWin || isLinux,
      quickKeyOrder: widget.quickKeyOrder,
      onCtrl: () => modifiers.tap(MobileModifierKey.ctrl),
      onAlt: () => modifiers.tap(MobileModifierKey.alt),
      onShift: () => modifiers.tap(MobileModifierKey.shift),
      onCommand: () => modifiers.tap(MobileModifierKey.command),
      onCtrlDoubleTap: () => modifiers.lock(MobileModifierKey.ctrl),
      onAltDoubleTap: () => modifiers.lock(MobileModifierKey.alt),
      onShiftDoubleTap: () => modifiers.lock(MobileModifierKey.shift),
      onCommandDoubleTap: () => modifiers.lock(MobileModifierKey.command),
      onFunctionKeys: () {
        setState(() {
          _fn = !_fn;
          if (_fn) {
            _more = false;
          }
        });
      },
      onMoreKeys: () {
        setState(() {
          _more = !_more;
          if (_more) {
            _fn = false;
          }
        });
      },
      onKeyPressed: inputModel.inputKey,
      onShortcutPressed: (key) => sendPrompt(isMac, key),
      labelBuilder: translate,
    );
  }
}

class ImagePaint extends StatefulWidget {
  const ImagePaint({Key? key}) : super(key: key);

  @override
  State<ImagePaint> createState() => _ImagePaintState();
}

class _ImagePaintState extends State<ImagePaint> {
  int? _textureId;
  int? _textureDisplay;
  int? _textureWidth;
  int? _textureHeight;
  int? _queuedDisplay;
  int? _queuedWidth;
  int? _queuedHeight;
  bool _targetUpdateScheduled = false;
  int _targetGeneration = 0;

  void _queueTextureTarget(int? display, int? width, int? height) {
    if (_queuedDisplay == display &&
        _queuedWidth == width &&
        _queuedHeight == height) {
      return;
    }
    _queuedDisplay = display;
    _queuedWidth = width;
    _queuedHeight = height;
    if (_targetUpdateScheduled) return;
    _targetUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _targetUpdateScheduled = false;
      if (!mounted) return;
      final nextDisplay = _queuedDisplay;
      final nextWidth = _queuedWidth;
      final nextHeight = _queuedHeight;
      _targetGeneration++;
      final generation = _targetGeneration;
      if (nextDisplay == null || nextWidth == null || nextHeight == null) {
        unawaited(_releaseTexture());
      } else if (_textureId == null ||
          _textureDisplay != nextDisplay ||
          _textureWidth != nextWidth ||
          _textureHeight != nextHeight) {
        unawaited(
          _createTexture(generation, nextDisplay, nextWidth, nextHeight),
        );
      }
    });
  }

  Future<void> _createTexture(
    int generation,
    int display,
    int width,
    int height,
  ) async {
    final textureId = await platformFFI.createAndroidRemoteVideoTexture(
      display: display,
      width: width,
      height: height,
    );
    if (textureId == null) return;
    if (!mounted || generation != _targetGeneration) {
      await platformFFI.releaseAndroidRemoteVideoTexture(
        display: display,
        textureId: textureId,
      );
      return;
    }
    final oldTextureId = _textureId;
    final oldDisplay = _textureDisplay;
    setState(() {
      _textureId = textureId;
      _textureDisplay = display;
      _textureWidth = width;
      _textureHeight = height;
    });
    if (oldTextureId != null && oldDisplay != null) {
      await platformFFI.releaseAndroidRemoteVideoTexture(
        display: oldDisplay,
        textureId: oldTextureId,
      );
    }
    await bind.sessionRefresh(sessionId: gFFI.sessionId, display: display);
  }

  Future<void> _releaseTexture() async {
    final textureId = _textureId;
    final display = _textureDisplay;
    if (textureId == null || display == null) return;
    if (mounted) {
      setState(() {
        _textureId = null;
        _textureDisplay = null;
        _textureWidth = null;
        _textureHeight = null;
      });
    }
    await platformFFI.releaseAndroidRemoteVideoTexture(
      display: display,
      textureId: textureId,
    );
  }

  @override
  void dispose() {
    _targetGeneration++;
    final textureId = _textureId;
    final display = _textureDisplay;
    if (textureId != null && display != null) {
      unawaited(
        platformFFI.releaseAndroidRemoteVideoTexture(
          display: display,
          textureId: textureId,
        ),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<ImageModel>(context);
    final c = Provider.of<CanvasModel>(context);
    final ffiModel = Provider.of<FfiModel>(context);
    var s = c.scale;
    if (!isMobileClient && ffiModel.isPeerLinux) {
      final displays = ffiModel.pi.getCurDisplays();
      if (displays.isNotEmpty) {
        s = s / displays[0].scale;
      }
    }
    final adjust = c.getAdjustY();
    final softwarePaint = CustomPaint(
      painter: ImagePainter(
        image: m.image,
        x: c.x / s,
        y: (c.y + adjust) / s,
        scale: s,
        filterQuality: isMobileClient
            ? mobileRemoteTextureFilterQuality(logicalScale: s)
            : null,
      ),
    );
    final display = ffiModel.pi.currentDisplay;
    final displayInfo = ffiModel.pi.tryGetDisplayIfNotAllDisplay();
    if (!isAndroid ||
        !m.useTextureRender ||
        displayInfo == null ||
        displayInfo.width <= 0 ||
        displayInfo.height <= 0) {
      _queueTextureTarget(null, null, null);
      return softwarePaint;
    }
    _queueTextureTarget(display, displayInfo.width, displayInfo.height);
    final textureId = _textureId;
    if (textureId == null ||
        !m.androidSurfaceTextureActive ||
        _textureDisplay != display ||
        _textureWidth != displayInfo.width ||
        _textureHeight != displayInfo.height) {
      return softwarePaint;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: c.x,
          top: c.y + adjust,
          width: displayInfo.width * s,
          height: displayInfo.height * s,
          child: Texture(
            textureId: textureId,
            filterQuality: mobileRemoteTextureFilterQuality(logicalScale: s),
          ),
        ),
      ],
    );
  }
}

Widget mobileRemoteCursorOverlay(String id) =>
    Positioned.fill(child: IgnorePointer(child: CursorPaint(id)));

class CursorPaint extends StatelessWidget {
  late final String id;
  CursorPaint(this.id);

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<CursorModel>(context);
    final c = Provider.of<CanvasModel>(context);
    final ffiModel = Provider.of<FfiModel>(context);
    final s = c.scale;
    double hotx = m.hotx;
    double hoty = m.hoty;
    var image = m.image;
    if (image == null) {
      if (preDefaultCursor.image != null) {
        image = preDefaultCursor.image;
        hotx = preDefaultCursor.image!.width / 2;
        hoty = preDefaultCursor.image!.height / 2;
      }
    }
    if (preForbiddenCursor.image != null &&
        !ffiModel.viewOnly &&
        !ffiModel.keyboard &&
        !ShowRemoteCursorState.find(id).value) {
      image = preForbiddenCursor.image;
      hotx = preForbiddenCursor.image!.width / 2;
      hoty = preForbiddenCursor.image!.height / 2;
    }
    if (image == null) {
      return Offstage();
    }

    final minSize = 12.0;
    double mins =
        minSize / (image.width > image.height ? image.width : image.height);
    double factor = 1.0;
    if (s < mins) {
      factor = s / mins;
    }
    final s2 = s < mins ? mins : s;
    final adjust = c.getAdjustY();
    return CustomPaint(
      painter: ImagePainter(
        image: image,
        x: (m.x - hotx) * factor + c.x / s2,
        y: (m.y - hoty) * factor + (c.y + adjust) / s2,
        scale: s2,
      ),
    );
  }
}

void showOptions(
  BuildContext context,
  String id,
  OverlayDialogManager dialogManager, {
  required MobileRemoteToolbarTransparencySettings toolbarTransparencySettings,
  required ValueChanged<MobileRemoteToolbarTransparencySettings>
  onToolbarTransparencySettingsChanged,
  required bool showMonitorsInToolbar,
  required ValueChanged<bool> onShowMonitorsInToolbarChanged,
  required MobileCursorInertiaSettings cursorInertiaSettings,
  required ValueChanged<MobileCursorInertiaSettings>
  onCursorInertiaSettingsChanged,
}) async {
  var displays = <Widget>[];
  final pi = gFFI.ffiModel.pi;
  final image = gFFI.ffiModel.getConnectionImageText();
  if (image != null) {
    displays.add(Padding(padding: const EdgeInsets.only(top: 8), child: image));
  }
  if (pi.displays.length > 1 && pi.currentDisplay != kAllDisplayValue) {
    final cur = pi.currentDisplay;
    final children = <Widget>[];
    final isDarkTheme = MyTheme.currentThemeMode() == ThemeMode.dark;
    final numColorSelected = Colors.white;
    final numColorUnselected = isDarkTheme ? Colors.grey : Colors.black87;
    // We can't use `Theme.of(context).primaryColor` here, the color is:
    // - light theme: 0xff2196f3 (Colors.blue)
    // - dark theme: 0xff212121 (the canvas color?)
    final numBgSelected = Theme.of(
      context,
    ).colorScheme.primary.withOpacity(0.6);
    for (var i = 0; i < pi.displays.length; ++i) {
      children.add(
        InkWell(
          onTap: () {
            if (i == cur) return;
            openMonitorInTheSameTab(i, gFFI, pi);
            gFFI.dialogManager.dismissAll();
          },
          child: Ink(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).hintColor),
              borderRadius: BorderRadius.circular(2.0),
              color: i == cur ? numBgSelected : null,
            ),
            child: Center(
              child: Text(
                (i + 1).toString(),
                style: TextStyle(
                  color: i == cur ? numColorSelected : numColorUnselected,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      );
    }
    displays.add(
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: children,
        ),
      ),
    );
  }
  if (displays.isNotEmpty) {
    displays.add(const Divider(color: MyTheme.border));
  }

  final selectedViewMode = gFFI.canvasModel.mobileViewScaleMode;
  final viewStyleRadios = <TRadioMenu<String>>[
    for (final mode in MobileRemoteViewScaleMode.values)
      TRadioMenu<String>(
        child: Text(translate(mode.label)),
        value: mode.value,
        groupValue: selectedViewMode.value,
        onChanged: (_) => gFFI.canvasModel.applyMobileViewScaleMode(mode),
      ),
  ];
  final selectedScrollStyle = normalizeMobileRemoteScrollStyle(
    await bind.sessionGetScrollStyle(sessionId: gFFI.sessionId) ?? '',
  );
  var activeEdgeThickness = gFFI.canvasModel.edgeScrollEdgeThickness.toDouble();
  final scrollStyleRadios = <TRadioMenu<String>>[
    for (final entry in <(String, String)>[
      (kRemoteScrollStyleAuto, 'ScrollAuto'),
      (kRemoteScrollStyleEdge, 'ScrollEdge'),
      (kRemoteScrollStyleEdgeAcceleration, 'ScrollEdgeAcceleration'),
    ])
      TRadioMenu<String>(
        child: Text(translate(entry.$2)),
        value: entry.$1,
        groupValue: selectedScrollStyle,
        onChanged: (value) async {
          if (value == null) return;
          await bind.sessionSetScrollStyle(
            sessionId: gFFI.sessionId,
            value: value,
          );
          await gFFI.canvasModel.updateScrollStyle();
        },
      ),
  ];
  var activeShowMonitorsInToolbar = showMonitorsInToolbar;
  var activeToolbarTransparencySettings = toolbarTransparencySettings;
  var activeQualityMonitorFadeSettings =
      QualityMonitorFadeSettings.fromUserDefaults();

  Future<void> persistQualityMonitorFadeSettings(
    QualityMonitorFadeSettings settings,
  ) async {
    await bind.mainSetUserDefaultOption(
      key: kOptionQualityMonitorInactiveOpacityPercent,
      value: settings.opacityPercent.toString(),
    );
    await bind.mainSetUserDefaultOption(
      key: kOptionQualityMonitorDimDelayMs,
      value: settings.delayMs.toString(),
    );
    await bind.mainSetUserDefaultOption(
      key: kOptionQualityMonitorDimDurationMs,
      value: settings.durationMs.toString(),
    );
  }

  var activeCursorInertiaSettings = cursorInertiaSettings;
  List<TRadioMenu<String>> imageQualityRadios = await toolbarImageQuality(
    context,
    id,
    gFFI,
    openCustomDialog: false,
  );
  List<TRadioMenu<String>> codecRadios = await toolbarCodec(context, id, gFFI);
  List<TRadioMenu<String>> captureBackendRadios = await toolbarCaptureBackend(
    gFFI,
  );
  List<TRadioMenu<String>> qualityMonitorRadios =
      await toolbarQualityMonitorPosition(gFFI);
  List<TRadioMenu<String>> qualityMonitorDetailsRadios =
      await toolbarQualityMonitorDetails(gFFI);
  List<TRadioMenu<String>> clipboardRadios = await toolbarClipboardDirection(
    gFFI,
  );
  List<TToggleMenu> cursorToggles = await toolbarCursor(context, id, gFFI);
  List<TToggleMenu> displayToggles = await toolbarDisplayToggle(
    context,
    id,
    gFFI,
  );
  if (isAndroid && bind.mainHasGpuTextureRender()) {
    displayToggles.add(
      TToggleMenu(
        value: gFFI.imageModel.useTextureRender,
        onChanged: (value) async {
          if (value == null) return;
          await bind.mainSetLocalOption(
            key: kOptionTextureRender,
            value: value ? 'Y' : 'N',
          );
        },
        child: Text(translate('Use texture rendering')),
      ),
    );
  }

  List<TToggleMenu> privacyModeList = [];
  // privacy mode
  final privacyModeState = PrivacyModeState.find(id);
  if (gFFI.ffiModel.keyboard && gFFI.ffiModel.pi.features.privacyMode) {
    privacyModeList = toolbarPrivacyMode(privacyModeState, context, id, gFFI);
    if (privacyModeList.length == 1) {
      displayToggles.add(privacyModeList[0]);
    }
  }

  dialogManager
      .show(
        (setState, close, context) {
          MobileRemoteRadioSection radioSection(
            String sectionId,
            List<TRadioMenu<String>> source, {
            Widget? heading,
            String? submenuId,
            bool honorEnabled = false,
            Widget Function(String value)? selectionDetailsBuilder,
          }) {
            return MobileRemoteRadioSection(
              id: sectionId,
              value: source.isEmpty ? '' : source.first.groupValue,
              heading: heading,
              submenuId: submenuId,
              selectionDetailsBuilder: selectionDetailsBuilder,
              items: [
                for (final item in source)
                  MobileRemoteRadioItem(
                    value: item.value,
                    child: item.child,
                    onChanged: item.onChanged,
                    commitSelection: !honorEnabled || item.enabled,
                  ),
              ],
            );
          }

          final resolution = getResolutionMenu(gFFI, id);
          final virtualDisplayMenu = getVirtualDisplayMenu(gFFI, id);
          return CustomAlertDialog(
            scrollable: false,
            contentBoxConstraints: BoxConstraints(
              maxWidth: 500,
              maxHeight: MediaQuery.sizeOf(context).height * 0.9,
            ),
            content: MobileRemoteOptionsContent(
              header: [
                ...displays,
                if (pi.displays.length > 1)
                  CheckboxListTile(
                    key: const Key('mobile-remote-show-monitors-toolbar'),
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    value: activeShowMonitorsInToolbar,
                    title: Text(translate('show_monitors_tip')),
                    onChanged: (value) async {
                      if (value == null) return;
                      setState(() => activeShowMonitorsInToolbar = value);
                      await bind.mainSetUserDefaultOption(
                        key: kKeyShowMonitorsToolbar,
                        value: value ? 'Y' : 'N',
                      );
                      onShowMonitorsInToolbarChanged(value);
                    },
                  ),
              ],
              radioSections: [
                radioSection(
                  'view-style',
                  viewStyleRadios,
                  heading: Text(translate('Scale')),
                ),
                radioSection(
                  'scroll-style',
                  scrollStyleRadios,
                  heading: Text(translate('Screen scrolling')),
                  selectionDetailsBuilder: (value) {
                    final usesEdgeThickness =
                        value == kRemoteScrollStyleEdge ||
                        value == kRemoteScrollStyleEdgeAcceleration;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (usesEdgeThickness)
                          EdgeThicknessControl(
                            key: const Key('mobile-remote-edge-thickness'),
                            value: activeEdgeThickness,
                            onChanged: (value) {
                              final thickness = value.round();
                              activeEdgeThickness = thickness.toDouble();
                              gFFI.canvasModel.updateEdgeScrollEdgeThickness(
                                thickness,
                              );
                              unawaited(
                                bind.sessionSetEdgeScrollEdgeThickness(
                                  sessionId: gFFI.sessionId,
                                  value: thickness,
                                ),
                              );
                            },
                          ),
                        const SizedBox(height: 8),
                        Text(translate('Cursor inertia time')),
                        MobileCursorInertiaControl(
                          key: const Key('mobile-remote-cursor-inertia'),
                          durationMs: activeCursorInertiaSettings.durationMs,
                          onChanged: (durationMs) {
                            activeCursorInertiaSettings =
                                activeCursorInertiaSettings.copyWith(
                                  durationMs: durationMs,
                                );
                            onCursorInertiaSettingsChanged(
                              activeCursorInertiaSettings,
                            );
                          },
                          onChangeEnd: (durationMs) {
                            unawaited(
                              bind.sessionPeerOption(
                                sessionId: gFFI.sessionId,
                                name: kOptionMobileCursorInertiaDurationMs,
                                value: durationMs.toString(),
                              ),
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
                MobileRemoteRadioSection(
                  id: 'overlay-appearance',
                  value: '',
                  items: const [],
                  heading: Text(translate('Overlay appearance')),
                  content: MobileOverlayAppearanceControls(
                    toolbarTitle: translate('Toolbar'),
                    toolbarOpacityLabel: translate('Opacity under cursor'),
                    qualityMonitorTitle: translate('Quality monitor'),
                    inactiveOpacityLabel: translate('Inactive opacity'),
                    fadeDelayLabel: translate('Fade delay'),
                    fadeDurationLabel: translate('Fade duration'),
                    toolbarSettings: activeToolbarTransparencySettings,
                    qualityMonitorSettings: activeQualityMonitorFadeSettings,
                    toolbarEnabled: !isOptionFixed(
                      kOptionMobileRemoteToolbarOverlapOpacityPercent,
                    ),
                    qualityMonitorOpacityEnabled: !isOptionFixed(
                      kOptionQualityMonitorInactiveOpacityPercent,
                    ),
                    qualityMonitorDelayEnabled: !isOptionFixed(
                      kOptionQualityMonitorDimDelayMs,
                    ),
                    qualityMonitorDurationEnabled: !isOptionFixed(
                      kOptionQualityMonitorDimDurationMs,
                    ),
                    onToolbarChanged: (settings) {
                      activeToolbarTransparencySettings = settings;
                      onToolbarTransparencySettingsChanged(settings);
                    },
                    onToolbarChangeEnd: (settings) {
                      activeToolbarTransparencySettings = settings;
                      onToolbarTransparencySettingsChanged(settings);
                      unawaited(
                        bind.sessionPeerOption(
                          sessionId: gFFI.sessionId,
                          name: kOptionMobileRemoteToolbarOverlapOpacityPercent,
                          value: settings.overlapOpacityPercent.toString(),
                        ),
                      );
                    },
                    onQualityMonitorChanged: (settings) {
                      activeQualityMonitorFadeSettings = settings;
                    },
                    onQualityMonitorChangeEnd: (settings) {
                      activeQualityMonitorFadeSettings = settings;
                      unawaited(persistQualityMonitorFadeSettings(settings));
                    },
                  ),
                ),
                radioSection(
                  'image-quality',
                  imageQualityRadios,
                  heading: Text(translate('Image Quality')),
                  selectionDetailsBuilder: (value) =>
                      value == kRemoteImageQualityCustom
                      ? MobileCustomImageQualityControls(
                          key: const ValueKey('mobile-custom-image-quality'),
                          peerId: id,
                          ffi: gFFI,
                        )
                      : const SizedBox.shrink(),
                ),
                radioSection(
                  'codec',
                  codecRadios,
                  heading: Text(translate('Codec')),
                  honorEnabled: true,
                ),
                radioSection(
                  'capture-backend',
                  captureBackendRadios,
                  heading: Text(translate('Capture')),
                ),
                radioSection(
                  'quality-monitor',
                  qualityMonitorRadios,
                  heading: Text(translate('Quality monitor')),
                  submenuId: 'quality-monitor',
                ),
                radioSection(
                  'quality-monitor-details',
                  qualityMonitorDetailsRadios,
                  heading: Text(translate('Quality monitor details')),
                  submenuId: 'quality-monitor',
                ),
                radioSection(
                  'clipboard',
                  clipboardRadios,
                  heading: Text(translate('Clipboard')),
                ),
              ],
              actions: [
                if (resolution != null)
                  MobileRemoteActionItem(
                    child: resolution.child,
                    onPressed: () {
                      close();
                      resolution.onPressed?.call();
                    },
                  ),
                if (virtualDisplayMenu != null)
                  MobileRemoteActionItem(
                    child: virtualDisplayMenu.child,
                    onPressed: () {
                      close();
                      virtualDisplayMenu.onPressed?.call();
                    },
                  ),
              ],
              toggles: [
                for (var i = 0; i < cursorToggles.length; i++)
                  MobileRemoteToggleItem(
                    id: 'cursor-$i',
                    value: cursorToggles[i].value,
                    child: cursorToggles[i].child,
                    onChanged: cursorToggles[i].onChanged,
                  ),
                for (var i = 0; i < displayToggles.length; i++)
                  MobileRemoteToggleItem(
                    id: 'display-$i',
                    value: displayToggles[i].value,
                    child: displayToggles[i].child,
                    onChanged: displayToggles[i].onChanged,
                    dividerBefore: i == 0 && cursorToggles.isNotEmpty,
                  ),
              ],
              footer: [
                if (privacyModeList.length > 1)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    title: Text(translate('Privacy mode')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setPrivacyModeDialog(
                      dialogManager,
                      privacyModeList,
                      privacyModeState,
                    ),
                  ),
              ],
            ),
          );
        },
        clickMaskDismiss: true,
        backDismiss: true,
      )
      .then((value) {
        _disableAndroidSoftKeyboard();
      });
}

TTextMenu? getVirtualDisplayMenu(FFI ffi, String id) {
  if (!showVirtualDisplayMenu(ffi)) {
    return null;
  }
  return TTextMenu(
    child: Text(translate("Virtual display")),
    onPressed: () {
      ffi.dialogManager
          .show(
            (setState, close, context) {
              final children = getVirtualDisplayMenuChildren(ffi, id, close);
              return CustomAlertDialog(
                title: Text(translate('Virtual display')),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              );
            },
            clickMaskDismiss: true,
            backDismiss: true,
          )
          .then((value) {
            _disableAndroidSoftKeyboard();
          });
    },
  );
}

TTextMenu? getResolutionMenu(FFI ffi, String id) {
  final ffiModel = ffi.ffiModel;
  final pi = ffiModel.pi;
  final resolutions = pi.resolutions;
  final display = pi.tryGetDisplayIfNotAllDisplay(display: pi.currentDisplay);

  final visible =
      ffiModel.keyboard && (resolutions.length > 1) && display != null;
  if (!visible) return null;

  return TTextMenu(
    child: Text(translate("Resolution")),
    onPressed: () {
      ffi.dialogManager
          .show(
            (setState, close, context) {
              final children = resolutions
                  .map(
                    (e) => getRadio<String>(
                      Text('${e.width}x${e.height}'),
                      '${e.width}x${e.height}',
                      '${display.width}x${display.height}',
                      (value) {
                        close();
                        bind.sessionChangeResolution(
                          sessionId: ffi.sessionId,
                          display: pi.currentDisplay,
                          width: e.width,
                          height: e.height,
                        );
                      },
                    ),
                  )
                  .toList();
              return CustomAlertDialog(
                title: Text(translate('Resolution')),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              );
            },
            clickMaskDismiss: true,
            backDismiss: true,
          )
          .then((value) {
            _disableAndroidSoftKeyboard();
          });
    },
  );
}

void sendPrompt(bool isMac, String key) {
  gFFI.inputModel.inputKeyWithTemporaryMobileModifier(
    key,
    isMac ? MobileModifierKey.command : MobileModifierKey.ctrl,
  );
}

class FABLocation extends FloatingActionButtonLocation {
  FloatingActionButtonLocation location;
  double offsetX;
  double offsetY;
  FABLocation(this.location, this.offsetX, this.offsetY);

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    final offset = location.getOffset(scaffoldGeometry);
    return Offset(offset.dx + offsetX, offset.dy + offsetY);
  }
}
