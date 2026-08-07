import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/desktop_home_page.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/session_tab.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart';
import 'package:flutter_hbb/desktop/widgets/first_run_wizard.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';
// import 'package:flutter/services.dart';

import '../../common/shared_state.dart';
import '../../common/widgets/dialog.dart';
import '../../utils/multi_window_manager.dart';
import '../../utils/platform_channel.dart';

class DesktopTabPage extends StatefulWidget {
  const DesktopTabPage({Key? key}) : super(key: key);

  @override
  State<DesktopTabPage> createState() => _DesktopTabPageState();

  static void onAddSetting(
      {SettingsTabKey initialPage = SettingsTabKey.general}) {
    try {
      DesktopTabController tabController = Get.find<DesktopTabController>();
      tabController.add(TabInfo(
          key: kTabLabelSettingPage,
          label: kTabLabelSettingPage,
          selectedIcon: Icons.build_sharp,
          unselectedIcon: Icons.build_outlined,
          page: DesktopSettingPage(
            key: const ValueKey(kTabLabelSettingPage),
            initialTabkey: initialPage,
          )));
    } catch (e) {
      debugPrintStack(label: '$e');
    }
  }
}

class _DesktopTabPageState extends State<DesktopTabPage> {
  final tabController = DesktopTabController(tabType: DesktopTabType.main);
  final SessionWindowHost _windowHost = const MainSessionWindowHost();
  late final MainWindowSessionBridge _sessionBridge;

  _DesktopTabPageState() {
    RemoteCountState.init();
    Get.put<DesktopTabController>(tabController);
    tabController.add(TabInfo(
        key: kTabLabelHomePage,
        label: kTabLabelHomePage,
        selectedIcon: Icons.home_sharp,
        unselectedIcon: Icons.home_outlined,
        closable: false,
        page: DesktopHomePage(
          key: const ValueKey(kTabLabelHomePage),
        )));
    RemoteCountState.find().value = 0;
    tabController.onSelected = _onSelected;
    tabController.onRemoved = _onRemoved;
  }

  @override
  void initState() {
    super.initState();
    _sessionBridge = MainWindowSessionBridge(
      openRemoteSession: _openRemoteSession,
      activateTab: _activateTab,
      activateRemoteSession: _activateRemoteSession,
      getCachedRemoteSession: _getCachedRemoteSession,
      getRemoteWindowCoords: _getRemoteWindowCoords,
      hasRemoteSessions: () => _remoteTabs.isNotEmpty,
      moveRemoteSessionFromDetachedWindow:
          _moveRemoteSessionFromDetachedWindow,
      closeRemoteSessions: _closeRemoteSessions,
    );
    MainWindowSessionBridge.register(_sessionBridge);
    // HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  Iterable<TabInfo> get _remoteTabs => tabController.state.value.tabs
      .where((tab) => tab.sessionKey?.kind == SessionTabKind.remoteDesktop);

  void _onSelected(String key) {
    if (bind.isIncomingOnly()) {
      if (key == kTabLabelHomePage) {
        windowManager.setSize(getIncomingOnlyHomeSize());
        setResizable(false);
      } else {
        windowManager.setSize(getIncomingOnlySettingsSize());
        setResizable(true);
      }
    }

    final page = tabController.widget(key);
    if (page is RemotePage) {
      bind.setCurSessionId(sessionId: page.ffi.sessionId);
      UnreadChatCountState.find(page.id).value = 0;
      page.reconnectIfStaleOnActivation();
      page.activateKeyboardInput();
    }
    _schedulePublishConnectionMenu();
  }

  void _onRemoved(int _, String key) {
    final remainingPeers = _remoteTabs
        .map((tab) => tab.sessionKey!.peerId)
        .toSet();
    final removedPeer = _peerIdForTabKey(key);
    if (removedPeer != null && !remainingPeers.contains(removedPeer)) {
      ConnectionTypeState.delete(removedPeer);
      stateGlobal.relativeMouseModeState.remove(removedPeer);
    }
    RemoteCountState.find().value = _remoteTabs.length;
    _schedulePublishConnectionMenu();
  }

  String? _peerIdForTabKey(String key) {
    for (final tab in tabController.state.value.tabs) {
      if (tab.key == key) {
        return tab.sessionKey?.peerId;
      }
    }
    const prefix = 'session:remoteDesktop:';
    if (!key.startsWith(prefix)) {
      return null;
    }
    final encodedPeerEnd = key.lastIndexOf(':');
    if (encodedPeerEnd <= prefix.length) {
      return null;
    }
    return Uri.decodeComponent(key.substring(prefix.length, encodedPeerEnd));
  }

  TabInfo? _findRemoteTab(String peerId, {String? sessionId}) {
    for (final tab in _remoteTabs) {
      final key = tab.sessionKey!;
      if (key.peerId == peerId &&
          (sessionId == null || key.sessionId == sessionId)) {
        return tab;
      }
    }
    return null;
  }

  Future<void> _syncTabBarWithWindowFullscreen() async {
    try {
      stateGlobal.setFullscreen(
        await windowManager.isFullScreen(),
        procWnd: false,
      );
    } catch (e) {
      debugPrint('Failed to refresh main-window fullscreen state: $e');
      stateGlobal.refreshTabBarVisibility();
    }
  }

  Future<bool> _openRemoteSession(RemoteSessionLaunch launch) async {
    if (!mounted) {
      return false;
    }
    final existing = _findRemoteTab(
      launch.peerId,
      sessionId: launch.sessionId,
    );
    if (existing != null) {
      tabController.jumpToByKey(existing.key);
      await _syncTabBarWithWindowFullscreen();
      await _windowHost.showAndFocus();
      return true;
    }

    final sessionKey = launch.tabKey;
    ConnectionTypeState.init(launch.peerId);
    late final RemotePage page;
    page = RemotePage(
      key: ValueKey(sessionKey.value),
      id: launch.peerId,
      sessionId: SessionID(launch.sessionId),
      password: launch.password,
      toolbarState: ToolbarState(),
      tabController: tabController,
      switchUuid: launch.switchUuid,
      forceRelay: launch.forceRelay,
      isSharedPassword: launch.isSharedPassword,
      pendingCachedPeerData: launch.pendingCachedPeerData,
      sessionTabKey: sessionKey,
      windowHost: _windowHost,
    );
    tabController.add(TabInfo(
      key: sessionKey.value,
      sessionKey: sessionKey,
      label: DesktopTab.tablabelGetter(launch.peerId).value,
      translateLabel: false,
      selectedIcon: Icons.desktop_windows_sharp,
      unselectedIcon: Icons.desktop_windows_outlined,
      onTabCloseButton: () => _closeSessionTab(sessionKey.value),
      page: page,
    ));
    RemoteCountState.find().value = _remoteTabs.length;
    _schedulePublishConnectionMenu();
    await _syncTabBarWithWindowFullscreen();
    await _windowHost.showAndFocus();
    return true;
  }

  Future<bool> _activateRemoteSession(String peerId) async {
    final tab = _findRemoteTab(peerId);
    if (tab == null) {
      return false;
    }
    tabController.jumpToByKey(tab.key);
    await _windowHost.showAndFocus();
    return true;
  }

  Future<bool> _activateTab(String tabId) async {
    var activated = tabController.jumpToByKey(tabId);
    if (!activated && tabId == kTabLabelSettingPage) {
      DesktopTabPage.onAddSetting();
      activated = tabController.jumpToByKey(tabId);
    }
    if (!activated) {
      return false;
    }
    await _windowHost.showAndFocus();
    return true;
  }

  Future<String?> _getCachedRemoteSession({
    required String peerId,
    required String? sessionId,
    required bool close,
  }) async {
    final tab = _findRemoteTab(peerId, sessionId: sessionId);
    if (tab == null || tab.page is! RemotePage) {
      return null;
    }
    final page = tab.page as RemotePage;
    final cachedData = page.ffi.ffiModel.cachedPeerData.toString();
    if (!close) {
      return cachedData;
    }
    return prepareRemoteSessionTransfer(
      cachedData: cachedData,
      releaseSourceTextures: page.prepareForSessionTransfer,
      detachSourceTab: () {
        closeSessionOnDispose[tab.sessionKey!.value] = false;
        tabController.closeBy(tab.key);
      },
    );
  }

  Future<bool> _moveRemoteSessionFromDetachedWindow({
    required int sourceWindowId,
    required String peerId,
    required String sessionId,
  }) async {
    try {
      final cachedData = await DesktopMultiWindow.invokeMethod(
        sourceWindowId,
        kWindowEventGetCachedSessionData,
        jsonEncode({
          'id': peerId,
          'session_id': sessionId,
          'close': true,
        }),
      );
      if (cachedData == null || cachedData.toString().isEmpty) {
        return false;
      }
      final opened = await _openRemoteSession(RemoteSessionLaunch(
        peerId: peerId,
        sessionId: sessionId,
        pendingCachedPeerData: cachedData.toString(),
      ));
      if (!opened) {
        await bind.sessionClose(sessionId: SessionID(sessionId));
      }
      return opened;
    } catch (e) {
      debugPrint('Move tab to main window failed for session $sessionId: $e');
      // The source window may have completed its detach before the IPC error
      // reached this isolate. A live no-window connection is not recoverable.
      await bind.sessionClose(sessionId: SessionID(sessionId));
      return false;
    }
  }

  Future<String?> _getRemoteWindowCoords() async {
    final selected = tabController.state.value.selectedTabInfo;
    if (selected.page is! RemotePage) {
      return null;
    }
    final page = selected.page as RemotePage;
    final ffi = page.ffi;
    final displayRect = ffi.ffiModel.displaysRect();
    if (displayRect == null) {
      return null;
    }
    final frame = await _windowHost.getFrame();
    ffi.cursorModel.moveLocal(0, 0);
    return jsonEncode(RemoteWindowCoords(
      frame,
      CanvasCoords.fromCanvasModel(ffi.canvasModel),
      CursorCoords.fromCursorModel(ffi.cursorModel),
      displayRect,
    ).toJson());
  }

  Future<bool> _closeRemoteSessions({
    required bool confirm,
    required bool detachedSessionsActive,
  }) async {
    final keys = _remoteTabs.map((tab) => tab.key).toList(growable: false);
    if (confirm &&
        (keys.isNotEmpty || detachedSessionsActive) &&
        !await closeConfirmDialog()) {
      return false;
    }
    for (final key in keys) {
      tabController.closeBy(key);
    }
    return true;
  }

  Future<void> _closeSessionTab(String key) async {
    if (await desktopTryShowTabAuditDialogCloseCancelled(
      id: key,
      tabController: tabController,
    )) {
      return;
    }
    tabController.closeBy(key);
  }

  void _schedulePublishConnectionMenu() {
    if (isMacOS) {
      unawaited(_publishConnectionMenu());
    }
  }

  Future<void> _publishConnectionMenu() async {
    final selected = tabController.state.value.selected;
    final tabs = tabController.state.value.tabs;
    final entries = <MacOSTabMenuEntry>[];

    void addTab(int index) {
      final tab = tabs[index];
      entries.add(MacOSTabMenuEntry(
        windowId: kMainWindowId,
        tabId: tab.key,
        title: tab.translateLabel ? translate(tab.label) : tab.label,
        selected: index == selected,
      ));
    }

    final homeIndex = tabs.indexWhere((tab) => tab.key == kTabLabelHomePage);
    if (homeIndex >= 0) {
      addTab(homeIndex);
    }
    final settingsIndex =
        tabs.indexWhere((tab) => tab.key == kTabLabelSettingPage);
    if (settingsIndex >= 0) {
      addTab(settingsIndex);
    } else {
      entries.add(MacOSTabMenuEntry(
        windowId: kMainWindowId,
        tabId: kTabLabelSettingPage,
        title: translate(kTabLabelSettingPage),
        selected: false,
      ));
    }
    for (var index = 0; index < tabs.length; index++) {
      if (index != homeIndex && index != settingsIndex) {
        addTab(index);
      }
    }
    await RdPlatformChannel.instance.updateMacOSTabMenu(
      kMainWindowId,
      entries,
    );
  }

  Widget _buildSessionTabMenu(String key) {
    final tab = tabController.state.value.tabs
        .firstWhereOrNull((tab) => tab.key == key);
    if (tab?.sessionKey?.kind != SessionTabKind.remoteDesktop) {
      return const SizedBox.shrink();
    }
    final sessionKey = tab!.sessionKey!;
    return Material(
      elevation: 6,
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => rustDeskWinManager.moveTabToNewWindow(
                kMainWindowId,
                sessionKey.peerId,
                sessionKey.sessionId,
                WindowType.RemoteDesktop,
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(translate('Move tab to new window')),
              ),
            ),
            InkWell(
              onTap: () => _closeSessionTab(key),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(translate('Close')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(
    String key,
    Widget icon,
    Widget label,
    TabThemeConf _,
  ) {
    final tab = tabController.state.value.tabs
        .firstWhereOrNull((tab) => tab.key == key);
    final peerId = tab?.sessionKey?.peerId;
    if (peerId == null) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [icon, label],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        icon,
        label,
        unreadMessageCountBuilder(UnreadChatCountState.find(peerId))
            .marginOnly(left: 4),
      ],
    );
  }

  /*
  bool _handleKeyEvent(KeyEvent event) {
    if (!mouseIn && event is KeyDownEvent) {
      print('key down: ${event.logicalKey}');
      shouldBeBlocked(_block, canBeBlocked);
    }
    return false; // allow it to propagate
  }
  */

  @override
  void dispose() {
    // HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    if (isMacOS) {
      unawaited(RdPlatformChannel.instance.updateMacOSTabMenu(
        kMainWindowId,
        const [],
      ));
    }
    MainWindowSessionBridge.unregister(_sessionBridge);
    Get.delete<DesktopTabController>();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabWidget = FirstRunWizardHost(
      child: Container(
          child: Scaffold(
              backgroundColor: Theme.of(context).colorScheme.background,
              body: DesktopTab(
                controller: tabController,
                selectedBorderColor: MyTheme.accent,
                tabBuilder: _buildTab,
                tabMenuBuilder: _buildSessionTabMenu,
                tail: Offstage(
                  offstage: bind.isIncomingOnly() || bind.isDisableSettings(),
                  child: ActionIcon(
                    message: 'Settings',
                    icon: IconFont.menu,
                    onTap: DesktopTabPage.onAddSetting,
                    isClose: false,
                  ),
                ),
              ))),
    );
    return isMacOS || kUseCompatibleUiMode
        ? tabWidget
        : Obx(
            () => DragToResizeArea(
              resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
              enableResizeEdges: windowManagerEnableResizeEdges,
              child: tabWidget,
            ),
          );
  }
}
