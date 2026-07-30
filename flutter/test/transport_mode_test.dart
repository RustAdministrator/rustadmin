import 'package:flutter_hbb/common/transport_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy disable UDP always maps to TCP only', () {
    expect(
      remoteTransportPreferenceFromOptions(
        remoteTransport: 'quic-only',
        disableUdp: 'Y',
      ),
      RemoteTransportPreference.tcpOnly,
    );
  });

  test('empty and preferred values map to automatic QUIC', () {
    for (final value in ['', 'quic-preferred']) {
      expect(
        remoteTransportPreferenceFromOptions(
          remoteTransport: value,
          disableUdp: 'N',
        ),
        RemoteTransportPreference.auto,
      );
    }
  });

  test('all preferences serialize to consistent legacy options', () {
    expect(
      remoteTransportOption(RemoteTransportPreference.auto),
      'quic-preferred',
    );
    expect(disableUdpOption(RemoteTransportPreference.auto), 'N');
    expect(
      remoteTransportOption(RemoteTransportPreference.quicOnly),
      'quic-only',
    );
    expect(disableUdpOption(RemoteTransportPreference.quicOnly), 'N');
    expect(remoteTransportOption(RemoteTransportPreference.tcpOnly), 'tcp');
    expect(disableUdpOption(RemoteTransportPreference.tcpOnly), 'Y');
  });
}
