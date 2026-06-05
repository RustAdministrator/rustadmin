import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_hbb/prototyping/toolbar_lab_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_isDesktopPlatform) {
    await windowManager.ensureInitialized();
  }

  runApp(const ToolbarLabApp());

  if (_isDesktopPlatform) {
    final options = WindowOptions(
      size: const Size(1500, 920),
      center: true,
      title: 'RustAdmin Toolbar Lab',
      backgroundColor: Colors.transparent,
      titleBarStyle: TitleBarStyle.hidden,
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

class ToolbarLabApp extends StatelessWidget {
  const ToolbarLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'RustAdmin Toolbar Lab',
      themeMode: ThemeMode.system,
      theme: MyTheme.lightTheme,
      darkTheme: MyTheme.darkTheme,
      home: const ToolbarLabPage(),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(1.0),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
