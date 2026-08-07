import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';

enum SystemWindowTheme { light, dark }

class MacOSTabMenuEntry {
  final int windowId;
  final String tabId;
  final String title;
  final bool selected;

  const MacOSTabMenuEntry({
    required this.windowId,
    required this.tabId,
    required this.title,
    required this.selected,
  });

  Map<String, Object> toJson() => {
        'windowId': windowId,
        'tabId': tabId,
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

  void setMacOSTabMenuHandler({
    required Future<bool> Function(int windowId, String tabId) activateTab,
    required Future<void> Function(bool value) setTabsInFullscreen,
  }) {
    assert(isMacOS);
    _hostMethodChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'activateTab':
          final args = call.arguments as Map<dynamic, dynamic>? ?? {};
          final windowId = args['windowId'];
          final tabId = args['tabId'];
          if (windowId is int && tabId is String && tabId.isNotEmpty) {
            return await activateTab(windowId, tabId);
          }
          return false;
        case 'setTabsInFullscreen':
          final args = call.arguments as Map<dynamic, dynamic>? ?? {};
          final value = args['value'];
          if (value is bool) {
            await setTabsInFullscreen(value);
            return true;
          }
          return false;
        default:
          return null;
      }
    });
  }

  Future<void> updateMacOSTabMenu(
      int windowId, List<MacOSTabMenuEntry> entries) {
    if (!isMacOS) {
      return Future.value();
    }
    return _hostMethodChannel.invokeMethod("updateTabMenu", {
      "windowId": windowId,
      "entries": entries.map((entry) => entry.toJson()).toList(),
      "tabsInFullscreen":
          mainGetLocalBoolOptionSync(kOptionAllowTabsInFullscreen),
    });
  }

  Future<void> updateMacOSTabsInFullscreen(bool value) {
    if (!isMacOS) {
      return Future.value();
    }
    return _hostMethodChannel.invokeMethod(
      "updateTabsInFullscreen",
      {"value": value},
    );
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
