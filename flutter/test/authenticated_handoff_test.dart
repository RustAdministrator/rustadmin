import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _Ffi implements FFI {
  @override
  late final SessionID sessionId = const Uuid().v4obj();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A pre-login window whose host reported display 1 at login, with two displays.
FfiModel loggedInOnDisplay1() {
  final ffi = _Ffi();
  final model = FfiModel(WeakReference<FFI>(ffi));
  model.pi.displays.value = [Display(), Display()];
  model.pi.currentDisplay = 1;
  model.cachedPeerData.peerInfo = {'current_display': '1', 'username': 'u'};
  return model;
}

void main() {
  // The host's follow-window event switched the pre-login window to display 0 right after
  // login; the window that took the session over opened display 1 from the login snapshot,
  // bound its render target to display 1, and drew none of the frames of display 0.
  test('the handed-over session data carries the display the session shows now', () {
    final model = loggedInOnDisplay1();
    model.pi.currentDisplay = 0;

    final handed = CachedPeerData.fromString(model.handoffSnapshot())!;

    expect(handed.peerInfo['current_display'], '0');
    expect(handed.peerInfo['username'], 'u');
  });

  test('the handed-over session data keeps the login display when nothing switched', () {
    final model = loggedInOnDisplay1();

    final handed = CachedPeerData.fromString(model.handoffSnapshot())!;

    expect(handed.peerInfo['current_display'], '1');
  });

  // After the snapshot is taken, a switch in the pre-login window would make the host send
  // a display the new window has no render target for.
  test('the pre-login window does not follow the host window after the handover', () async {
    final model = loggedInOnDisplay1();
    model.debugMarkAuthenticatedHandoff();

    await model.handleFollowCurrentDisplayValue(0, model.sessionId, 'peer');

    expect(model.pi.currentDisplay, 1);
  });
}
