import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:external_path/external_path.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/main.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../common.dart';
import '../generated_bridge.dart';

final class RgbaFrame extends Struct {
  @Uint32()
  external int len;
  external Pointer<Uint8> data;
}

typedef F3 = Pointer<Uint8> Function(Pointer<Utf8>, int);
typedef F3Dart = Pointer<Uint8> Function(Pointer<Utf8>, Int32);
typedef HandleEvent = Future<void> Function(Map<String, dynamic> evt);

/// FFI wrapper around the native Rust core.
/// Hides the platform differences.
class PlatformFFI {
  static const _flutterDiagnosticMaxBytes = 2 * 1024 * 1024;
  String _dir = '';
  // _homeDir is only needed for Android and IOS.
  String _homeDir = '';
  final _eventHandlers = <String, Map<String, HandleEvent>>{};
  late Rustadmin _ffiBind;
  late String _appType;
  StreamEventHandler? _eventCallback;
  File? _flutterDiagnosticFile;
  bool _androidDiagnosticLoggingEnabled = true;
  bool _androidDiagnosticHandlersInstalled = false;

  PlatformFFI._();

  static final PlatformFFI instance = PlatformFFI._();
  final _toAndroidChannel = const MethodChannel('mChannel');

  Rustadmin get ffiBind => _ffiBind;
  F3? _session_get_rgba;

  static get localeName => Platform.localeName;

  static get isMain => instance._appType == kAppTypeMain;

  static String getByName(String name, [String arg = '']) {
    return '';
  }

  static void setByName(String name, [String value = '']) {}

  @visibleForTesting
  void initForTest(Rustadmin ffiBind, {String appType = kAppTypeMain}) {
    assert(isTest);
    _appType = appType;
    _ffiBind = ffiBind;
  }

  static Future<String> getVersion() async {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  bool registerEventHandler(
      String eventName, String handlerName, HandleEvent handler,
      {bool replace = false}) {
    debugPrint('registerEventHandler $eventName $handlerName');
    var handlers = _eventHandlers[eventName];
    if (handlers == null) {
      _eventHandlers[eventName] = {handlerName: handler};
      return true;
    } else {
      if (!replace && handlers.containsKey(handlerName)) {
        return false;
      } else {
        handlers[handlerName] = handler;
        return true;
      }
    }
  }

  void unregisterEventHandler(String eventName, String handlerName) {
    debugPrint('unregisterEventHandler $eventName $handlerName');
    var handlers = _eventHandlers[eventName];
    if (handlers != null) {
      handlers.remove(handlerName);
    }
  }

  String translate(String name, String locale) =>
      _ffiBind.translate(name: name, locale: locale);

  Uint8List? getRgba(SessionID sessionId, int display, int bufSize) {
    if (_session_get_rgba == null) return null;
    final sessionIdStr = sessionId.toString();
    var a = sessionIdStr.toNativeUtf8();
    try {
      final buffer = _session_get_rgba!(a, display);
      if (buffer == nullptr) {
        return null;
      }
      final data = buffer.asTypedList(bufSize);
      return data;
    } finally {
      malloc.free(a);
    }
  }

  int getRgbaSize(SessionID sessionId, int display) =>
      _ffiBind.sessionGetRgbaSize(sessionId: sessionId, display: display);
  void nextRgba(SessionID sessionId, int display) =>
      _ffiBind.sessionNextRgba(sessionId: sessionId, display: display);
  void registerPixelbufferTexture(SessionID sessionId, int display, int ptr) =>
      _ffiBind.sessionRegisterPixelbufferTexture(
          sessionId: sessionId, display: display, ptr: ptr);
  void registerGpuTexture(SessionID sessionId, int display, int ptr) =>
      _ffiBind.sessionRegisterGpuTexture(
          sessionId: sessionId, display: display, ptr: ptr);
  void registerPixelbufferRenderTarget(
          SessionID sessionId, int display, int ptr, int token) =>
      _ffiBind.sessionRegisterPixelbufferRenderTarget(
          sessionId: sessionId, display: display, ptr: ptr, token: token);
  void unregisterPixelbufferRenderTarget(
          SessionID sessionId, int display, int token) =>
      _ffiBind.sessionUnregisterPixelbufferRenderTarget(
          sessionId: sessionId, display: display, token: token);
  void registerGpuRenderTarget(
          SessionID sessionId, int display, int ptr, int token) =>
      _ffiBind.sessionRegisterGpuRenderTarget(
          sessionId: sessionId, display: display, ptr: ptr, token: token);
  void unregisterGpuRenderTarget(
          SessionID sessionId, int display, int token) =>
      _ffiBind.sessionUnregisterGpuRenderTarget(
          sessionId: sessionId, display: display, token: token);
  int nextRenderTargetToken() => _ffiBind.getNextRenderTargetToken();

  /// Init the FFI class, loads the native Rust core library.
  Future<void> init(String appType) async {
    _appType = appType;
    final linuxLibraryPath =
        '${File(Platform.resolvedExecutable).parent.path}/lib/librustdesk.so';
    final dylib = isAndroid
        ? DynamicLibrary.open('librustdesk.so')
        : isLinux
            ? DynamicLibrary.open(File(linuxLibraryPath).existsSync()
                ? linuxLibraryPath
                : 'librustdesk.so')
            : isWindows
                ? DynamicLibrary.open('librustdesk.dll')
                :
                // Use executable itself as the dynamic library for MacOS.
                // Multiple dylib instances will cause some global instances to be invalid.
                // eg. `lazy_static` objects in rust side, will be created more than once, which is not expected.
                //
                // isMacOS? DynamicLibrary.open("liblibrustdesk.dylib") :
                DynamicLibrary.process();
    debugPrint('initializing FFI $_appType');
    try {
      _session_get_rgba = dylib.lookupFunction<F3Dart, F3>("session_get_rgba");
      try {
        // SYSTEM user failed
        _dir = (await getApplicationDocumentsDirectory()).path;
      } catch (e) {
        debugPrint('Failed to get documents directory: $e');
      }
      _ffiBind = RustadminImpl(dylib);

      if (isLinux) {
        if (isMain) {
          // Start a dbus service for uri links, no need to await
          _ffiBind.mainStartDbusServer();
        }
      } else if (isMacOS && isMain) {
        // Start ipc service for uri links.
        _ffiBind.mainStartIpcUrlServer();
      }
      _startListenEvent(_ffiBind); // global event
      try {
        if (isAndroid) {
          // only support for android
          final directories =
              await ExternalPath.getExternalStorageDirectories();
          if (directories != null && directories.isNotEmpty) {
            _homeDir = directories.first;
          }
        } else if (isIOS) {
          // The previous code was `_homeDir = (await getDownloadsDirectory())?.path ?? '';`,
          // which provided the `downloads` path in the sandbox.
          // It is unclear why we now use the `data` directory in the sandbox instead.
          _homeDir = _ffiBind.mainGetDataDirIos(appDir: _dir);
        } else {
          // no need to set home dir
        }
      } catch (e) {
        debugPrintStack(label: 'initialize failed: $e');
      }
      String id = 'NA';
      String name = 'Flutter';
      DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
      if (isAndroid) {
        AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        name = '${androidInfo.brand}-${androidInfo.model}';
        id = androidInfo.id.hashCode.toString();
        androidVersion = androidInfo.version.sdkInt;
      } else if (isIOS) {
        IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        name = iosInfo.utsname.machine;
        id = iosInfo.identifierForVendor.hashCode.toString();
      } else if (isLinux) {
        LinuxDeviceInfo linuxInfo = await deviceInfo.linuxInfo;
        name = linuxInfo.name;
        id = linuxInfo.machineId ?? linuxInfo.id;
      } else if (isWindows) {
        try {
          // request windows build number to fix overflow on win7
          windowsBuildNumber = getWindowsTargetBuildNumber();
          WindowsDeviceInfo winInfo = await deviceInfo.windowsInfo;
          name = winInfo.computerName;
          id = winInfo.computerName;
        } catch (e) {
          debugPrintStack(label: "get windows device info failed: $e");
          name = "unknown";
          id = "unknown";
        }
      } else if (isMacOS) {
        MacOsDeviceInfo macOsInfo = await deviceInfo.macOsInfo;
        name = macOsInfo.computerName;
        id = macOsInfo.systemGUID ?? '';
      }
      if (isAndroid || isIOS) {
        debugPrint(
            '_appType:$_appType,info1-id:$id,info2-name:$name,dir:$_dir,homeDir:$_homeDir');
      } else {
        debugPrint(
            '_appType:$_appType,info1-id:$id,info2-name:$name,dir:$_dir');
      }
      if (desktopType == DesktopType.cm) {
        await _ffiBind.cmInit();
      }
      await _ffiBind.mainDeviceId(id: id);
      await _ffiBind.mainDeviceName(name: name);
      await _ffiBind.mainSetHomeDir(home: _homeDir);
      await _ffiBind.mainInit(
        appDir: _dir,
        customClientConfig: '',
      );
      if (isAndroid) {
        final enabled = option2bool(
            kOptionEnableAndroidDiagnosticLogging,
            _ffiBind.mainGetLocalOption(
                key: kOptionEnableAndroidDiagnosticLogging));
        setAndroidDiagnosticLoggingEnabled(enabled);
      }
    } catch (e) {
      debugPrintStack(label: 'initialize failed: $e');
    }
    version = await getVersion();
  }

  Future<bool> tryHandle(Map<String, dynamic> evt) async {
    final name = evt['name'];
    if (name != null) {
      final handlers = _eventHandlers[name];
      if (handlers != null) {
        if (handlers.isNotEmpty) {
          for (var handler in handlers.values) {
            await handler(evt);
          }
          return true;
        }
      }
    }
    return false;
  }

  /// Start listening to the Rust core's events and frames.
  void _startListenEvent(Rustadmin rustdeskImpl) {
    final appType =
        _appType == kAppTypeDesktopRemote ? '$_appType,$kWindowId' : _appType;
    var sink = rustdeskImpl.startGlobalEventStream(appType: appType);
    sink.listen((message) {
      () async {
        try {
          Map<String, dynamic> event = json.decode(message);
          // _tryHandle here may be more flexible than _eventCallback
          if (!await tryHandle(event)) {
            if (_eventCallback != null) {
              await _eventCallback!(event);
            }
          }
        } catch (e) {
          debugPrint('json.decode fail(): $e');
        }
      }();
    });
  }

  void setEventCallback(StreamEventHandler fun) async {
    _eventCallback = fun;
  }

  void setRgbaCallback(void Function(int, Uint8List) fun) async {}

  void startDesktopWebListener() {}

  void stopDesktopWebListener() {}

  void setMethodCallHandler(FMethod callback) {
    _toAndroidChannel.setMethodCallHandler((call) async {
      callback(call.method, call.arguments);
      return null;
    });
  }

  invokeMethod(String method, [dynamic arguments]) async {
    if (!isAndroid) return Future<bool>(() => false);
    return await _toAndroidChannel.invokeMethod(method, arguments);
  }

  Future<String?> exportAndroidDiagnostics() async {
    if (!isAndroid) return null;
    return _toAndroidChannel.invokeMethod<String>('export_diagnostics');
  }

  Future<void> clearAndroidDiagnostics() async {
    if (!isAndroid) return;
    await _toAndroidChannel.invokeMethod<void>('clear_diagnostics');
  }

  Future<int?> createAndroidRemoteVideoTexture({
    required int display,
    required int width,
    required int height,
  }) async {
    if (!isAndroid) return null;
    try {
      return await _toAndroidChannel.invokeMethod<int>(
        'create_remote_video_texture',
        {'display': display, 'width': width, 'height': height},
      );
    } on PlatformException catch (error) {
      debugPrint('Failed to create Android remote video texture: $error');
      return null;
    }
  }

  Future<void> releaseAndroidRemoteVideoTexture({
    required int display,
    required int textureId,
  }) async {
    if (!isAndroid) return;
    try {
      await _toAndroidChannel.invokeMethod<bool>(
        'release_remote_video_texture',
        {'display': display, 'texture_id': textureId},
      );
    } on PlatformException catch (error) {
      debugPrint('Failed to release Android remote video texture: $error');
    }
  }

  void syncAndroidServiceAppDirConfigPath() {
    invokeMethod(AndroidChannel.kSyncAppDirConfigPath, _dir);
  }

  void setAndroidDiagnosticLoggingEnabled(bool enabled) {
    _androidDiagnosticLoggingEnabled = enabled;
    if (_dir.isEmpty) return;
    try {
      if (enabled && _flutterDiagnosticFile == null) {
        final directory = Directory('$_dir/diagnostics')
          ..createSync(recursive: true);
        _flutterDiagnosticFile = File('${directory.path}/flutter-errors.log');
        _rotateFlutterDiagnosticFileIfNeeded();
      }

      if (!_androidDiagnosticHandlersInstalled) {
        _androidDiagnosticHandlersInstalled = true;
        final previousFlutterHandler = FlutterError.onError;
        FlutterError.onError = (details) {
          _appendFlutterDiagnostic(
              'FlutterError', details.exception, details.stack);
          previousFlutterHandler?.call(details);
        };

        final previousPlatformHandler = PlatformDispatcher.instance.onError;
        PlatformDispatcher.instance.onError = (error, stack) {
          _appendFlutterDiagnostic('PlatformDispatcher', error, stack);
          return previousPlatformHandler?.call(error, stack) ?? false;
        };
      }
    } catch (_) {
      _flutterDiagnosticFile = null;
    }
  }

  void _appendFlutterDiagnostic(
      String source, Object error, StackTrace? stack) {
    if (!_androidDiagnosticLoggingEnabled) return;
    final file = _flutterDiagnosticFile;
    if (file == null) return;
    try {
      _rotateFlutterDiagnosticFileIfNeeded();
      var entry = '${DateTime.now().toUtc().toIso8601String()} '
          '[$source] $error\n${stack ?? ''}\n';
      if (entry.length > 64 * 1024) {
        entry = '${entry.substring(0, 64 * 1024)}\n[truncated]\n';
      }
      file.writeAsStringSync(entry, mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  void _rotateFlutterDiagnosticFileIfNeeded() {
    final file = _flutterDiagnosticFile;
    if (file == null || !file.existsSync()) return;
    if (file.lengthSync() < _flutterDiagnosticMaxBytes) return;
    final previous = File('${file.path}.1');
    if (previous.existsSync()) previous.deleteSync();
    file.renameSync(previous.path);
  }

  void setFullscreenCallback(void Function(bool) fun) {}
}
