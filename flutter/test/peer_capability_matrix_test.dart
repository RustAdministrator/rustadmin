import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/peer_capability_matrix.dart';
import 'package:flutter_test/flutter_test.dart';

PeerCapabilityMatrix matrix({
  String platform = '',
  bool sasEnabled = false,
  bool captureBackendSelection = false,
  bool keyboardV2CommittedText = false,
  bool keyboardV2PhysicalKey = false,
  bool keyboardV2LayoutAwareText = false,
}) {
  return PeerCapabilityMatrix.fromPeerInfo(
    platform: platform,
    sasEnabled: sasEnabled,
    captureBackendSelection: captureBackendSelection,
    keyboardV2CommittedText: keyboardV2CommittedText,
    keyboardV2PhysicalKey: keyboardV2PhysicalKey,
    keyboardV2LayoutAwareText: keyboardV2LayoutAwareText,
  );
}

void main() {
  test('platform additions reject stale, malformed, and non-map payloads', () {
    expect(decodePeerPlatformAdditions(null), isEmpty);
    expect(decodePeerPlatformAdditions('not-json'), isEmpty);
    expect(decodePeerPlatformAdditions('[1, 2]'), isEmpty);
    expect(decodePeerPlatformAdditions('{"support_capture_backend":true}'), {
      'support_capture_backend': true,
    });
  });

  test('desktop platform family is explicit and deterministic', () {
    expect(matrix(platform: kPeerPlatformWindows).isDesktop, isTrue);
    expect(matrix(platform: kPeerPlatformMacOS).isDesktop, isTrue);
    expect(matrix(platform: kPeerPlatformLinux).isDesktop, isTrue);
    expect(matrix(platform: kPeerPlatformAndroid).isDesktop, isFalse);
    expect(matrix(platform: 'future-os').isDesktop, isFalse);
  });

  test('unknown peers receive no implicit optional capabilities', () {
    final capabilities = matrix(platform: 'future-os');
    expect(capabilities.mobileSystemActions, isFalse);
    expect(capabilities.desktopCursorControls, isFalse);
    expect(capabilities.captureBackendSelection, isFalse);
    expect(
      capabilities.physicalKeyInput(translateModeSupported: true),
      isFalse,
    );
  });

  test('legacy Windows translate mode keeps physical-key fallback', () {
    final capabilities = matrix(platform: kPeerPlatformWindows);
    expect(capabilities.physicalKeyInput(translateModeSupported: true), isTrue);
    expect(
      capabilities.physicalKeyInput(translateModeSupported: false),
      isFalse,
    );
  });

  test('explicit physical-key capability is platform independent', () {
    final capabilities = matrix(
      platform: 'future-os',
      keyboardV2PhysicalKey: true,
    );
    expect(
      capabilities.physicalKeyInput(translateModeSupported: false),
      isTrue,
    );
  });

  test('explicit negotiated capabilities are platform independent', () {
    final capabilities = matrix(
      platform: 'future-os',
      captureBackendSelection: true,
      keyboardV2CommittedText: true,
      keyboardV2LayoutAwareText: true,
    );
    expect(capabilities.captureBackendSelection, isTrue);
    expect(capabilities.keyboardV2CommittedText, isTrue);
    expect(capabilities.keyboardV2LayoutAwareText, isTrue);
  });

  test('elevation preserves Windows SAS fallback semantics', () {
    expect(matrix(platform: kPeerPlatformWindows).elevationRequest, isTrue);
    expect(
      matrix(platform: kPeerPlatformWindows, sasEnabled: true).elevationRequest,
      isFalse,
    );
    expect(matrix(platform: kPeerPlatformLinux).elevationRequest, isFalse);
  });
}
