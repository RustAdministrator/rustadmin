import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/prototyping/mobile_remote_lab_page.dart';
import 'package:flutter_hbb/prototyping/mobile_remote_lab_revision.dart';
import 'package:window_manager/window_manager.dart';

const _configuredScreensDirectory = String.fromEnvironment(
  'RUSTADMIN_LAB_SCREENS',
);
const _labWindowTitle =
    'RustAdmin Mobile Remote Lab · $mobileRemoteLabRevisionLabel';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_isDesktopPlatform) {
    await windowManager.ensureInitialized();
  }

  runApp(const MobileRemoteLabApp());

  if (_isDesktopPlatform) {
    const options = WindowOptions(
      size: Size(1440, 920),
      minimumSize: Size(980, 700),
      center: true,
      title: _labWindowTitle,
      titleBarStyle: TitleBarStyle.normal,
    );
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setOpacity(1);
    });
  }
}

bool get _isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

class MobileRemoteLabApp extends StatefulWidget {
  const MobileRemoteLabApp({super.key});

  @override
  State<MobileRemoteLabApp> createState() => _MobileRemoteLabAppState();
}

class _MobileRemoteLabAppState extends State<MobileRemoteLabApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: _labWindowTitle,
      themeMode: _themeMode,
      theme: mobileRemoteLabTheme(Brightness.light),
      darkTheme: mobileRemoteLabTheme(Brightness.dark),
      home: MobileRemoteLabPage(
        initialScreensDirectory: _configuredScreensDirectory,
        themeMode: _themeMode,
        onThemeModeChanged: (value) {
          setState(() {
            _themeMode = value;
          });
        },
      ),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.noScaling),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
