import 'dart:convert';

import 'package:flutter_hbb/consts.dart';

Map<String, dynamic> decodePeerPlatformAdditions(Object? raw) {
  if (raw is! String || raw.isEmpty) return {};
  try {
    final decoded = json.decode(raw);
    return decoded is Map<String, dynamic> ? decoded : {};
  } catch (_) {
    return {};
  }
}

enum PeerPlatformKind { windows, macos, linux, android, other }

class PeerCapabilityMatrix {
  final PeerPlatformKind platform;
  final bool sasEnabled;
  final bool captureBackendSelection;
  final bool keyboardV2CommittedText;
  final bool keyboardV2PhysicalKey;
  final bool keyboardV2LayoutAwareText;

  const PeerCapabilityMatrix({
    required this.platform,
    required this.sasEnabled,
    required this.captureBackendSelection,
    required this.keyboardV2CommittedText,
    required this.keyboardV2PhysicalKey,
    required this.keyboardV2LayoutAwareText,
  });

  factory PeerCapabilityMatrix.fromPeerInfo({
    required String platform,
    required bool sasEnabled,
    required bool captureBackendSelection,
    required bool keyboardV2CommittedText,
    required bool keyboardV2PhysicalKey,
    required bool keyboardV2LayoutAwareText,
  }) {
    return PeerCapabilityMatrix(
      platform: switch (platform) {
        kPeerPlatformWindows => PeerPlatformKind.windows,
        kPeerPlatformMacOS => PeerPlatformKind.macos,
        kPeerPlatformLinux => PeerPlatformKind.linux,
        kPeerPlatformAndroid => PeerPlatformKind.android,
        _ => PeerPlatformKind.other,
      },
      sasEnabled: sasEnabled,
      captureBackendSelection: captureBackendSelection,
      keyboardV2CommittedText: keyboardV2CommittedText,
      keyboardV2PhysicalKey: keyboardV2PhysicalKey,
      keyboardV2LayoutAwareText: keyboardV2LayoutAwareText,
    );
  }

  bool get isWindows => platform == PeerPlatformKind.windows;
  bool get isMacOS => platform == PeerPlatformKind.macos;
  bool get isLinux => platform == PeerPlatformKind.linux;
  bool get isAndroid => platform == PeerPlatformKind.android;
  bool get isDesktop => isWindows || isMacOS || isLinux;

  bool get mobileSystemActions => isAndroid;
  bool get desktopCursorControls => isDesktop;
  bool get elevationRequest => isWindows && !sasEnabled;

  bool physicalKeyInput({required bool translateModeSupported}) {
    return keyboardV2PhysicalKey || (isWindows && translateModeSupported);
  }
}
