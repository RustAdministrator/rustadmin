import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/platform_channel.dart';

void main() {
  test('macOS tab menu entry serializes platform payload', () {
    const entry = MacOSTabMenuEntry(
      windowId: 7,
      tabId: 'session:remoteDesktop:123456789:session-7',
      title: 'Office Mac',
      selected: true,
    );

    expect(entry.toJson(), {
      'windowId': 7,
      'tabId': 'session:remoteDesktop:123456789:session-7',
      'title': 'Office Mac',
      'selected': true,
    });
  });
}
