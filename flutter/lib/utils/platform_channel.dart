import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/common.dart';

enum SystemWindowTheme { light, dark }

class MacOSConnectionMenuEntry {
  final int windowId;
  final String peerId;
  final String title;
  final bool selected;

  const MacOSConnectionMenuEntry({
    required this.windowId,
    required this.peerId,
    required this.title,
    required this.selected,
  });

  Map<String, Object> toJson() => {
        'windowId': windowId,
        'peerId': peerId,
        'title': title,
        'selected': selected,
      };
}

/// The platform channel for RustDesk.
class RdPlatformChannel {
  RdPlatformChannel._();

  static final RdPlatformChannel _windowUtil = RdPlatformChannel._();

  static RdPlatformChannel get instance => _windowUtil;

  final MethodChannel _hostMethodChannel =
      MethodChannel("org.rustdesk.rustdesk/host");

  void setMacOSConnectionMenuHandler(
      Future<bool> Function(int windowId, String peerId) handler) {
    assert(isMacOS);
    _hostMethodChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'activateConnection':
          final args = call.arguments as Map<dynamic, dynamic>? ?? {};
          final windowId = args['windowId'];
          final peerId = args['peerId'];
          if (windowId is int && peerId is String && peerId.isNotEmpty) {
            return await handler(windowId, peerId);
          }
          return false;
        default:
          return null;
      }
    });
  }

  Future<void> updateMacOSConnectionMenu(
      int windowId, List<MacOSConnectionMenuEntry> entries) {
    if (!isMacOS) {
      return Future.value();
    }
    return _hostMethodChannel.invokeMethod("updateConnectionMenu", {
      "windowId": windowId,
      "entries": entries.map((entry) => entry.toJson()).toList(),
    });
  }

  /// Bump the position of the mouse cursor, if applicable
  Future<bool> bumpMouse({required int dx, required int dy}) async {
    // No debug output; this call is too chatty.

    bool? result = await _hostMethodChannel
      .invokeMethod("bumpMouse", {"dx": dx, "dy": dy});

    return result ?? false;
  }

  /// Change the theme of the system window
  Future<void> changeSystemWindowTheme(SystemWindowTheme theme) {
    assert(isMacOS);
    if (kDebugMode) {
      print(
          "[Window ${kWindowId ?? 'Main'}] change system window theme to ${theme.name}");
    }
    return _hostMethodChannel
        .invokeMethod("setWindowTheme", {"themeName": theme.name});
  }

  /// Terminate .app manually.
  Future<void> terminate() {
    assert(isMacOS);
    return _hostMethodChannel.invokeMethod("terminate");
  }
}
