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
  RemotePage(
      {Key? key,
      required this.id,
      this.password,
      this.isSharedPassword,
      this.forceRelay})
      : super(key: key);

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

  final _blockableOverlayState = BlockableOverlayState();

  final keyboardVisibilityController = KeyboardVisibilityController();
  late final StreamSubscription<bool> keyboardSubscription;
  final FocusNode _mobileFocusNode = FocusNode();
  final FocusNode _physicalFocusNode = FocusNode();
  var _showEdit = false; // use soft keyboard
  var _showCustomButtonEditor = false;
  var _toolbarTransparencySettings =
      MobileRemoteToolbarTransparencySettings.defaults;
  var _cursorInertiaSettings = MobileCursorInertiaSettings.defaults;
  var _quickKeyOrder = List<MobileRemoteQuickKey>.of(
    mobileRemoteDefaultQuickKeyOrder,
  );

  InputModel get inputModel => gFFI.inputModel;
  SessionID get sessionId => gFFI.sessionId;

  final TextEditingController _textController =
      TextEditingController(text: initText);

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
    _cursorInertiaSettings = _cursorInertiaSettingsFromUserDefaults();
    gFFI.canvasModel.initializeEdgeScrollFallback(this);
    gFFI.ffiModel.updateEventListener(sessionId, widget.id);
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
      await gFFI.start(
        widget.id,
        password: widget.password,
        isSharedPassword: widget.isSharedPassword,
        forceRelay: widget.forceRelay,
      );
      if (!mounted || gFFI.closed) return;
      await _refreshMobileInputSettings();
      unawaited(gFFI.qualityMonitorModel.checkShowQualityMonitor(sessionId));
    } catch (e, stackTrace) {
      debugPrint('Failed to start mobile session: $e\n$stackTrace');
      if (!mounted) return;
      gFFI.dialogManager.dismissAll();
      showToast(translate('Failed to connect'));
      closeConnection();
    }
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
      if (mounted &&
          (toolbarSettings != _toolbarTransparencySettings ||
              inertiaSettings != _cursorInertiaSettings)) {
        setState(() {
          _toolbarTransparencySettings = toolbarSettings;
          _cursorInertiaSettings = inertiaSettings;
        });
      }
    } catch (error) {
      debugPrint('Failed to load mobile input settings: $error');
    }
  }

  @override
  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
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
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
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
        underlying: Container(
          color: bgColor,
        ),
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
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
            overlays: SystemUiOverlay.values);
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
    for (;
        common < subOldValue.length &&
            common < subNewValue.length &&
            subNewValue[common] == subOldValue[common];
        ++common) {}

    // get newStr from subNewValue
    var newStr = "";
    if (subNewValue.length > common) {
      newStr = subNewValue.substring(common);
    }

    // Set the value to the old value and early return if is still composing. (1 && 2)
    // 1. The composing range is valid
    // 2. The new string is shorter than the composing range.
    if (_textController.value.isComposingRangeValid) {
      final composingLength = _textController.value.composing.end -
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
      bind.sessionInputString(sessionId: sessionId, value: newStr);
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
          bind.sessionInputString(sessionId: sessionId, value: content);
          openKeyboard();
          return;
        }
        bind.sessionInputString(sessionId: sessionId, value: content);
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
    } else if (char == ' ') {
      char = 'VK_SPACE';
    }
    inputModel.inputKey(char);
  }

  void _requestMobileSoftKeyboard() {
    if (!mounted || !_showEdit) return;
    _mobileFocusNode.requestFocus();
    if (!isIOS) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_showEdit || !_mobileFocusNode.hasFocus) return;
      unawaited(
        SystemChannels.textInput.invokeMethod<void>('TextInput.show'),
      );
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
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
            overlays: SystemUiOverlay.values);
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
        clientClose(sessionId, gFFI);
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
          () => getRawPointerAndKeyBody(
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
                                  if (_currentOrientation != orientation) {
                                    Timer(
                                      const Duration(milliseconds: 200),
                                      () {
                                        gFFI.dialogManager
                                            .resetMobileActionsOverlay(
                                              ffi: gFFI,
                                            );
                                        _currentOrientation = orientation;
                                        gFFI.canvasModel.updateViewStyle();
                                      },
                                    );
                                  }
                                  return Container(
                                    color: MyTheme.canvasColor,
                                    child: inputModel.isPhysicalMouse.value
                                        ? getBodyForMobile()
                                        : RawTouchGestureDetectorRegion(
                                            child: getBodyForMobile(),
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
    return Obx(
      () => MobileRemoteToolbar(
        onDisconnect: () => clientClose(sessionId, gFFI),
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
        chatButton: chatButton,
        cursorPosition: cursorModel.mobileViewportPosition - const Offset(8, 8),
        transparencySettings: _toolbarTransparencySettings,
      ),
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
              paints.add(CursorPaint(widget.id));
            }
            if (gFFI.ffiModel.touchMode) {
              paints.add(FloatingMouse(ffi: gFFI));
            } else {
              paints.add(FloatingMouseWidgets(ffi: gFFI));
            }
            if (gFFI.ffiModel.pi.displays.isNotEmpty && !keyboardIsVisible) {
              paints.add(
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: getFloatingToolbar(),
                  ),
                ),
              );
            }
            paints.add(
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: KeyHelpTools(
                  keyboardIsVisible: keyboardIsVisible,
                  showGestureHelp: _showGestureHelp,
                  quickKeyOrder: _quickKeyOrder,
                ),
              ),
            );
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
          sessionId: sessionId, arg: 'show-remote-cursor');
      if (ffiModel.keyboard || cursor) {
        paints.add(CursorPaint(widget.id));
      }
    }
    return Container(
        color: MyTheme.canvasColor, child: Stack(children: paints));
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
                sections: [
                  if (mobileActionMenus.isNotEmpty)
                    MobileRemoteActionSection(
                      id: 'android',
                      title: Text(translate('Android device actions')),
                      actions: [
                        for (final menu in mobileActionMenus) actionItem(menu),
                      ],
                    ),
                  MobileRemoteActionSection(
                    id: 'session',
                    title: Text(translate('Session actions')),
                    actions: [for (final menu in menus) actionItem(menu)],
                  ),
                ],
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
                      backgroundColor:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
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
                bind.mainSetLocalOption(key: kOptionTouchMode, value: v);
              },
              virtualMouseMode: gFFI.ffiModel.virtualMouseMode,
              inputModel: gFFI.inputModel,
            )));
  }

  // * Currently mobile does not enable map mode
  // void changePhysicalKeyboardInputMode() async {
  //   var current = await bind.sessionGetKeyboardMode(id: widget.id) ?? "legacy";
  //   gFFI.dialogManager.show((setState, close) {
  //     void setMode(String? v) async {
  //       await bind.sessionSetKeyboardMode(id: widget.id, value: v ?? "");
  //       setState(() => current = v ?? '');
  //       Future.delayed(Duration(milliseconds: 300), close);
  //     }
  //
  //     return CustomAlertDialog(
  //         title: Text(translate('Physical Keyboard Input Mode')),
  //         content: Column(mainAxisSize: MainAxisSize.min, children: [
  //           getRadio('Legacy mode', 'legacy', current, setMode),
  //           getRadio('Map mode', 'map', current, setMode),
  //         ]));
  //   }, clickMaskDismiss: true);
  // }
}

class KeyHelpTools extends StatefulWidget {
  final bool keyboardIsVisible;
  final bool showGestureHelp;
  final List<MobileRemoteQuickKey> quickKeyOrder;

  /// need to show by external request, etc [keyboardIsVisible] or [changeTouchMode]
  bool get requestShow => keyboardIsVisible || showGestureHelp;

  const KeyHelpTools({
    required this.keyboardIsVisible,
    required this.showGestureHelp,
    required this.quickKeyOrder,
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
      Offset pos = renderObject.localToGlobal(Offset.zero);
      gFFI.cursorModel.keyHelpToolsVisibilityChanged(
          Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height),
          widget.keyboardIsVisible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasModifierOn = inputModel.ctrl ||
        inputModel.alt ||
        inputModel.shift ||
        inputModel.command;

    if (!hasModifierOn && !widget.requestShow) {
      gFFI.cursorModel
          .keyHelpToolsVisibilityChanged(null, widget.keyboardIsVisible);
      return Offstage();
    }

    final pi = gFFI.ffiModel.pi;
    final isMac = pi.platform == kPeerPlatformMacOS;
    final isWin = pi.platform == kPeerPlatformWindows;
    final isLinux = pi.platform == kPeerPlatformLinux;
    _scheduleRectUpdate();
    return MobileRemoteKeyHelpTools(
      key: _key,
      ctrlActive: inputModel.ctrl,
      altActive: inputModel.alt,
      shiftActive: inputModel.shift,
      commandActive: inputModel.command,
      functionKeysActive: _fn,
      moreKeysActive: _more,
      isMac: isMac,
      showWindowsLinuxKeys: isWin || isLinux,
      quickKeyOrder: widget.quickKeyOrder,
      onCtrl: () => setState(() => inputModel.ctrl = !inputModel.ctrl),
      onAlt: () => setState(() => inputModel.alt = !inputModel.alt),
      onShift: () => setState(() => inputModel.shift = !inputModel.shift),
      onCommand: () =>
          setState(() => inputModel.command = !inputModel.command),
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

class ImagePaint extends StatelessWidget {
  const ImagePaint({Key? key}) : super(key: key);

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
    return CustomPaint(
      painter: ImagePainter(
          image: m.image,
          x: c.x / s,
          y: (c.y + adjust) / s,
          scale: s,
          filterQuality: isMobileClient
              ? mobileRemoteTextureFilterQuality(logicalScale: s)
              : null),
    );
  }
}

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
          scale: s2),
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
    final numBgSelected =
        Theme.of(context).colorScheme.primary.withOpacity(0.6);
    for (var i = 0; i < pi.displays.length; ++i) {
      children.add(InkWell(
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
                  color: i == cur ? numBgSelected : null),
              child: Center(
                  child: Text((i + 1).toString(),
                      style: TextStyle(
                          color:
                              i == cur ? numColorSelected : numColorUnselected,
                          fontWeight: FontWeight.bold))))));
    }
    displays.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: children,
        )));
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
  var activeEdgeThickness =
      gFFI.canvasModel.edgeScrollEdgeThickness.toDouble();
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
  var activeToolbarTransparencySettings = toolbarTransparencySettings;
  final toolbarOpacityRadios = <TRadioMenu<String>>[
    for (final percent
        in MobileRemoteToolbarTransparencySettings.opacityPresets)
      TRadioMenu<String>(
        child: Text(mobileRemoteToolbarOpacityLabel(percent)),
        value: percent.toString(),
        groupValue: activeToolbarTransparencySettings.overlapOpacityPercent
            .toString(),
        onChanged: (value) async {
          final percent = int.tryParse(value ?? '');
          if (percent == null) return;
          activeToolbarTransparencySettings = activeToolbarTransparencySettings
              .copyWith(overlapOpacityPercent: percent);
          onToolbarTransparencySettingsChanged(
            activeToolbarTransparencySettings,
          );
          await bind.sessionPeerOption(
            sessionId: gFFI.sessionId,
            name: kOptionMobileRemoteToolbarOverlapOpacityPercent,
            value: percent.toString(),
          );
        },
      ),
  ];
  var activeCursorInertiaSettings = cursorInertiaSettings;
  final cursorInertiaRadios = <TRadioMenu<String>>[
    for (final durationMs in MobileCursorInertiaSettings.durationPresetsMs)
      TRadioMenu<String>(
        child: Text(mobileCursorInertiaDurationLabel(durationMs)),
        value: durationMs.toString(),
        groupValue: activeCursorInertiaSettings.durationMs.toString(),
        onChanged: (value) async {
          final durationMs = int.tryParse(value ?? '');
          if (durationMs == null) return;
          activeCursorInertiaSettings = activeCursorInertiaSettings.copyWith(
            durationMs: durationMs,
          );
          onCursorInertiaSettingsChanged(activeCursorInertiaSettings);
          await bind.sessionPeerOption(
            sessionId: gFFI.sessionId,
            name: kOptionMobileCursorInertiaDurationMs,
            value: durationMs.toString(),
          );
        },
      ),
  ];
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
            bool honorEnabled = false,
            Widget Function(String value)? selectionDetailsBuilder,
          }) {
            return MobileRemoteRadioSection(
              id: sectionId,
              value: source.isEmpty ? '' : source.first.groupValue,
              heading: heading,
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
            contentBoxConstraints: BoxConstraints(
              maxWidth: 500,
              maxHeight: MediaQuery.sizeOf(context).height * 0.9,
            ),
            content: MobileRemoteOptionsContent(
              header: displays,
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
                    if (!usesEdgeThickness) return const SizedBox.shrink();
                    return EdgeThicknessControl(
                      key: const Key('mobile-remote-edge-thickness'),
                      value: activeEdgeThickness,
                      onChanged: (value) {
                        final thickness = value.round();
                        activeEdgeThickness = thickness.toDouble();
                        gFFI.canvasModel.updateEdgeScrollEdgeThickness(
                          thickness,
                        );
                        unawaited(bind.sessionSetEdgeScrollEdgeThickness(
                          sessionId: gFFI.sessionId,
                          value: thickness,
                        ));
                      },
                    );
                  },
                ),
                radioSection(
                  'toolbar-cursor-overlap-opacity',
                  toolbarOpacityRadios,
                  heading: Text(translate('Toolbar opacity under cursor')),
                ),
                radioSection(
                  'cursor-inertia-time',
                  cursorInertiaRadios,
                  heading: Text(translate('Cursor inertia time')),
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
                ),
                radioSection(
                  'quality-monitor-details',
                  qualityMonitorDetailsRadios,
                  heading: Text(translate('Quality monitor details')),
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
      ffi.dialogManager.show((setState, close, context) {
        final children = getVirtualDisplayMenuChildren(ffi, id, close);
        return CustomAlertDialog(
          title: Text(translate('Virtual display')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        );
      }, clickMaskDismiss: true, backDismiss: true).then((value) {
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
      ffi.dialogManager.show((setState, close, context) {
        final children = resolutions
            .map((e) => getRadio<String>(
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
                ))
            .toList();
        return CustomAlertDialog(
          title: Text(translate('Resolution')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        );
      }, clickMaskDismiss: true, backDismiss: true).then((value) {
        _disableAndroidSoftKeyboard();
      });
    },
  );
}

void sendPrompt(bool isMac, String key) {
  final old = isMac ? gFFI.inputModel.command : gFFI.inputModel.ctrl;
  if (isMac) {
    gFFI.inputModel.command = true;
  } else {
    gFFI.inputModel.ctrl = true;
  }
  gFFI.inputModel.inputKey(key);
  if (isMac) {
    gFFI.inputModel.command = old;
  } else {
    gFFI.inputModel.ctrl = old;
  }
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
