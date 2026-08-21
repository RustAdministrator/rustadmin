bool isResettablePeerTrustError(String text) {
  if (text.startsWith('Handshake failed: peer identity changed')) {
    return true;
  }

  if (text ==
          'Handshake failed: trusted peer key changed or is invalid; rendezvous pairing passphrase is required to repair trust' ||
      text ==
          'Handshake failed: trusted peer key changed or is invalid; local or rendezvous pairing passphrase is required to repair trust') {
    return true;
  }

  if (text.startsWith(
    'QUIC application authentication failed: server device identity key is not trusted',
  )) {
    return true;
  }

  return text.startsWith('QUIC identity for peer ') &&
      text.endsWith('changed; explicit trust replacement is required');
}
