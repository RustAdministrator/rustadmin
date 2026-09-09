package io.github.rustadministrator.rustadmin

internal data class AndroidHostTextState(
    val text: String,
    val selectionStart: Int,
    val selectionEnd: Int,
) {
    fun isValid(): Boolean = AndroidCommittedTextBounds.validate(text) == null &&
        isBoundary(selectionStart) && isBoundary(selectionEnd)

    // Accessibility offsets are UTF-16 offsets, not code-point or grapheme counts.
    private fun isBoundary(offset: Int): Boolean = offset in 0..text.length &&
        !(offset > 0 && offset < text.length &&
            Character.isHighSurrogate(text[offset - 1]) && Character.isLowSurrogate(text[offset]))

    fun replaceSelection(value: String): AndroidHostTextState? {
        if (!isValid() || AndroidCommittedTextBounds.validate(value) != null) return null
        val start = minOf(selectionStart, selectionEnd)
        val end = maxOf(selectionStart, selectionEnd)
        val updated = text.replaceRange(start, end, value)
        val cursor = start + value.length
        return AndroidHostTextState(updated, cursor, cursor).takeIf { it.isValid() }
    }
}

internal interface AndroidHostTextTarget {
    // Each operation must revalidate the same input-focused node, never search another field.
    fun read(): AndroidHostTextState?
    fun setText(expected: AndroidHostTextState, value: String): Boolean
    fun setSelection(expectedText: String, start: Int, end: Int): Boolean
}

internal enum class AndroidHostEditResult {
    REJECTED,
    APPLIED,
    TEXT_APPLIED_SELECTION_UNCONFIRMED,
}

internal fun applyAndroidHostEdit(
    target: AndroidHostTextTarget,
    before: AndroidHostTextState,
    after: AndroidHostTextState,
): AndroidHostEditResult {
    if (!before.isValid() || !after.isValid() || target.read() != before) {
        return AndroidHostEditResult.REJECTED
    }
    val textChanged = before.text != after.text
    if (textChanged && !target.setText(before, after.text)) return AndroidHostEditResult.REJECTED
    if (!textChanged && before == after) return AndroidHostEditResult.APPLIED
    // A successful SET_TEXT must never be repeated if the subsequent selection fails.
    val current = target.read()
    val selectionApplied = current?.text == after.text &&
        target.setSelection(after.text, after.selectionStart, after.selectionEnd)
    return when {
        selectionApplied -> AndroidHostEditResult.APPLIED
        textChanged -> AndroidHostEditResult.TEXT_APPLIED_SELECTION_UNCONFIRMED
        else -> AndroidHostEditResult.REJECTED
    }
}

internal fun dispatchAndroidHostInput(connection: (() -> Unit)?, fallback: () -> Unit) {
    // AccessibilityInputConnection returns void: even an exception cannot prove non-delivery.
    if (connection != null) connection() else fallback()
}
