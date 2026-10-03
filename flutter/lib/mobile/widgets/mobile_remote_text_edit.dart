import 'package:flutter/material.dart';

class MobileCommittedTextEdit {
  const MobileCommittedTextEdit({
    required this.text,
    required this.deleteBeforeGraphemes,
    this.deleteAfterGraphemes = 0,
  });

  final String text;
  final int deleteBeforeGraphemes;
  final int deleteAfterGraphemes;

  bool get isEmpty =>
      text.isEmpty && deleteBeforeGraphemes == 0 && deleteAfterGraphemes == 0;
}

/// Converts one native editing update into the edit to apply to the remote.
///
/// The selection pair anchors edits when repeated characters make a text-only
/// diff ambiguous. The common-suffix fallback keeps unchanged text after a
/// middle deletion out of the committed payload.
MobileCommittedTextEdit mobileCommittedTextEditValue(
  TextEditingValue oldValue,
  TextEditingValue newValue, {
  bool replacedByClipboard = false,
}) {
  if (replacedByClipboard) {
    return MobileCommittedTextEdit(
      text: newValue.text,
      deleteBeforeGraphemes: 0,
    );
  }

  final oldGraphemes = oldValue.text.characters.toList(growable: false);
  final newGraphemes = newValue.text.characters.toList(growable: false);
  if (oldGraphemes.length == newGraphemes.length &&
      _sameRange(oldGraphemes, 0, newGraphemes, 0, oldGraphemes.length)) {
    return const MobileCommittedTextEdit(text: '', deleteBeforeGraphemes: 0);
  }

  final anchored = _selectionAnchoredEdit(
    oldValue,
    newValue,
    oldGraphemes,
    newGraphemes,
  );
  return anchored ??
      _textDiffEdit(oldValue, newValue, oldGraphemes, newGraphemes);
}

/// Applies the iOS sentinel rule before normalizing the native edit.
///
/// Prefix loss is only clipboard replacement when the text input controller
/// supplied explicit paste provenance or the native selection covers the
/// internal sentinel. A deletion that happens to shorten the sentinel
/// therefore remains a deletion edit.
MobileCommittedTextEdit mobileIOSSoftKeyboardTextEdit(
  TextEditingValue oldValue,
  TextEditingValue newValue, {
  required String internalSentinel,
  bool hasPasteProvenance = false,
}) {
  if (internalSentinel.isEmpty || !oldValue.text.startsWith(internalSentinel)) {
    return mobileCommittedTextEditValue(oldValue, newValue);
  }

  final oldGraphemes = oldValue.text.characters.toList(growable: false);
  final newGraphemes = newValue.text.characters.toList(growable: false);
  final normalEdit = mobileCommittedTextEditValue(oldValue, newValue);
  if (normalEdit.text.isEmpty) return normalEdit;
  final sentinelGraphemes = internalSentinel.characters.length;
  final selectionCoversSentinel = _selectionCoversSentinel(
    oldValue,
    internalSentinel,
  );
  final selectionCoversWholeBuffer =
      oldValue.selection.isValid &&
      oldValue.selection.start == 0 &&
      oldValue.selection.end >= oldValue.text.length;
  final replacementProvenance = hasPasteProvenance || selectionCoversSentinel;
  if (!replacementProvenance) {
    return mobileCommittedTextEditValue(oldValue, newValue);
  }

  if (selectionCoversWholeBuffer) {
    return MobileCommittedTextEdit(
      text: newValue.text,
      deleteBeforeGraphemes: 0,
    );
  }

  if (selectionCoversSentinel) {
    final anchored = _selectionAnchoredEdit(
      oldValue,
      newValue,
      oldGraphemes,
      newGraphemes,
    );
    if (anchored != null && anchored.text.isNotEmpty) {
      return MobileCommittedTextEdit(
        text: anchored.text,
        deleteBeforeGraphemes: 0,
        deleteAfterGraphemes: 0,
      );
    }
  }

  if (!newValue.text.startsWith(internalSentinel)) {
    final commonPrefix = _commonPrefixLength(oldGraphemes, newGraphemes);
    final commonSuffix = _commonSuffixLength(
      oldGraphemes,
      newGraphemes,
      oldStart: commonPrefix,
      newStart: commonPrefix,
    );
    if (commonPrefix == 0 && commonSuffix > 0) {
      final deleteBefore = normalEdit.deleteBeforeGraphemes - sentinelGraphemes;
      return MobileCommittedTextEdit(
        text: normalEdit.text,
        deleteBeforeGraphemes: deleteBefore < 0 ? 0 : deleteBefore,
        deleteAfterGraphemes: normalEdit.deleteAfterGraphemes,
      );
    }
  }

  return normalEdit;
}

bool _selectionCoversSentinel(TextEditingValue value, String internalSentinel) {
  final selection = value.selection;
  return selection.isValid &&
      selection.start == 0 &&
      selection.end >= internalSentinel.length;
}

/// Compatibility wrapper for callers that only have the committed strings.
/// New code that receives native editing values should use
/// [mobileCommittedTextEditValue] so selection provenance is retained.
MobileCommittedTextEdit mobileCommittedTextEdit(
  String oldValue,
  String newValue, {
  bool replacedByClipboard = false,
}) => mobileCommittedTextEditValue(
  TextEditingValue(
    text: oldValue,
    selection: TextSelection.collapsed(offset: oldValue.length),
  ),
  TextEditingValue(
    text: newValue,
    selection: TextSelection.collapsed(offset: newValue.length),
  ),
  replacedByClipboard: replacedByClipboard,
);

MobileCommittedTextEdit? _selectionAnchoredEdit(
  TextEditingValue oldValue,
  TextEditingValue newValue,
  List<String> oldGraphemes,
  List<String> newGraphemes,
) {
  final oldSelection = oldValue.selection;
  final newSelection = newValue.selection;
  if (!oldSelection.isValid ||
      !newSelection.isValid ||
      !newSelection.isCollapsed) {
    return null;
  }

  final oldSelectionStart = _graphemeOffset(oldValue.text, oldSelection.start);
  final oldSelectionEnd = _graphemeOffset(oldValue.text, oldSelection.end);
  final newCursor = _graphemeOffset(newValue.text, newSelection.extentOffset);
  if (oldSelectionStart == null ||
      oldSelectionEnd == null ||
      newCursor == null) {
    return null;
  }

  if (oldSelectionStart == oldSelectionEnd) {
    final oldCursor = oldSelectionStart;
    if (newCursor < oldCursor) {
      return _anchoredEdit(
        oldGraphemes,
        newGraphemes,
        oldStart: newCursor,
        oldEnd: oldCursor,
        newStart: newCursor,
        newEnd: newCursor,
        deleteBeforeGraphemes: oldCursor - newCursor,
      );
    }
    if (newCursor > oldCursor) {
      return _anchoredEdit(
        oldGraphemes,
        newGraphemes,
        oldStart: oldCursor,
        oldEnd: oldCursor,
        newStart: oldCursor,
        newEnd: newCursor,
        deleteBeforeGraphemes: 0,
      );
    }

    final suffix = _commonSuffixLength(
      oldGraphemes,
      newGraphemes,
      oldStart: oldCursor,
      newStart: newCursor,
    );
    return _anchoredEdit(
      oldGraphemes,
      newGraphemes,
      oldStart: oldCursor,
      oldEnd: oldGraphemes.length - suffix,
      newStart: newCursor,
      newEnd: newGraphemes.length - suffix,
      deleteBeforeGraphemes: 0,
      deleteAfterGraphemes: oldGraphemes.length - suffix - oldCursor,
    );
  }

  return _anchoredEdit(
    oldGraphemes,
    newGraphemes,
    oldStart: oldSelectionStart,
    oldEnd: oldSelectionEnd,
    newStart: oldSelectionStart,
    newEnd: newCursor,
    deleteBeforeGraphemes: oldSelectionEnd - oldSelectionStart,
  );
}

MobileCommittedTextEdit? _anchoredEdit(
  List<String> oldGraphemes,
  List<String> newGraphemes, {
  required int oldStart,
  required int oldEnd,
  required int newStart,
  required int newEnd,
  required int deleteBeforeGraphemes,
  int deleteAfterGraphemes = 0,
}) {
  if (oldStart < 0 ||
      oldStart > oldEnd ||
      oldEnd > oldGraphemes.length ||
      newStart < 0 ||
      newStart > newEnd ||
      newEnd > newGraphemes.length ||
      deleteBeforeGraphemes < 0 ||
      deleteAfterGraphemes < 0) {
    return null;
  }
  if (!_sameRange(oldGraphemes, 0, newGraphemes, 0, oldStart)) {
    return null;
  }
  final oldSuffixLength = oldGraphemes.length - oldEnd;
  final newSuffixLength = newGraphemes.length - newEnd;
  if (oldSuffixLength != newSuffixLength ||
      !_sameRange(
        oldGraphemes,
        oldEnd,
        newGraphemes,
        newEnd,
        oldSuffixLength,
      )) {
    return null;
  }
  return MobileCommittedTextEdit(
    text: newGraphemes.sublist(newStart, newEnd).join(),
    deleteBeforeGraphemes: deleteBeforeGraphemes,
    deleteAfterGraphemes: deleteAfterGraphemes,
  );
}

MobileCommittedTextEdit _textDiffEdit(
  TextEditingValue oldValue,
  TextEditingValue newValue,
  List<String> oldGraphemes,
  List<String> newGraphemes,
) {
  final commonPrefix = _commonPrefixLength(oldGraphemes, newGraphemes);
  final commonSuffix = _commonSuffixLength(
    oldGraphemes,
    newGraphemes,
    oldStart: commonPrefix,
    newStart: commonPrefix,
  );
  final oldEnd = oldGraphemes.length - commonSuffix;
  final newEnd = newGraphemes.length - commonSuffix;

  var deleteBeforeGraphemes = oldEnd - commonPrefix;
  var deleteAfterGraphemes = 0;
  final oldSelection = oldValue.selection;
  final newSelection = newValue.selection;
  final oldCursor = oldSelection.isValid && oldSelection.isCollapsed
      ? _graphemeOffset(oldValue.text, oldSelection.extentOffset)
      : null;
  final newCursor = newSelection.isValid && newSelection.isCollapsed
      ? _graphemeOffset(newValue.text, newSelection.extentOffset)
      : null;
  if (oldCursor != null &&
      newCursor != null &&
      oldCursor == newCursor &&
      commonPrefix == oldCursor &&
      newEnd == newCursor) {
    deleteBeforeGraphemes = 0;
    deleteAfterGraphemes = oldEnd - oldCursor;
  }
  return MobileCommittedTextEdit(
    text: newGraphemes.sublist(commonPrefix, newEnd).join(),
    deleteBeforeGraphemes: deleteBeforeGraphemes,
    deleteAfterGraphemes: deleteAfterGraphemes,
  );
}

int _commonPrefixLength(List<String> oldGraphemes, List<String> newGraphemes) {
  var prefix = 0;
  while (prefix < oldGraphemes.length &&
      prefix < newGraphemes.length &&
      oldGraphemes[prefix] == newGraphemes[prefix]) {
    prefix++;
  }
  return prefix;
}

int _commonSuffixLength(
  List<String> oldGraphemes,
  List<String> newGraphemes, {
  required int oldStart,
  required int newStart,
}) {
  var suffix = 0;
  while (oldGraphemes.length - suffix > oldStart &&
      newGraphemes.length - suffix > newStart &&
      oldGraphemes[oldGraphemes.length - suffix - 1] ==
          newGraphemes[newGraphemes.length - suffix - 1]) {
    suffix++;
  }
  return suffix;
}

bool _sameRange(
  List<String> left,
  int leftStart,
  List<String> right,
  int rightStart,
  int length,
) {
  if (length < 0 ||
      leftStart < 0 ||
      rightStart < 0 ||
      leftStart + length > left.length ||
      rightStart + length > right.length) {
    return false;
  }
  for (var i = 0; i < length; i++) {
    if (left[leftStart + i] != right[rightStart + i]) return false;
  }
  return true;
}

int? _graphemeOffset(String text, int codeUnitOffset) {
  if (codeUnitOffset < 0 || codeUnitOffset > text.length) return null;
  return text.substring(0, codeUnitOffset).characters.length;
}
