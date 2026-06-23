import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/platform_channel.dart';

void main() {
  test('macOS connection menu entry serializes platform payload', () {
    const entry = MacOSConnectionMenuEntry(
      windowId: 7,
      peerId: '123456789',
      title: 'Office Mac',
      selected: true,
    );

    expect(entry.toJson(), {
      'windowId': 7,
      'peerId': '123456789',
      'title': 'Office Mac',
      'selected': true,
    });
  });
}
