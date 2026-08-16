bool isResettablePeerTrustError(String text) {
  if (text.startsWith('Handshake failed: peer identity changed')) {
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
