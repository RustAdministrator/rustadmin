enum KeyboardInputRejection {
  textTooLarge,
  textQueueFull,
  invalidText,
  pressCount,
}

typedef KeyboardInputRejectionHandler =
    void Function(KeyboardInputRejection reason);

abstract final class KeyboardTextPolicy {
  static const maxOperationBytes = 64 * 1024;
  static const maxPendingBytes = 64 * 1024;
  static const maxPendingOperations = 64;
  static const maxEditGraphemes = 64 * 1024;

  // Count without allocating an unbounded encoded copy or replacing malformed
  // UTF-16. Wire chunking remains in Rust with the negotiated per-message cap.
  static ({int bytes, KeyboardInputRejection? rejection}) inspect(String text) {
    var bytes = 0;
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++index >= text.length) {
          return (bytes: bytes, rejection: KeyboardInputRejection.invalidText);
        }
        final low = text.codeUnitAt(index);
        if (low < 0xdc00 || low > 0xdfff) {
          return (bytes: bytes, rejection: KeyboardInputRejection.invalidText);
        }
        bytes += 4;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return (bytes: bytes, rejection: KeyboardInputRejection.invalidText);
      } else {
        bytes += unit <= 0x7f
            ? 1
            : unit <= 0x7ff
            ? 2
            : 3;
      }
      if (bytes > maxOperationBytes) {
        return (bytes: bytes, rejection: KeyboardInputRejection.textTooLarge);
      }
    }
    return (bytes: bytes, rejection: null);
  }
}
