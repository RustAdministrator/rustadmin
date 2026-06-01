import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';

void main() {
  test('clipboard direction defaults to bidirectional', () {
    for (final value in ['', ' N ', 'both', 'bidirectional', 'all']) {
      expect(
        normalizeClipboardDirectionPolicy(value),
        kClipboardDirectionBoth,
        reason: value,
      );
    }
  });

  test('clipboard direction preserves legacy receive-only value', () {
    for (final value in [
      'Y',
      'yes',
      'true',
      '1',
      'remote-to-local',
      'remote_to_local',
      'receive',
      'receive-only',
      'inbound',
    ]) {
      expect(
        normalizeClipboardDirectionPolicy(value),
        kClipboardDirectionRemoteToLocal,
        reason: value,
      );
    }
  });

  test('clipboard direction supports send-only and fails closed', () {
    for (final value in [
      'local-to-remote',
      'local_to_remote',
      'send',
      'send-only',
      'outbound',
    ]) {
      expect(
        normalizeClipboardDirectionPolicy(value),
        kClipboardDirectionLocalToRemote,
        reason: value,
      );
    }

    for (final value in ['off', 'none', 'disabled', 'unexpected']) {
      expect(
        normalizeClipboardDirectionPolicy(value),
        kClipboardDirectionOff,
        reason: value,
      );
    }
  });

  test('clipboard direction labels are user-facing', () {
    expect(clipboardDirectionPolicyLabel(kClipboardDirectionBoth),
        'Bidirectional');
    expect(clipboardDirectionPolicyLabel(kClipboardDirectionLocalToRemote),
        'Send clipboard to peer only');
    expect(clipboardDirectionPolicyLabel(kClipboardDirectionRemoteToLocal),
        'Receive clipboard from peer only');
    expect(clipboardDirectionPolicyLabel(kClipboardDirectionOff), 'Disabled');
  });

  test('clipboard direction menu orders disabled before enabled modes', () {
    expect(clipboardDirectionMenuKeys(), [
      kClipboardDirectionOff,
      kClipboardDirectionRemoteToLocal,
      kClipboardDirectionLocalToRemote,
      kClipboardDirectionBoth,
    ]);
  });

  test('clipboard direction session toggle value is normalized', () {
    expect(
      sessionClipboardDirectionToggleValue('send-only'),
      '$kSessionToggleClipboardDirectionPrefix'
      '$kClipboardDirectionLocalToRemote',
    );
    expect(
      sessionClipboardDirectionToggleValue('unexpected'),
      '$kSessionToggleClipboardDirectionPrefix$kClipboardDirectionOff',
    );
  });
}
