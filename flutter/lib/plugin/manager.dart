// The plugin manager is a singleton class that manages the plugins.
// 1. It merge metadata and the desc of plugins.

import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/session_event.dart';

const String kValueTrue = '1';
const String kValueFalse = '0';

class ConfigItem {
  String key;
  String description;
  String defaultValue;

  ConfigItem(this.key, this.defaultValue, this.description);
  ConfigItem.fromJson(Map<String, dynamic> json)
      : key = json['key'] ?? '',
        description = json['description'] ?? '',
        defaultValue = json['default'] ?? '';

  static String get trueValue => kValueTrue;
  static String get falseValue => kValueFalse;
  static bool isTrue(String value) => value == kValueTrue;
  static bool isFalse(String value) => value == kValueFalse;
}

class UiType {
  String key;
  String text;
  String tooltip;
  String action;

  UiType(this.key, this.text, this.tooltip, this.action);

  UiType.fromJson(Map<String, dynamic> json)
      : key = json['key'] ?? '',
        text = json['text'] ?? '',
        tooltip = json['tooltip'] ?? '',
        action = json['action'] ?? '';

  static UiType? create(Map<String, dynamic> json) {
    if (json['t'] == 'Button') {
      return UiButton.fromJson(json['c']);
    } else if (json['t'] == 'Checkbox') {
      return UiCheckbox.fromJson(json['c']);
    } else {
      return null;
    }
  }
}

class UiButton extends UiType {
  String icon;

  UiButton(
      {required String key,
      required String text,
      required this.icon,
      required String tooltip,
      required String action})
      : super(key, text, tooltip, action);

  UiButton.fromJson(Map<String, dynamic> json)
      : icon = json['icon'] ?? '',
        super.fromJson(json);
}

class UiCheckbox extends UiType {
  UiCheckbox(
      {required String key,
      required String text,
      required String tooltip,
      required String action})
      : super(key, text, tooltip, action);

  UiCheckbox.fromJson(Map<String, dynamic> json) : super.fromJson(json);
}

class Location {
  // location key:
  //  host|main|settings|plugin
  //  client|remote|toolbar|display
  HashMap<String, UiType> ui;

  Location(this.ui);
  Location.fromJson(Map<String, dynamic> json) : ui = HashMap() {
    (json['ui'] as Map<String, dynamic>).forEach((key, value) {
      var ui = UiType.create(value);
      if (ui != null) {
        this.ui[ui.key] = ui;
      }
    });
  }
}

class PublishInfo {
  PublishInfo({
    required this.lastReleased,
    required this.published,
  });

  final DateTime lastReleased;
  final DateTime published;
}

class Meta {
  Meta({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.author,
    required this.home,
    required this.license,
    required this.publishInfo,
    required this.source,
  });

  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final String home;
  final String license;
  final PublishInfo publishInfo;
  final String source;
}

class SourceInfo {
  String name; // 1. RustDesk github 2. Local
  String url;
  String description;

  SourceInfo({
    required this.name,
    required this.url,
    required this.description,
  });
}

class PluginInfo with ChangeNotifier {
  SourceInfo sourceInfo;
  Meta meta;
  String installedVersion; // It is empty if not installed.
  String failedMsg;
  String invalidReason; // It is empty if valid.

  PluginInfo({
    required this.sourceInfo,
    required this.meta,
    required this.installedVersion,
    required this.invalidReason,
    this.failedMsg = '',
  });

  bool get installed => installedVersion.isNotEmpty;
  bool get needUpdate => installed && installedVersion != meta.version;

  void setInstall(String msg) {
    if (msg == "finished") {
      msg = '';
    }
    failedMsg = msg;
    if (msg.isEmpty) {
      installedVersion = meta.version;
    }
    notifyListeners();
  }

  void setUninstall(String msg) {
    failedMsg = msg;
    if (msg.isEmpty) {
      installedVersion = '';
    }
    notifyListeners();
  }
}

class PluginManager with ChangeNotifier {
  String failedReason = ''; // The reason of failed to load plugins.
  final List<PluginInfo> _plugins = [];

  PluginManager._();
  static final PluginManager _instance = PluginManager._();
  static PluginManager get instance => _instance;

  List<PluginInfo> get plugins => _plugins;

  PluginInfo? getPlugin(String id) {
    for (var p in _plugins) {
      if (p.meta.id == id) {
        return p;
      }
    }
    return null;
  }

  void handleCatalogEvent(PluginCatalogSessionEvent event) {
    _plugins
      ..clear()
      ..addAll(event.plugins.map(_pluginFromSessionValue));
    _sortPlugins();
    notifyListeners();
  }

  void handleInstallStatusEvent(PluginInstallStatusSessionEvent event) {
    if (event.install) {
      _handlePluginInstall(event.id, event.message);
    } else {
      _handlePluginUninstall(event.id, event.message);
    }
  }

  void _sortPlugins() {
    plugins.sort((a, b) {
      if (a.installed) {
        return -1;
      } else if (b.installed) {
        return 1;
      } else {
        return 0;
      }
    });
  }

  void _handlePluginInstall(String id, String msg) {
    debugPrint('Plugin \'$id\' install msg $msg');
    for (var i = 0; i < _plugins.length; i++) {
      if (_plugins[i].meta.id == id) {
        _plugins[i].setInstall(msg);
        _sortPlugins();
        notifyListeners();
        return;
      }
    }
  }

  void _handlePluginUninstall(String id, String msg) {
    debugPrint('Plugin \'$id\' uninstall msg $msg');
    for (var i = 0; i < _plugins.length; i++) {
      if (_plugins[i].meta.id == id) {
        _plugins[i].setUninstall(msg);
        _sortPlugins();
        notifyListeners();
        return;
      }
    }
  }

  PluginInfo _pluginFromSessionValue(SessionPluginCatalogValue value) {
    final source = SourceInfo(
      name: value.sourceName,
      url: value.sourceUrl,
      description: value.sourceDescription,
    );
    final meta = Meta(
      id: value.id,
      name: value.name,
      version: value.version,
      description: value.description,
      author: value.author,
      home: value.home,
      license: value.license,
      source: value.source,
      publishInfo: PublishInfo(
        lastReleased: value.lastReleased,
        published: value.published,
      ),
    );
    return PluginInfo(
      sourceInfo: source,
      meta: meta,
      installedVersion: value.installedVersion,
      invalidReason: value.invalidReason,
    );
  }
}

PluginManager get pluginManager => PluginManager.instance;
