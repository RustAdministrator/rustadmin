import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/desktop/session_tab.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

MainWindowSessionBridge _bridge() => MainWindowSessionBridge(
  openRemoteSession: (_) async => true,
  activateTab: (_) async => true,
  activateRemoteSession: (_) async => true,
  getCachedRemoteSession:
      ({required peerId, required sessionId, required close}) async => null,
  getRemoteWindowCoords: () async => null,
  hasRemoteSessions: () => false,
  moveRemoteSessionFromDetachedWindow:
      ({required sourceWindowId, required peerId, required sessionId}) async =>
          true,
  closeRemoteSessions:
      ({required confirm, required detachedSessionsActive}) async => true,
);

void main() {
  group('fullscreen tab visibility', () {
    test('uses the preference only while the window is fullscreen', () {
      expect(
        shouldShowDesktopTabBar(
          fullscreen: false,
          tabsInFullscreen: false,
        ),
        isTrue,
      );
      expect(
        shouldShowDesktopTabBar(
          fullscreen: false,
          tabsInFullscreen: true,
        ),
        isTrue,
      );
      expect(
        shouldShowDesktopTabBar(
          fullscreen: true,
          tabsInFullscreen: false,
        ),
        isFalse,
      );
      expect(
        shouldShowDesktopTabBar(
          fullscreen: true,
          tabsInFullscreen: true,
        ),
        isTrue,
      );
    });
  });

  group('SessionTabKey', () {
    test('includes kind, encoded peer, and Rust session identity', () {
      const key = SessionTabKey.remoteDesktop(
        peerId: 'peer:name/with spaces',
        sessionId: 'session-7',
      );

      expect(
        key.value,
        'session:remoteDesktop:peer%3Aname%2Fwith%20spaces:session-7',
      );
      expect(key.toString(), key.value);
    });

    test('allows simultaneous sessions for the same peer', () {
      const first = SessionTabKey.remoteDesktop(
        peerId: 'peer-1',
        sessionId: 'session-1',
      );
      const second = SessionTabKey.remoteDesktop(
        peerId: 'peer-1',
        sessionId: 'session-2',
      );

      expect(first, isNot(second));
      expect(first.value, isNot(second.value));
    });
  });

  group('main-window routing', () {
    test('requires the option, host, session, and cached handoff data', () {
      expect(
        shouldOpenRemoteSessionInMainWindow(
          optionEnabled: true,
          hostRegistered: true,
          hasActiveDetachedRemoteWindow: false,
          sessionId: 'session-1',
          pendingCachedPeerData: '{"peer":"peer-1"}',
        ),
        isTrue,
      );

      for (final values in <(bool, bool, bool, String?, String?)>[
        (false, true, false, 'session-1', '{}'),
        (true, false, false, 'session-1', '{}'),
        (true, true, true, 'session-1', '{}'),
        (true, true, false, null, '{}'),
        (true, true, false, '', '{}'),
        (true, true, false, 'session-1', null),
        (true, true, false, 'session-1', ''),
      ]) {
        expect(
          shouldOpenRemoteSessionInMainWindow(
            optionEnabled: values.$1,
            hostRegistered: values.$2,
            hasActiveDetachedRemoteWindow: values.$3,
            sessionId: values.$4,
            pendingCachedPeerData: values.$5,
          ),
          isFalse,
        );
      }
    });

    test('active detached window takes precedence over the main window', () {
      expect(
        shouldPreferActiveDetachedRemoteWindow(
          mainWindowOptionEnabled: true,
          hasActiveDetachedRemoteWindow: true,
        ),
        isTrue,
      );
      expect(
        shouldPreferActiveDetachedRemoteWindow(
          mainWindowOptionEnabled: true,
          hasActiveDetachedRemoteWindow: false,
        ),
        isFalse,
      );
      expect(
        shouldPreferActiveDetachedRemoteWindow(
          mainWindowOptionEnabled: false,
          hasActiveDetachedRemoteWindow: true,
        ),
        isFalse,
      );
    });

    test('does not let a stale host unregister the current host', () {
      final first = _bridge();
      final second = _bridge();

      MainWindowSessionBridge.register(first);
      MainWindowSessionBridge.register(second);
      MainWindowSessionBridge.unregister(first);
      expect(MainWindowSessionBridge.current, same(second));

      MainWindowSessionBridge.unregister(second);
      expect(MainWindowSessionBridge.current, isNull);
    });

    test('restores keyboard focus only to an active remote surface', () {
      expect(
        shouldRestoreRemoteKeyboardFocus(
          windowBlurred: false,
          canRequestFocus: true,
          activeTab: true,
          editableTextFocused: false,
        ),
        isTrue,
      );

      for (final values in <(bool, bool, bool, bool)>[
        (true, true, true, false),
        (false, false, true, false),
        (false, true, false, false),
        (false, true, true, true),
      ]) {
        expect(
          shouldRestoreRemoteKeyboardFocus(
            windowBlurred: values.$1,
            canRequestFocus: values.$2,
            activeTab: values.$3,
            editableTextFocused: values.$4,
          ),
          isFalse,
        );
      }
    });

    test('main close requires confirmation when it hosts remote sessions', () {
      expect(
        shouldCloseMainWindowWithSessions(hasHostedRemoteSessions: true),
        isTrue,
      );
      expect(
        shouldCloseMainWindowWithSessions(hasHostedRemoteSessions: false),
        isFalse,
      );
    });

    test('session transfer releases source textures before detaching', () async {
      final events = <String>[];

      final cachedData = await prepareRemoteSessionTransfer(
        cachedData: '{"peer":"peer-1"}',
        releaseSourceTextures: () async => events.add('release-textures'),
        detachSourceTab: () => events.add('detach-tab'),
      );

      expect(cachedData, '{"peer":"peer-1"}');
      expect(events, ['release-textures', 'detach-tab']);
    });

    test('session transfer keeps source attached without cached data', () async {
      var releasedTextures = false;
      var detachedTab = false;

      final cachedData = await prepareRemoteSessionTransfer(
        cachedData: '',
        releaseSourceTextures: () async => releasedTextures = true,
        detachSourceTab: () => detachedTab = true,
      );

      expect(cachedData, isNull);
      expect(releasedTextures, isFalse);
      expect(detachedTab, isFalse);
    });

    test('session transfer does not detach when texture release fails', () async {
      var detachedTab = false;

      await expectLater(
        prepareRemoteSessionTransfer(
          cachedData: '{}',
          releaseSourceTextures: () async => throw StateError('release failed'),
          detachSourceTab: () => detachedTab = true,
        ),
        throwsStateError,
      );

      expect(detachedTab, isFalse);
    });
  });

  test('shared peer state remains until the final session releases it', () {
    const peerId = 'shared-state-session-peer';
    Get.testMode = true;

    initSharedStates(peerId);
    initSharedStates(peerId);
    final unread = UnreadChatCountState.find(peerId)..value = 3;

    removeSharedStates(peerId);
    expect(
      Get.isRegistered<RxInt>(tag: UnreadChatCountState.tag(peerId)),
      isTrue,
    );
    expect(UnreadChatCountState.find(peerId), same(unread));
    expect(UnreadChatCountState.find(peerId).value, 3);

    removeSharedStates(peerId);
    expect(
      Get.isRegistered<RxInt>(tag: UnreadChatCountState.tag(peerId)),
      isFalse,
    );
  });
}
