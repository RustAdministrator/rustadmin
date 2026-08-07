enum RemoteTransportPreference { auto, quicOnly, tcpOnly }

RemoteTransportPreference remoteTransportPreferenceFromOptions({
  required String remoteTransport,
  required String disableUdp,
}) {
  if (disableUdp == 'Y' || remoteTransport == 'tcp') {
    return RemoteTransportPreference.tcpOnly;
  }
  if (remoteTransport == 'quic-only') {
    return RemoteTransportPreference.quicOnly;
  }
  return RemoteTransportPreference.auto;
}

String remoteTransportOption(RemoteTransportPreference preference) {
  switch (preference) {
    case RemoteTransportPreference.auto:
      return 'quic-preferred';
    case RemoteTransportPreference.quicOnly:
      return 'quic-only';
    case RemoteTransportPreference.tcpOnly:
      return 'tcp';
  }
}

String disableUdpOption(RemoteTransportPreference preference) {
  return preference == RemoteTransportPreference.tcpOnly ? 'Y' : 'N';
}

String remoteTransportLabel(RemoteTransportPreference preference) {
  switch (preference) {
    case RemoteTransportPreference.auto:
      return 'Auto (QUIC preferred)';
    case RemoteTransportPreference.quicOnly:
      return 'QUIC only';
    case RemoteTransportPreference.tcpOnly:
      return 'TCP only';
  }
}
