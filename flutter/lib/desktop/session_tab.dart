import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:window_manager/window_manager.dart';

enum SessionTabKind {
  remoteDesktop,
  fileTransfer,
  viewCamera,
  portForward,
  terminal,
}

@immutable
class SessionTabKey {
  const SessionTabKey({
    required this.kind,
    required this.peerId,
    required this.sessionId,
  });

  const SessionTabKey.remoteDesktop({
    required String peerId,
    required String sessionId,
  }) : this(
         kind: SessionTabKind.remoteDesktop,
         peerId: peerId,
         sessionId: sessionId,
       );

  final SessionTabKind kind;
  final String peerId;
  final String sessionId;

  String get value =>
      'session:${kind.name}:${Uri.encodeComponent(peerId)}:$sessionId';

  @override
  bool operator ==(Object other) =>
      other is SessionTabKey &&
      other.kind == kind &&
      other.peerId == peerId &&
      other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(kind, peerId, sessionId);

  @override
  String toString() => value;
}

@immutable
class RemoteSessionLaunch {
  const RemoteSessionLaunch({
    required this.peerId,
    required this.sessionId,
    this.password,
    this.isSharedPassword,
    this.switchUuid,
    this.forceRelay,
    this.pendingCachedPeerData,
  });

  final String peerId;
  final String sessionId;
  final String? password;
  final bool? isSharedPassword;
  final String? switchUuid;
  final bool? forceRelay;
  final String? pendingCachedPeerData;

  SessionTabKey get tabKey =>
      SessionTabKey.remoteDesktop(peerId: peerId, sessionId: sessionId);
}

bool shouldOpenRemoteSessionInMainWindow({
  required bool optionEnabled,
  required bool hostRegistered,
  required bool hasActiveDetachedRemoteWindow,
  required String? sessionId,
  required String? pendingCachedPeerData,
}) =>
    optionEnabled &&
    hostRegistered &&
    !hasActiveDetachedRemoteWindow &&
    sessionId != null &&
    sessionId.isNotEmpty &&
    pendingCachedPeerData != null &&
    pendingCachedPeerData.isNotEmpty;

bool shouldPreferActiveDetachedRemoteWindow({
  required bool mainWindowOptionEnabled,
  required bool hasActiveDetachedRemoteWindow,
}) =>
    mainWindowOptionEnabled && hasActiveDetachedRemoteWindow;

bool shouldRestoreRemoteKeyboardFocus({
  required bool windowBlurred,
  required bool canRequestFocus,
  required bool activeTab,
  required bool editableTextFocused,
}) =>
    !windowBlurred &&
    canRequestFocus &&
    activeTab &&
    !editableTextFocused;

bool shouldCloseMainWindowWithSessions({
  required bool hasHostedRemoteSessions,
}) =>
    hasHostedRemoteSessions;

Future<String?> prepareRemoteSessionTransfer({
  required String cachedData,
  required Future<void> Function() releaseSourceTextures,
  required void Function() detachSourceTab,
}) async {
  if (cachedData.isEmpty) {
    return null;
  }
  await releaseSourceTextures();
  detachSourceTab();
  return cachedData;
}

class MainWindowSessionBridge {
  MainWindowSessionBridge({
    required this.openRemoteSession,
    required this.activateTab,
    required this.activateRemoteSession,
    required this.getCachedRemoteSession,
    required this.getRemoteWindowCoords,
    required this.hasRemoteSessions,
    required this.moveRemoteSessionFromDetachedWindow,
    required this.closeRemoteSessions,
  });

  final Future<bool> Function(RemoteSessionLaunch launch) openRemoteSession;
  final Future<bool> Function(String tabId) activateTab;
  final Future<bool> Function(String peerId) activateRemoteSession;
  final Future<String?> Function({
    required String peerId,
    required String? sessionId,
    required bool close,
  })
  getCachedRemoteSession;
  final Future<String?> Function() getRemoteWindowCoords;
  final bool Function() hasRemoteSessions;
  final Future<bool> Function({
    required int sourceWindowId,
    required String peerId,
    required String sessionId,
  })
  moveRemoteSessionFromDetachedWindow;
  final Future<bool> Function({
    required bool confirm,
    required bool detachedSessionsActive,
  })
  closeRemoteSessions;

  static MainWindowSessionBridge? _current;

  static MainWindowSessionBridge? get current => _current;

  static void register(MainWindowSessionBridge bridge) {
    _current = bridge;
  }

  static void unregister(MainWindowSessionBridge bridge) {
    if (identical(_current, bridge)) {
      _current = null;
    }
  }
}

abstract class SessionWindowHost {
  const SessionWindowHost();

  bool get isMainWindow;
  int get windowId;

  Future<void> setFullscreen(bool value);
  Future<void> minimize();
  Future<void> showAndFocus();
  Future<Rect> getFrame();
  Future<void> setFrame(Rect frame);

  void syncFullscreenState(bool value) {
    stateGlobal.setFullscreen(value, procWnd: false);
  }
}

class MainSessionWindowHost extends SessionWindowHost {
  const MainSessionWindowHost();

  @override
  bool get isMainWindow => true;

  @override
  int get windowId => kMainWindowId;

  @override
  Future<void> setFullscreen(bool value) async {
    syncFullscreenState(value);
    await windowManager.setFullScreen(value);
  }

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<void> showAndFocus() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<Rect> getFrame() async {
    final position = await windowManager.getPosition();
    final size = await windowManager.getSize();
    return position & size;
  }

  @override
  Future<void> setFrame(Rect frame) async {
    await windowManager.setPosition(frame.topLeft);
    await windowManager.setSize(frame.size);
  }
}

class DetachedSessionWindowHost extends SessionWindowHost {
  const DetachedSessionWindowHost(this.windowId);

  @override
  final int windowId;

  WindowController get _controller => WindowController.fromWindowId(windowId);

  @override
  bool get isMainWindow => false;

  @override
  Future<void> setFullscreen(bool value) async {
    syncFullscreenState(value);
    await _controller.setFullscreen(value);
  }

  @override
  Future<void> minimize() => _controller.minimize();

  @override
  Future<void> showAndFocus() async {
    await _controller.show();
    await _controller.focus();
  }

  @override
  Future<Rect> getFrame() => _controller.getFrame();

  @override
  Future<void> setFrame(Rect frame) => _controller.setFrame(frame);
}
