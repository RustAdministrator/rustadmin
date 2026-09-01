import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bot_toast/bot_toast.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_hbb/common/widgets/peers_view.dart';
import 'package:flutter_hbb/common/session_peer_settings.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/ab_model.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/cm_file_model.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/group_model.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/peer_capability_matrix.dart';
import 'package:flutter_hbb/models/peer_tab_model.dart';
import 'package:flutter_hbb/models/printer_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/models/user_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/models/desktop_render_texture.dart';
import 'package:flutter_hbb/models/terminal_model.dart';
import 'package:flutter_hbb/plugin/manager.dart';
import 'package:flutter_hbb/plugin/widgets/desc_ui.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_hbb/utils/http_service.dart' as http;
import 'package:tuple/tuple.dart';
import 'package:image/image.dart' as img2;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';
import 'package:file_picker/file_picker.dart';
import 'package:vector_math/vector_math.dart' show Vector2;

import '../common.dart';
import '../common/peer_trust_error.dart';
import '../mobile/mobile_viewport.dart';
import '../mobile/android_vpn_controller.dart';
import '../utils/image.dart' as img;
import '../common/widgets/dialog.dart';
import 'android_render_target_controller.dart';
import 'input_model.dart';
import 'platform_model.dart';
import 'session_event.dart';
import 'session_handle.dart';
import 'package:flutter_hbb/utils/scale.dart';

import 'package:flutter_hbb/generated_bridge.dart'
    if (dart.library.html) 'package:flutter_hbb/web/bridge.dart';
import 'package:flutter_hbb/native/custom_cursor.dart'
    if (dart.library.html) 'package:flutter_hbb/web/custom_cursor.dart';

typedef ReconnectHandle = Function(OverlayDialogManager, SessionID, bool);
final _constSessionId = Uuid().v4obj();

const kRustAdminDefaultSessionPermissions = <String, bool>{
  'keyboard': true,
  'clipboard': false,
  'audio': false,
  'file': false,
  'restart': false,
  'recording': false,
  'block_input': false,
  'file_transfer': false,
  'port_forward': false,
  'view_camera': false,
  'terminal': false,
};

const _kInitialSessionPermissionNames = <String>{
  'keyboard',
  'clipboard',
  'audio',
  'file',
  'restart',
  'recording',
  'block_input',
};

Map<String, bool> rustAdminDefaultSessionPermissions() =>
    Map<String, bool>.of(kRustAdminDefaultSessionPermissions);

class CachedPeerData {
  Map<String, dynamic> updatePrivacyMode = {};
  Map<String, dynamic> peerInfo = {};
  List<Map<String, dynamic>> cursorDataList = [];
  Map<String, dynamic> lastCursorId = {};
  Map<String, bool> permissions = {};

  bool secure = false;
  bool direct = false;
  String streamType = '';

  CachedPeerData();

  @override
  String toString() {
    return jsonEncode({
      'updatePrivacyMode': updatePrivacyMode,
      'peerInfo': peerInfo,
      'cursorDataList': cursorDataList,
      'lastCursorId': lastCursorId,
      'permissions': permissions,
      'secure': secure,
      'direct': direct,
      'streamType': streamType,
    });
  }

  static CachedPeerData? fromString(String s) {
    try {
      final map = jsonDecode(s);
      final data = CachedPeerData();
      data.updatePrivacyMode = map['updatePrivacyMode'];
      data.peerInfo = map['peerInfo'];
      for (final cursorData in map['cursorDataList']) {
        data.cursorDataList.add(cursorData);
      }
      data.lastCursorId = map['lastCursorId'];
      map['permissions'].forEach((key, value) {
        data.permissions[key] = value;
      });
      data.secure = map['secure'];
      data.direct = map['direct'];
      data.streamType = map['streamType'];
      return data;
    } catch (e) {
      debugPrint('Failed to parse CachedPeerData: $e');
      return null;
    }
  }
}

class FfiModel with ChangeNotifier {
  CachedPeerData cachedPeerData = CachedPeerData();
  PeerInfo _pi = PeerInfo();
  Rect? _rect;

  var _inputBlocked = false;
  final _permissions = <String, bool>{};
  bool? _secure;
  bool? _direct;
  bool _touchMode = false;
  late VirtualMouseMode virtualMouseMode;
  Timer? _timer;
  var _reconnects = 1;
  DateTime? _offlineReconnectStartTime;
  bool _viewOnly = false;
  bool _showMyCursor = false;
  WeakReference<FFI> parent;
  late final SessionID sessionId;

  RxBool waitForImageDialogShow = true.obs;
  Timer? waitForImageTimer;
  RxBool waitForFirstImage = true.obs;
  bool isRefreshing = false;
  bool _authenticatedHandoffPeerInfoReady = false;
  bool _authenticatedHandoffNotified = false;
  final _receivedInitialPermissions = <String>{};
  Timer? _authenticatedHandoffFallbackTimer;

  Timer? timerScreenshot;

  Rect? get rect => _rect;
  bool get isOriginalResolutionSet =>
      _pi.tryGetDisplayIfNotAllDisplay()?.isOriginalResolutionSet ?? false;
  bool get isVirtualDisplayResolution =>
      _pi.tryGetDisplayIfNotAllDisplay()?.isVirtualDisplayResolution ?? false;
  bool get isOriginalResolution =>
      _pi.tryGetDisplayIfNotAllDisplay()?.isOriginalResolution ?? false;

  Map<String, bool> get permissions => _permissions;
  setPermissions(Map<String, bool> permissions) {
    _permissions.clear();
    _permissions.addAll(kRustAdminDefaultSessionPermissions);
    _permissions.addAll(permissions);
  }

  bool? get secure => _secure;

  bool? get direct => _direct;

  PeerInfo get pi => _pi;

  bool get inputBlocked => _inputBlocked;

  bool get touchMode => _touchMode;

  bool get isPeerAndroid => _pi.capabilities.isAndroid;
  bool get isPeerMobile => isPeerAndroid;

  bool get isPeerLinux => _pi.capabilities.isLinux;

  bool get viewOnly => _viewOnly;
  bool get showMyCursor => _showMyCursor;

  set inputBlocked(v) {
    _inputBlocked = v;
  }

  FfiModel(this.parent) {
    clear();
    sessionId = parent.target!.sessionId;
    cachedPeerData.permissions = _permissions;
    virtualMouseMode = VirtualMouseMode(this);
  }

  Rect? globalDisplaysRect() => _getDisplaysRect(_pi.displays, true);
  Rect? displaysRect() => _getDisplaysRect(_pi.getCurDisplays(), false);
  Rect? _getDisplaysRect(List<Display> displays, bool useDisplayScale) {
    if (displays.isEmpty) {
      return null;
    }
    if (isPeerLinux) {
      useDisplayScale = true;
    }
    int scale(int len, double s) {
      if (useDisplayScale) {
        return len.toDouble() ~/ s;
      } else {
        return len;
      }
    }

    double l = displays[0].x;
    double t = displays[0].y;
    double r = displays[0].x + scale(displays[0].width, displays[0].scale);
    double b = displays[0].y + scale(displays[0].height, displays[0].scale);
    for (var display in displays.sublist(1)) {
      l = min(l, display.x);
      t = min(t, display.y);
      r = max(r, display.x + scale(display.width, display.scale));
      b = max(b, display.y + scale(display.height, display.scale));
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  toggleTouchMode() {
    if (!isPeerAndroid) {
      _touchMode = !_touchMode;
      notifyListeners();
    }
  }

  updatePermissionValues(Map<String, bool> permissions, String id) {
    // Track previous keyboard permission to detect revocation.
    final hadKeyboardPerm = _permissions['keyboard'] != false;
    final revokesKeyboard = hadKeyboardPerm && permissions['keyboard'] == false;
    final updatedPermissions = <String>[];

    if (revokesKeyboard) {
      parent.target?.inputModel.permissionRevoked();
    }

    permissions.forEach((k, v) {
      if (k.isEmpty) return;
      _permissions[k] = v;
      if (_kInitialSessionPermissionNames.contains(k)) {
        updatedPermissions.add(k);
      }
    });
    if (updatedPermissions.isNotEmpty) {
      _receivedInitialPermissions.addAll(updatedPermissions);
    }
    // Only inited at remote page
    if (parent.target?.connType == ConnType.defaultConn) {
      KeyboardEnabledState.find(id).value = _permissions['keyboard'] != false;
    }

    // If keyboard permission was revoked while relative mouse mode is active,
    // forcefully disable relative mouse mode to prevent the user from being trapped.
    final hasKeyboardPerm = _permissions['keyboard'] != false;
    if (hadKeyboardPerm && !hasKeyboardPerm) {
      final inputModel = parent.target?.inputModel;
      if (inputModel != null && inputModel.relativeMouseMode.value) {
        inputModel.setRelativeMouseMode(false);
        showToast(translate('rel-mouse-permission-lost-tip'));
      }
    }

    debugPrint('updatePermission: $_permissions');
    notifyListeners();
    _tryNotifyAuthenticatedHandoff(id);
  }

  bool get keyboard => _permissions['keyboard'] != false;

  clear() {
    _pi = PeerInfo();
    _secure = null;
    _direct = null;
    _inputBlocked = false;
    _timer?.cancel();
    _timer = null;
    clearPermissions();
    waitForImageTimer?.cancel();
    _authenticatedHandoffFallbackTimer?.cancel();
    _authenticatedHandoffFallbackTimer = null;
    _authenticatedHandoffPeerInfoReady = false;
    _authenticatedHandoffNotified = false;
    _receivedInitialPermissions.clear();
    timerScreenshot?.cancel();
  }

  setConnectionType(
      String peerId, bool secure, bool direct, String streamType) {
    cachedPeerData.secure = secure;
    cachedPeerData.direct = direct;
    cachedPeerData.streamType = streamType;
    _secure = secure;
    _direct = direct;
    try {
      var connectionType = ConnectionTypeState.find(peerId);
      connectionType.setSecure(secure);
      connectionType.setDirect(direct);
      connectionType.setStreamType(streamType);
    } catch (e) {
      //
    }
  }

  Widget? getConnectionImageText() {
    if (secure == null || direct == null) {
      return null;
    } else {
      final icon =
          '${secure == true ? 'secure' : 'insecure'}${direct == true ? '' : '_relay'}';
      final iconWidget =
          SvgPicture.asset('assets/$icon.svg', width: 48, height: 48);
      String connectionText =
          getConnectionText(secure!, direct!, cachedPeerData.streamType);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconWidget,
          SizedBox(height: 4),
          Text(
            connectionText,
            style: TextStyle(fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      );
    }
  }

  clearPermissions() {
    _inputBlocked = false;
    _permissions.clear();
    _permissions.addAll(kRustAdminDefaultSessionPermissions);
  }

  handleCachedPeerData(CachedPeerData data, String peerId) async {
    handleMessageBoxEvent(
      const MessageBoxSessionEvent(
        type: 'success',
        title: 'Successful',
        text: kMsgboxTextWaitingForImage,
        link: '',
        hasRetry: false,
        origin: MessageBoxOrigin.core,
      ),
      sessionId,
      peerId,
    );
    await updatePrivacyModeSignal(sessionId, peerId);
    setConnectionType(peerId, data.secure, data.direct, data.streamType);
    final peerInfoEvent = decodeTypedSessionEvent({
      ...data.peerInfo,
      'name': 'peer_info',
    });
    if (peerInfoEvent is! PeerInfoSessionEvent) {
      debugPrint('Rejected invalid cached peer_info snapshot');
      return;
    }
    await handlePeerInfoEvent(peerInfoEvent, peerId, true);
    for (final element in data.cursorDataList) {
      final event = decodeTypedSessionEvent({...element, 'name': 'cursor_data'});
      if (event is CursorShapeSessionEvent) {
        updateLastCursorIdValue(event.id);
        await handleCursorShapeEvent(event);
      }
    }
    if (data.lastCursorId.isNotEmpty) {
      final event = decodeTypedSessionEvent({
        ...data.lastCursorId,
        'name': 'cursor_id',
      });
      if (event is CursorIdSessionEvent) {
        updateLastCursorIdValue(event.id);
        handleCursorIdEvent(event);
      }
    }
  }

  void _tryNotifyAuthenticatedHandoff(String peerId,
      {bool allowPartialSnapshot = false}) {
    final ffi = parent.target;
    final onAuthenticated = ffi?.onAuthenticated;
    if (ffi == null ||
        onAuthenticated == null ||
        _authenticatedHandoffNotified ||
        !_authenticatedHandoffPeerInfoReady) {
      return;
    }
    if (!allowPartialSnapshot &&
        !_receivedInitialPermissions
            .containsAll(_kInitialSessionPermissionNames)) {
      return;
    }
    if (allowPartialSnapshot &&
        !_receivedInitialPermissions
            .containsAll(_kInitialSessionPermissionNames)) {
      debugPrint(
          'Opening authenticated remote window with partial permission snapshot: $_receivedInitialPermissions');
    }
    if (!_initialCursorReadyForAuthenticatedHandoff()) {
      if (!allowPartialSnapshot) {
        return;
      }
      debugPrint(
          'Opening authenticated remote window before initial cursor data was received.');
    }
    _authenticatedHandoffNotified = true;
    _authenticatedHandoffFallbackTimer?.cancel();
    _authenticatedHandoffFallbackTimer = null;
    ffi.onAuthenticated = null;
    unawaited(onAuthenticated(ffi, peerId));
  }

  // Cursor data can arrive after peer_info and permissions. Wait for it during
  // pre-auth handoff so the attached desktop window does not render fallback.
  bool _initialCursorReadyForAuthenticatedHandoff() {
    final ffi = parent.target;
    if (ffi == null || ffi.connType != ConnType.defaultConn) {
      return true;
    }
    if (_pi.cursorEmbedded || _pi.isWayland) {
      return true;
    }
    return cachedPeerData.cursorDataList.isNotEmpty ||
        ffi.cursorModel.image != null ||
        ffi.cursorModel.cache != null;
  }

  // todo: why called by two position
  StreamEventHandler startEventListener(SessionID sessionId, String peerId) {
    return (evt) async {
      final typedEvent = decodeTypedSessionEvent(evt);
      if (typedEvent != null) {
        await _routeTypedSessionEvent(typedEvent, sessionId, peerId);
        return;
      }
      debugPrint('Event is not handled in the fixed branch: ${evt['name']}');
    };
  }

  Future<void> _routeTypedSessionEvent(
    SessionEvent event,
    SessionID sessionId,
    String peerId,
  ) async {
    if (event is ConnectionReadySessionEvent) {
      setConnectionType(peerId, event.secure, event.direct, event.streamType);
      parent.target?.qualityMonitorModel.updateConnectionInfo(
        event.streamType,
        event.direct,
      );
    } else if (event is PermissionSessionEvent) {
      updatePermissionValues(event.permissions, peerId);
    } else if (event is ClipboardSessionEvent) {
      Clipboard.setData(ClipboardData(text: event.content));
    } else if (event is ClientChatSessionEvent) {
      parent.target?.chatModel.receive(ChatModel.clientModeID, event.text);
    } else if (event is ServerChatSessionEvent) {
      parent.target?.chatModel.receive(event.id, event.text);
    } else if (event is ShowElevationSessionEvent) {
      parent.target?.serverModel.setShowElevation(event.show);
    } else if (event is VoiceCallClosedSessionEvent) {
      parent.target?.chatModel.onVoiceCallClosed(event.reason);
    } else if (event is FingerprintSessionEvent) {
      FingerprintState.find(peerId).value = event.fingerprint;
    } else if (event is RecordStatusSessionEvent) {
      if (desktopType == DesktopType.remote ||
          desktopType == DesktopType.viewCamera ||
          isMobile) {
        parent.target?.recordingModel.updateStatus(event.start);
      }
    } else if (event is SessionSignalEvent) {
      switch (event.signal) {
        case SessionSignal.voiceCallWaiting:
          parent.target?.chatModel.onVoiceCallWaiting();
        case SessionSignal.voiceCallStarted:
          parent.target?.chatModel.onVoiceCallStarted();
        case SessionSignal.voiceCallIncoming:
          parent.target?.chatModel.onVoiceCallIncoming();
        case SessionSignal.exitRelativeMouseMode:
          parent.target?.inputModel.exitRelativeMouseModeWithKeyRelease();
      }
    } else if (event is CursorShapeSessionEvent) {
      updateLastCursorIdValue(event.id);
      await handleCursorShapeEvent(event, peerId: peerId);
    } else if (event is CursorIdSessionEvent) {
      handleCursorIdEvent(event);
    } else if (event is CursorPositionSessionEvent) {
      await parent.target?.cursorModel.updateCursorPositionValue(
        event.x,
        event.y,
        peerId,
      );
    } else if (event is BlockInputSessionEvent) {
      updateBlockInputStateValue(event.enabled, peerId);
    } else if (event is PrivacyModeChangedSessionEvent) {
      await updatePrivacyModeSignal(sessionId, peerId);
    } else if (event is TextureRenderSessionEvent) {
      handleUseTextureRenderValue(event.enabled, sessionId);
    } else if (event is FollowCurrentDisplaySessionEvent) {
      await handleFollowCurrentDisplayValue(
        event.displayIndex,
        sessionId,
        peerId,
      );
    } else if (event is TerminalResponseSessionEvent) {
      parent.target?.routeTerminalResponseEvent(event);
    } else if (event is FileJobProgressSessionEvent) {
      parent.target?.fileModel.jobController.updateJobProgressEvent(event);
    } else if (event is FileJobDoneSessionEvent) {
      final refresh =
          await parent.target?.fileModel.jobController.jobDoneEvent(event);
      if (refresh == true) {
        // many job done for delete directory
        // todo: refresh may not work when confirm delete local directory
        parent.target?.fileModel.refreshAll();
      }
    } else if (event is FileJobErrorSessionEvent) {
      parent.target?.fileModel.handleJobErrorEvent(event);
    } else if (event is FileFolderStatsSessionEvent) {
      parent.target?.fileModel.jobController.updateFolderStatsEvent(event);
    } else if (event is FileDirectorySessionEvent) {
      parent.target?.fileModel.receiveFileDirectoryEvent(event);
    } else if (event is EmptyDirectoriesSessionEvent) {
      parent.target?.fileModel.receiveEmptyDirectoriesEvent(event);
    } else if (event is FileOverrideConfirmSessionEvent) {
      await parent.target?.fileModel.postOverrideFileConfirmEvent(event);
    } else if (event is FileResumeJobSessionEvent) {
      await parent.target?.fileModel.jobController.loadLastJobEvent(event);
    } else if (event is SessionControlEvent) {
      await _handleSessionControlEvent(event, sessionId);
    } else if (event is PeerHashSyncSessionEvent) {
      if (desktopType == DesktopType.main || isWeb || isMobile) {
        gFFI.abModel.changePersonalHashPassword(event.id, event.hash);
      }
    } else if (event is PeerOptionSyncSessionEvent) {
      _handleSyncPeerOptionEvent(event, peerId);
    } else if (event is WebSelectedFileSessionEvent) {
      if (isWeb) parent.target?.fileModel.onSelectedFileEvent(event);
    } else if (event is WebEmptyDirectoriesSessionEvent) {
      if (isWeb) parent.target?.fileModel.sendEmptyDirectoriesEvent(event);
    } else if (event is PrinterRequestSessionEvent) {
      _handlePrinterRequestEvent(event, sessionId);
    } else if (event is ScreenshotSessionEvent) {
      _handleScreenshotEvent(event, sessionId);
    } else if (event is MessageBoxSessionEvent) {
      handleMessageBoxEvent(event, sessionId, peerId);
    } else if (event is ToastSessionEvent) {
      handleToastEvent(event);
    } else if (event is MultipleWindowsSessionsEvent) {
      handleMultipleWindowsSessionsEvent(event, sessionId, peerId);
    } else if (event is ClientSnapshotSessionEvent) {
      switch (event.kind) {
        case ClientSnapshotKind.addConnection:
          parent.target?.serverModel.addConnectionEvent(event.client);
        case ClientSnapshotKind.voiceState:
          parent.target?.serverModel.updateVoiceCallStateEvent(event.client);
      }
    } else if (event is ClientRemovedSessionEvent) {
      parent.target?.serverModel.onClientRemoveEvent(event);
    } else if (event is ClientPermissionSessionEvent) {
      switch (event.kind) {
        case ClientPermissionKind.update:
          parent.target?.serverModel.updateClientPermissionEvent(event);
        case ClientPermissionKind.request:
          parent.target?.serverModel.handlePermissionRequestEvent(event);
      }
    } else if (event is PluginCatalogSessionEvent) {
      pluginManager.handleCatalogEvent(event);
    } else if (event is PluginInstallStatusSessionEvent) {
      pluginManager.handleInstallStatusEvent(event);
    } else if (event is PluginContentSessionEvent) {
      final message = event.message;
      if (message != null) handleMessageBoxEvent(message, sessionId, peerId);
    } else if (event is PluginReloadSessionEvent) {
      handleReloadingEvent(event);
    } else if (event is PluginOptionSessionEvent) {
      handleOptionEvent(event);
    } else if (event is CmTransferLogSessionEvent) {
      if (isDesktop) gFFI.cmFileModel.handleTransferEvent(event);
    } else if (event is CmFileActionSessionEvent) {
      if (isDesktop) gFFI.cmFileModel.handleFileActionEvent(event);
    } else if (event is CmFileRenameSessionEvent) {
      if (isDesktop) gFFI.cmFileModel.handleRenameEvent(event);
    } else if (event is PeerInfoSessionEvent) {
      await handlePeerInfoEvent(event, peerId, false);
    } else if (event is SyncPeerInfoSessionEvent) {
      await handleSyncPeerInfoEvent(event, sessionId, peerId);
    } else if (event is SwitchDisplaySessionEvent) {
      handleSwitchDisplayEvent(event, sessionId, peerId);
    } else if (event is SyncPlatformAdditionsSessionEvent) {
      handlePlatformAdditionsEvent(event);
    } else if (event is QualityStatusSessionEvent) {
      parent.target?.qualityMonitorModel.updateQualityStatusEvent(event);
    } else if (event is InvalidSessionEvent) {
      debugPrint(
        'Rejected malformed session event ${event.name}: ${event.reason}',
      );
    }
  }

  Future<void> _handleSessionControlEvent(
    SessionControlEvent event,
    SessionID sessionId,
  ) async {
    switch (event.kind) {
      case SessionControlKind.cancelMessageBox:
        cancelMsgBoxValue(event.value, sessionId);
      case SessionControlKind.switchBack:
        await bind.sessionSwitchSides(sessionId: sessionId);
        closeConnection(id: event.value);
      case SessionControlKind.portableServiceRunning:
        _handlePortableServiceRunning(event.enabled);
      case SessionControlKind.urlSchemeReceived:
        onUrlSchemeReceivedValue(event.value);
    }
  }

  void _handleScreenshotEvent(
      ScreenshotSessionEvent event, SessionID sessionId) {
    timerScreenshot?.cancel();
    timerScreenshot = null;
    final msg = event.message;
    final msgBoxType = 'custom-nook-nocancel-hasclose';
    final msgBoxTitle = 'Take screenshot';
    final dialogManager = parent.target!.dialogManager;
    if (msg.isNotEmpty) {
      msgBox(sessionId, msgBoxType, msgBoxTitle, msg, '', dialogManager);
    } else {
      final msgBoxText = 'screenshot-action-tip';

      close() {
        dialogManager.dismissAll();
      }

      saveAs() {
        close();
        Future.delayed(Duration.zero, () async {
          final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          String? outputFile = await FilePicker.saveFile(
            dialogTitle: '${translate('Save as')}...',
            fileName: 'screenshot_$ts.png',
            allowedExtensions: ['png'],
            type: FileType.custom,
          );
          if (outputFile == null) {
            bind.sessionHandleScreenshot(sessionId: sessionId, action: '2');
          } else {
            final res = await bind.sessionHandleScreenshot(
                sessionId: sessionId, action: '0:$outputFile');
            if (res.isNotEmpty) {
              msgBox(sessionId, 'custom-nook-nocancel-hasclose-error',
                  'Take screenshot', res, '', dialogManager);
            }
          }
        });
      }

      copyToClipboard() {
        bind.sessionHandleScreenshot(sessionId: sessionId, action: '1');
        close();
      }

      cancel() {
        bind.sessionHandleScreenshot(sessionId: sessionId, action: '2');
        close();
      }

      final List<Widget> buttons = [
        dialogButton('${translate('Save as')}...', onPressed: saveAs),
        dialogButton('Copy to clipboard', onPressed: copyToClipboard),
        dialogButton('Cancel', onPressed: cancel),
      ];
      dialogManager.dismissAll();
      dialogManager.show(
        (setState, close, context) => CustomAlertDialog(
          title: null,
          content: SelectionArea(
              child: msgboxContent(msgBoxType, msgBoxTitle, msgBoxText)),
          actions: buttons,
        ),
        tag: '$msgBoxType-$msgBoxTitle-$msgBoxTitle',
      );
    }
  }

  void _handlePrinterRequestEvent(
      PrinterRequestSessionEvent event, SessionID sessionId) {
    final id = event.id;
    final path = event.path;
    final dialogManager = parent.target!.dialogManager;
    dialogManager.show((setState, close, context) {
      PrinterOptions printerOptions = PrinterOptions.load();
      final saveSettings = mainGetLocalBoolOptionSync(kKeyPrinterSave).obs;
      final dontShowAgain = false.obs;
      final Rx<String> selectedPrinterName = printerOptions.printerName.obs;
      final printerNames = printerOptions.printerNames;
      final defaultOrSelectedGroupValue =
          (printerOptions.action == kValuePrinterIncomingJobDismiss
                  ? kValuePrinterIncomingJobDefault
                  : printerOptions.action)
              .obs;

      onRatioChanged(String? value) {
        defaultOrSelectedGroupValue.value =
            value ?? kValuePrinterIncomingJobDefault;
      }

      onSubmit() {
        final printerName = defaultOrSelectedGroupValue.isEmpty
            ? ''
            : selectedPrinterName.value;
        bind.sessionPrinterResponse(
            sessionId: sessionId, id: id, path: path, printerName: printerName);
        if (saveSettings.value || dontShowAgain.value) {
          bind.mainSetLocalOption(key: kKeyPrinterSelected, value: printerName);
          bind.mainSetLocalOption(
              key: kKeyPrinterIncomingJobAction,
              value: defaultOrSelectedGroupValue.value);
        }
        if (dontShowAgain.value) {
          mainSetLocalBoolOption(kKeyPrinterAllowAutoPrint, true);
        }
        close();
      }

      onCancel() {
        if (dontShowAgain.value) {
          bind.mainSetLocalOption(
              key: kKeyPrinterIncomingJobAction,
              value: kValuePrinterIncomingJobDismiss);
        }
        close();
      }

      final printerItemHeight = 30.0;
      final selectionAreaHeight =
          printerItemHeight * min(8.0, max(printerNames.length, 3.0));
      final content = Column(
        children: [
          Text(translate('print-incoming-job-confirm-tip')),
          Row(
            children: [
              Obx(() => Radio<String>(
                  value: kValuePrinterIncomingJobDefault,
                  groupValue: defaultOrSelectedGroupValue.value,
                  onChanged: onRatioChanged)),
              GestureDetector(
                  child: Text(translate('use-the-default-printer-tip')),
                  onTap: () => onRatioChanged(kValuePrinterIncomingJobDefault)),
            ],
          ),
          Column(
            children: [
              Row(children: [
                Obx(() => Radio<String>(
                    value: kValuePrinterIncomingJobSelected,
                    groupValue: defaultOrSelectedGroupValue.value,
                    onChanged: onRatioChanged)),
                GestureDetector(
                    child: Text(translate('use-the-selected-printer-tip')),
                    onTap: () =>
                        onRatioChanged(kValuePrinterIncomingJobSelected)),
              ]),
              SizedBox(
                height: selectionAreaHeight,
                width: 500,
                child: ListView.builder(
                    itemBuilder: (context, index) {
                      return Obx(() => GestureDetector(
                            child: Container(
                              decoration: BoxDecoration(
                                color: selectedPrinterName.value ==
                                        printerNames[index]
                                    ? (defaultOrSelectedGroupValue.value ==
                                            kValuePrinterIncomingJobSelected
                                        ? MyTheme.button
                                        : MyTheme.button.withOpacity(0.5))
                                    : Theme.of(context).cardColor,
                                borderRadius: BorderRadius.all(
                                  Radius.circular(4.0),
                                ),
                              ),
                              key: ValueKey(printerNames[index]),
                              height: printerItemHeight,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 10.0),
                                  child: Text(
                                    printerNames[index],
                                    style: TextStyle(fontSize: 14),
                                  ),
                                ),
                              ),
                            ),
                            onTap: defaultOrSelectedGroupValue.value ==
                                    kValuePrinterIncomingJobSelected
                                ? () {
                                    selectedPrinterName.value =
                                        printerNames[index];
                                  }
                                : null,
                          ));
                    },
                    itemCount: printerNames.length),
              ),
            ],
          ),
          Row(
            children: [
              Obx(() => Checkbox(
                  value: saveSettings.value,
                  onChanged: (value) {
                    if (value != null) {
                      saveSettings.value = value;
                      mainSetLocalBoolOption(kKeyPrinterSave, value);
                    }
                  })),
              GestureDetector(
                  child: Text(translate('save-settings-tip')),
                  onTap: () {
                    saveSettings.value = !saveSettings.value;
                    mainSetLocalBoolOption(kKeyPrinterSave, saveSettings.value);
                  }),
            ],
          ),
          Row(
            children: [
              Obx(() => Checkbox(
                  value: dontShowAgain.value,
                  onChanged: (value) {
                    if (value != null) {
                      dontShowAgain.value = value;
                    }
                  })),
              GestureDetector(
                  child: Text(translate('dont-show-again-tip')),
                  onTap: () {
                    dontShowAgain.value = !dontShowAgain.value;
                  }),
            ],
          ),
        ],
      );
      return CustomAlertDialog(
        title: Text(translate('Incoming Print Job')),
        content: content,
        actions: [
          dialogButton('OK', onPressed: onSubmit),
          dialogButton('Cancel', onPressed: onCancel),
        ],
        onSubmit: onSubmit,
        onCancel: onCancel,
      );
    });
  }

  void handleUseTextureRenderValue(bool enabled, SessionID sessionId) {
    parent.target?.imageModel.setUseTextureRender(enabled);
    waitForFirstImage.value = true;
    isRefreshing = true;
    showConnectedWaitingForImage(parent.target!.dialogManager, sessionId,
        'success', 'Successful', kMsgboxTextWaitingForImage);
  }

  void _handleSyncPeerOptionEvent(
      PeerOptionSyncSessionEvent event, String peer) {
    switch (event.kind) {
      case PeerOptionSyncKind.viewOnly:
        final viewOnly = event.viewOnly;
        if (viewOnly != null) setViewOnly(peer, viewOnly);
      case PeerOptionSyncKind.keyboardMode:
        parent.target?.inputModel.updateKeyboardMode();
      case PeerOptionSyncKind.inputSource:
        stateGlobal.getInputSource(force: true);
      case PeerOptionSyncKind.other:
        break;
    }
  }

  void onUrlSchemeReceivedValue(String value) {
    final url = value.trim();
    if (url.startsWith(bind.mainUriPrefixSync()) &&
        handleUriLink(uriString: url)) {
      return;
    }
    switch (url) {
      case kUrlActionClose:
        debugPrint("closing all instances");
        Future.microtask(() async {
          if (await rustDeskWinManager.closeAllSessionWindows()) {
            await windowManager.setPreventClose(false);
            await windowManager.close();
          }
        });
        break;
      default:
        windowOnTop(null);
        break;
    }
  }

  /// Bind the event listener to receive events from the Rust core.
  updateEventListener(SessionID sessionId, String peerId) {
    platformFFI.setEventCallback(startEventListener(sessionId, peerId));
  }

  void _handlePortableServiceRunning(bool running) {
    parent.target?.elevationModel.onPortableServiceRunning(running);
  }

  handleAliasChanged(Map<String, dynamic> evt) {
    if (!(isDesktop || isWebDesktop)) return;
    final String peerId = evt['id'];
    final String alias = evt['alias'];
    String label = getDesktopTabLabel(peerId, alias);
    final rxTabLabel = PeerStringOption.find(evt['id'], 'tabLabel');
    if (rxTabLabel.value != label) {
      rxTabLabel.value = label;
    }
  }

  Future<void> updateCurDisplay(SessionID sessionId,
      {updateCursorPos = false}) async {
    final newRect = displaysRect();
    if (newRect == null) {
      return;
    }
    if (newRect != _rect) {
      if (newRect.left != _rect?.left || newRect.top != _rect?.top) {
        parent.target?.cursorModel.updateDisplayOrigin(
            newRect.left, newRect.top,
            updateCursorPos: updateCursorPos);
      }
      _rect = newRect;
      if (isMobileClient &&
          parent.target?.connType == ConnType.defaultConn) {
        parent.target?.canvasModel.requestMobileViewFit();
      }
      // Await updateViewStyle to ensure view geometry is fully updated before
      // updating pointer lock center. This prevents stale center calculations.
      await parent.target?.canvasModel
          .updateViewStyle(refreshMousePos: updateCursorPos);
      _updateSessionWidthHeight(sessionId);

      // Keep pointer lock center in sync when using relative mouse mode.
      // Note: updatePointerLockCenter is async-safe (handles errors internally),
      // so we fire-and-forget here.
      final inputModel = parent.target?.inputModel;
      if (inputModel != null && inputModel.relativeMouseMode.value) {
        inputModel.updatePointerLockCenter();
      }
    }
  }

  void handleSwitchDisplayEvent(
      SwitchDisplaySessionEvent event, SessionID sessionId, String peerId) {
    final display = event.displayIndex;
    if (display >= _pi.displays.length) {
      debugPrint('Ignoring switch_display for unknown display $display');
      return;
    }

    if (_pi.currentDisplay != kAllDisplayValue) {
      if (bind.peerGetSessionsCount(
              id: peerId, connType: parent.target!.connType.index) >
          1) {
        if (display != _pi.currentDisplay) {
          return;
        }
      }
      if (!_pi.isSupportMultiUiSession) {
        _pi.currentDisplay = display;
      }
      // If `isSupportMultiUiSession` is true, the switch display message should not be used to update current display.
      // It is only used to update the display info.
    }

    final newDisplay = _displayFromSessionValue(event.display);
    newDisplay._scale = _pi.scaleOfDisplay(display);
    _pi.displays[display] = newDisplay;

    if (!_pi.isSupportMultiUiSession || _pi.currentDisplay == display) {
      updateCurDisplay(sessionId);
    }

    if (!_pi.isSupportMultiUiSession) {
      try {
        CurrentDisplayState.find(peerId).value = display;
      } catch (e) {
        //
      }
    }

    if (!_pi.isSupportMultiUiSession || _pi.currentDisplay == display) {
      _applyResolutionValues(event.resolutions);
    }
    notifyListeners();
  }

  void cancelMsgBoxValue(String value, SessionID sessionId) {
    if (parent.target == null) return;
    final dialogManager = parent.target!.dialogManager;
    final tag = '$sessionId-$value';
    dialogManager.dismissByTag(tag);
  }

  void handleMultipleWindowsSessionsEvent(
      MultipleWindowsSessionsEvent event,
      SessionID sessionId,
      String peerId) {
    if (parent.target == null) return;
    final dialogManager = parent.target!.dialogManager;
    final title = translate('Multiple Windows sessions found');
    final text = translate('Please select the session you want to connect to');
    final type = "";

    showWindowsSessionsDialog(type, title, text, dialogManager, sessionId,
        [for (final session in event.sessions) session.id],
        [for (final session in event.sessions) session.name]);
  }

  void handleMessageBoxEvent(
      MessageBoxSessionEvent event, SessionID sessionId, String peerId) {
    if (parent.target == null) return;
    final dialogManager = parent.target!.dialogManager;
    final type = event.type;
    final title = event.title;
    final text = event.text;
    final link = event.link;

    if (event.origin == MessageBoxOrigin.plugin) {
      msgBox(sessionId, type, title, text, link, dialogManager);
      return;
    }

    void rejectSecurityPrompt({required bool pairing}) {
      () async {
        if (pairing) {
          await bind.sessionSubmitDirectPairingPassphrase(
            sessionId: sessionId,
            passphrase: '',
            approved: false,
          );
        } else {
          await bind.sessionConfirmDirectTrust(
            sessionId: sessionId,
            approved: false,
          );
        }
        closeConnection();
      }();
    }

    // Disable relative mouse mode on any error-type message to ensure cursor is released.
    // This includes connection errors, session-ending messages, elevation errors, etc.
    // Safety: releasing pointer lock on errors prevents the user from being stuck.
    if (title == 'Connection Error' ||
        type == 'error' ||
        type == 'restarting' ||
        type.contains('error')) {
      parent.target?.inputModel.setRelativeMouseMode(false);
    }

    if (type == 'input-pairing-passphrase' ||
        type == 'input-direct-pairing-passphrase') {
      final details = event.securityDetails;
      if (details != null) {
        showPairingPassphraseDialog(sessionId, dialogManager, details);
      } else {
        rejectSecurityPrompt(pairing: true);
      }
    } else if (type == 'confirm-peer-trust' || type == 'confirm-direct-trust') {
      final details = event.securityDetails;
      if (details != null) {
        showPeerTrustDialog(sessionId, dialogManager, details);
      } else {
        rejectSecurityPrompt(pairing: false);
      }
    } else if (type == 'error' &&
        title == 'Connection Error' &&
        isResettablePeerTrustError(text)) {
      showPeerIdentityChangedDialog(sessionId, dialogManager, text);
    } else if (type == 're-input-password') {
      wrongPasswordDialog(sessionId, dialogManager, type, title, text);
    } else if (type == 'input-2fa') {
      enter2FaDialog(sessionId, dialogManager);
    } else if (type == 'input-password') {
      enterPasswordDialog(sessionId, dialogManager);
    } else if (type == 'session-login' || type == 'session-re-login') {
      enterUserLoginDialog(sessionId, dialogManager, 'login_linux_tip', true);
    } else if (type == 'session-login-password') {
      enterUserLoginAndPasswordDialog(
          sessionId, dialogManager, 'login_linux_tip', true);
    } else if (type == 'terminal-admin-login') {
      enterUserLoginDialog(
          sessionId, dialogManager, 'terminal-admin-login-tip', false);
    } else if (type == 'terminal-admin-login-password') {
      enterUserLoginAndPasswordDialog(
          sessionId, dialogManager, 'terminal-admin-login-tip', false);
    } else if (type == 'restarting') {
      showMsgBox(sessionId, type, title, text, link, false, dialogManager,
          hasCancel: false);
    } else if (type == 'wait-remote-accept-nook') {
      showWaitAcceptDialog(sessionId, type, title, text, dialogManager);
    } else if (type == 'on-uac' || type == 'on-foreground-elevated') {
      showOnBlockDialog(sessionId, type, title, text, dialogManager);
    } else if (type == 'wait-uac') {
      showWaitUacDialog(sessionId, dialogManager, type);
    } else if (type == 'elevation-error') {
      showElevationError(sessionId, type, title, text, dialogManager);
    } else if (type == 'relay-hint' || type == 'relay-hint2') {
      showRelayHintDialog(sessionId, type, title, text, dialogManager, peerId);
    } else if (text == kMsgboxTextWaitingForImage) {
      showConnectedWaitingForImage(dialogManager, sessionId, type, title, text);
    } else if (title == 'Privacy mode') {
      final hasRetry = event.hasRetry;
      showPrivacyFailedDialog(
          sessionId, type, title, text, link, hasRetry, dialogManager);
    } else {
      var hasRetry = event.hasRetry;
      if (!hasRetry) {
        hasRetry = shouldAutoRetryOnOffline(type, title, text);
      }
      showMsgBox(sessionId, type, title, text, link, hasRetry, dialogManager);
    }
  }

  void showPeerTrustDialog(
      SessionID sessionId,
      OverlayDialogManager dialogManager,
      SecurityPromptDetails details) {
    final dialogTag = '$sessionId-confirm-peer-trust';
    if (dialogManager.hasDialog(dialogTag)) {
      return;
    }
    final peer = details.peer;
    final peerId = details.peerId;
    final fingerprint = details.fingerprint;
    final trustPhrase = details.trustPhrase;
    final direct = details.direct;
    final controller = TextEditingController();
    String normalizePhrase(String value) =>
        value.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
    final normalizedTrustPhrase = normalizePhrase(trustPhrase);
    final invalidTrustPayload = normalizedTrustPhrase.isEmpty;
    dialogManager.show(
      tag: dialogTag,
      (setState, close, context) {
        final phraseConfirmed = !invalidTrustPayload &&
            normalizePhrase(controller.text) == normalizedTrustPhrase;

        void reject() {
          () async {
            await bind.sessionConfirmDirectTrust(
                sessionId: sessionId, approved: false);
            closeConnection();
            close();
          }();
        }

        void approve() {
          () async {
            await bind.sessionConfirmDirectTrust(
                sessionId: sessionId, approved: true);
            close();
          }();
        }

        Widget buildLine(String label, String value) {
          if (value.isEmpty) {
            return const SizedBox.shrink();
          }
          final baseStyle = Theme.of(context).textTheme.bodyMedium ??
              DefaultTextStyle.of(context).style;
          final valueStyle = label == 'Endpoint'
              ? baseStyle.copyWith(
                  color: Colors.amber.shade700,
                  decoration: TextDecoration.none,
                )
              : baseStyle.copyWith(decoration: TextDecoration.none);
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectionArea(
              child: RichText(
                text: TextSpan(
                  style: baseStyle.copyWith(decoration: TextDecoration.none),
                  children: [
                    TextSpan(
                      text: '$label: ',
                      style: baseStyle.copyWith(
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    TextSpan(text: value, style: valueStyle),
                  ],
                ),
              ),
            ),
          );
        }

        return CustomAlertDialog(
          title: Text(translate('Trust this device')),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                direct
                    ? 'First direct local connection. Approve and remember this device key?'
                    : 'First secure connection for this peer. Approve and remember this device key?',
              ).marginOnly(bottom: 12),
              Text(
                'Compare the trust phrase with the remote device, then type it below to continue.',
              ).marginOnly(bottom: 12),
              buildLine(direct ? 'Endpoint' : 'Peer', peer),
              buildLine('Peer ID', peerId),
              buildLine('Trust phrase', trustPhrase),
              buildLine('Fingerprint', fingerprint),
              if (invalidTrustPayload)
                Text(
                  'The trust information from the remote side is missing or invalid. Reject this connection.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ).marginOnly(bottom: 12),
              TextField(
                controller: controller,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: translate('Type trust phrase'),
                  hintText: trustPhrase,
                ),
              ).marginOnly(top: 8),
            ],
          ),
          actions: [
            dialogButton('Reject', onPressed: reject, isOutline: true),
            dialogButton('Trust', onPressed: phraseConfirmed ? approve : null),
          ],
          onCancel: reject,
        );
      },
    );
  }

  void showPairingPassphraseDialog(
      SessionID sessionId,
      OverlayDialogManager dialogManager,
      SecurityPromptDetails details) {
    final dialogTag = '$sessionId-input-pairing-passphrase';
    if (dialogManager.hasDialog(dialogTag)) {
      return;
    }
    final peer = details.peer;
    final peerId = details.peerId;
    final direct = details.direct;
    final controller = TextEditingController();
    bool obscure = true;
    bool submitting = false;
    dialogManager.show(
      tag: dialogTag,
      (setState, close, context) {
        void cancel() {
          () async {
            await bind.sessionSubmitDirectPairingPassphrase(
              sessionId: sessionId,
              passphrase: '',
              approved: false,
            );
            closeConnection();
            close();
          }();
        }

        void submit() {
          if (submitting || controller.text.isEmpty) {
            return;
          }
          submitting = true;
          () async {
            await bind.sessionSubmitDirectPairingPassphrase(
              sessionId: sessionId,
              passphrase: controller.text,
              approved: true,
            );
            close();
          }();
        }

        Widget buildLine(String label, String value) {
          if (value.isEmpty) {
            return const SizedBox.shrink();
          }
          final baseStyle = Theme.of(context).textTheme.bodyMedium ??
              DefaultTextStyle.of(context).style;
          final valueStyle = label == 'Endpoint'
              ? baseStyle.copyWith(
                  color: Colors.amber.shade700,
                  decoration: TextDecoration.none,
                )
              : baseStyle.copyWith(decoration: TextDecoration.none);
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectionArea(
              child: RichText(
                text: TextSpan(
                  style: baseStyle.copyWith(decoration: TextDecoration.none),
                  children: [
                    TextSpan(
                      text: '$label: ',
                      style: baseStyle.copyWith(
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    TextSpan(text: value, style: valueStyle),
                  ],
                ),
              ),
            ),
          );
        }

        return CustomAlertDialog(
          title: Text(translate(direct
              ? 'Pairing passphrase required'
              : 'Rendezvous pairing passphrase required')),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                direct
                    ? 'Enter the local or rendezvous pairing passphrase to continue this direct connection.'
                    : 'Enter the rendezvous pairing passphrase to continue this connection.',
              ).marginOnly(bottom: 12),
              buildLine(direct ? 'Endpoint' : 'Peer', peer),
              buildLine('Peer ID', peerId),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: obscure,
                autocorrect: false,
                maxLength: bind.mainMaxEncryptLen(),
                selectAllOnFocus: false,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: direct
                      ? 'Pairing passphrase'
                      : 'Rendezvous pairing passphrase',
                  suffixIcon: IconButton(
                    onPressed: () => setState(() {
                      obscure = !obscure;
                    }),
                    icon: Icon(
                      obscure ? Icons.visibility_off : Icons.visibility,
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            dialogButton('Cancel', onPressed: cancel, isOutline: true),
            dialogButton(
              'Continue',
              onPressed: controller.text.isEmpty ? null : submit,
            ),
          ],
          onSubmit: controller.text.isEmpty ? null : submit,
          onCancel: cancel,
        );
      },
    );
  }

  void showPeerIdentityChangedDialog(
      SessionID sessionId, OverlayDialogManager dialogManager, String text) {
    dialogManager.show(
      tag: '$sessionId-peer-identity-changed',
      (setState, close, context) {
        void onClose() {
          closeConnection();
          close();
        }

        void onReset() {
          () async {
            try {
              final ok = bind.sessionResetPeerTrust(sessionId: sessionId);
              if (!ok) {
                showToast('Failed to reset peer trust');
                return;
              }
              close();
              reconnect(dialogManager, sessionId, false);
            } catch (_) {
              showToast('Failed to reset peer trust');
            }
          }();
        }

        return CustomAlertDialog(
          title: Text(translate('Peer identity changed')),
          content: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'The stored device identity no longer matches the remote peer.',
                ).marginOnly(bottom: 12),
                Text(text),
              ],
            ),
          ),
          actions: [
            dialogButton('Close', onPressed: onClose, isOutline: true),
            dialogButton('Reset trust', onPressed: onReset),
          ],
          onCancel: onClose,
        );
      },
    );
  }

  /// Auto-retry check for "Remote desktop is offline" error.
  /// returns true to auto-retry, false otherwise.
  bool shouldAutoRetryOnOffline(
    String type,
    String title,
    String text,
  ) {
    if (type == 'error' &&
        title == 'Connection Error' &&
        text == 'Remote desktop is offline' &&
        _pi.isSet.isTrue) {
      // Auto retry for ~30s (server's peer offline threshold) when controlled peer's account changes
      // (e.g., signout, switch user, login into OS) causes temporary offline via websocket/tcp connection.
      // The actual wait may exceed 30s (e.g., 20s elapsed + 16s next retry = 36s), which is acceptable
      // since the controlled side reconnects quickly after account changes.
      // Uses time-based check instead of _reconnects count because user can manually retry.
      // https://github.com/rustdesk/rustdesk/discussions/14048
      if (_offlineReconnectStartTime == null) {
        // First offline, record time and start retry
        _offlineReconnectStartTime = DateTime.now();
        return true;
      } else {
        final elapsed =
            DateTime.now().difference(_offlineReconnectStartTime!).inSeconds;
        if (elapsed < 30) {
          return true;
        }
      }
    }
    return false;
  }

  void handleToastEvent(ToastSessionEvent event) {
    final duration = Duration(milliseconds: event.durationMs);
    if (event.text.isEmpty) {
      BotToast.showLoading(
        duration: duration,
        clickClose: true,
        allowClick: true,
      );
    } else {
      if (event.type.contains('error')) {
        BotToast.showText(
          contentColor: Colors.red,
          text: translate(event.text),
          duration: duration,
          clickClose: true,
          onlyOne: true,
        );
      } else {
        BotToast.showText(
          text: translate(event.text),
          duration: duration,
          clickClose: true,
          onlyOne: true,
        );
      }
    }
  }

  /// Show a message box with [type], [title] and [text].
  showMsgBox(SessionID sessionId, String type, String title, String text,
      String link, bool hasRetry, OverlayDialogManager dialogManager,
      {bool? hasCancel}) async {
    final noteAllowed = parent.target != null &&
        allowAskForNoteAtEndOfConnection(parent.target, false) &&
        (title == "Connection Error" || type == "restarting");
    final showNoteEdit = noteAllowed && !hasRetry;
    if (showNoteEdit) {
      await showConnEndAuditDialogCloseCanceled(
          ffi: parent.target!, type: type, title: title, text: text);
      closeConnection();
    } else {
      VoidCallback? onSubmit;
      if (noteAllowed && hasRetry) {
        final ffi = parent.target!;
        onSubmit = () async {
          _timer?.cancel();
          _timer = null;
          await showConnEndAuditDialogCloseCanceled(
              ffi: ffi, type: type, title: title, text: text);
          closeConnection();
        };
      }
      msgBox(sessionId, type, title, text, link, dialogManager,
          hasCancel: hasCancel,
          reconnect: hasRetry ? reconnect : null,
          reconnectTimeout: hasRetry ? _reconnects : null,
          onSubmit: onSubmit);
    }
    _timer?.cancel();
    if (hasRetry) {
      _timer = Timer(Duration(seconds: _reconnects), () {
        reconnect(dialogManager, sessionId, false);
      });
      _reconnects *= 2;
    } else {
      _reconnects = 1;
      _offlineReconnectStartTime = null;
    }
  }

  void reconnect(OverlayDialogManager dialogManager, SessionID sessionId,
      bool forceRelay) {
    // Disable relative mouse mode before reconnecting to ensure cursor is released.
    parent.target?.inputModel.setRelativeMouseMode(false);
    bind.sessionReconnect(sessionId: sessionId, forceRelay: forceRelay);
    clearPermissions();
    dialogManager.dismissAll();
    dialogManager.showLoading(translate('Connecting...'),
        onCancel: closeConnection);
  }

  Future<void> showRelayHintDialog(
      SessionID sessionId,
      String type,
      String title,
      String text,
      OverlayDialogManager dialogManager,
      String peerId) async {
    var hint = "\n\n${translate('relay_hint_tip')}";
    if (text.contains("10054") || text.contains("104")) {
      hint = "";
    }
    final text2 = "${translate(text)}$hint";

    if (parent.target != null &&
        allowAskForNoteAtEndOfConnection(parent.target, false) &&
        pi.isSet.isTrue) {
      if (await showConnEndAuditDialogCloseCanceled(
          ffi: parent.target!, type: type, title: title, text: text2)) {
        return;
      }
      closeConnection();
      return;
    }

    dialogManager.show(tag: '$sessionId-$type', (setState, close, context) {
      onClose() {
        closeConnection();
        close();
      }

      final style =
          ElevatedButton.styleFrom(backgroundColor: Colors.green[700]);

      return CustomAlertDialog(
        title: null,
        content: msgboxContent(type, title, text2),
        actions: [
          dialogButton('Close', onPressed: onClose, isOutline: true),
          if (type == 'relay-hint')
            dialogButton('Connect via relay',
                onPressed: () => reconnect(dialogManager, sessionId, true),
                buttonStyle: style,
                isOutline: true),
          dialogButton('Retry',
              onPressed: () => reconnect(dialogManager, sessionId, false)),
          if (type == 'relay-hint2')
            dialogButton('Connect via relay',
                onPressed: () => reconnect(dialogManager, sessionId, true),
                buttonStyle: style),
        ],
        onCancel: onClose,
      );
    });
  }

  void showConnectedWaitingForImage(OverlayDialogManager dialogManager,
      SessionID sessionId, String type, String title, String text) {
    onClose() {
      closeConnection();
    }

    if (waitForFirstImage.isFalse) return;
    dialogManager.show(
      (setState, close, context) => CustomAlertDialog(
          title: null,
          content: SelectionArea(child: msgboxContent(type, title, text)),
          actions: [
            dialogButton("Cancel", onPressed: onClose, isOutline: true)
          ],
          onCancel: onClose),
      tag: '$sessionId-waiting-for-image',
    );
    waitForImageDialogShow.value = true;
    waitForImageTimer = Timer(Duration(milliseconds: 1500), () {
      if (waitForFirstImage.isTrue && !isRefreshing) {
        bind.sessionInputOsPassword(sessionId: sessionId, value: '');
      }
    });
    bind.sessionOnWaitingForImageDialogShow(sessionId: sessionId);
  }

  void showPrivacyFailedDialog(
      SessionID sessionId,
      String type,
      String title,
      String text,
      String link,
      bool hasRetry,
      OverlayDialogManager dialogManager) {
    // There are display changes on the remote side,
    // which will cause some messages to refresh the canvas and dismiss dialogs.
    // So we add a delay here to ensure the dialog is displayed.
    Future.delayed(Duration(milliseconds: 3000), () {
      showMsgBox(sessionId, type, title, text, link, hasRetry, dialogManager);
    });
  }

  _updateSessionWidthHeight(SessionID sessionId) {
    if (_rect == null) return;
    if (_rect!.width <= 0 || _rect!.height <= 0) {
      debugPrintStack(
          label: 'invalid display size (${_rect!.width},${_rect!.height})');
    } else {
      final displays = _pi.getCurDisplays();
      if (displays.length == 1) {
        bind.sessionSetSize(
          sessionId: sessionId,
          display:
              pi.currentDisplay == kAllDisplayValue ? 0 : pi.currentDisplay,
          width: displays[0].width,
          height: displays[0].height,
        );
      } else {
        for (int i = 0; i < displays.length; ++i) {
          bind.sessionSetSize(
            sessionId: sessionId,
            display: i,
            width: displays[i].width,
            height: displays[i].height,
          );
        }
      }
    }
  }

  void _queryAuditGuid(String peerId) async {
    try {
      if (bind.isDisableAccount()) {
        return;
      }
      if (bind
          .sessionGetAuditServerSync(sessionId: sessionId, typ: "conn/active")
          .isEmpty) {
        return;
      }
      if (!mainGetLocalBoolOptionSync(
          kOptionAllowAskForNoteAtEndOfConnection)) {
        return;
      }
      if (bind.sessionGetAuditGuid(sessionId: sessionId).isNotEmpty) {
        debugPrint('Get cached audit GUID');
        return;
      }
      final url = bind.sessionGetAuditServerSync(
          sessionId: sessionId, typ: "conn/active");
      if (url.isEmpty) {
        return;
      }
      final initialConnSessionId =
          bind.sessionGetConnSessionId(sessionId: sessionId);
      final connType = switch (parent.target?.connType) {
        ConnType.defaultConn => 0,
        ConnType.fileTransfer => 1,
        ConnType.portForward => 2,
        ConnType.rdp => 2,
        ConnType.viewCamera => 3,
        ConnType.terminal => 4,
        _ => 0,
      };

      const retryIntervals = [1, 1, 2, 2, 3, 3];

      for (int attempt = 1; attempt <= retryIntervals.length; attempt++) {
        final currentConnSessionId =
            bind.sessionGetConnSessionId(sessionId: sessionId);
        if (currentConnSessionId != initialConnSessionId) {
          debugPrint('connSessionId changed, stopping audit GUID query');
          return;
        }

        final fullUrl =
            '$url?id=$peerId&session_id=$currentConnSessionId&conn_type=$connType';

        debugPrint(
            'Querying audit GUID, attempt $attempt/${retryIntervals.length}');
        try {
          var headers = getHttpHeaders();
          headers['Content-Type'] = "application/json";

          final response = await http.get(
            Uri.parse(fullUrl),
            headers: headers,
          );

          if (response.statusCode == 200) {
            final guid = jsonDecode(response.body) as String?;
            if (guid != null && guid.isNotEmpty) {
              bind.sessionSetAuditGuid(sessionId: sessionId, guid: guid);
              debugPrint('Successfully retrieved audit GUID');
              return;
            }
          } else {
            debugPrint(
                'Failed to query audit GUID. Status: ${response.statusCode}, Body: ${response.body}');
            return;
          }
        } catch (e) {
          debugPrint('Error querying audit GUID (attempt $attempt): $e');
        }

        if (attempt < retryIntervals.length) {
          await Future.delayed(Duration(seconds: retryIntervals[attempt - 1]));
        }
      }

      debugPrint(
          'Failed to retrieve audit GUID after ${retryIntervals.length} attempts');
    } catch (e) {
      debugPrint('Error in _queryAuditGuid: $e');
    }
  }

  Future<void> handlePeerInfoEvent(
      PeerInfoSessionEvent event, String peerId, bool isCache) async {
    parent.target?.chatModel.voiceCallStatus.value = VoiceCallStatus.notStarted;

    _queryAuditGuid(peerId);

    cachedPeerData.peerInfo = Map<String, dynamic>.from(
        event.toLegacyPayload(includeResolutions: false));

    // Recent peer is updated by handle_peer_info(ui_session_interface.rs) --> handle_peer_info(client.rs) --> save_config(client.rs)
    bind.mainLoadRecentPeers();

    parent.target?.dialogManager.dismissAll();
    _pi.version = event.version;
    // Note: Relative mouse mode is NOT auto-enabled on connect.
    // Users must manually enable it via toolbar or keyboard shortcut (Ctrl+Alt+Shift+M).
    //
    // For desktop/webDesktop, keyboard mode initialization is handled later by
    // checkDesktopKeyboardMode() which may change the mode if not supported,
    // followed by updateKeyboardMode() to sync InputModel.keyboardMode.
    // For mobile, updateKeyboardMode() is currently a no-op (only executes on desktop/web),
    // but we call it here for consistency and future-proofing.
    if (isMobile) {
      parent.target?.inputModel.updateKeyboardMode();
    }
    _pi.isSupportMultiUiSession =
        bind.isSupportMultiUiSession(version: _pi.version);
    _pi.username = event.username;
    _pi.hostname = event.hostname;
    _pi.platform = event.platform;
    _pi.sasEnabled = event.sasEnabled;
    final currentDisplay = event.currentDisplay;
    if (_pi.primaryDisplay == kInvalidDisplayIndex) {
      _pi.primaryDisplay = currentDisplay;
    }

    if (bind.peerGetSessionsCount(
            id: peerId, connType: parent.target!.connType.index) <=
        1) {
      _pi.currentDisplay = currentDisplay;
    }

    try {
      CurrentDisplayState.find(peerId).value = _pi.currentDisplay;
    } catch (e) {
      //
    }

    final connType = parent.target?.connType;
    if (isPeerAndroid) {
      _touchMode = true;
    } else {
      // `kOptionTouchMode` is originally peer option, but it is moved to local option later.
      // We check local option first, if not set, then check peer option.
      // Because if local option is not empty:
      // 1. User has set the touch mode explicitly.
      // 2. The advanced option (custom client) is set.
      //    Then we choose to use the local option.
      final optLocal = remoteAppLocalSettings.read(
        RemoteAppLocalSettingsRegistry.touchMode,
      );
      final optLocalRaw = remoteAppLocalSettings.readRaw(
        RemoteAppLocalSettingsRegistry.touchMode,
      );
      if (optLocalRaw.isNotEmpty) {
        _touchMode = optLocal;
      } else {
        final settings = SessionPeerSettingsRepository.forSession(sessionId);
        _touchMode =
            (await settings.readRaw(
              SessionPeerSettingsRegistry.legacyTouchMode,
            )).isNotEmpty;
      }
    }
    if (isMobile) {
      virtualMouseMode.loadOptions();
    }
    if (connType == ConnType.fileTransfer) {
      parent.target?.fileModel.onReady();
    } else if (connType == ConnType.terminal) {
      // Call onReady on all registered terminal models
      final models = parent.target?._terminalModels.values ?? [];
      for (final model in models) {
        model.onReady();
      }
    } else if (connType == ConnType.defaultConn ||
        connType == ConnType.viewCamera) {
      final displays = event.displays;
      final newDisplays = [
        for (final display in displays) _displayFromSessionValue(display),
      ];
      _pi.displays.value = newDisplays;
      _pi.displaysCount.value = _pi.displays.length;
      if (_pi.currentDisplay < _pi.displays.length) {
        // now replaced to _updateCurDisplay
        await updateCurDisplay(sessionId);
      }
      if (displays.isNotEmpty) {
        _reconnects = 1;
        _offlineReconnectStartTime = null;
        waitForFirstImage.value = true;
        isRefreshing = false;
      }
      _pi.features.privacyMode = event.features.privacyMode;
      _pi.features.keyboardV2CommittedText =
          event.features.keyboardV2CommittedText;
      _pi.features.keyboardV2PhysicalKey =
          event.features.keyboardV2PhysicalKey;
      _pi.features.keyboardV2LayoutAwareText =
          event.features.keyboardV2LayoutAwareText;
      if (!isCache) {
        _applyResolutionValues(event.resolutions);
      }
      parent.target?.elevationModel.onPeerInfo(_pi);
    }
    if (connType == ConnType.defaultConn) {
      final liveSettings = LiveSessionSettingsRepository.forSession(sessionId);
      setViewOnly(
        peerId,
        liveSettings.readSync(LiveSessionSettingsRegistry.viewOnly),
      );
      setShowMyCursor(
        liveSettings.readSync(LiveSessionSettingsRegistry.showMyCursor),
      );
    }
    if (connType == ConnType.defaultConn || connType == ConnType.viewCamera) {
      _pi.platformAdditions =
          Map<String, dynamic>.from(event.platformAdditions);
    }

    _pi.isSet.value = true;
    stateGlobal.resetLastResolutionGroupValues(peerId);

    if (isDesktop || isWebDesktop) {
      // checkDesktopKeyboardMode may change the keyboard mode if the current
      // mode is not supported. Re-sync InputModel.keyboardMode afterwards.
      // Note: updateKeyboardMode() is a no-op on mobile (early-returns).
      await checkDesktopKeyboardMode();
      await parent.target?.inputModel.updateKeyboardMode();
    }

    notifyListeners();

    if (!isCache) {
      final onAuthenticated = parent.target?.onAuthenticated;
      if (onAuthenticated != null) {
        _authenticatedHandoffPeerInfoReady = true;
        _authenticatedHandoffFallbackTimer?.cancel();
        _authenticatedHandoffFallbackTimer =
            Timer(const Duration(milliseconds: 500), () {
          _tryNotifyAuthenticatedHandoff(
            peerId,
            allowPartialSnapshot: true,
          );
        });
        _tryNotifyAuthenticatedHandoff(peerId);
      } else {
        tryUseAllMyDisplaysForTheRemoteSession(peerId);
      }
    }
  }

  checkDesktopKeyboardMode() async {
    if (isInputSourceFlutter) {
      // Local side, flutter keyboard input source
      // Currently only map mode is supported, legacy mode is used for compatibility.
      for (final mode in [kKeyMapMode, kKeyLegacyMode]) {
        if (bind.sessionIsKeyboardModeSupported(
            sessionId: sessionId, mode: mode)) {
          await bind.sessionSetKeyboardMode(sessionId: sessionId, value: mode);
          break;
        }
      }
    } else {
      final curMode = await bind.sessionGetKeyboardMode(sessionId: sessionId);
      if (curMode != null) {
        if (bind.sessionIsKeyboardModeSupported(
            sessionId: sessionId, mode: curMode)) {
          return;
        }
      }

      // If current keyboard mode is not supported, change to another one.
      for (final mode in [kKeyMapMode, kKeyTranslateMode, kKeyLegacyMode]) {
        if (bind.sessionIsKeyboardModeSupported(
            sessionId: sessionId, mode: mode)) {
          bind.sessionSetKeyboardMode(sessionId: sessionId, value: mode);
          break;
        }
      }
    }
  }

  tryUseAllMyDisplaysForTheRemoteSession(String peerId) async {
    if (bind.sessionGetUseAllMyDisplaysForTheRemoteSession(
            sessionId: sessionId) !=
        'Y') {
      return;
    }

    if (!_pi.isSupportMultiDisplay || _pi.displays.length <= 1) {
      return;
    }

    final screenRectList = await getScreenRectList();
    if (screenRectList.length <= 1) {
      return;
    }

    // to-do: peer currentDisplay is the primary display, but the primary display may not be the first display.
    // local primary display also may not be the first display.
    //
    // 0 is assumed to be the primary display here, for now.

    // move to the first display and set fullscreen
    bind.sessionSwitchDisplay(
      isDesktop: isDesktop,
      sessionId: sessionId,
      value: Int32List.fromList([0]),
    );
    _pi.currentDisplay = 0;
    try {
      CurrentDisplayState.find(peerId).value = _pi.currentDisplay;
    } catch (e) {
      //
    }
    await tryMoveToScreenAndSetFullscreen(
      screenRectList[0],
      targetWindowId: parent.target?.hostWindowId,
    );

    final length = _pi.displays.length < screenRectList.length
        ? _pi.displays.length
        : screenRectList.length;
    for (var i = 1; i < length; i++) {
      openMonitorInNewTabOrWindow(
        i,
        peerId,
        _pi,
        screenRect: screenRectList[i],
        sourceWindowId: parent.target?.hostWindowId,
        sourceSessionId: sessionId.toString(),
      );
    }
  }

  tryShowAndroidActionsOverlay({int delayMSecs = 10}) {
    if (isPeerAndroid) {
      if (parent.target?.connType == ConnType.defaultConn &&
          parent.target != null &&
          parent.target!.ffiModel.permissions['keyboard'] != false) {
        Timer(Duration(milliseconds: delayMSecs), () {
          if (parent.target!.dialogManager.mobileActionsOverlayVisible.isTrue) {
            parent.target!.dialogManager
                .showMobileActionsOverlay(ffi: parent.target!);
          }
        });
      }
    }
  }

  void _applyResolutionValues(List<SessionResolutionValue> values) {
    final resolutions = [
      for (final value in values) Resolution(value.width, value.height),
    ]..sort((a, b) {
        final widthOrder = b.width.compareTo(a.width);
        return widthOrder != 0 ? widthOrder : b.height.compareTo(a.height);
      });
    _pi.resolutions = resolutions;
  }

  Display _displayFromSessionValue(SessionDisplayValue value) {
    final display = Display();
    display.x = value.x ?? display.x;
    display.y = value.y ?? display.y;
    display.width = value.width ?? display.width;
    display.height = value.height ?? display.height;
    display.cursorEmbedded = value.cursorEmbedded;
    display.originalWidth = value.originalWidth ?? kInvalidResolutionValue;
    display.originalHeight = value.originalHeight ?? kInvalidResolutionValue;
    display._scale = 1.0;
    final scaledWidth = value.scaledWidth;
    if (scaledWidth != null) {
      if (scaledWidth > 0 && display.width > 0) {
        display._scale = max(display.width.toDouble() / scaledWidth, 1.0);
      } else {
        debugPrint(
            'Invalid scaled_width ($scaledWidth) or width (${display.width}), using default scale 1.0');
      }
    }
    return display;
  }

  void updateLastCursorIdValue(String id) {
    parent.target?.cursorModel.id = id;
  }

  void handleCursorIdEvent(CursorIdSessionEvent event) {
    final payload = event.toLegacyPayload();
    cachedPeerData.lastCursorId = payload;
    parent.target?.cursorModel.updateCursorIdValue(event.id);
  }

  Future<void> handleCursorShapeEvent(
    CursorShapeSessionEvent event, {
    String? peerId,
  }) async {
    cachedPeerData.cursorDataList.add(event.toLegacyPayload());
    await parent.target?.cursorModel.updateCursorShape(event);
    if (peerId != null) {
      _tryNotifyAuthenticatedHandoff(peerId);
    }
  }

  Future<void> handleSyncPeerInfoEvent(
      SyncPeerInfoSessionEvent event,
      SessionID sessionId,
      String peerId) async {
    final displayValues = event.displays;
    if (displayValues != null) {
      cachedPeerData.peerInfo['displays'] = jsonEncode([
        for (final display in displayValues) display.toLegacyMap(),
      ]);
      final newDisplays = [
        for (final display in displayValues)
          _displayFromSessionValue(display),
      ];
      _pi.displays.value = newDisplays;
      _pi.displaysCount.value = _pi.displays.length;

      if (_pi.currentDisplay == kAllDisplayValue) {
        await updateCurDisplay(sessionId);
        // to-do: What if the displays are changed?
      } else {
        if (_pi.currentDisplay >= 0 &&
            _pi.currentDisplay < _pi.displays.length) {
          await updateCurDisplay(sessionId);
        } else {
          if (_pi.displays.isNotEmpty) {
            // Notify to switch display
            msgBox(sessionId, 'custom-nook-nocancel-hasclose-info', 'Prompt',
                'display_is_plugged_out_msg', '', parent.target!.dialogManager);
            final isPeerPrimaryDisplayValid =
                pi.primaryDisplay == kInvalidDisplayIndex ||
                    pi.primaryDisplay >= pi.displays.length;
            final newDisplay =
                isPeerPrimaryDisplayValid ? 0 : pi.primaryDisplay;
            bind.sessionSwitchDisplay(
              isDesktop: isDesktop,
              sessionId: sessionId,
              value: Int32List.fromList([newDisplay]),
            );

            if (_pi.isSupportMultiUiSession) {
              // If the peer supports multi-ui-session, no switch display message will be send back.
              // We need to update the display manually.
              switchToNewDisplay(newDisplay, sessionId, peerId);
            }
          } else {
            msgBox(sessionId, 'nocancel-error', 'Prompt', 'No Displays', '',
                parent.target!.dialogManager);
          }
        }
      }
    }
    parent.target!.canvasModel
        .tryUpdateScrollStyle(Duration(milliseconds: 300), null);
    notifyListeners();
  }

  void handlePlatformAdditionsEvent(
      SyncPlatformAdditionsSessionEvent event) {
    if (event.clearVirtualDisplays) {
      _pi.platformAdditions.remove(kPlatformAdditionsRustDeskVirtualDisplays);
      _pi.platformAdditions.remove(kPlatformAdditionsAmyuniVirtualDisplays);
    } else {
      for (final entry in event.updates.entries) {
        _pi.platformAdditions[entry.key] = entry.value;
      }
      if (!event.updates
          .containsKey(kPlatformAdditionsRustDeskVirtualDisplays)) {
        _pi.platformAdditions
            .remove(kPlatformAdditionsRustDeskVirtualDisplays);
      }
      if (!event.updates
          .containsKey(kPlatformAdditionsAmyuniVirtualDisplays)) {
        _pi.platformAdditions.remove(kPlatformAdditionsAmyuniVirtualDisplays);
      }
    }

    cachedPeerData.peerInfo['platform_additions'] =
        json.encode(_pi.platformAdditions);
  }

  Future<void> handleFollowCurrentDisplayValue(
    int? displayIndex,
    SessionID sessionId,
    String peerId,
  ) async {
    if (displayIndex != null) {
      if (pi.currentDisplay == kAllDisplayValue) {
        return;
      }
      _pi.currentDisplay = displayIndex;
      try {
        CurrentDisplayState.find(peerId).value = _pi.currentDisplay;
      } catch (e) {
        //
      }
      bind.sessionSwitchDisplay(
        isDesktop: isDesktop,
        sessionId: sessionId,
        value: Int32List.fromList([_pi.currentDisplay]),
      );
    }
    notifyListeners();
  }

  // Directly switch to the new display without waiting for the response.
  switchToNewDisplay(int display, SessionID sessionId, String peerId,
      {bool updateCursorPos = false}) {
    // no need to wait for the response
    pi.currentDisplay = display;
    updateCurDisplay(sessionId, updateCursorPos: updateCursorPos);
    try {
      CurrentDisplayState.find(peerId).value = display;
    } catch (e) {
      //
    }
  }

  void updateBlockInputStateValue(bool enabled, String peerId) {
    _inputBlocked = enabled;
    notifyListeners();
    try {
      BlockInputState.find(peerId).value = enabled;
    } catch (e) {
      //
    }
  }

  Future<void> updatePrivacyModeSignal(
    SessionID sessionId,
    String peerId,
  ) async {
    notifyListeners();
    try {
      final isOn = LiveSessionSettingsRepository.forSession(
        sessionId,
      ).readSync(LiveSessionSettingsRegistry.privacyMode);
      if (isOn) {
        final settings = SessionPeerSettingsRepository.forSession(sessionId);
        var privacyModeImpl = await settings.read(
          SessionPeerSettingsRegistry.privacyModeImplementation,
        );
        // For compatibility, version < 1.2.4, the default value is 'privacy_mode_impl_mag'.
        final initDefaultPrivacyMode = 'privacy_mode_impl_mag';
        PrivacyModeState.find(peerId).value =
            privacyModeImpl.isEmpty ? initDefaultPrivacyMode : privacyModeImpl;
      } else {
        PrivacyModeState.find(peerId).value = '';
      }
    } catch (e) {
      //
    }
  }

  void setViewOnly(String id, bool value) {
    if (versionCmp(_pi.version, '1.2.0') < 0) return;
    // tmp fix for https://github.com/rustdesk/rustdesk/pull/3706#issuecomment-1481242389
    // because below rx not used in mobile version, so not initialized, below code will cause crash
    // current our flutter code quality is fucking shit now. !!!!!!!!!!!!!!!!
    try {
      if (value) {
        ShowRemoteCursorState.find(id).value = value;
      } else {
        ShowRemoteCursorState.find(id).value =
            LiveSessionSettingsRepository.forSession(sessionId).readSync(
          LiveSessionSettingsRegistry.showRemoteCursor,
        );
      }
    } catch (e) {
      //
    }
    if (_viewOnly != value) {
      _viewOnly = value;
      notifyListeners();
    }
  }

  void setShowMyCursor(bool value) {
    if (_showMyCursor != value) {
      _showMyCursor = value;
      notifyListeners();
    }
  }
}

class VirtualMouseMode with ChangeNotifier {
  bool _showVirtualMouse = false;
  double _virtualMouseScale = 1.0;
  bool _showVirtualJoystick = false;

  bool get showVirtualMouse => _showVirtualMouse;
  double get virtualMouseScale => _virtualMouseScale;
  bool get showVirtualJoystick => _showVirtualJoystick;

  FfiModel ffiModel;

  VirtualMouseMode(this.ffiModel);

  bool _shouldShow() => !ffiModel.isPeerAndroid;

  setShowVirtualMouse(bool b) {
    if (b == _showVirtualMouse) return;
    if (_shouldShow()) {
      _showVirtualMouse = b;
      notifyListeners();
    }
  }

  setVirtualMouseScale(double s) {
    if (s <= 0) return;
    if (s == _virtualMouseScale) return;
    _virtualMouseScale = s;
    unawaited(
      remoteAppLocalSettings.write(
        RemoteAppLocalSettingsRegistry.virtualMouseScale,
        s,
      ),
    );
    notifyListeners();
  }

  setShowVirtualJoystick(bool b) {
    if (b == _showVirtualJoystick) return;
    if (_shouldShow()) {
      _showVirtualJoystick = b;
      notifyListeners();
    }
  }

  void loadOptions() {
    _showVirtualMouse = remoteAppLocalSettings.read(
      RemoteAppLocalSettingsRegistry.showVirtualMouse,
    );
    _virtualMouseScale = remoteAppLocalSettings.read(
      RemoteAppLocalSettingsRegistry.virtualMouseScale,
    );
    _showVirtualJoystick = remoteAppLocalSettings.read(
      RemoteAppLocalSettingsRegistry.showVirtualJoystick,
    );
    notifyListeners();
  }

  Future<void> toggleVirtualMouse() async {
    final value = !showVirtualMouse;
    await remoteAppLocalSettings.write(
      RemoteAppLocalSettingsRegistry.showVirtualMouse,
      value,
    );
    setShowVirtualMouse(value);
  }

  Future<void> toggleVirtualJoystick() async {
    final value = !showVirtualJoystick;
    await remoteAppLocalSettings.write(
      RemoteAppLocalSettingsRegistry.showVirtualJoystick,
      value,
    );
    setShowVirtualJoystick(value);
  }
}

Size? remoteRenderableFrameSize({
  required Size? softwareFrameSize,
  required bool androidTextureActive,
  required Size? androidTextureFrameSize,
}) {
  if (androidTextureActive &&
      androidTextureFrameSize != null &&
      androidTextureFrameSize.width > 0 &&
      androidTextureFrameSize.height > 0) {
    return androidTextureFrameSize;
  }
  if (softwareFrameSize != null &&
      softwareFrameSize.width > 0 &&
      softwareFrameSize.height > 0) {
    return softwareFrameSize;
  }
  return null;
}

class ImageModel with ChangeNotifier {
  ui.Image? _image;

  ui.Image? get image => _image;

  String id = '';

  late final SessionID sessionId;

  bool _useTextureRender = false;
  late final AndroidRenderTargetController _androidRenderTarget;
  bool _interactionGeometryInitialized = false;

  WeakReference<FFI> parent;

  final List<Function(String)> callbacksOnFirstImage = [];

  ImageModel(this.parent) {
    sessionId = parent.target!.sessionId;
    _androidRenderTarget = AndroidRenderTargetController(
      create: (target) => platformFFI.createAndroidRemoteVideoTexture(
        display: target.display,
        width: target.width,
        height: target.height,
      ),
      release: (target, textureId) =>
          platformFFI.releaseAndroidRemoteVideoTexture(
        display: target.display,
        textureId: textureId,
      ),
      refresh: (display) =>
          bind.sessionRefresh(sessionId: sessionId, display: display),
      onChanged: notifyListeners,
      onError: (error, stackTrace) {
        debugPrint('Android render target failed: $error\n$stackTrace');
      },
    );
  }

  get useTextureRender => _useTextureRender;
  AndroidRenderTargetSnapshot get androidRenderTarget =>
      _androidRenderTarget.snapshot;
  int get androidRenderTargetEpoch => _androidRenderTarget.intentEpoch;
  get androidSurfaceTextureActive =>
      _androidRenderTarget.snapshot.canRenderTexture;
  Size? get renderFrameSize => remoteRenderableFrameSize(
        softwareFrameSize: _image == null
            ? null
            : Size(_image!.width.toDouble(), _image!.height.toDouble()),
        androidTextureActive: _androidRenderTarget.snapshot.canRenderTexture &&
            _androidRenderTarget.snapshot.target?.display ==
                parent.target?.ffiModel.pi.currentDisplay,
        androidTextureFrameSize: _androidRenderTarget.snapshot.target == null
            ? null
            : Size(
                _androidRenderTarget.snapshot.target!.width.toDouble(),
                _androidRenderTarget.snapshot.target!.height.toDouble(),
              ),
      );
  bool get hasRenderableFrame => renderFrameSize != null;

  addCallbackOnFirstImage(Function(String) cb) => callbacksOnFirstImage.add(cb);

  void clearImage() => _publishImage(null);

  void _publishImage(ui.Image? image) {
    final previous = _image;
    if (identical(previous, image)) return;
    _image = image;
    notifyListeners();
    if (previous != null) {
      SchedulerBinding.instance.addPostFrameCallback(
        (_) => previous.dispose(),
      );
    }
  }

  bool _webDecodingRgba = false;
  final List<Uint8List> _webRgbaList = List.empty(growable: true);
  webOnRgba(int display, Uint8List rgba) async {
    // deep copy needed, otherwise "instantiateCodec failed: TypeError: Cannot perform Construct on a detached ArrayBuffer"
    _webRgbaList.add(Uint8List.fromList(rgba));
    if (_webDecodingRgba) {
      return;
    }
    _webDecodingRgba = true;
    try {
      while (_webRgbaList.isNotEmpty) {
        final rgba2 = _webRgbaList.last;
        _webRgbaList.clear();
        await decodeAndUpdate(display, rgba2);
      }
    } catch (e) {
      debugPrint('onRgba error: $e');
    }
    _webDecodingRgba = false;
  }

  onRgba(int display, Uint8List rgba) async {
    try {
      await decodeAndUpdate(display, rgba);
    } catch (e) {
      debugPrint('onRgba error: $e');
    }
    platformFFI.nextRgba(sessionId, display);
  }

  decodeAndUpdate(int display, Uint8List rgba) async {
    final pid = parent.target?.id;
    final rect = parent.target?.ffiModel.pi.getDisplayRect(display);
    final image = await img.decodeImageFromPixels(
      rgba,
      rect?.width.toInt() ?? 0,
      rect?.height.toInt() ?? 0,
      isWeb | isWindows | isLinux
          ? ui.PixelFormat.rgba8888
          : ui.PixelFormat.bgra8888,
    );
    if (parent.target?.id != pid) return;
    await update(image);
  }

  update(ui.Image? image) async {
    if (!_interactionGeometryInitialized && image != null) {
      if (isDesktop || isWebDesktop) {
        await parent.target?.canvasModel.updateViewStyle();
        await parent.target?.canvasModel.updateScrollStyle();
        await parent.target?.canvasModel.initializeEdgeScrollEdgeThickness();
      }
      await _ensureInteractionGeometry();
    }
    if (image == null) {
      _publishImage(null);
      await _androidRenderTarget.retire();
      _interactionGeometryInitialized = false;
    } else {
      parent.target?.canvasModel.tryApplyPendingMobileCursorFocus();
      _publishImage(image);
    }
  }

  Future<void> onAndroidSurfaceTextureFrame(int display, bool active) async {
    if (!active) {
      setAndroidSurfaceTextureActive(false);
      return;
    }
    final ffi = parent.target;
    if (ffi == null || ffi.ffiModel.pi.currentDisplay != display) {
      return;
    }
    final rect = ffi.ffiModel.pi.getDisplayRect(display);
    if (rect == null || rect.width <= 0 || rect.height <= 0) {
      return;
    }
    final target = _androidRenderTarget.snapshot.target;
    if (_androidRenderTarget.snapshot.phase != AndroidRenderTargetPhase.ready ||
        target == null ||
        target.display != display ||
        target.width != rect.width.toInt() ||
        target.height != rect.height.toInt()) {
      return;
    }
    await _ensureInteractionGeometry();
    final changed = _androidRenderTarget.producerFrame(
      display: display,
      width: rect.width.toInt(),
      height: rect.height.toInt(),
      active: true,
    );
    if (!changed) return;
    ffi.canvasModel.tryApplyPendingMobileCursorFocus();
  }

  Future<void> _ensureInteractionGeometry() async {
    if (_interactionGeometryInitialized) return;
    final ffi = parent.target;
    if (ffi == null) return;
    _interactionGeometryInitialized = true;
    await initializeCursorAndCanvas(ffi);
  }

  // mobile only
  double get maxScale {
    final frameSize = renderFrameSize;
    if (frameSize == null) return 1.5;
    final size = parent.target!.canvasModel.getSize();
    final xscale = size.width / frameSize.width;
    final yscale = size.height / frameSize.height;
    return max(1.5, max(xscale, yscale));
  }

  // mobile only
  double get minScale {
    final frameSize = renderFrameSize;
    if (frameSize == null) return 1.5;
    final size = parent.target!.canvasModel.getSize();
    final xscale = size.width / frameSize.width;
    final yscale = size.height / frameSize.height;
    return min(xscale, yscale) / 1.5;
  }

  updateUserTextureRender() {
    final preValue = _useTextureRender;
    _useTextureRender =
        (isDesktop || isAndroid) && bind.mainGetUseTextureRender();
    if (!_useTextureRender) {
      unawaited(_androidRenderTarget.retire());
    }
    if (preValue != _useTextureRender) {
      notifyListeners();
    }
  }

  setUseTextureRender(bool value) {
    _useTextureRender = value;
    if (!value) {
      unawaited(_androidRenderTarget.retire());
    }
    notifyListeners();
  }

  setAndroidSurfaceTextureActive(bool value) {
    if (!value) {
      _androidRenderTarget.producerFrame(
        display: -1,
        width: 0,
        height: 0,
        active: false,
      );
    }
  }

  Future<void> requireAndroidTextureTarget(
    AndroidTextureTarget? target, {
    int? intentEpoch,
  }) =>
      target == null
          ? _androidRenderTarget.retire(intentEpoch: intentEpoch)
          : _androidRenderTarget.requireTarget(
              target,
              intentEpoch: intentEpoch,
            );

  void disposeImage() {
    _publishImage(null);
    unawaited(_androidRenderTarget.retire());
    _interactionGeometryInitialized = false;
  }
}

enum ScrollStyle {
  scrollbar(kRemoteScrollStyleBar),
  scrollauto(kRemoteScrollStyleAuto),
  scrolledge(kRemoteScrollStyleEdge),
  scrolledgeaccel(kRemoteScrollStyleEdgeAcceleration);

  const ScrollStyle(this.stringValue);

  final String stringValue;

  String toJson() {
    return name;
  }

  static ScrollStyle fromJson(String json, [ScrollStyle? fallbackValue]) {
    switch (json) {
      case 'scrollbar':
        return scrollbar;
      case 'scrollauto':
        return scrollauto;
      case 'scrolledge':
        return scrolledge;
      case 'scrolledgeaccel':
        return scrolledgeaccel;
    }

    if (fallbackValue != null) {
      return fallbackValue;
    }

    throw ArgumentError("Unknown ScrollStyle JSON value: '$json'");
  }

  @override
  String toString() {
    return stringValue;
  }

  static ScrollStyle fromString(String string, [ScrollStyle? fallbackValue]) {
    switch (string) {
      case kRemoteScrollStyleBar:
        return scrollbar;
      case kRemoteScrollStyleAuto:
        return scrollauto;
      case kRemoteScrollStyleEdge:
        return scrolledge;
      case kRemoteScrollStyleEdgeAcceleration:
        return scrolledgeaccel;
    }

    if (fallbackValue != null) {
      return fallbackValue;
    }

    throw ArgumentError("Unknown ScrollStyle string value: '$string'");
  }
}

class ViewStyle {
  final String style;
  final double width;
  final double height;
  final int displayWidth;
  final int displayHeight;
  ViewStyle({
    required this.style,
    required this.width,
    required this.height,
    required this.displayWidth,
    required this.displayHeight,
  });

  static defaultViewStyle() {
    final desktop = (isDesktop || isWebDesktop);
    final w =
        desktop ? kDesktopDefaultDisplayWidth : kMobileDefaultDisplayWidth;
    final h =
        desktop ? kDesktopDefaultDisplayHeight : kMobileDefaultDisplayHeight;
    return ViewStyle(
      style: '',
      width: w.toDouble(),
      height: h.toDouble(),
      displayWidth: w,
      displayHeight: h,
    );
  }

  static int _double2Int(double v) => (v * 100).round().toInt();

  @override
  bool operator ==(Object other) =>
      other is ViewStyle &&
      other.runtimeType == runtimeType &&
      _innerEqual(other);

  bool _innerEqual(ViewStyle other) {
    return style == other.style &&
        ViewStyle._double2Int(other.width) == ViewStyle._double2Int(width) &&
        ViewStyle._double2Int(other.height) == ViewStyle._double2Int(height) &&
        other.displayWidth == displayWidth &&
        other.displayHeight == displayHeight;
  }

  @override
  int get hashCode => Object.hash(
        style,
        ViewStyle._double2Int(width),
        ViewStyle._double2Int(height),
        displayWidth,
        displayHeight,
      ).hashCode;

  double get scale {
    double s = 1.0;
    if (style == kRemoteViewStyleAdaptive) {
      if (width != 0 &&
          height != 0 &&
          displayWidth != 0 &&
          displayHeight != 0) {
        final s1 = width / displayWidth;
        final s2 = height / displayHeight;
        s = s1 < s2 ? s1 : s2;
      }
    } else if (style == kRemoteViewStyleCustom) {
      // Custom scale is session-scoped and applied in CanvasModel.updateViewStyle()
    }
    return s;
  }
}

enum EdgeScrollState {
  inactive,
  armed,
  active,
}

enum MobileCursorFocusRequest {
  initialReveal,
  center,
}

class EdgeScrollFallbackState {
  final CanvasModel _owner;
  static const double _kEdgeAccelerationMaxSpeedPxPerSecond = 1800.0;

  late Ticker _ticker;

  Duration _lastTotalElapsed = Duration.zero;
  bool _nextEventIsFirst = true;
  Vector2 _encroachment = Vector2.zero();
  Vector2 _edgeAccelerationFactor = Vector2.zero();

  EdgeScrollFallbackState(this._owner, TickerProvider tickerProvider) {
    _ticker = tickerProvider.createTicker(emitTick);
  }

  void setEncroachment(Vector2 encroachment) {
    _encroachment = encroachment;
  }

  void setEdgeAccelerationFactor(Vector2 factor) {
    _edgeAccelerationFactor = factor;
  }

  void emitTick(Duration totalElapsed) {
    if (_nextEventIsFirst) {
      _lastTotalElapsed = totalElapsed;
      _nextEventIsFirst = false;
    } else {
      final thisTickElapsed = totalElapsed - _lastTotalElapsed;
      if (_owner._usesEdgeAcceleration) {
        final seconds =
            thisTickElapsed.inMicroseconds / Duration.microsecondsPerSecond;
        final delta = _edgeAccelerationFactor *
            (_kEdgeAccelerationMaxSpeedPxPerSecond * seconds);
        if (!_owner.performEdgeScroll(delta)) {
          stop();
        } else if (!_owner._usesMobileRemoteViewport) {
          // Desktop scroll containers need their pointer position remapped.
          // On mobile this would move the peer cursor while only the viewport
          // is supposed to move, and can clamp it to a remote-screen corner.
          _owner.syncRemoteCursorAfterViewportScroll();
        }
      } else {
        const double kFrameTime = 1000.0 / 60.0;
        const double kSpeedFactor = 0.1;

        var delta = _encroachment *
            (kSpeedFactor * thisTickElapsed.inMilliseconds / kFrameTime);

        final moved = _owner.performEdgeScroll(delta);
        if (_owner._usesMobileRemoteViewport && !moved) {
          stop();
        }
      }

      _lastTotalElapsed = totalElapsed;
    }
  }

  void start() {
    if (!_ticker.isActive) {
      _nextEventIsFirst = true;
      _ticker.start();
    }
  }

  void stop() {
    _ticker.stop();
  }

  void dispose() {
    _ticker.dispose();
  }
}

class CanvasModel with ChangeNotifier {
  static const double _kEdgeAccelerationMinFactor = 0.0;
  static const double _kEdgeAccelerationMaxFactor = 1.0;

  // image offset of canvas
  double _x = 0;
  // image offset of canvas
  double _y = 0;
  // image scale
  double _scale = 1.0;
  double _devicePixelRatio = 1.0;
  Size _size = Size.zero;
  // the tabbar over the image
  // double tabBarHeight = 0.0;
  // the window border's width
  // double windowBorderWidth = 0.0;
  // remote id
  String id = '';
  late final SessionID sessionId;
  // scroll offset x percent
  double _scrollX = 0.0;
  // scroll offset y percent
  double _scrollY = 0.0;
  ScrollStyle _scrollStyle = ScrollStyle.scrollauto;
  // edge scroll mode: trigger scrolling when the cursor is close to the edge of the view
  int _edgeScrollEdgeThickness = 100;
  // tracks whether edge scroll should be active, prevents spurious
  // scrolling when the cursor enters the view from outside
  EdgeScrollState _edgeScrollState = EdgeScrollState.inactive;
  // fallback strategy for when Bump Mouse isn't available
  late EdgeScrollFallbackState _edgeScrollFallbackState;
  bool _edgeScrollFallbackInitialized = false;
  // to avoid hammering a non-functional Bump Mouse
  bool _bumpMouseIsWorking = true;
  bool _mobileSelectionEdgeScrollActive = false;
  ViewStyle _lastViewStyle = ViewStyle.defaultViewStyle();
  MobileRemoteViewScaleMode _mobileViewScaleMode =
      kDefaultMobileRemoteViewScaleMode;
  bool _mobileFitPending = true;
  MobileCursorFocusRequest? _mobileCursorFocusRequest =
      MobileCursorFocusRequest.initialReveal;
  bool _mobileCursorFocusDisplaySwitchAttempted = false;

  Timer? _timerMobileFocusCanvasCursor;
  Timer? _timerMobileRestoreCanvasOffset;
  Offset? _offsetBeforeMobileSoftKeyboard;
  double? _scaleBeforeMobileSoftKeyboard;

  // `isMobileCanvasChanged` is used to avoid canvas reset when changing the input method
  // after showing the soft keyboard.
  bool isMobileCanvasChanged = false;

  final ScrollController _horizontal = ScrollController();
  final ScrollController _vertical = ScrollController();

  final _imageOverflow = false.obs;

  WeakReference<FFI> parent;

  CanvasModel(this.parent) {
    sessionId = parent.target!.sessionId;
  }

  double get x => _x;
  double get y => _y;
  double get scale => _scale;
  double get devicePixelRatio => _devicePixelRatio;
  Size get size => _size;
  ScrollStyle get scrollStyle => _scrollStyle;
  int get edgeScrollEdgeThickness => _edgeScrollEdgeThickness;
  ViewStyle get viewStyle => _lastViewStyle;
  MobileRemoteViewScaleMode get mobileViewScaleMode => _mobileViewScaleMode;
  RxBool get imageOverflow => _imageOverflow;
  bool get _usesMobileRemoteViewport =>
      isMobileClient && parent.target?.connType == ConnType.defaultConn;
  bool get _usesMobileEdgeScroll =>
      _usesMobileRemoteViewport &&
      (_scrollStyle == ScrollStyle.scrolledge ||
          _scrollStyle == ScrollStyle.scrolledgeaccel);
  MobileRemoteScrollDirections get mobileViewportScrollDirections {
    if (!_usesMobileRemoteViewport) {
      return MobileRemoteScrollDirections.all;
    }
    return mobileRemoteScrollDirections(
      canvasOffset: Offset(_x, _y + getAdjustY()),
      texture: _mobileTextureSize(),
      viewport: size,
      scale: _scale,
    );
  }

  _resetScroll() => setScrollPercent(0.0, 0.0);

  void setScrollPercent(double x, double y) {
    _scrollX = x.isFinite ? x : 0.0;
    _scrollY = y.isFinite ? y : 0.0;
  }

  void pushScrollPositionToUI(double scrollPixelX, double scrollPixelY) {
    if (_horizontal.hasClients) {
      _horizontal.jumpTo(scrollPixelX);
    }
    if (_vertical.hasClients) {
      _vertical.jumpTo(scrollPixelY);
    }
  }

  ScrollController get scrollHorizontal => _horizontal;
  ScrollController get scrollVertical => _vertical;
  double get scrollX => _scrollX;
  double get scrollY => _scrollY;

  static double get leftToEdge =>
      isDesktop ? windowBorderWidth + kDragToResizeAreaPadding.left : 0;
  static double get rightToEdge =>
      isDesktop ? windowBorderWidth + kDragToResizeAreaPadding.right : 0;
  static double get topToEdge => isDesktop
      ? tabBarHeight + windowBorderWidth + kDragToResizeAreaPadding.top
      : 0;
  static double get bottomToEdge =>
      isDesktop ? windowBorderWidth + kDragToResizeAreaPadding.bottom : 0;

  Size getSize() {
    final mediaData = MediaQueryData.fromView(ui.window);
    final size = mediaData.size;
    // If minimized, w or h may be negative here.
    double w = size.width - leftToEdge - rightToEdge;
    double h = size.height - topToEdge - bottomToEdge;
    if (isMobileClient) {
      // Account for horizontal safe area insets on both orientations.
      w = w - mediaData.padding.left - mediaData.padding.right;
      // Portrait excludes the status-bar/notch inset. Landscape intentionally
      // keeps the existing full-height behavior because the home indicator
      // auto-hides during a remote session.
      final isPortrait = size.height > size.width;
      final topInset = isPortrait ? mediaData.padding.top : 0.0;
      h = mobileRemoteUsableViewportHeight(
        screenHeight: size.height - topToEdge - bottomToEdge,
        topInset: topInset,
        keyboardInset: mediaData.viewInsets.bottom,
        keyHelpTop:
            parent.target?.cursorModel.keyHelpToolsRectToAdjustCanvas?.top,
      );
    }
    return Size(w < 0 ? 0 : w, h < 0 ? 0 : h);
  }

  // mobile only
  double getAdjustY() {
    if (_usesMobileRemoteViewport) {
      return 0;
    }
    final bottom =
        parent.target?.cursorModel.keyHelpToolsRectToAdjustCanvas?.bottom ?? 0;
    return max(bottom - MediaQueryData.fromView(ui.window).padding.top, 0);
  }

  updateSize() => _size = getSize();

  Size _mobileTextureSize() => Size(
        getDisplayWidth().toDouble(),
        getDisplayHeight().toDouble(),
      );

  double _mobileMinimumScale() {
    return mobileRemoteMinimumCanvasScale(
      texture: _mobileTextureSize(),
      viewport: size,
    );
  }

  void requestMobileViewFit({MobileRemoteViewScaleMode? mode}) {
    if (mode != null) {
      _mobileViewScaleMode = mode;
    }
    _mobileFitPending = true;
  }

  void applyMobileViewScaleMode(MobileRemoteViewScaleMode mode) {
    requestMobileViewFit(mode: mode);
    updateSize();
    _applyPendingMobileFit();
    notifyListeners();
  }

  void _applyPendingMobileFit() {
    final texture = _mobileTextureSize();
    if (texture.width <= 0 ||
        texture.height <= 0 ||
        size.width <= 0 ||
        size.height <= 0) {
      return;
    }
    _devicePixelRatio = ui.window.devicePixelRatio;
    _scale = mobileRemoteScaleForMode(
      mode: _mobileViewScaleMode,
      texture: texture,
      viewport: size,
      devicePixelRatio: _devicePixelRatio,
    );
    _scale = max(_scale, _mobileMinimumScale());
    final offset = mobileRemoteClampCanvasOffset(
      proposed: Offset(
        (size.width - texture.width * _scale) / 2,
        (size.height - texture.height * _scale) / 2,
      ),
      texture: texture,
      viewport: size,
      scale: _scale,
    );
    final adjust = getAdjustY();
    _x = offset.dx;
    _y = offset.dy - adjust;
    _mobileFitPending = false;
    _updateImageOverflow();
    if (isAndroid) {
      unawaited(
        bind.mainSetCommon(
          key: 'debug-probe-log',
          value:
              'Android mobile viewport fit: mode=${_mobileViewScaleMode.value}, viewport=${size.width}x${size.height}, texture=${texture.width}x${texture.height}, scale=$_scale',
        ),
      );
    }
  }

  void _clampMobileCanvas() {
    final texture = _mobileTextureSize();
    final minimumScale = _mobileMinimumScale();
    if (_scale < minimumScale) {
      final previousScale = _scale;
      if (previousScale.isFinite && previousScale > 0) {
        final viewportCenter = size.center(Offset.zero);
        final textureAtCenter = mobileRemoteTexturePositionFromViewport(
          viewportPosition: viewportCenter,
          canvasOffset: Offset(_x, _y),
          scale: previousScale,
        );
        _scale = minimumScale;
        final centeredOffset = viewportCenter - textureAtCenter * _scale;
        _x = centeredOffset.dx;
        _y = centeredOffset.dy;
      } else {
        _scale = minimumScale;
      }
    }
    final adjust = getAdjustY();
    final offset = mobileRemoteClampCanvasOffset(
      proposed: Offset(_x, _y + adjust),
      texture: texture,
      viewport: size,
      scale: _scale,
    );
    _x = offset.dx;
    _y = offset.dy - adjust;
    _updateImageOverflow();
  }

  void _updateImageOverflow() {
    final texture = _mobileTextureSize();
    final overflow = texture.width * _scale > size.width ||
        texture.height * _scale > size.height;
    if (_imageOverflow.value != overflow) {
      _imageOverflow.value = overflow;
    }
  }

  updateViewStyle({refreshMousePos = true, notify = true}) async {
    if (_usesMobileRemoteViewport) {
      updateSize();
      if (_mobileFitPending) {
        _applyPendingMobileFit();
      } else {
        _clampMobileCanvas();
      }
      if (notify) {
        notifyListeners();
      }
      return;
    }
    final style = await bind.sessionGetViewStyle(sessionId: sessionId);
    if (style == null) {
      return;
    }

    updateSize();
    final displayWidth = getDisplayWidth();
    final displayHeight = getDisplayHeight();
    final viewStyle = ViewStyle(
      style: style,
      width: size.width,
      height: size.height,
      displayWidth: displayWidth,
      displayHeight: displayHeight,
    );
    // If only the Custom scale percent changed, proceed to update even if
    // the basic ViewStyle fields are equal.
    // In Custom scale mode, the scale percent can change independently of the other
    // ViewStyle fields and is not captured by the equality check. Therefore, we must
    // allow updates to proceed when style == kRemoteViewStyleCustom, even if the
    // rest of the ViewStyle fields are unchanged.
    if (_lastViewStyle == viewStyle && style != kRemoteViewStyleCustom) {
      return;
    }
    if (_lastViewStyle.style != viewStyle.style) {
      _resetScroll();
    }
    _lastViewStyle = viewStyle;
    _scale = viewStyle.scale;

    // Apply custom scale percent when in Custom mode
    if (style == kRemoteViewStyleCustom) {
      try {
        _scale = await getSessionCustomScale(sessionId);
      } catch (e, stack) {
        debugPrint('Error in getSessionCustomScale: $e');
        debugPrintStack(stackTrace: stack);
        _scale = 1.0;
      }
    }

    _devicePixelRatio = ui.window.devicePixelRatio;
    if (kIgnoreDpi) {
      if (style == kRemoteViewStyleOriginal) {
        _scale = 1.0 / _devicePixelRatio;
      } else if (_scale != 0 && style == kRemoteViewStyleCustom) {
        _scale /= _devicePixelRatio;
      }
    }
    _resetCanvasOffset(displayWidth, displayHeight);
    final overflow = _x < 0 || y < 0;
    if (_imageOverflow.value != overflow) {
      _imageOverflow.value = overflow;
    }
    if (notify) {
      notifyListeners();
    }
    if (!isMobile && refreshMousePos) {
      parent.target?.inputModel.refreshMousePos();
    }
    tryUpdateScrollStyle(Duration.zero, style);
  }

  _resetCanvasOffset(int displayWidth, int displayHeight) {
    _x = (size.width - displayWidth * _scale) / 2;
    _y = (size.height - displayHeight * _scale) / 2;
    if (isMobile) {
      _moveToCenterCursor();
    }
  }

  tryUpdateScrollStyle(Duration duration, String? style) async {
    if (_scrollStyle == ScrollStyle.scrollauto) return;
    style ??= await bind.sessionGetViewStyle(sessionId: sessionId);
    if (style != kRemoteViewStyleOriginal && style != kRemoteViewStyleCustom) {
      return;
    }

    _resetScroll();

    Future.delayed(duration, () async {
      updateScrollPercent();
    });
  }

  Future<void> updateScrollStyle() async {
    final style = await bind.sessionGetScrollStyle(sessionId: sessionId);

    _scrollStyle =
        style != null ? ScrollStyle.fromString(style) : ScrollStyle.scrollauto;
    cancelEdgeScroll();

    if (_scrollStyle == ScrollStyle.scrolledge ||
        _scrollStyle == ScrollStyle.scrolledgeaccel) {
      rearmEdgeScroll();
    } else {
      _edgeScrollState = EdgeScrollState.inactive;
    }

    if (_scrollStyle != ScrollStyle.scrollauto) {
      _resetScroll();
    }

    if (_usesMobileRemoteViewport) {
      updateSize();
      _clampMobileCanvas();
    }

    notifyListeners();
  }

  Future<void> initializeEdgeScrollEdgeThickness() async {
    final savedValue =
        await bind.sessionGetEdgeScrollEdgeThickness(sessionId: sessionId);

    if (savedValue != null) {
      _edgeScrollEdgeThickness = savedValue;
    }
  }

  void updateEdgeScrollEdgeThickness(int newThickness) {
    _edgeScrollEdgeThickness = newThickness;
    if (_usesMobileEdgeScroll) {
      updateSize();
      _clampMobileCanvas();
    }
    notifyListeners();
  }

  void update(double x, double y, double scale) {
    _x = x;
    _y = y;
    _scale = scale;
    notifyListeners();
  }

  bool get cursorEmbedded =>
      parent.target?.ffiModel._pi.cursorEmbedded ?? false;

  int getDisplayWidth() {
    final defaultWidth = (isDesktop || isWebDesktop)
        ? kDesktopDefaultDisplayWidth
        : kMobileDefaultDisplayWidth;
    return parent.target?.ffiModel.rect?.width.toInt() ?? defaultWidth;
  }

  int getDisplayHeight() {
    final defaultHeight = (isDesktop || isWebDesktop)
        ? kDesktopDefaultDisplayHeight
        : kMobileDefaultDisplayHeight;
    return parent.target?.ffiModel.rect?.height.toInt() ?? defaultHeight;
  }

  static double get windowBorderWidth => stateGlobal.windowBorderWidth.value;
  static double get tabBarHeight => stateGlobal.tabBarHeight;

  void activateLocalCursor() {
    if (isDesktop || isWebDesktop) {
      try {
        RemoteCursorMovedState.find(id).value = false;
      } catch (e) {
        //
      }
    }
  }

  void updateLocalCursor(double x, double y) {
    // If keyboard is not permitted, do not move cursor when mouse is moving.
    if (parent.target != null && parent.target!.ffiModel.keyboard) {
      // Draw cursor if is not desktop.
      if (!(isDesktop || isWebDesktop)) {
        parent.target!.cursorModel.moveLocal(x, y);
      } else {
        try {
          RemoteCursorMovedState.find(id).value = false;
        } catch (e) {
          //
        }
      }
    }
  }

  void moveDesktopMouse(double x, double y) {
    if (size.width == 0 || size.height == 0) {
      return;
    }

    // On mobile platforms, move the canvas with the cursor.
    final dw = getDisplayWidth() * _scale;
    final dh = getDisplayHeight() * _scale;
    var dxOffset = 0;
    var dyOffset = 0;
    try {
      if (dw > size.width) {
        dxOffset = (x - dw * (x / size.width) - _x).toInt();
      }
      if (dh > size.height) {
        dyOffset = (y - dh * (y / size.height) - _y).toInt();
      }
    } catch (e) {
      debugPrintStack(
          label:
              '(x,y) ($x,$y), (_x,_y) ($_x,$_y), _scale $_scale, display size (${getDisplayWidth()},${getDisplayHeight()}), size $size, , $e');
      return;
    }

    _x += dxOffset;
    _y += dyOffset;
    if (dxOffset != 0 || dyOffset != 0) {
      notifyListeners();
    }
  }

  void initializeEdgeScrollFallback(TickerProvider tickerProvider) {
    if (_edgeScrollFallbackInitialized) {
      _edgeScrollFallbackState.dispose();
    }
    _edgeScrollFallbackState = EdgeScrollFallbackState(this, tickerProvider);
    _edgeScrollFallbackInitialized = true;
  }

  void disposeEdgeScrollFallback() {
    _edgeScrollState = EdgeScrollState.inactive;
    _mobileSelectionEdgeScrollActive = false;
    if (_edgeScrollFallbackInitialized) {
      _edgeScrollFallbackState.dispose();
      _edgeScrollFallbackInitialized = false;
    }
  }

  void disableEdgeScroll() {
    _edgeScrollState = EdgeScrollState.inactive;
    cancelEdgeScroll();
  }

  void rearmEdgeScroll() {
    _edgeScrollState = EdgeScrollState.armed;
  }

  void cancelEdgeScroll() {
    if (_edgeScrollFallbackInitialized) {
      _edgeScrollFallbackState.stop();
    }
  }

  bool get _usesEdgeAcceleration =>
      _mobileSelectionEdgeScrollActive ||
      _scrollStyle == ScrollStyle.scrolledgeaccel;

  void beginMobileSelectionEdgeScroll() {
    if (!_usesMobileRemoteViewport) return;
    _mobileSelectionEdgeScrollActive = true;
    _edgeScrollState = EdgeScrollState.active;
  }

  void updateMobileSelectionEdgeScroll(Offset touchPosition) {
    if (!_mobileSelectionEdgeScrollActive) return;
    edgeScrollMouse(touchPosition.dx, touchPosition.dy);
  }

  void endMobileSelectionEdgeScroll() {
    if (!_mobileSelectionEdgeScrollActive) return;
    _mobileSelectionEdgeScrollActive = false;
    cancelEdgeScroll();
    if (_scrollStyle == ScrollStyle.scrolledge ||
        _scrollStyle == ScrollStyle.scrolledgeaccel) {
      _edgeScrollState = EdgeScrollState.armed;
    } else {
      _edgeScrollState = EdgeScrollState.inactive;
    }
  }

  (Vector2, Vector2) getScrollInfo() {
    final scrollPixel = Vector2(
        _horizontal.hasClients ? _horizontal.position.pixels : 0,
        _vertical.hasClients ? _vertical.position.pixels : 0);

    final max = Vector2(
        _horizontal.hasClients ? _horizontal.position.maxScrollExtent : 0,
        _vertical.hasClients ? _vertical.position.maxScrollExtent : 0);

    return (scrollPixel, max);
  }

  void edgeScrollMouse(double x, double y) async {
    final mobileViewportCanScroll =
        _usesMobileRemoteViewport && _imageOverflow.isTrue;
    if (!_edgeScrollFallbackInitialized ||
        (_edgeScrollState == EdgeScrollState.inactive) ||
        (size.width == 0 || size.height == 0) ||
        !(mobileViewportCanScroll ||
            _horizontal.hasClients ||
            _vertical.hasClients)) {
      return;
    }

    final edgeThickness = min(
      _edgeScrollEdgeThickness.toDouble(),
      min(size.width, size.height) / 2,
    );
    final mobileDirections = mobileViewportScrollDirections;

    if (_edgeScrollState == EdgeScrollState.armed &&
        _usesMobileRemoteViewport) {
      _edgeScrollState = EdgeScrollState.active;
    } else if (_edgeScrollState == EdgeScrollState.armed) {
      // Edge scroll is armed to become active once the cursor
      // is observed within the rectangle interior to the
      // edge scroll regions. If the user has just moved the
      // cursor in from outside of the window, edge scrolling
      // doesn't happen yet.
      final clientArea = Rect.fromLTWH(0, 0, size.width, size.height);

      final innerZone = clientArea.deflate(edgeThickness);

      if (innerZone.contains(Offset(x, y))) {
        _edgeScrollState = EdgeScrollState.active;
      } else {
        // Not yet.
        return;
      }
    }

    final deviceEdgeFactor = Vector2(
      mobileRemoteDeviceEdgeScrollAxisFactor(
        pointerPosition: x,
        viewportExtent: size.width,
        edgeThickness: edgeThickness,
      ),
      mobileRemoteDeviceEdgeScrollAxisFactor(
        pointerPosition: y,
        viewportExtent: size.height,
        edgeThickness: edgeThickness,
      ),
    );
    final fixedEdgeFactor = _usesMobileRemoteViewport
        ? Vector2(
            mobileRemoteEdgeScrollAxisDirection(
              pointerPosition: x,
              viewportExtent: size.width,
              edgeThickness: _edgeScrollEdgeThickness.toDouble(),
              canScrollTowardStart: mobileDirections.left,
              canScrollTowardEnd: mobileDirections.right,
            ),
            mobileRemoteEdgeScrollAxisDirection(
              pointerPosition: y,
              viewportExtent: size.height,
              edgeThickness: _edgeScrollEdgeThickness.toDouble(),
              canScrollTowardStart: mobileDirections.up,
              canScrollTowardEnd: mobileDirections.down,
            ),
          )
        : deviceEdgeFactor;
    final encroachment = fixedEdgeFactor * edgeThickness;

    if (_usesEdgeAcceleration) {
      final selectionFactor = mobileRemoteSelectionEdgeScrollFactor(
        touchPosition: Offset(x, y),
        viewport: size,
        edgeThickness: _edgeScrollEdgeThickness.toDouble(),
        directions: mobileDirections,
      );
      final edgeAccelerationFactor = _mobileSelectionEdgeScrollActive
          ? Vector2(selectionFactor.dx, selectionFactor.dy)
          : _usesMobileRemoteViewport
          ? Vector2(
              mobileRemoteEdgeAccelerationAxisFactor(
                pointerPosition: x,
                viewportExtent: size.width,
                edgeThickness: _edgeScrollEdgeThickness.toDouble(),
                canScrollTowardStart: mobileDirections.left,
                canScrollTowardEnd: mobileDirections.right,
              ),
              mobileRemoteEdgeAccelerationAxisFactor(
                pointerPosition: y,
                viewportExtent: size.height,
                edgeThickness: _edgeScrollEdgeThickness.toDouble(),
                canScrollTowardStart: mobileDirections.up,
                canScrollTowardEnd: mobileDirections.down,
              ),
            )
          : _computeEdgeAccelerationFactor(x: x, y: y);
      if (edgeAccelerationFactor.length2 == 0) {
        _edgeScrollFallbackState.stop();
      } else {
        _edgeScrollFallbackState
            .setEdgeAccelerationFactor(edgeAccelerationFactor);
        _edgeScrollFallbackState.start();
      }
      return;
    }

    if (_usesMobileRemoteViewport) {
      if (encroachment.length2 == 0) {
        _edgeScrollFallbackState.stop();
      } else {
        _edgeScrollFallbackState.setEncroachment(encroachment);
        _edgeScrollFallbackState.start();
      }
      return;
    }

    var (scrollPixel, max) = getScrollInfo();

    encroachment.clamp(-scrollPixel, max - scrollPixel);

    if (encroachment.length2 == 0) {
      _edgeScrollFallbackState.stop();
    } else {
      var bumpAmount = -encroachment;

      // Round away from 0: this ensures that the mouse will be bumped clear of
      // whichever edge scroll zone(s) it is in
      bumpAmount.x += bumpAmount.x.sign * 0.5;
      bumpAmount.y += bumpAmount.y.sign * 0.5;

      var bumpMouseSucceeded = _bumpMouseIsWorking &&
          (await rustDeskWinManager.call(WindowType.Main, kWindowBumpMouse,
                  {"dx": bumpAmount.x.round(), "dy": bumpAmount.y.round()}))
              .result;

      if (bumpMouseSucceeded) {
        performEdgeScroll(encroachment);
      } else {
        // If we can't BumpMouse, then we switch to slower scrolling with autorepeat

        // Don't keep hammering BumpMouse if it's not working.
        _bumpMouseIsWorking = false;

        // Keep scrolling as long as the user is overtop of an edge.
        _edgeScrollFallbackState.setEncroachment(encroachment);
        _edgeScrollFallbackState.start();
      }
    }
  }

  Vector2 _computeEdgeAccelerationFactor({
    required double x,
    required double y,
  }) {
    final (scrollPixel, max) = getScrollInfo();
    final thickness = _edgeScrollEdgeThickness.toDouble();

    double axisFactor({
      required double position,
      required double viewportExtent,
      required double scrollPosition,
      required double scrollMax,
    }) {
      if (position < thickness) {
        if (scrollPosition <= 0) {
          return 0.0;
        }
        return -(((thickness - position) / thickness)
            .clamp(
              _kEdgeAccelerationMinFactor,
              _kEdgeAccelerationMaxFactor,
            )
            .toDouble());
      }
      if (position >= viewportExtent - thickness) {
        if (scrollPosition >= scrollMax) {
          return 0.0;
        }
        return ((position - (viewportExtent - thickness)) / thickness)
            .clamp(
              _kEdgeAccelerationMinFactor,
              _kEdgeAccelerationMaxFactor,
            )
            .toDouble();
      }
      return 0.0;
    }

    return Vector2(
      axisFactor(
        position: x,
        viewportExtent: size.width,
        scrollPosition: scrollPixel.x,
        scrollMax: max.x,
      ),
      axisFactor(
        position: y,
        viewportExtent: size.height,
        scrollPosition: scrollPixel.y,
        scrollMax: max.y,
      ),
    );
  }

  bool performEdgeScroll(Vector2 delta) {
    if (_usesMobileRemoteViewport) {
      final previousX = _x;
      final previousY = _y;
      _x -= delta.x;
      _y -= delta.y;
      _clampMobileCanvas();
      if (_x == previousX && _y == previousY) {
        return false;
      }
      parent.target?.cursorModel.followMobileViewportScroll(
        Offset(_x - previousX, _y - previousY),
      );
      isMobileCanvasChanged = true;
      notifyListeners();
      return true;
    }

    var (scrollPixel, max) = getScrollInfo();
    final previousX = scrollPixel.x;
    final previousY = scrollPixel.y;

    scrollPixel += delta;

    scrollPixel.clamp(Vector2.zero(), max);

    if (scrollPixel.x == previousX && scrollPixel.y == previousY) {
      return false;
    }

    var scrollPixelPercent = scrollPixel.clone();

    scrollPixelPercent.divide(max);
    scrollPixelPercent.scale(100.0);

    setScrollPercent(scrollPixelPercent.x, scrollPixelPercent.y);
    pushScrollPositionToUI(scrollPixel.x, scrollPixel.y);

    notifyListeners();
    return true;
  }

  void syncRemoteCursorAfterViewportScroll() {
    parent.target?.inputModel.refreshMousePosAfterViewportScroll();
  }

  panX(double dx) {
    _x += dx;
    if (_usesMobileRemoteViewport) {
      isMobileCanvasChanged = true;
      updateSize();
      _clampMobileCanvas();
    } else if (isMobile) {
      isMobileCanvasChanged = true;
    }
    notifyListeners();
  }

  resetOffset() {
    if (_usesMobileRemoteViewport) {
      requestMobileViewFit();
      updateViewStyle();
    } else if (isWebDesktop) {
      updateViewStyle();
    } else {
      _resetCanvasOffset(getDisplayWidth(), getDisplayHeight());
    }
    notifyListeners();
  }

  panY(double dy) {
    _y += dy;
    if (_usesMobileRemoteViewport) {
      isMobileCanvasChanged = true;
      updateSize();
      _clampMobileCanvas();
    } else if (isMobile) {
      isMobileCanvasChanged = true;
    }
    notifyListeners();
  }

  // mobile only
  updateScale(double v, Offset focalPoint) {
    if (parent.target?.imageModel.hasRenderableFrame != true) return;
    final s = _scale;
    final proposedScale = _scale * v;
    if (!proposedScale.isFinite || proposedScale <= 0) return;
    if (_usesMobileRemoteViewport) {
      updateSize();
      _scale = max(proposedScale, _mobileMinimumScale());
    } else {
      _scale = proposedScale;
      final maxs = parent.target?.imageModel.maxScale ?? 1;
      final mins = parent.target?.imageModel.minScale ?? 1;
      if (_scale > maxs) _scale = maxs;
      if (_scale < mins) _scale = mins;
    }
    // (focalPoint.dx - _x_1) / s1 + displayOriginX = (focalPoint.dx - _x_2) / s2 + displayOriginX
    // _x_2 = focalPoint.dx - (focalPoint.dx - _x_1) / s1 * s2
    _x = focalPoint.dx - (focalPoint.dx - _x) / s * _scale;
    final adjust = getAdjustY();
    // (focalPoint.dy - _y_1 - adjust) / s1 + displayOriginY = (focalPoint.dy - _y_2 - adjust) / s2 + displayOriginY
    // _y_2 = focalPoint.dy - adjust - (focalPoint.dy - _y_1 - adjust) / s1 * s2
    _y = focalPoint.dy - adjust - (focalPoint.dy - _y - adjust) / s * _scale;
    if (_usesMobileRemoteViewport) {
      isMobileCanvasChanged = true;
      _mobileFitPending = false;
      _clampMobileCanvas();
    } else if (isMobile) {
      isMobileCanvasChanged = true;
    }
    notifyListeners();
  }

  // For reset canvas to the last view style
  reset() {
    if (_usesMobileRemoteViewport) {
      requestMobileViewFit();
      updateSize();
      _applyPendingMobileFit();
      notifyListeners();
      return;
    }
    _scale = _lastViewStyle.scale;
    _devicePixelRatio = ui.window.devicePixelRatio;
    if (kIgnoreDpi && _lastViewStyle.style == kRemoteViewStyleOriginal) {
      _scale = 1.0 / _devicePixelRatio;
    }
    _resetCanvasOffset(getDisplayWidth(), getDisplayHeight());
    bind.sessionSetViewStyle(sessionId: sessionId, value: _lastViewStyle.style);
    notifyListeners();
  }

  clear() {
    _x = 0;
    _y = 0;
    _scale = 1.0;
    _lastViewStyle = ViewStyle.defaultViewStyle();
    _mobileViewScaleMode = kDefaultMobileRemoteViewScaleMode;
    _mobileFitPending = true;
    _mobileCursorFocusRequest = MobileCursorFocusRequest.initialReveal;
    _mobileCursorFocusDisplaySwitchAttempted = false;
    _mobileSelectionEdgeScrollActive = false;
    _timerMobileFocusCanvasCursor?.cancel();
    _timerMobileRestoreCanvasOffset?.cancel();
    _offsetBeforeMobileSoftKeyboard = null;
    _scaleBeforeMobileSoftKeyboard = null;
  }

  updateScrollPercent() {
    final percentX = _horizontal.hasClients
        ? _horizontal.position.extentBefore /
            (_horizontal.position.extentBefore +
                _horizontal.position.extentInside +
                _horizontal.position.extentAfter)
        : 0.0;
    final percentY = _vertical.hasClients
        ? _vertical.position.extentBefore /
            (_vertical.position.extentBefore +
                _vertical.position.extentInside +
                _vertical.position.extentAfter)
        : 0.0;
    setScrollPercent(percentX, percentY);
  }

  void mobileFocusCanvasCursor() {
    _timerMobileFocusCanvasCursor?.cancel();
    _timerMobileFocusCanvasCursor =
        Timer(Duration(milliseconds: 100), () async {
      updateSize();
      _resetCanvasOffset(getDisplayWidth(), getDisplayHeight());
      notifyListeners();
    });
  }

  void requestMobileCursorFocus() {
    _mobileCursorFocusRequest = MobileCursorFocusRequest.center;
    _mobileCursorFocusDisplaySwitchAttempted = false;
    tryApplyPendingMobileCursorFocus();
  }

  void tryApplyPendingMobileCursorFocus() {
    final request = _mobileCursorFocusRequest;
    final target = parent.target;
    if (request == null ||
        target == null ||
        !_usesMobileRemoteViewport ||
        !target.cursorModel.hasRemotePosition ||
        !target.imageModel.hasRenderableFrame) {
      return;
    }
    final remoteRect = target.ffiModel.rect;
    if (remoteRect == null || remoteRect.isEmpty) return;
    final remoteCursor = target.cursorModel.remotePosition;
    if (!remoteRect.contains(remoteCursor)) {
      if (!_mobileCursorFocusDisplaySwitchAttempted &&
          target.ffiModel.pi.currentDisplay != kAllDisplayValue) {
        final displays = target.ffiModel.pi.displays;
        for (var index = 0; index < displays.length; index++) {
          final display = displays[index];
          final displayRect = Rect.fromLTWH(
            display.x,
            display.y,
            display.width.toDouble(),
            display.height.toDouble(),
          );
          if (displayRect.contains(remoteCursor) &&
              index != target.ffiModel.pi.currentDisplay) {
            _mobileCursorFocusDisplaySwitchAttempted = true;
            openMonitorInTheSameTab(
              index,
              target,
              target.ffiModel.pi,
              updateCursorPos: false,
            );
            return;
          }
        }
      }
      return;
    }

    updateSize();
    if (_mobileFitPending) {
      _applyPendingMobileFit();
    }
    if (size.isEmpty || !_scale.isFinite || _scale <= 0) return;
    final offset = mobileRemoteCanvasOffsetForCursor(
      cursorTexturePosition: Offset(target.cursorModel.x, target.cursorModel.y),
      currentCanvasOffset: Offset(_x, _y + getAdjustY()),
      texture: _mobileTextureSize(),
      viewport: size,
      scale: _scale,
      center: request == MobileCursorFocusRequest.center,
    );
    final adjust = getAdjustY();
    _x = offset.dx;
    _y = offset.dy - adjust;
    _mobileFitPending = false;
    _mobileCursorFocusRequest = null;
    _mobileCursorFocusDisplaySwitchAttempted = false;
    _updateImageOverflow();
    notifyListeners();
  }

  void saveMobileOffsetBeforeSoftKeyboard() {
    _timerMobileRestoreCanvasOffset?.cancel();
    _offsetBeforeMobileSoftKeyboard = Offset(_x, _y);
    _scaleBeforeMobileSoftKeyboard = _scale;
  }

  void restoreMobileOffsetAfterSoftKeyboard() {
    _timerMobileRestoreCanvasOffset?.cancel();
    _timerMobileFocusCanvasCursor?.cancel();
    if (_usesMobileRemoteViewport) {
      _timerMobileRestoreCanvasOffset = Timer(Duration(milliseconds: 100), () {
        updateSize();
        _offsetBeforeMobileSoftKeyboard = null;
        _scaleBeforeMobileSoftKeyboard = null;
        _clampMobileCanvas();
        notifyListeners();
      });
      return;
    }
    final targetOffset = _offsetBeforeMobileSoftKeyboard;
    final targetScale = _scaleBeforeMobileSoftKeyboard;
    if (targetOffset == null || targetScale == null) {
      return;
    }
    _timerMobileRestoreCanvasOffset = Timer(Duration(milliseconds: 100), () {
      updateSize();
      _x = targetOffset.dx;
      _y = targetOffset.dy;
      _scale = targetScale;
      _offsetBeforeMobileSoftKeyboard = null;
      _scaleBeforeMobileSoftKeyboard = null;
      notifyListeners();
    });
  }

  // mobile only
  // Move the canvas to make the cursor visible(center) on the screen.
  void _moveToCenterCursor() {
    Rect? imageRect = parent.target?.ffiModel.rect;
    if (imageRect == null) {
      // unreachable
      return;
    }
    final maxX = 0.0;
    final minX = _size.width + (imageRect.left - imageRect.right) * _scale;
    final maxY = 0.0;
    final minY = _size.height + (imageRect.top - imageRect.bottom) * _scale;
    Offset offsetToCenter =
        parent.target?.cursorModel.getCanvasOffsetToCenterCursor() ??
            Offset.zero;
    if (minX < 0) {
      _x = min(max(offsetToCenter.dx, minX), maxX);
    } else {
      // _size.width > (imageRect.right, imageRect.left) * _scale, we should not change _x
    }
    if (minY < 0) {
      _y = min(max(offsetToCenter.dy, minY), maxY);
    } else {
      // _size.height > (imageRect.bottom - imageRect.top) * _scale, , we should not change _y
    }
  }
}

// data for cursor
class CursorData {
  final String peerId;
  final String id;
  final img2.Image image;
  double scale;
  Uint8List? data;
  final double hotxOrigin;
  final double hotyOrigin;
  double hotx;
  double hoty;
  final int width;
  final int height;

  CursorData({
    required this.peerId,
    required this.id,
    required this.image,
    required this.scale,
    required this.data,
    required this.hotxOrigin,
    required this.hotyOrigin,
    required this.width,
    required this.height,
  })  : hotx = hotxOrigin * scale,
        hoty = hotyOrigin * scale;

  int _doubleToInt(double v) => (v * 10e6).round().toInt();

  double _checkUpdateScale(double scale) {
    double oldScale = this.scale;
    if (scale != 1.0) {
      // Update data if scale changed.
      final tgtWidth = (width * scale).toInt();
      final tgtHeight = (height * scale).toInt();
      if (tgtWidth < kMinCursorSize || tgtHeight < kMinCursorSize) {
        double sw = kMinCursorSize.toDouble() / width;
        double sh = kMinCursorSize.toDouble() / height;
        scale = sw < sh ? sh : sw;
      }
    }

    if (_doubleToInt(oldScale) != _doubleToInt(scale)) {
      if (isWindows) {
        data = img2
            .copyResize(
              image,
              width: (width * scale).toInt(),
              height: (height * scale).toInt(),
              interpolation: img2.Interpolation.average,
            )
            .getBytes(order: img2.ChannelOrder.bgra);
      } else {
        data = Uint8List.fromList(
          img2.encodePng(
            img2.copyResize(
              image,
              width: (width * scale).toInt(),
              height: (height * scale).toInt(),
              interpolation: img2.Interpolation.average,
            ),
          ),
        );
      }
    }

    this.scale = scale;
    hotx = hotxOrigin * scale;
    hoty = hotyOrigin * scale;
    return scale;
  }

  String updateGetKey(double scale) {
    scale = _checkUpdateScale(scale);
    return '${peerId}_${id}_${_doubleToInt(width * scale)}_${_doubleToInt(height * scale)}';
  }
}

const _forbiddenCursorPng =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAMAAABEpIrGAAAAAXNSR0IB2cksfwAAAAlwSFlzAAALEwAACxMBAJqcGAAAAkZQTFRFAAAA2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4G2B4GWAwCAAAAAAAA2B4GAAAAMTExAAAAAAAA2B4G2B4G2B4GAAAAmZmZkZGRAQEBAAAA2B4G2B4G2B4G////oKCgAwMDag8D2B4G2B4G2B4Gra2tBgYGbg8D2B4G2B4Gubm5CQkJTwsCVgwC2B4GxcXFDg4OAAAAAAAA2B4G2B4Gz8/PFBQUAAAAAAAA2B4G2B4G2B4G2B4G2B4G2B4G2B4GDgIA2NjYGxsbAAAAAAAA2B4GFwMB4eHhIyMjAAAAAAAA2B4G6OjoLCwsAAAAAAAA2B4G2B4G2B4G2B4G2B4GCQEA4ODgv7+/iYmJY2NjAgICAAAA9PT0Ojo6AAAAAAAAAAAA+/v7SkpKhYWFr6+vAAAAAAAA8/PzOTk5ERER9fX1KCgoAAAAgYGBKioqAAAAAAAApqamlpaWAAAAAAAAAAAAAAAAAAAAAAAALi4u/v7+GRkZAAAAAAAAAAAAAAAAAAAAfn5+AAAAAAAAV1dXkJCQAAAAAAAAAQEBAAAAAAAAAAAA7Hz6BAAAAMJ0Uk5TAAIWEwEynNz6//fVkCAatP2fDUHs6cDD8d0mPfT5fiEskiIR584A0gejr3AZ+P4plfALf5ZiTL85a4ziD6697fzN3UYE4v/4TwrNHuT///tdRKZh///+1U/ZBv///yjb///eAVL//50Cocv//6oFBbPvpGZCbfT//7cIhv///8INM///zBEcWYSZmO7//////1P////ts/////8vBv//////gv//R/z///QQz9sevP///2waXhNO/+fc//8mev/5gAe2r90MAAAByUlEQVR4nGNggANGJmYWBpyAlY2dg5OTi5uHF6s0H78AJxRwCAphyguLgKRExcQlQLSkFLq8tAwnp6ycPNABjAqKQKNElVDllVU4OVVhVquJA81Q10BRoAkUUYbJa4Edoo0sr6PLqaePLG/AyWlohKTAmJPTBFnelAFoixmSAnNOTgsUeQZLTk4rJAXWnJw2EHlbiDyDPCenHZICe04HFrh+RydnBgYWPU5uJAWinJwucPNd3dw9GDw5Ob2QFHBzcnrD7ffx9fMPCOTkDEINhmC4+3x8Q0LDwlEDIoKTMzIKKg9SEBIdE8sZh6SAJZ6Tkx0qD1YQkpCYlIwclCng0AXLQxSEpKalZyCryATKZwkhKQjJzsnNQ1KQXwBUUVhUXBJYWgZREFJeUVmFpMKlWg+anmqgCkJq6+obkG1pLEBTENLU3NKKrIKhrb2js8u4G6Kgpze0r3/CRAZMAHbkpJDJU6ZMmTqtFbuC6TNmhsyaMnsOFlmwgrnzpsxfELJwEXZ5Bp/FS3yWLlsesmLlKuwKVk9Ys5Zh3foN0zduwq5g85atDAzbpqSGbN9RhV0FGOzctWH3lD14FOzdt3H/gQw8Cg4u2gQPAwBYDXXdIH+wqAAAAABJRU5ErkJggg==';
const _defaultCursorPng =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAAXNSR0IArs4c6QAAAARzQklUCAgICHwIZIgAAAFmSURBVFiF7dWxSlxREMbx34QFDRowYBchZSxSCWlMCOwD5FGEFHap06UI7KPsAyyEEIQFqxRaCqYTsqCJFsKkuAeRXb17wrqV918dztw55zszc2fo6Oh47MR/e3zO1/iAHWmznHKGQwx9ip/LEbCfazbsoY8j/JLOhcC6sCW9wsjEwJf483AC9nPNc1+lFRwI13d+l3rYFS799rFGxJMqARv2pBXh+72XQ7gWvklPS7TmMl9Ak/M+DqrENvxAv/guKKApuKPWl0/TROK4+LbSqzhuB+OZ3fRSeFPWY+Fkyn56Y29hfgTSpnQ+s98cvorVey66uPlNFxKwZOYLCGfCs5n9NMYVrsp6mvXSoFqpqYFDvMBkStgJJe93dZOwVXxbqUnBENulydSReqUrDhcX0PT2EXarBYS3GNXMhboinBgIl9K71kg0L3+PvyYGdVpruT2MwrF0iotiXfIwus0Dj+OOjo6Of+e7ab74RkpgAAAAAElFTkSuQmCC';

const kPreForbiddenCursorId = "-2";
final preForbiddenCursor = PredefinedCursor(
  png: _forbiddenCursorPng,
  id: kPreForbiddenCursorId,
);
const kPreDefaultCursorId = "-1";
final preDefaultCursor = PredefinedCursor(
  png: _defaultCursorPng,
  id: kPreDefaultCursorId,
  hotxGetter: (double w) => w / 2,
  hotyGetter: (double h) => h / 2,
);

class PredefinedCursor {
  ui.Image? _image;
  img2.Image? _image2;
  CursorData? _cache;
  String png;
  String id;
  double Function(double)? hotxGetter;
  double Function(double)? hotyGetter;

  PredefinedCursor(
      {required this.png, required this.id, this.hotxGetter, this.hotyGetter}) {
    init();
  }

  ui.Image? get image => _image;
  CursorData? get cache => _cache;

  init() {
    _image2 = img2.decodePng(base64Decode(png));
    if (_image2 != null) {
      // The png type of forbidden cursor image is `PngColorType.indexed`.
      if (id == kPreForbiddenCursorId) {
        _image2 = _image2!.convert(format: img2.Format.uint8, numChannels: 4);
      }

      () async {
        final defaultImg = _image2!;
        // This function is called only one time, no need to care about the performance.
        Uint8List data = defaultImg.getBytes(order: img2.ChannelOrder.rgba);
        _image?.dispose();
        _image = await img.decodeImageFromPixels(
            data, defaultImg.width, defaultImg.height, ui.PixelFormat.rgba8888);
        if (_image == null) {
          print("decodeImageFromPixels failed, pre-defined cursor $id");
          return;
        }
        double scale = 1.0;
        if (isWindows) {
          data = _image2!.getBytes(order: img2.ChannelOrder.bgra);
        } else {
          data = Uint8List.fromList(img2.encodePng(_image2!));
        }

        _cache = CursorData(
          peerId: '',
          id: id,
          image: _image2!.clone(),
          scale: scale,
          data: data,
          hotxOrigin:
              hotxGetter != null ? hotxGetter!(_image2!.width.toDouble()) : 0,
          hotyOrigin:
              hotyGetter != null ? hotyGetter!(_image2!.height.toDouble()) : 0,
          width: _image2!.width,
          height: _image2!.height,
        );
      }();
    }
  }
}

class CursorModel with ChangeNotifier {
  ui.Image? _image;
  final _images = <String, Tuple3<ui.Image, double, double>>{};
  CursorData? _cache;
  final _cacheMap = <String, CursorData>{};
  final _cacheKeys = <String>{};
  double _x = -10000;
  double _y = -10000;
  bool _hasRemotePosition = false;
  // int.parse(evt['id']) may cause FormatException
  // So we use String here.
  String _id = "-1";
  double _hotx = 0;
  double _hoty = 0;
  double _displayOriginX = 0;
  double _displayOriginY = 0;
  DateTime? _firstUpdateMouseTime;
  Rect? _windowRect;
  List<RemoteWindowCoords> _remoteWindowCoords = [];
  bool gotMouseControl = true;
  DateTime _lastPeerMouse = DateTime.now()
      .subtract(Duration(milliseconds: 3000 * kMouseControlTimeoutMSec));
  String peerId = '';
  WeakReference<FFI> parent;

  // Only for mobile.
  // Block remote input events above the KeyHelpTools in every input mode.
  //
  // A better way is to not listen events from the KeyHelpTools.
  // But we're now using a Container(child: Stack(...)) to wrap the KeyHelpTools,
  // and the listener is on the Container.
  Rect? _keyHelpToolsInputRect;
  Rect? _keyHelpToolsGlobalRect;
  // `lastIsBlocked` is only used in common/widgets/remote_input.dart -> _RawTouchGestureDetectorRegionState -> onDoubleTap()
  // Because onDoubleTap() doesn't have the `event` parameter, we can't get the touch event's position.
  bool _lastIsBlocked = false;
  bool _lastKeyboardIsVisible = false;

  bool get lastKeyboardIsVisible => _lastKeyboardIsVisible;

  Rect? get keyHelpToolsRectToAdjustCanvas =>
      _lastKeyboardIsVisible ? _keyHelpToolsGlobalRect : null;
  // The blocked rect is used to block the pointer/touch events in the remote page.
  final List<Rect> _blockedRects = [];
  // Used in shouldBlock().
  // _blockEvents is a flag to block pointer/touch events on the remote image.
  // It is set to true to prevent accidental touch events in the following scenarios:
  //   1. In floating mouse mode, when the scroll circle is shown.
  //   2. In floating mouse widgets mode, when the left/right buttons are moving.
  //   3. In floating mouse widgets mode, when using the virtual joystick.
  // When _blockEvents is true, all pointer/touch events are blocked regardless of the contents of _blockedRects.
  // _blockedRects contains specific rectangular regions where events are blocked; these are checked when _blockEvents is false.
  // In summary: _blockEvents acts as a global block, while _blockedRects provides fine-grained blocking.
  bool _blockEvents = false;
  List<Rect> get blockedRects => List.unmodifiable(_blockedRects);

  set blockEvents(bool v) => _blockEvents = v;

  keyHelpToolsVisibilityChanged(
    Rect? inputRect,
    Rect? globalRect,
    bool keyboardIsVisible,
  ) {
    _keyHelpToolsInputRect = inputRect;
    _keyHelpToolsGlobalRect = globalRect;
    if (inputRect == null) {
      _lastIsBlocked = false;
    } else {
      // Block the touch event is safe here.
      // `lastIsBlocked` is only used in onDoubleTap() to block the touch event from the KeyHelpTools.
      // `lastIsBlocked` will be set when the cursor is moving or touch somewhere else.
      _lastIsBlocked = true;
    }
    if (isMobile && _lastKeyboardIsVisible != keyboardIsVisible) {
      if (keyboardIsVisible) {
        parent.target?.canvasModel.saveMobileOffsetBeforeSoftKeyboard();
        parent.target?.canvasModel.mobileFocusCanvasCursor();
        parent.target?.canvasModel.isMobileCanvasChanged = false;
      } else {
        parent.target?.canvasModel.restoreMobileOffsetAfterSoftKeyboard();
      }
    }
    _lastKeyboardIsVisible = keyboardIsVisible;
  }

  addBlockedRect(Rect rect) {
    _blockedRects.add(rect);
  }

  removeBlockedRect(Rect rect) {
    _blockedRects.remove(rect);
  }

  get lastIsBlocked => _lastIsBlocked;

  ui.Image? get image => _image;
  CursorData? get cache => _cache;

  double get x => _x - _displayOriginX;
  double get y => _y - _displayOriginY;

  double get devicePixelRatio => parent.target!.canvasModel.devicePixelRatio;

  Offset get offset => Offset(_x, _y);
  Offset get remotePosition => Offset(_x, _y);
  bool get hasRemotePosition => _hasRemotePosition;

  Offset get mobileViewportPosition {
    final canvasModel = parent.target?.canvasModel;
    if (canvasModel == null) {
      return Offset.zero;
    }
    return mobileRemoteViewportPositionFromTexture(
      texturePosition: Offset(x, y),
      canvasOffset: Offset(canvasModel.x, canvasModel.y),
      scale: canvasModel.scale,
    );
  }

  double get hotx => _hotx;
  double get hoty => _hoty;

  set id(String id) => _id = id;

  bool get isPeerControlProtected =>
      DateTime.now().difference(_lastPeerMouse).inMilliseconds <
      kMouseControlTimeoutMSec;

  bool isConnIn2Secs() {
    if (_firstUpdateMouseTime == null) {
      _firstUpdateMouseTime = DateTime.now();
      return true;
    } else {
      return DateTime.now().difference(_firstUpdateMouseTime!).inSeconds < 2;
    }
  }

  CursorModel(this.parent);

  Set<String> get cachedKeys => _cacheKeys;
  addKey(String key) => _cacheKeys.add(key);

  // remote physical display coordinate
  // For update pan (mobile), onOneFingerPanStart, onOneFingerPanUpdate, onHoldDragUpdate
  Rect getVisibleRect() {
    final size = parent.target?.canvasModel.getSize() ??
        MediaQueryData.fromView(ui.window).size;
    final xoffset = parent.target?.canvasModel.x ?? 0;
    final yoffset = parent.target?.canvasModel.y ?? 0;
    final scale = parent.target?.canvasModel.scale ?? 1;
    final x0 = _displayOriginX - xoffset / scale;
    final y0 = _displayOriginY - yoffset / scale;
    return Rect.fromLTWH(x0, y0, size.width / scale, size.height / scale);
  }

  Offset getCanvasOffsetToCenterCursor() {
    // Cursor should be at the center of the visible rect.
    // _x = rect.left + rect.width / 2
    // _y = rect.right + rect.height / 2
    // See `getVisibleRect()`
    // _x = _displayOriginX - xoffset / scale + size.width / scale * 0.5;
    // _y = _displayOriginY - yoffset / scale + size.height / scale * 0.5;
    final size = parent.target?.canvasModel.getSize() ??
        MediaQueryData.fromView(ui.window).size;
    final xoffset = (_displayOriginX - _x) * scale + size.width * 0.5;
    final yoffset = (_displayOriginY - _y) * scale + size.height * 0.5;
    return Offset(xoffset, yoffset);
  }

  get scale => parent.target?.canvasModel.scale ?? 1.0;

  // Mobile: block remote input events originating over KeyHelpTools.
  shouldBlock(double x, double y) {
    if (_blockEvents) {
      return true;
    }
    final offset = Offset(x, y);
    for (final rect in _blockedRects) {
      if (isPointInRect(offset, rect)) {
        return true;
      }
    }

    if (_keyHelpToolsInputRect != null &&
        isPointInRect(offset, _keyHelpToolsInputRect!)) {
      return true;
    }
    return false;
  }

  bool shouldBlockGlobal(double x, double y) {
    if (_blockEvents) return true;
    final rect = _keyHelpToolsGlobalRect;
    return rect != null && isPointInRect(Offset(x, y), rect);
  }

  // For touch mode
  Future<bool> move(double x, double y) async {
    if (shouldBlock(x, y)) {
      _lastIsBlocked = true;
      return false;
    }
    _lastIsBlocked = false;
    if (!_moveLocalIfInRemoteRect(x, y)) {
      return false;
    }
    await parent.target?.inputModel.moveMouse(_x, _y);
    return true;
  }

  Future<void> syncCursorPosition() async {
    await parent.target?.inputModel.moveMouse(_x, _y);
  }

  void followMobileViewportScroll(Offset canvasDelta) {
    final target = parent.target;
    final rect = target?.ffiModel.rect;
    final canvasModel = target?.canvasModel;
    if (target == null ||
        rect == null ||
        canvasModel == null ||
        target.ffiModel.viewOnly ||
        !target.ffiModel.keyboard) {
      return;
    }
    final farEdgeInset = target.ffiModel.pi.platform == kPeerPlatformWindows
        ? 0.0
        : 1.0;
    final next = mobileRemoteCursorAfterCanvasScroll(
      currentRemotePosition: Offset(_x, _y),
      canvasDelta: canvasDelta,
      scale: canvasModel.scale,
      remoteBounds: rect,
      farEdgeInset: farEdgeInset,
    );
    if (next.dx == _x && next.dy == _y) {
      return;
    }
    _x = next.dx;
    _y = next.dy;
    unawaited(target.inputModel.moveMouse(_x, _y));
    notifyListeners();
  }

  bool isInRemoteRect(Offset offset) {
    return getRemotePosInRect(offset) != null;
  }

  Offset? getRemotePosInRect(Offset offset) {
    final adjust = parent.target?.canvasModel.getAdjustY() ?? 0;
    final newPos = _getNewPos(offset.dx, offset.dy, adjust);
    final visibleRect = getVisibleRect();
    if (!isPointInRect(newPos, visibleRect)) {
      return null;
    }
    final rect = parent.target?.ffiModel.rect;
    if (rect != null) {
      if (!isPointInRect(newPos, rect)) {
        return null;
      }
    }
    return newPos;
  }

  Offset _getNewPos(double x, double y, double adjust) {
    final xoffset = parent.target?.canvasModel.x ?? 0;
    final yoffset = parent.target?.canvasModel.y ?? 0;
    final newX = (x - xoffset) / scale + _displayOriginX;
    final newY = (y - yoffset - adjust) / scale + _displayOriginY;
    return Offset(newX, newY);
  }

  bool _moveLocalIfInRemoteRect(double x, double y) {
    final newPos = getRemotePosInRect(Offset(x, y));
    if (newPos == null) {
      return false;
    }
    _x = newPos.dx;
    _y = newPos.dy;
    notifyListeners();
    return true;
  }

  moveLocal(double x, double y, {double adjust = 0}) {
    final newPos = _getNewPos(x, y, adjust);
    _x = newPos.dx;
    _y = newPos.dy;
    notifyListeners();
  }

  reset() {
    _x = _displayOriginX;
    _y = _displayOriginY;
    parent.target?.inputModel.moveMouse(_x, _y);
    parent.target?.canvasModel.reset();
    notifyListeners();
  }

  updatePan(Offset delta, Offset localPosition, bool touchMode) async {
    if (touchMode) {
      await _handleTouchMode(delta, localPosition);
      return;
    }
    double dx = delta.dx;
    double dy = delta.dy;
    if (parent.target?.imageModel.hasRenderableFrame != true) return;
    final canvasModel = parent.target?.canvasModel;
    final scale = canvasModel?.scale ?? 1.0;
    final useEdgeScroll = parent.target?.inputModel.useEdgeScroll ?? false;
    if (useEdgeScroll &&
        canvasModel?._usesMobileRemoteViewport == true &&
        canvasModel?.scrollStyle == ScrollStyle.scrolledge) {
      final currentViewportPosition = mobileViewportPosition;
      final nextViewportPosition = mobileRemoteClampCursorToNeutralRegion(
        pointerPosition: currentViewportPosition + delta,
        viewport: canvasModel!.size,
        edgeThickness: canvasModel.edgeScrollEdgeThickness.toDouble(),
        directions: canvasModel.mobileViewportScrollDirections,
      );
      final clampedDelta = nextViewportPosition - currentViewportPosition;
      dx = clampedDelta.dx;
      dy = clampedDelta.dy;
    }
    dx /= scale;
    dy /= scale;
    final r = getVisibleRect();
    var cx = r.center.dx;
    var cy = r.center.dy;
    var tryMoveCanvasX = false;
    final displayRect = parent.target?.ffiModel.rect;
    if (dx > 0) {
      final maxCanvasCanMove = _displayOriginX +
          (displayRect?.width ?? 1280) -
          r.right.roundToDouble();
      tryMoveCanvasX = _x + dx > cx && maxCanvasCanMove > 0;
      if (tryMoveCanvasX) {
        dx = min(dx, maxCanvasCanMove);
      } else {
        final maxCursorCanMove = r.right - _x;
        dx = min(dx, maxCursorCanMove);
      }
    } else if (dx < 0) {
      final maxCanvasCanMove = _displayOriginX - r.left.roundToDouble();
      tryMoveCanvasX = _x + dx < cx && maxCanvasCanMove < 0;
      if (tryMoveCanvasX) {
        dx = max(dx, maxCanvasCanMove);
      } else {
        final maxCursorCanMove = r.left - _x;
        dx = max(dx, maxCursorCanMove);
      }
    }
    var tryMoveCanvasY = false;
    if (dy > 0) {
      final mayCanvasCanMove = _displayOriginY +
          (displayRect?.height ?? 720) -
          r.bottom.roundToDouble();
      tryMoveCanvasY = _y + dy > cy && mayCanvasCanMove > 0;
      if (tryMoveCanvasY) {
        dy = min(dy, mayCanvasCanMove);
      } else {
        final mayCursorCanMove = r.bottom - _y;
        dy = min(dy, mayCursorCanMove);
      }
    } else if (dy < 0) {
      final mayCanvasCanMove = _displayOriginY - r.top.roundToDouble();
      tryMoveCanvasY = _y + dy < cy && mayCanvasCanMove < 0;
      if (tryMoveCanvasY) {
        dy = max(dy, mayCanvasCanMove);
      } else {
        final mayCursorCanMove = r.top - _y;
        dy = max(dy, mayCursorCanMove);
      }
    }

    if (dx == 0 && dy == 0) return;

    Point<double>? newPos;
    final rect = parent.target?.ffiModel.rect;
    if (rect == null) {
      // unreachable
      return;
    }
    newPos = InputModel.getPointInRemoteRect(
        false,
        parent.target?.ffiModel.pi.platform,
        kPointerEventKindMouse,
        kMouseEventTypeDefault,
        _x + dx,
        _y + dy,
        rect,
        buttons: kPrimaryButton);
    if (newPos == null) {
      return;
    }
    dx = newPos.x - _x;
    dy = newPos.y - _y;
    _x = newPos.x;
    _y = newPos.y;
    if (tryMoveCanvasX && dx != 0 && !useEdgeScroll) {
      parent.target?.canvasModel.panX(-dx * scale);
    }
    if (tryMoveCanvasY && dy != 0 && !useEdgeScroll) {
      parent.target?.canvasModel.panY(-dy * scale);
    }

    parent.target?.inputModel.moveMouse(_x, _y);
    notifyListeners();
  }

  bool _isInCurrentWindow(double x, double y) {
    final w = _windowRect!.width / devicePixelRatio;
    final h = _windowRect!.width / devicePixelRatio;
    return x >= 0 && y >= 0 && x <= w && y <= h;
  }

  _handleTouchMode(Offset delta, Offset localPosition) async {
    bool isMoved = false;
    if (_remoteWindowCoords.isNotEmpty &&
        _windowRect != null &&
        !_isInCurrentWindow(localPosition.dx, localPosition.dy)) {
      final coords = InputModel.findRemoteCoords(localPosition.dx,
          localPosition.dy, _remoteWindowCoords, devicePixelRatio);
      if (coords != null) {
        double x2 =
            (localPosition.dx - coords.relativeOffset.dx / devicePixelRatio) /
                coords.canvas.scale;
        double y2 =
            (localPosition.dy - coords.relativeOffset.dy / devicePixelRatio) /
                coords.canvas.scale;
        x2 += coords.cursor.offset.dx;
        y2 += coords.cursor.offset.dy;
        await parent.target?.inputModel.moveMouse(x2, y2);
        isMoved = true;
      }
    }
    if (!isMoved) {
      final rect = parent.target?.ffiModel.rect;
      if (rect == null) {
        // unreachable
        return;
      }

      Offset? movementInRect(double x, double y, Rect r) {
        final isXInRect = x >= r.left && x <= r.right;
        final isYInRect = y >= r.top && y <= r.bottom;
        if (!(isXInRect || isYInRect)) {
          return null;
        }
        if (x < r.left) {
          x = r.left;
        } else if (x > r.right) {
          x = r.right;
        }
        if (y < r.top) {
          y = r.top;
        } else if (y > r.bottom) {
          y = r.bottom;
        }
        return Offset(x, y);
      }

      final scale = parent.target?.canvasModel.scale ?? 1.0;
      var movement =
          movementInRect(_x + delta.dx / scale, _y + delta.dy / scale, rect);
      if (movement == null) {
        return;
      }
      movement = movementInRect(movement.dx, movement.dy, getVisibleRect());
      if (movement == null) {
        return;
      }

      _x = movement.dx;
      _y = movement.dy;
      await parent.target?.inputModel.moveMouse(_x, _y);
    }
    notifyListeners();
  }

  disposeImages() {
    _images.forEach((_, v) => v.item1.dispose());
    _images.clear();
  }

  Future<void> updateCursorShape(CursorShapeSessionEvent event) async {
    final id = event.id;
    final hotx = event.hotx;
    final hoty = event.hoty;
    final width = event.width;
    final height = event.height;
    final rgba = Uint8List.fromList(event.colors);
    final image = await img.decodeImageFromPixels(
        rgba, width, height, ui.PixelFormat.rgba8888);
    if (image == null) {
      return;
    }
    if (await _updateCache(rgba, image, id, hotx, hoty, width, height)) {
      _images[id]?.item1.dispose();
      _images[id] = Tuple3(image, hotx, hoty);
    }

    // Update last cursor data.
    // Do not use the previous `image` and `id`, because `_id` may be changed.
    _updateCurData();
  }

  Future<bool> _updateCache(
    Uint8List rgba,
    ui.Image image,
    String id,
    double hotx,
    double hoty,
    int w,
    int h,
  ) async {
    Uint8List? data;
    img2.Image imgOrigin = img2.Image.fromBytes(
        width: w, height: h, bytes: rgba.buffer, order: img2.ChannelOrder.rgba);
    if (isWindows) {
      data = imgOrigin.getBytes(order: img2.ChannelOrder.bgra);
    } else {
      ByteData? imgBytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (imgBytes == null) {
        return false;
      }
      data = imgBytes.buffer.asUint8List();
    }
    final cache = CursorData(
      peerId: peerId,
      id: id,
      image: imgOrigin,
      scale: 1.0,
      data: data,
      hotxOrigin: hotx,
      hotyOrigin: hoty,
      width: w,
      height: h,
    );
    _cacheMap[id] = cache;
    return true;
  }

  bool _updateCurData() {
    _cache = _cacheMap[_id];
    final tmp = _images[_id];
    if (tmp != null) {
      _image = tmp.item1;
      _hotx = tmp.item2;
      _hoty = tmp.item3;
      try {
        // may throw exception, because the listener maybe already dispose
        notifyListeners();
      } catch (e) {
        debugPrint(
            'WARNING: updateCursorId $_id, without notifyListeners(). $e');
      }
      return true;
    } else {
      if (_image != null || _cache != null) {
        _image = null;
        _cache = null;
        _hotx = 0;
        _hoty = 0;
        notifyListeners();
      }
      return false;
    }
  }

  void updateCursorIdValue(String id) {
    _id = id;
    if (!_updateCurData()) {
      debugPrint(
          'WARNING: updateCursorId $_id, cache is ${_cache == null ? "null" : "not null"}. without notifyListeners()');
    }
  }

  Future<void> updateCursorPositionValue(
    double x,
    double y,
    String id,
  ) async {
    if (!isConnIn2Secs()) {
      gotMouseControl = false;
      _lastPeerMouse = DateTime.now();
    }
    _x = x;
    _y = y;
    _hasRemotePosition = true;
    try {
      RemoteCursorMovedState.find(id).value = true;
    } catch (e) {
      //
    }
    notifyListeners();
    parent.target?.canvasModel.tryApplyPendingMobileCursorFocus();
  }

  updateDisplayOrigin(double x, double y, {updateCursorPos = true}) {
    _displayOriginX = x;
    _displayOriginY = y;
    if (updateCursorPos) {
      _x = x + 1;
      _y = y + 1;
      parent.target?.inputModel.moveMouse(x, y);
    }
    parent.target?.canvasModel.resetOffset();
    notifyListeners();
  }

  updateDisplayOriginWithCursor(
      double x, double y, double xCursor, double yCursor) {
    _displayOriginX = x;
    _displayOriginY = y;
    _x = xCursor;
    _y = yCursor;
    parent.target?.inputModel.moveMouse(x, y);
    notifyListeners();
  }

  clear() {
    _x = -10000;
    _y = -10000;
    _hasRemotePosition = false;
    _image = null;
    _firstUpdateMouseTime = null;
    gotMouseControl = true;
    disposeImages();

    _clearCache();
    _cache = null;
    _cacheMap.clear();
  }

  _clearCache() {
    final keys = {...cachedKeys};
    for (var k in keys) {
      debugPrint("deleting cursor with key $k");
      deleteCustomCursor(k);
    }
    _cacheKeys.clear();
    resetSystemCursor();
  }

  trySetRemoteWindowCoords() {
    Future.delayed(Duration.zero, () async {
      _windowRect =
          await InputModel.fillRemoteCoordsAndGetCurFrame(_remoteWindowCoords);
    });
  }

  clearRemoteWindowCoords() {
    _windowRect = null;
    _remoteWindowCoords.clear();
  }
}

class QualityMonitorData {
  String? speed;
  String? fps;
  String? delay;
  String? targetBitrate;
  String? codecFormat;
  String? chroma;
  String? connectionType;
  String? transportMtu;
  String? transportRttMs;
  String? transportLostPackets;
  String? datagramPayload;
  String? negotiatedDatagramPayload;
  String? quicProtocol;
  String? quicVideoTransport;
  String? quicReassemblyDrops;
  String? quicReassemblyReasons;
  String? quicReassemblyFrame;
  String? quicReassemblyTiming;
  String? quicKeyframeRequests;
  String? quicKeyframeBarrier;
  String? quicReceiverRecovery;
  String? quicSenderRecovery;
  String? quicSenderAdmission;
  String? quicSenderFrame;
  String? quicSenderPercentiles;
  String? quicSenderSpace;
  String? quicDisposableDrops;
  String? quicVideoQueueTargetMs;
  String? hostVersion;
  String? clientVersion;
  String? decoder;
  String? renderer;
  String? captureBackend;
  String? captureFrame;
  String? encoderBackend;
  String? encoderInput;
  String? frameResolution;
  String? decodeFps;
  String? videoQueue;
  String? videoThreads;
  String? textureRender;
  String? direct;
  String? fpsMode;
  String? autoFps;
  String? videoProgress;
  String? videoDropped;
  String? videoDecodeTimeUs;
  String? videoRenderSubmitTimeUs;
  String? videoFeedbackQueue;
  String? displayRefresh;
  String? videoDeliveryPhase;
  String? videoRecoveryCount;
  String? videoStallMs;
  String? requestedVideoProfile;
  String? effectiveVideoProfile;
  String? movieTargetFps;
  String? moviePacingFps;
  String? movieHostPipelineP95Us;
  String? movieFallbackReason;
  String? moviePlayoutDelayMs;

  bool get isQuicTransport =>
      connectionType?.toUpperCase().contains('QUIC') == true;

  bool clearQuicTransportMetrics() {
    final hadMetrics = transportMtu != null ||
        transportRttMs != null ||
        transportLostPackets != null ||
        datagramPayload != null ||
        negotiatedDatagramPayload != null ||
        quicProtocol != null ||
        quicVideoTransport != null ||
        quicReassemblyDrops != null ||
        quicReassemblyReasons != null ||
        quicReassemblyFrame != null ||
        quicReassemblyTiming != null ||
        quicKeyframeRequests != null ||
        quicKeyframeBarrier != null ||
        quicReceiverRecovery != null ||
        quicSenderRecovery != null ||
        quicSenderAdmission != null ||
        quicSenderFrame != null ||
        quicSenderPercentiles != null ||
        quicSenderSpace != null ||
        quicDisposableDrops != null ||
        quicVideoQueueTargetMs != null;
    transportMtu = null;
    transportRttMs = null;
    transportLostPackets = null;
    datagramPayload = null;
    negotiatedDatagramPayload = null;
    quicProtocol = null;
    quicVideoTransport = null;
    quicReassemblyDrops = null;
    quicReassemblyReasons = null;
    quicReassemblyFrame = null;
    quicReassemblyTiming = null;
    quicKeyframeRequests = null;
    quicKeyframeBarrier = null;
    quicReceiverRecovery = null;
    quicSenderRecovery = null;
    quicSenderAdmission = null;
    quicSenderFrame = null;
    quicSenderPercentiles = null;
    quicSenderSpace = null;
    quicDisposableDrops = null;
    quicVideoQueueTargetMs = null;
    return hadMetrics;
  }

  String? get codecLabel {
    final codec = codecFormat;
    if ((codec == 'H264' || codec == 'H265') &&
        (encoderBackend == 'Hardware NVIDIA NVENC p5 via FFmpeg' ||
            encoderBackend == 'Hardware VideoToolbox HQ via FFmpeg')) {
      return '$codec HQ';
    }
    return codec;
  }
}

class QualityMonitorModel with ChangeNotifier {
  WeakReference<FFI>? parent;

  QualityMonitorModel(this.parent);
  QualityMonitorModel.detached() : parent = null {
    _show = true;
    showListenable.value = true;
  }
  var _show = false;
  final showListenable = ValueNotifier<bool>(false);
  var _position = kQualityMonitorPositionTopRight;
  var _details = kQualityMonitorDetailsBasic;
  Offset? _floatingPosition;
  Size? _floatingSize;
  Timer? _floatingPositionStoreTimer;
  Timer? _floatingSizeStoreTimer;
  SessionID? _sessionId;
  var _data = QualityMonitorData();

  bool get show => _show;
  String get position => _position;
  String get details => _details;
  bool get extendedDetails => _details == kQualityMonitorDetailsExtended;
  Offset? get floatingPosition => _floatingPosition;
  Size? get floatingSize => _floatingSize;
  QualityMonitorData get data => _data;

  void applyDetachedSnapshot({
    required String details,
    required QualityMonitorData data,
  }) {
    _show = true;
    if (!showListenable.value) {
      showListenable.value = true;
    }
    _position = kQualityMonitorPositionDetached;
    _details = normalizeQualityMonitorDetails(details);
    _data = data;
    notifyListeners();
  }

  Future<void> setDetails(String value) async {
    final details = normalizeQualityMonitorDetails(value);
    if (_details == details) return;
    final sessionId = parent?.target?.sessionId;
    if (sessionId == null) {
      _details = details;
      notifyListeners();
      return;
    }
    _details = details;
    notifyListeners();
    await SessionPeerSettingsRepository.forSession(sessionId).write(
      SessionPeerSettingsRegistry.qualityMonitorDetails,
      details,
    );
  }

  String? _directLabel(dynamic direct) {
    if (direct == null) return null;
    if (direct is bool) return direct ? 'yes' : 'no';
    final value = direct.toString();
    if (value.isEmpty) return null;
    return value == 'true' ? 'yes' : 'no';
  }

  Future<String?> _clientVersion() async {
    var value = '';
    try {
      value = await bind.mainGetVersion();
    } catch (_) {
      //
    }
    if (value.isEmpty) {
      value = version;
    }
    return value.isEmpty ? null : value;
  }

  String? _hostVersion() {
    final value = parent?.target?.ffiModel.pi.fullVersion;
    return value == null || value.isEmpty ? null : value;
  }

  bool _resetDataForSession(SessionID sessionId) {
    if (_sessionId == sessionId) return false;
    _sessionId = sessionId;
    _data.speed = null;
    _data.fps = null;
    _data.delay = null;
    _data.targetBitrate = null;
    _data.codecFormat = null;
    _data.chroma = null;
    _data.connectionType = null;
    _data.clearQuicTransportMetrics();
    _data.hostVersion = null;
    _data.clientVersion = null;
    _data.decoder = null;
    _data.renderer = null;
    _data.captureBackend = null;
    _data.captureFrame = null;
    _data.encoderBackend = null;
    _data.encoderInput = null;
    _data.frameResolution = null;
    _data.decodeFps = null;
    _data.videoQueue = null;
    _data.videoThreads = null;
    _data.textureRender = null;
    _data.direct = null;
    _data.fpsMode = null;
    _data.autoFps = null;
    _data.videoProgress = null;
    _data.videoDropped = null;
    _data.videoDecodeTimeUs = null;
    _data.videoRenderSubmitTimeUs = null;
    _data.videoFeedbackQueue = null;
    _data.displayRefresh = null;
    _data.videoDeliveryPhase = null;
    _data.videoRecoveryCount = null;
    _data.videoStallMs = null;
    _data.requestedVideoProfile = null;
    _data.effectiveVideoProfile = null;
    _data.movieTargetFps = null;
    _data.moviePacingFps = null;
    _data.movieHostPipelineP95Us = null;
    _data.movieFallbackReason = null;
    _data.moviePlayoutDelayMs = null;
    return true;
  }

  updateConnectionInfo(dynamic streamType, [dynamic direct]) {
    final value = streamType?.toString();
    final connectionType = value == null || value.isEmpty ? null : value;
    final directLabel = _directLabel(direct);
    final connectionChanged = _data.connectionType != connectionType;
    final isQuicTransport =
        connectionType?.toUpperCase().contains('QUIC') == true;
    final transportReset = connectionChanged || !isQuicTransport
        ? _data.clearQuicTransportMetrics()
        : false;
    if (_data.connectionType == connectionType &&
        _data.direct == directLabel &&
        !transportReset) {
      return;
    }
    _data.connectionType = connectionType;
    _data.direct = directLabel;
    notifyListeners();
  }

  Future<void> clearFloatingPosition(SessionID sessionId) async {
    _floatingPositionStoreTimer?.cancel();
    _floatingPositionStoreTimer = null;
    if (_floatingPosition == null) {
      return;
    }
    _floatingPosition = null;
    await SessionPeerSettingsRepository.forSession(sessionId).write(
      SessionPeerSettingsRegistry.qualityMonitorFloatingPosition,
      '',
    );
    notifyListeners();
  }

  void updateFloatingPosition(Offset position, {bool persist = true}) {
    final sessionId = parent?.target?.sessionId;
    if (sessionId == null) return;
    final rounded =
        Offset(position.dx.roundToDouble(), position.dy.roundToDouble());
    if (_floatingPosition != rounded) {
      _floatingPosition = rounded;
      notifyListeners();
    }
    if (!persist) return;
    _floatingPositionStoreTimer?.cancel();
    final settings = SessionPeerSettingsRepository.forSession(sessionId);
    _floatingPositionStoreTimer =
        Timer(const Duration(milliseconds: 300), () {
      unawaited(
        settings.write(
          SessionPeerSettingsRegistry.qualityMonitorFloatingPosition,
          _formatFloatingPosition(rounded),
        ),
      );
    });
  }

  Future<void> commitFloatingPosition() async {
    _floatingPositionStoreTimer?.cancel();
    _floatingPositionStoreTimer = null;
    final sessionId = parent?.target?.sessionId;
    final position = _floatingPosition;
    if (sessionId == null || position == null) return;
    await SessionPeerSettingsRepository.forSession(sessionId).write(
      SessionPeerSettingsRegistry.qualityMonitorFloatingPosition,
      _formatFloatingPosition(position),
    );
  }

  void updateFloatingSize(Size size, {bool persist = true}) {
    final sessionId = parent?.target?.sessionId;
    if (sessionId == null ||
        !size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      return;
    }
    final rounded =
        Size(size.width.roundToDouble(), size.height.roundToDouble());
    if (_floatingSize != rounded) {
      _floatingSize = rounded;
      notifyListeners();
    }
    if (!persist) return;
    _floatingSizeStoreTimer?.cancel();
    final settings = SessionPeerSettingsRepository.forSession(sessionId);
    _floatingSizeStoreTimer =
        Timer(const Duration(milliseconds: 300), () {
      unawaited(
        settings.write(
          SessionPeerSettingsRegistry.qualityMonitorFloatingSize,
          _formatFloatingSize(rounded),
        ),
      );
    });
  }

  Future<void> commitFloatingSize() async {
    _floatingSizeStoreTimer?.cancel();
    _floatingSizeStoreTimer = null;
    final sessionId = parent?.target?.sessionId;
    final size = _floatingSize;
    if (sessionId == null || size == null) return;
    await SessionPeerSettingsRepository.forSession(sessionId).write(
      SessionPeerSettingsRegistry.qualityMonitorFloatingSize,
      _formatFloatingSize(size),
    );
  }

  checkShowQualityMonitor(SessionID sessionId) async {
    final dataReset = _resetDataForSession(sessionId);
    final settings = SessionPeerSettingsRepository.forSession(sessionId);
    final show = await LiveSessionSettingsRepository.forSession(
      sessionId,
    ).read(LiveSessionSettingsRegistry.showQualityMonitor);
    final position =
        await settings.read(SessionPeerSettingsRegistry.qualityMonitorPosition);
    final details =
        await settings.read(SessionPeerSettingsRegistry.qualityMonitorDetails);
    final floatingPosition = _parseFloatingPosition(
      await settings.read(
        SessionPeerSettingsRegistry.qualityMonitorFloatingPosition,
      ),
    );
    final floatingSize = _parseFloatingSize(
      await settings.read(
        SessionPeerSettingsRegistry.qualityMonitorFloatingSize,
      ),
    );
    final hostVersion = _hostVersion();
    final clientVersion = await _clientVersion();
    final showChanged = _show != show;
    if (showChanged ||
        _position != position ||
        _details != details ||
        _floatingPosition != floatingPosition ||
        _floatingSize != floatingSize ||
        _data.hostVersion != hostVersion ||
        _data.clientVersion != clientVersion ||
        dataReset) {
      _show = show;
      if (showChanged) {
        showListenable.value = show;
      }
      _position = position;
      _details = details;
      _floatingPosition = floatingPosition;
      _floatingSize = floatingSize;
      _data.hostVersion = hostVersion;
      _data.clientVersion = clientVersion;
      notifyListeners();
    }
  }

  static String _formatFloatingPosition(Offset position) {
    return '${position.dx.round()},${position.dy.round()}';
  }

  static Offset? _parseFloatingPosition(String value) {
    if (value.isEmpty) return null;
    final parts = value.split(',');
    if (parts.length != 2) return null;
    final x = double.tryParse(parts[0]);
    final y = double.tryParse(parts[1]);
    if (x == null || y == null) return null;
    return Offset(x, y);
  }

  static String _formatFloatingSize(Size size) {
    return '${size.width.round()},${size.height.round()}';
  }

  static Size? _parseFloatingSize(String value) {
    if (value.isEmpty) return null;
    final parts = value.split(',');
    if (parts.length != 2) return null;
    final width = double.tryParse(parts[0]);
    final height = double.tryParse(parts[1]);
    if (width == null ||
        height == null ||
        !width.isFinite ||
        !height.isFinite ||
        width <= 0 ||
        height <= 0) {
      return null;
    }
    return Size(width, height);
  }

  String? _displayMetricFromValues(Map<String, String>? values) {
    if (values == null || values.isEmpty) return null;
    final pi = parent?.target?.ffiModel.pi;
    if (pi != null) {
      final currentDisplay = pi.currentDisplay;
      if (currentDisplay != kAllDisplayValue) {
        return values[currentDisplay.toString()]?.toString();
      }
      if (pi.displays.isNotEmpty) {
        final displayValues = <String>[];
        for (var i = 0; i < pi.displays.length; i++) {
          displayValues.add((values[i.toString()] ?? '-').toString());
        }
        return displayValues.join(' ');
      }
    }
    final entries = values.entries.toList()
      ..sort((a, b) {
        final aKey = int.tryParse(a.key);
        final bKey = int.tryParse(b.key);
        if (aKey != null && bKey != null) return aKey.compareTo(bKey);
        return a.key.compareTo(b.key);
      });
    if (entries.length == 1) return entries.first.value.toString();
    return entries.map((e) => '${e.key}:${e.value}').join(' ');
  }

  String? _formatDisplayRefresh(String? value) {
    if (value == null || value.isEmpty) return null;
    final formatted = <String>[];
    for (final token in value.split(' ')) {
      final separator = token.indexOf(':');
      final prefix = separator < 0 ? '' : token.substring(0, separator + 1);
      final raw = separator < 0 ? token : token.substring(separator + 1);
      final millihz = int.tryParse(raw);
      if (millihz == null || millihz <= 0) {
        formatted.add('$prefix-');
        continue;
      }
      final hz = (millihz / 1000)
          .toStringAsFixed(millihz % 1000 == 0 ? 0 : 2);
      formatted.add('$prefix$hz');
    }
    return formatted.isEmpty ? null : formatted.join(' ');
  }

  void updateQualityStatusEvent(QualityStatusSessionEvent event) {
    try {
      final evt = event.values;
      String? eventString(String key) {
        final value = evt[key];
        return value is String && value.isNotEmpty ? value : null;
      }

      if (evt.containsKey('connection_type')) {
        final connectionType = eventString('connection_type');
        if (_data.connectionType != connectionType) {
          _data.clearQuicTransportMetrics();
        }
        _data.connectionType = connectionType;
      }
      final isQuicTransport = _data.isQuicTransport;
      if (!isQuicTransport) {
        _data.clearQuicTransportMetrics();
      }
      void updateTransportMetric(
          String key, void Function(String? value) update) {
        if (evt.containsKey(key)) {
          update(isQuicTransport ? eventString(key) : null);
        }
      }

      if (evt.containsKey('speed') && (evt['speed'] as String).isNotEmpty) {
        _data.speed = evt['speed'];
      }
      final fps = event.displayMap('fps');
      if (fps != null && fps.isNotEmpty) {
        final pi = parent?.target?.ffiModel.pi;
        if (pi != null) {
          final currentDisplay = pi.currentDisplay;
          if (currentDisplay != kAllDisplayValue) {
            final fps2 = fps[currentDisplay.toString()];
            if (fps2 != null) {
              _data.fps = fps2.toString();
            }
          } else if (fps.isNotEmpty) {
            final fpsList = [];
            for (var i = 0; i < pi.displays.length; i++) {
              fpsList.add((fps[i.toString()] ?? 0).toString());
            }
            _data.fps = fpsList.join(' ');
          }
        } else {
          _data.fps = null;
        }
      }
      if (evt.containsKey('delay') && (evt['delay'] as String).isNotEmpty) {
        _data.delay = evt['delay'];
      }
      if (evt.containsKey('target_bitrate') &&
          (evt['target_bitrate'] as String).isNotEmpty) {
        _data.targetBitrate = evt['target_bitrate'];
      }
      if (evt.containsKey('codec_format') &&
          (evt['codec_format'] as String).isNotEmpty) {
        _data.codecFormat = evt['codec_format'];
      }
      if (evt.containsKey('chroma') && (evt['chroma'] as String).isNotEmpty) {
        _data.chroma = evt['chroma'];
      }
      updateTransportMetric(
          'transport_mtu', (value) => _data.transportMtu = value);
      updateTransportMetric(
          'transport_rtt_ms', (value) => _data.transportRttMs = value);
      updateTransportMetric('transport_lost_packets',
          (value) => _data.transportLostPackets = value);
      updateTransportMetric(
          'datagram_payload', (value) => _data.datagramPayload = value);
      updateTransportMetric('negotiated_datagram_payload',
          (value) => _data.negotiatedDatagramPayload = value);
      updateTransportMetric(
          'quic_protocol', (value) => _data.quicProtocol = value);
      updateTransportMetric(
          'quic_video_transport', (value) => _data.quicVideoTransport = value);
      updateTransportMetric('quic_reassembly_drops',
          (value) => _data.quicReassemblyDrops = value);
      updateTransportMetric('quic_reassembly_reasons',
          (value) => _data.quicReassemblyReasons = value);
      updateTransportMetric('quic_reassembly_frame',
          (value) => _data.quicReassemblyFrame = value);
      updateTransportMetric('quic_reassembly_timing',
          (value) => _data.quicReassemblyTiming = value);
      updateTransportMetric('quic_keyframe_requests',
          (value) => _data.quicKeyframeRequests = value);
      updateTransportMetric('quic_keyframe_barrier',
          (value) => _data.quicKeyframeBarrier = value);
      updateTransportMetric('quic_receiver_recovery',
          (value) => _data.quicReceiverRecovery = value);
      updateTransportMetric('quic_sender_recovery',
          (value) => _data.quicSenderRecovery = value);
      updateTransportMetric('quic_sender_admission',
          (value) => _data.quicSenderAdmission = value);
      updateTransportMetric(
          'quic_sender_frame', (value) => _data.quicSenderFrame = value);
      updateTransportMetric('quic_sender_percentiles',
          (value) => _data.quicSenderPercentiles = value);
      updateTransportMetric(
          'quic_sender_space', (value) => _data.quicSenderSpace = value);
      updateTransportMetric('quic_disposable_drops',
          (value) => _data.quicDisposableDrops = value);
      updateTransportMetric('quic_video_queue_target_ms',
          (value) => _data.quicVideoQueueTargetMs = value);
      final hostVersion = _hostVersion();
      if (hostVersion != null) {
        _data.hostVersion = hostVersion;
      }
      if ((_data.clientVersion == null || _data.clientVersion!.isEmpty) &&
          version.isNotEmpty) {
        _data.clientVersion = version;
      }
      if (evt.containsKey('decoder') &&
          (evt['decoder'] as String).isNotEmpty) {
        _data.decoder = evt['decoder'];
      }
      if (evt.containsKey('renderer') &&
          (evt['renderer'] as String).isNotEmpty) {
        _data.renderer = evt['renderer'];
      }
      if (evt.containsKey('capture_backend') &&
          (evt['capture_backend'] as String).isNotEmpty) {
        _data.captureBackend = evt['capture_backend'];
      }
      if (evt.containsKey('capture_frame') &&
          (evt['capture_frame'] as String).isNotEmpty) {
        _data.captureFrame = evt['capture_frame'];
      }
      if (evt.containsKey('encoder_backend') &&
          (evt['encoder_backend'] as String).isNotEmpty) {
        _data.encoderBackend = evt['encoder_backend'];
      }
      if (evt.containsKey('encoder_input') &&
          (evt['encoder_input'] as String).isNotEmpty) {
        _data.encoderInput = evt['encoder_input'];
      }
      if (event.contains('decode_fps')) {
        _data.decodeFps = _displayMetricFromValues(
          event.displayMap('decode_fps'),
        );
      }
      if (event.contains('video_queue')) {
        _data.videoQueue = _displayMetricFromValues(
          event.displayMap('video_queue'),
        );
      }
      if (event.contains('frame_resolution')) {
        _data.frameResolution = _displayMetricFromValues(
          event.displayMap('frame_resolution'),
        );
      }
      if (evt.containsKey('video_threads') &&
          (evt['video_threads'] as String).isNotEmpty) {
        _data.videoThreads = evt['video_threads'];
      }
      if (evt.containsKey('texture_render') &&
          (evt['texture_render'] as String).isNotEmpty) {
        _data.textureRender =
            evt['texture_render'] == 'true' ? 'enabled' : 'disabled';
      }
      if (evt.containsKey('direct') && (evt['direct'] as String).isNotEmpty) {
        _data.direct = _directLabel(evt['direct']);
      }
      if (evt.containsKey('fps_mode') &&
          (evt['fps_mode'] as String).isNotEmpty) {
        _data.fpsMode = evt['fps_mode'];
      }
      if (evt.containsKey('auto_fps') &&
          (evt['auto_fps'] as String).isNotEmpty) {
        _data.autoFps = evt['auto_fps'];
      }
      if (event.contains('video_progress')) {
        _data.videoProgress = _displayMetricFromValues(
          event.displayMap('video_progress'),
        );
      }
      if (event.contains('video_dropped')) {
        _data.videoDropped = _displayMetricFromValues(
          event.displayMap('video_dropped'),
        );
      }
      if (event.contains('video_decode_time_us')) {
        _data.videoDecodeTimeUs = _displayMetricFromValues(
          event.displayMap('video_decode_time_us'),
        );
      }
      if (event.contains('video_render_submit_time_us')) {
        _data.videoRenderSubmitTimeUs = _displayMetricFromValues(
          event.displayMap('video_render_submit_time_us'),
        );
      }
      if (event.contains('video_feedback_queue')) {
        _data.videoFeedbackQueue = _displayMetricFromValues(
          event.displayMap('video_feedback_queue'),
        );
      }
      if (event.contains('display_refresh_millihz')) {
        final millihz = _displayMetricFromValues(
          event.displayMap('display_refresh_millihz'),
        );
        _data.displayRefresh = _formatDisplayRefresh(millihz);
      }
      if (evt.containsKey('video_delivery_phase') &&
          (evt['video_delivery_phase'] as String).isNotEmpty) {
        final phase = evt['video_delivery_phase'] as String;
        _data.videoDeliveryPhase = phase.isEmpty
            ? null
            : '${phase[0].toUpperCase()}${phase.substring(1)}';
      }
      if (evt.containsKey('video_recovery_count') &&
          (evt['video_recovery_count'] as String).isNotEmpty) {
        _data.videoRecoveryCount = evt['video_recovery_count'];
      }
      if (evt.containsKey('video_stall_ms') &&
          (evt['video_stall_ms'] as String).isNotEmpty) {
        _data.videoStallMs = evt['video_stall_ms'];
      }
      if (evt.containsKey('requested_video_profile') &&
          (evt['requested_video_profile'] as String).isNotEmpty) {
        _data.requestedVideoProfile = evt['requested_video_profile'];
        if (_data.requestedVideoProfile != kVideoProfileMovie) {
          _data.movieTargetFps = null;
          _data.moviePacingFps = null;
          _data.movieHostPipelineP95Us = null;
          _data.movieFallbackReason = null;
          _data.moviePlayoutDelayMs = null;
        }
      }
      if (evt.containsKey('effective_video_profile') &&
          (evt['effective_video_profile'] as String).isNotEmpty) {
        _data.effectiveVideoProfile = evt['effective_video_profile'];
        if (_data.effectiveVideoProfile == 'movie-full') {
          _data.movieFallbackReason = null;
        }
      }
      if (evt.containsKey('movie_target_fps') &&
          (evt['movie_target_fps'] as String).isNotEmpty) {
        _data.movieTargetFps = evt['movie_target_fps'];
      }
      if (evt.containsKey('movie_pacing_fps') &&
          (evt['movie_pacing_fps'] as String).isNotEmpty) {
        _data.moviePacingFps = evt['movie_pacing_fps'];
      }
      if (evt.containsKey('movie_host_pipeline_p95_us') &&
          (evt['movie_host_pipeline_p95_us'] as String).isNotEmpty) {
        _data.movieHostPipelineP95Us = evt['movie_host_pipeline_p95_us'];
      }
      if (evt.containsKey('movie_fallback_reason') &&
          (evt['movie_fallback_reason'] as String).isNotEmpty) {
        _data.movieFallbackReason = evt['movie_fallback_reason'];
      }
      if (evt.containsKey('movie_playout_delay_ms') &&
          (evt['movie_playout_delay_ms'] as String).isNotEmpty) {
        _data.moviePlayoutDelayMs = evt['movie_playout_delay_ms'];
      }
      notifyListeners();
    } catch (e) {
      //
    }
  }

  @override
  void dispose() {
    _floatingPositionStoreTimer?.cancel();
    _floatingSizeStoreTimer?.cancel();
    showListenable.dispose();
    super.dispose();
  }
}

class RecordingModel with ChangeNotifier {
  WeakReference<FFI> parent;
  RecordingModel(this.parent);
  bool _start = false;
  bool get start => _start;

  toggle() async {
    if (isIOS) return;
    final sessionId = parent.target?.sessionId;
    if (sessionId == null) return;
    final pi = parent.target?.ffiModel.pi;
    if (pi == null) return;
    bool value = !_start;
    if (value) {
      await sessionRefreshVideo(sessionId, pi);
    }
    await bind.sessionRecordScreen(sessionId: sessionId, start: value);
  }

  updateStatus(bool status) {
    _start = status;
    notifyListeners();
  }
}

class ElevationModel with ChangeNotifier {
  WeakReference<FFI> parent;
  ElevationModel(this.parent);
  bool _running = false;
  bool _canElevate = false;
  bool get showRequestMenu => _canElevate && !_running;
  onPeerInfo(PeerInfo pi) {
    _canElevate = pi.capabilities.elevationRequest;
    _running = false;
  }

  onPortableServiceRunning(bool running) => _running = running;
}

// The index values of `ConnType` are same as rust protobuf.
enum ConnType {
  defaultConn,
  fileTransfer,
  portForward,
  rdp,
  viewCamera,
  terminal
}

/// Flutter state manager and data communication with the Rust core.
class FFI {
  var id = '';
  var version = '';
  var connType = ConnType.defaultConn;
  late SessionHandle<EventToUI> _sessionHandle;
  bool get closed => _sessionHandle.isClosed;
  int? hostWindowId;
  Future<void> Function(FFI ffi, String peerId)? onAuthenticated;

  /// dialogManager use late to ensure init after main page binding [globalKey]
  late final dialogManager = OverlayDialogManager();

  late final SessionID sessionId;
  late final ImageModel imageModel; // session
  late final FfiModel ffiModel; // session
  late final CursorModel cursorModel; // session
  late final CanvasModel canvasModel; // session
  late final ServerModel serverModel; // global
  late final ChatModel chatModel; // session
  late final FileModel fileModel; // session
  late final AbModel abModel; // global
  late final GroupModel groupModel; // global
  late final UserModel userModel; // global
  late final PeerTabModel peerTabModel; // global
  late final QualityMonitorModel qualityMonitorModel; // session
  late final RecordingModel recordingModel; // session
  late final InputModel inputModel; // session
  late final ElevationModel elevationModel; // session
  late final CmFileModel cmFileModel; // cm
  late final TextureModel textureModel; //session
  late final Peers recentPeersModel; // global
  late final Peers favoritePeersModel; // global
  late final Peers lanPeersModel; // global

  // Terminal model registry for multiple terminals
  final Map<int, TerminalModel> _terminalModels = {};
  // Getter for terminal models
  Map<int, TerminalModel> get terminalModels => _terminalModels;

  FFI(SessionID? sId) {
    sessionId = sId ?? (isDesktop ? Uuid().v4obj() : _constSessionId);
    _sessionHandle = _newSessionHandle();
    imageModel = ImageModel(WeakReference(this));
    ffiModel = FfiModel(WeakReference(this));
    cursorModel = CursorModel(WeakReference(this));
    canvasModel = CanvasModel(WeakReference(this));
    serverModel = ServerModel(WeakReference(this));
    chatModel = ChatModel(WeakReference(this));
    fileModel = FileModel(WeakReference(this));
    userModel = UserModel(WeakReference(this));
    peerTabModel = PeerTabModel(WeakReference(this));
    abModel = AbModel(WeakReference(this));
    groupModel = GroupModel(WeakReference(this));
    qualityMonitorModel = QualityMonitorModel(WeakReference(this));
    recordingModel = RecordingModel(WeakReference(this));
    inputModel = InputModel(WeakReference(this));
    elevationModel = ElevationModel(WeakReference(this));
    cmFileModel = CmFileModel(WeakReference(this));
    textureModel = TextureModel(WeakReference(this));
    recentPeersModel = Peers(
        name: PeersModelName.recent,
        loadEvent: LoadEvent.recent,
        getInitPeers: null);
    favoritePeersModel = Peers(
        name: PeersModelName.favorite,
        loadEvent: LoadEvent.favorite,
        getInitPeers: null);
    lanPeersModel = Peers(
        name: PeersModelName.lan, loadEvent: LoadEvent.lan, getInitPeers: null);
  }

  SessionHandle<EventToUI> _newSessionHandle() => SessionHandle<EventToUI>(
    sessionId: sessionId,
    closeNative: () => bind.sessionClose(sessionId: sessionId),
    releasePlatformLease: isAndroid
        ? (generation) => AndroidVpnSessionCoordinator.instance.release(
            generation: generation,
          )
        : null,
  );

  /// Mobile reuse FFI
  void mobileReset() {
    ffiModel.waitForFirstImage.value = true;
    ffiModel.isRefreshing = false;
    ffiModel.waitForImageDialogShow.value = true;
    ffiModel.waitForImageTimer?.cancel();
    ffiModel.waitForImageTimer = null;
  }

  /// Start with the given [id]. Only transfer file if [isFileTransfer], only view camera if [isViewCamera], only port forward if [isPortForward].
  Future<void> start(
    String id, {
    bool isFileTransfer = false,
    bool isViewCamera = false,
    bool isPortForward = false,
    bool isRdp = false,
    bool isTerminal = false,
    String? switchUuid,
    String? password,
    bool? isSharedPassword,
    String? connToken,
    bool? forceRelay,
    int? tabWindowId,
    int? display,
    List<int>? displays,
    bool attachExisting = false,
    String? cachedPeerData,
    int? hostWindowId,
    String? transferSourceSessionId,
  }) async {
    if (!_sessionHandle.isPristine) {
      final canReplace = await _sessionHandle.prepareForReplacement(
        cleanupClosedSession: isMobile ? _cleanupMobileSessionState : null,
      );
      if (!canReplace) {
        throw StateError('Previous remote session is not fully closed');
      }
      _sessionHandle = _newSessionHandle();
    }
    this.hostWindowId = hostWindowId;
    if (isMobile) mobileReset();
    final sessionKind = SessionKind.fromLegacyFlags(
      isFileTransfer: isFileTransfer,
      isViewCamera: isViewCamera,
      isPortForward: isPortForward,
      isRdp: isRdp,
      isTerminal: isTerminal,
    );
    connType = switch (sessionKind) {
      SessionKind.remoteDesktop => ConnType.defaultConn,
      SessionKind.fileTransfer => ConnType.fileTransfer,
      SessionKind.viewCamera => ConnType.viewCamera,
      SessionKind.portForward => ConnType.portForward,
      SessionKind.rdp => ConnType.portForward,
      SessionKind.terminal => ConnType.terminal,
    };
    if (sessionKind == SessionKind.remoteDesktop) {
      chatModel.resetClientMode();
      canvasModel.id = id;
      imageModel.id = id;
      cursorModel.peerId = id;
    }

    final isNewPeer = tabWindowId == null;
    final lease = await _sessionHandle.start(
      acquirePlatformLease: isAndroid
          ? () async {
              final coordinator = AndroidVpnSessionCoordinator.instance;
              final attached = await coordinator.attach(
                id,
                sessionId.toString(),
              );
              final generation = coordinator.activeSessionGeneration;
              if (!attached || generation == null) {
                throw StateError('Failed to protect the outgoing Android session');
              }
              return generation;
            }
          : null,
      addNative: () async {
        // If tabWindowId is set, this attaches another UI to an existing peer.
        if (isNewPeer && !attachExisting) {
          final addRes = isMobile
              ? await bind.sessionAddAsync(
                  sessionId: sessionId,
                  id: id,
                  isFileTransfer: isFileTransfer,
                  isViewCamera: isViewCamera,
                  isPortForward: isPortForward,
                  isRdp: isRdp,
                  isTerminal: isTerminal,
                  switchUuid: switchUuid ?? '',
                  forceRelay: forceRelay ?? false,
                  password: password ?? '',
                  isSharedPassword: isSharedPassword ?? false,
                  connToken: connToken,
                )
              : bind.sessionAddSync(
                  sessionId: sessionId,
                  id: id,
                  isFileTransfer: isFileTransfer,
                  isViewCamera: isViewCamera,
                  isPortForward: isPortForward,
                  isRdp: isRdp,
                  isTerminal: isTerminal,
                  switchUuid: switchUuid ?? '',
                  forceRelay: forceRelay ?? false,
                  password: password ?? '',
                  isSharedPassword: isSharedPassword ?? false,
                  connToken: connToken,
                );
          if (addRes.isNotEmpty) {
            throw StateError(addRes);
          }
        } else if (display != null) {
          if (displays == null) {
            throw StateError(
              'Cannot attach display $display without a display set',
            );
          }
          final addRes = bind.sessionAddExistedSync(
            id: id,
            sessionId: sessionId,
            displays: Int32List.fromList(displays),
            isViewCamera: isViewCamera,
          );
          if (addRes.isNotEmpty) {
            throw StateError(addRes);
          }
          ffiModel.pi.currentDisplay = display;
        }
      },
      prepareEvents: () async {
        if (isDesktop &&
            (connType == ConnType.defaultConn ||
                connType == ConnType.viewCamera)) {
          textureModel.updateCurrentDisplay(display ?? 0);
        }
        if (isDesktop) {
          inputModel.updateTrackpadSpeed();
        }
      },
      startEvents: () {
        if (isNewPeer || display == null || displays == null) {
          return bind.sessionStart(sessionId: sessionId, id: id);
        }
        return bind.sessionStartWithDisplays(
          sessionId: sessionId,
          id: id,
          displays: Int32List.fromList(displays),
        );
      },
    );
    if (lease == null) return;
    final sessionGeneration = lease.generation;
    final stream = lease.events;

    if (isWeb) {
      platformFFI.setRgbaCallback((int display, Uint8List data) {
        final frame = Uint8List.fromList(data);
        unawaited(
          _sessionHandle.dispatchEvent(
            sessionGeneration,
            () async {
              await onEvent2UIRgba();
              await imageModel.onRgba(display, frame);
            },
            onError: (error, stackTrace) {
              debugPrint('Web RGBA dispatch failed: $error');
              debugPrintStack(stackTrace: stackTrace);
            },
          ),
        );
      });
      this.id = id;
      _sessionHandle.connected(sessionGeneration);
      return;
    }

    final cb = ffiModel.startEventListener(sessionId, id);
    Future<void> handleCachedSessionData(
      String cachedData, {
      bool runAuthenticatedSetup = false,
    }) async {
      final data = CachedPeerData.fromString(cachedData);
      if (data == null) {
        debugPrint('Unreachable, the cached data cannot be decoded.');
        return;
      }
      ffiModel.setPermissions(data.permissions);
      await ffiModel.handleCachedPeerData(data, id);
      await sessionRefreshVideo(sessionId, ffiModel.pi);
      await bind.sessionRequestNewDisplayInitMsgs(
          sessionId: sessionId, display: ffiModel.pi.currentDisplay);
      if (runAuthenticatedSetup && connType == ConnType.defaultConn) {
        await ffiModel.tryUseAllMyDisplaysForTheRemoteSession(id);
      }
    }

    imageModel.updateUserTextureRender();
    final hasGpuTextureRender = bind.mainHasGpuTextureRender();
    final SimpleWrapper<bool> isToNewWindowNotified = SimpleWrapper(false);
    var streamCloseQueued = false;
    void reportEventError(Object error, StackTrace stackTrace) {
      debugPrint('Session event dispatch failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    Future<void> dispatchSessionEvent(Future<void> Function() dispatch) =>
        _sessionHandle.dispatchEvent(
          sessionGeneration,
          dispatch,
          onError: reportEventError,
        );

    Future<void> transferSessionToTab() async {
      final args = jsonEncode({
        'id': id,
        if (transferSourceSessionId != null)
          'session_id': transferSourceSessionId
        else if (display == null)
          'session_id': sessionId.toString(),
        'close': display == null,
      });
      final cachedData = await DesktopMultiWindow.invokeMethod(
        tabWindowId!,
        kWindowEventGetCachedSessionData,
        args,
      );
      if (cachedData == null) {
        debugPrint('Unreachable, the cached data is empty.');
        return;
      }
      await handleCachedSessionData(cachedData);
    }

    Future<void> handleSessionMessage(EventToUI message) async {
      if (message is EventToUI_Event) {
        Map<String, dynamic>? event;
        try {
          event = json.decode(message.field0);
        } catch (e) {
          debugPrint('json.decode fail1(): $e, ${message.field0}');
        }
        if (event != null) await cb(event);
      } else if (message is EventToUI_Rgba) {
        final display = message.field0;
        if (isAndroid) imageModel.setAndroidSurfaceTextureActive(false);
        final sz = platformFFI.getRgbaSize(sessionId, display);
        if (sz == 0) {
          platformFFI.nextRgba(sessionId, display);
          return;
        }
        final rgba = platformFFI.getRgba(sessionId, display, sz);
        if (rgba != null) {
          await onEvent2UIRgba();
          await imageModel.onRgba(display, rgba);
        } else {
          platformFFI.nextRgba(sessionId, display);
        }
      } else if (message is EventToUI_Texture) {
        final display = message.field0;
        final gpuTexture = message.field1;
        debugPrint(
          'EventToUI_Texture display:$display, gpuTexture:$gpuTexture',
        );
        if (gpuTexture && !hasGpuTextureRender) {
          debugPrint('the gpuTexture is not supported.');
          return;
        }
        if (isAndroid) {
          await imageModel.onAndroidSurfaceTextureFrame(display, gpuTexture);
        }
        textureModel.setTextureType(display: display, gpuTexture: gpuTexture);
        await onEvent2UIRgba();
      }
    }

    final subscription = stream.listen((message) {
      if (streamCloseQueued || !_sessionHandle.accepts(sessionGeneration)) {
        return;
      }
      if (message is EventToUI_Event && message.field0 == 'close') {
        streamCloseQueued = true;
        unawaited(_sessionHandle.remoteClosedAfterEvents(sessionGeneration));
        debugPrint('Exit session event loop');
        return;
      }
      if (tabWindowId != null && !isToNewWindowNotified.value) {
        isToNewWindowNotified.value = true;
        unawaited(dispatchSessionEvent(transferSessionToTab));
      }
      unawaited(dispatchSessionEvent(() => handleSessionMessage(message)));
    });
    await _sessionHandle.bindSubscription(sessionGeneration, subscription);
    if (!_sessionHandle.accepts(sessionGeneration)) return;
    // every instance will bind a stream
    this.id = id;
    _sessionHandle.connected(sessionGeneration);
    if (cachedPeerData != null) {
      Future.delayed(Duration.zero, () {
        if (!_sessionHandle.accepts(sessionGeneration)) return;
        unawaited(
          dispatchSessionEvent(
            () => handleCachedSessionData(
              cachedPeerData,
              runAuthenticatedSetup: attachExisting && tabWindowId == null,
            ),
          ),
        );
      });
    }
  }

  Future<void> onEvent2UIRgba() async {
    if (ffiModel.waitForImageDialogShow.isTrue) {
      ffiModel.waitForImageDialogShow.value = false;
      ffiModel.waitForImageTimer?.cancel();
      clearWaitingForImage(dialogManager, sessionId);
    }
    if (ffiModel.waitForFirstImage.value == true) {
      ffiModel.waitForFirstImage.value = false;
      dialogManager.dismissAll();
      await canvasModel.updateViewStyle();
      await canvasModel.updateScrollStyle();
      await canvasModel.initializeEdgeScrollEdgeThickness();
      for (final cb in imageModel.callbacksOnFirstImage) {
        cb(id);
      }
    }
  }

  /// Login with [password], choose if the client should [remember] it.
  void login(String osUsername, String osPassword, SessionID sessionId,
      String password, bool remember) {
    bind.sessionLogin(
        sessionId: sessionId,
        osUsername: osUsername,
        osPassword: osPassword,
        password: password,
        remember: remember);
  }

  void send2FA(SessionID sessionId, String code, bool trustThisDevice) {
    bind.sessionSend2Fa(
        sessionId: sessionId, code: code, trustThisDevice: trustThisDevice);
  }

  Future<void> _cleanupMobileSessionState() async {
    chatModel.close();
    for (final model in _terminalModels.values) {
      model.dispose();
    }
    _terminalModels.clear();
    await imageModel.update(null);
    cursorModel.clear();
    ffiModel.clear();
    canvasModel.clear();
    inputModel.setRelativeMouseMode(false);
    inputModel.resetModifiers();
    id = '';
    debugPrint('mobile session reset for fresh reconnect');
  }

  /// Clear session-scoped state while keeping the mobile page reusable.
  Future<void> resetMobileSessionForReconnect({
    required bool closeSession,
  }) => _sessionHandle.close(
    nativeClosePolicy: closeSession
        ? NativeSessionClosePolicy.requestClose
        : NativeSessionClosePolicy.alreadyClosed,
    cleanup: _cleanupMobileSessionState,
  );

  /// Close the remote session.
  Future<void> close(
      {bool closeSession = true, bool saveCanvasConfig = true}) =>
      _sessionHandle.close(
        nativeClosePolicy: closeSession
            ? NativeSessionClosePolicy.requestClose
            : NativeSessionClosePolicy.alreadyClosed,
        cleanup: () async {
          chatModel.close();
          // Close all terminal models
          for (final model in _terminalModels.values) {
            model.dispose();
          }
          _terminalModels.clear();
          if (saveCanvasConfig &&
              imageModel.hasRenderableFrame &&
              !isWebDesktop) {
            await setCanvasConfig(
                sessionId,
                cursorModel.x,
                cursorModel.y,
                canvasModel.x,
                canvasModel.y,
                canvasModel.scale,
                ffiModel.pi.currentDisplay);
          }
          imageModel.callbacksOnFirstImage.clear();
          await imageModel.update(null);
          cursorModel.clear();
          ffiModel.clear();
          canvasModel.clear();
          inputModel.resetModifiers();
          // Dispose relative mouse mode resources to ensure cursor is restored
          inputModel.disposeRelativeMouseMode();
          debugPrint('model $id closed');
          id = '';
        },
      );

  void setMethodCallHandler(FMethod callback) {
    platformFFI.setMethodCallHandler(callback);
  }

  Future<bool> invokeMethod(String method, [dynamic arguments]) async {
    return await platformFFI.invokeMethod(method, arguments);
  }

  // Terminal model management
  void registerTerminalModel(int terminalId, TerminalModel model) {
    debugPrint('[FFI] Registering terminal model for terminal $terminalId');
    _terminalModels[terminalId] = model;
  }

  void unregisterTerminalModel(int terminalId) {
    debugPrint('[FFI] Unregistering terminal model for terminal $terminalId');
    _terminalModels.remove(terminalId);
  }

  void routeTerminalResponseEvent(TerminalResponseSessionEvent event) {
    // Route to specific terminal model if it exists
    final model = _terminalModels[event.terminalId];
    if (model != null) {
      model.handleTerminalResponseEvent(event);
    }
  }
}

const kInvalidResolutionValue = -1;
const kVirtualDisplayResolutionValue = 0;

class Display {
  double x = 0;
  double y = 0;
  int width = 0;
  int height = 0;
  bool cursorEmbedded = false;
  int originalWidth = kInvalidResolutionValue;
  int originalHeight = kInvalidResolutionValue;
  double _scale = 1.0;
  double get scale => _scale > 1.0 ? _scale : 1.0;

  Display() {
    width = (isDesktop || isWebDesktop)
        ? kDesktopDefaultDisplayWidth
        : kMobileDefaultDisplayWidth;
    height = (isDesktop || isWebDesktop)
        ? kDesktopDefaultDisplayHeight
        : kMobileDefaultDisplayHeight;
  }

  @override
  bool operator ==(Object other) =>
      other is Display &&
      other.runtimeType == runtimeType &&
      _innerEqual(other);

  bool _innerEqual(Display other) =>
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.cursorEmbedded == cursorEmbedded;

  bool get isOriginalResolutionSet =>
      originalWidth != kInvalidResolutionValue &&
      originalHeight != kInvalidResolutionValue;
  bool get isVirtualDisplayResolution =>
      originalWidth == kVirtualDisplayResolutionValue &&
      originalHeight == kVirtualDisplayResolutionValue;
  bool get isOriginalResolution =>
      width == (originalWidth * scale).round() &&
      height == (originalHeight * scale).round();
}

class Resolution {
  int width = 0;
  int height = 0;
  Resolution(this.width, this.height);

  @override
  String toString() {
    return 'Resolution($width,$height)';
  }
}

class Features {
  bool privacyMode = false;
  bool keyboardV2CommittedText = false;
  bool keyboardV2PhysicalKey = false;
  bool keyboardV2LayoutAwareText = false;
}

const kInvalidDisplayIndex = -1;

class PeerInfo with ChangeNotifier {
  String version = '';
  String username = '';
  String hostname = '';
  String platform = '';
  bool sasEnabled = false;
  bool isSupportMultiUiSession = false;
  int currentDisplay = 0;
  int primaryDisplay = kInvalidDisplayIndex;
  RxList<Display> displays = <Display>[].obs;
  Features features = Features();
  List<Resolution> resolutions = [];
  Map<String, dynamic> platformAdditions = {};

  RxInt displaysCount = 0.obs;
  RxBool isSet = false.obs;

  bool get isWayland => platformAdditions[kPlatformAdditionsIsWayland] == true;
  bool get isHeadless => platformAdditions[kPlatformAdditionsHeadless] == true;
  bool get isInstalled =>
      !capabilities.isWindows ||
      platformAdditions[kPlatformAdditionsIsInstalled] == true;
  List<int> get RustDeskVirtualDisplays => List<int>.from(
      platformAdditions[kPlatformAdditionsRustDeskVirtualDisplays] ?? []);
  int get amyuniVirtualDisplayCount =>
      platformAdditions[kPlatformAdditionsAmyuniVirtualDisplays] ?? 0;

  bool get isSupportMultiDisplay =>
      (isDesktop || isWebDesktop) && isSupportMultiUiSession;
  bool get forceTextureRender => currentDisplay == kAllDisplayValue;

  bool get cursorEmbedded => tryGetDisplay()?.cursorEmbedded ?? false;

  bool get isRustDeskIdd =>
      platformAdditions[kPlatformAdditionsIddImpl] == 'rustdesk_idd';
  bool get isAmyuniIdd =>
      platformAdditions[kPlatformAdditionsIddImpl] == 'amyuni_idd';
  String get fullVersion =>
      platformAdditions[kPlatformAdditionsFullVersion] as String? ?? version;
  bool get supportCaptureBackend =>
      capabilities.captureBackendSelection;
  PeerCapabilityMatrix get capabilities =>
      PeerCapabilityMatrix.fromPeerInfo(
        platform: platform,
        sasEnabled: sasEnabled,
        captureBackendSelection:
            platformAdditions[kPlatformAdditionsSupportCaptureBackend] == true,
        keyboardV2CommittedText: features.keyboardV2CommittedText,
        keyboardV2PhysicalKey: features.keyboardV2PhysicalKey,
        keyboardV2LayoutAwareText: features.keyboardV2LayoutAwareText,
      );

  Display? tryGetDisplay({int? display}) {
    if (displays.isEmpty) {
      return null;
    }
    display ??= currentDisplay;
    if (display == kAllDisplayValue) {
      return displays[0];
    } else {
      if (display > 0 && display < displays.length) {
        return displays[display];
      } else {
        return displays[0];
      }
    }
  }

  Display? tryGetDisplayIfNotAllDisplay({int? display}) {
    if (displays.isEmpty) {
      return null;
    }
    display ??= currentDisplay;
    if (display == kAllDisplayValue) {
      return null;
    }
    if (display >= 0 && display < displays.length) {
      return displays[display];
    } else {
      return null;
    }
  }

  List<Display> getCurDisplays() {
    if (currentDisplay == kAllDisplayValue) {
      return displays;
    } else {
      if (currentDisplay >= 0 && currentDisplay < displays.length) {
        return [displays[currentDisplay]];
      } else {
        return [];
      }
    }
  }

  double scaleOfDisplay(int display) {
    if (display >= 0 && display < displays.length) {
      return displays[display].scale;
    }
    return 1.0;
  }

  Rect? getDisplayRect(int display) {
    final d = tryGetDisplayIfNotAllDisplay(display: display);
    if (d == null) return null;
    return Rect.fromLTWH(d.x, d.y, d.width.toDouble(), d.height.toDouble());
  }
}

const canvasKey = 'canvas';

Future<void> setCanvasConfig(
    SessionID sessionId,
    double xCursor,
    double yCursor,
    double xCanvas,
    double yCanvas,
    double scale,
    int currentDisplay) async {
  final p = <String, dynamic>{};
  p['xCursor'] = xCursor;
  p['yCursor'] = yCursor;
  p['xCanvas'] = xCanvas;
  p['yCanvas'] = yCanvas;
  p['scale'] = scale;
  p['currentDisplay'] = currentDisplay;
  await bind.sessionSetFlutterOption(
      sessionId: sessionId, k: canvasKey, v: jsonEncode(p));
}

Future<Map<String, dynamic>?> getCanvasConfig(SessionID sessionId) async {
  if (!isWebDesktop) return null;
  var p =
      await bind.sessionGetFlutterOption(sessionId: sessionId, k: canvasKey);
  if (p == null || p.isEmpty) return null;
  try {
    Map<String, dynamic> m = json.decode(p);
    return m;
  } catch (e) {
    return null;
  }
}

Future<void> initializeCursorAndCanvas(FFI ffi) async {
  var p = await getCanvasConfig(ffi.sessionId);
  int currentDisplay = 0;
  if (p != null) {
    currentDisplay = p['currentDisplay'];
  }
  if (p == null || currentDisplay != ffi.ffiModel.pi.currentDisplay) {
    ffi.cursorModel.updateDisplayOrigin(
        ffi.ffiModel.rect?.left ?? 0, ffi.ffiModel.rect?.top ?? 0,
        updateCursorPos: !isMobileClient);
    return;
  }
  double xCursor = p['xCursor'];
  double yCursor = p['yCursor'];
  double xCanvas = p['xCanvas'];
  double yCanvas = p['yCanvas'];
  double scale = p['scale'];
  ffi.cursorModel.updateDisplayOriginWithCursor(ffi.ffiModel.rect?.left ?? 0,
      ffi.ffiModel.rect?.top ?? 0, xCursor, yCursor);
  ffi.canvasModel.update(xCanvas, yCanvas, scale);
}

clearWaitingForImage(OverlayDialogManager? dialogManager, SessionID sessionId) {
  dialogManager?.dismissByTag('$sessionId-waiting-for-image');
}
