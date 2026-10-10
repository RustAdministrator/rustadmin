import 'package:flutter_hbb/common/peer_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('diffPeerOptions', () {
    test('returns only what changed', () {
      final loaded = {'a': '1', 'b': '2', 'c': ''};
      expect(diffPeerOptions(loaded, {'a': '1', 'b': '2', 'c': ''}), isEmpty);
      expect(diffPeerOptions(loaded, {'a': '1', 'b': '3', 'c': ''}),
          {'b': '3'});
      expect(diffPeerOptions(loaded, {'a': '9', 'b': '2', 'c': 'x'}),
          {'a': '9', 'c': 'x'});
    });

    test('a key that was not loaded counts as changed', () {
      expect(diffPeerOptions({'a': '1'}, {'a': '1', 'new': 'v'}),
          {'new': 'v'});
    });

    test('an unchanged dialog writes nothing', () {
      // The case the old save() got wrong: every option was written back,
      // turning unset values into explicit ones.
      final loaded = {
        'image_quality': 'balanced',
        'keyboard_mode': '',
        'one-way-clipboard-redirection': 'both',
        'disable_clipboard': 'N',
      };
      expect(diffPeerOptions(loaded, Map.of(loaded)), isEmpty);
    });
  });

  group('effectiveClipboardDirection', () {
    String normalize(String value) =>
        const {'both', 'off', 'local-to-remote', 'remote-to-local'}
                .contains(value)
            ? value
            : 'both';

    test('the direction option wins when it is set', () {
      expect(
          effectiveClipboardDirection(
              directionOption: 'local-to-remote',
              legacyDisableClipboard: 'Y',
              off: 'off',
              normalize: normalize),
          'local-to-remote');
    });

    test('the legacy flag closes the clipboard only when it is exactly Y', () {
      for (final legacy in ['Y']) {
        expect(
            effectiveClipboardDirection(
                directionOption: '',
                legacyDisableClipboard: legacy,
                off: 'off',
                normalize: normalize),
            'off');
      }
      for (final legacy in ['', 'N', 'y', 'true']) {
        expect(
            effectiveClipboardDirection(
                directionOption: '',
                legacyDisableClipboard: legacy,
                off: 'off',
                normalize: normalize),
            'both',
            reason: legacy);
      }
    });
  });
}
