/// Helpers for editing the per-peer options without rewriting what the user did
/// not touch.

/// The options that differ between what was loaded and what was edited. Keys
/// missing from `loaded` count as changed.
Map<String, String> diffPeerOptions(
  Map<String, String> loaded,
  Map<String, String> edited,
) {
  final changed = <String, String>{};
  edited.forEach((key, value) {
    if (loaded[key] != value) {
      changed[key] = value;
    }
  });
  return changed;
}

/// The clipboard direction a peer is configured with. The direction option is
/// authoritative when it is set; otherwise the older per-peer
/// `disable_clipboard` flag (only "Y" means disabled) closes the clipboard.
String effectiveClipboardDirection({
  required String directionOption,
  required String legacyDisableClipboard,
  required String off,
  required String Function(String) normalize,
}) {
  if (directionOption.trim().isEmpty && legacyDisableClipboard == 'Y') {
    return off;
  }
  return normalize(directionOption);
}
