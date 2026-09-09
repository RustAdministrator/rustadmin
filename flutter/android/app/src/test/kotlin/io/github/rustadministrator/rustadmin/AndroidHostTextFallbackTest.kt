package io.github.rustadministrator.rustadmin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidHostTextFallbackTest {
    private class Target(var state: AndroidHostTextState?) : AndroidHostTextTarget {
        var writes = 0
        var selections = 0
        var acceptText = true
        var acceptSelection = true
        var loseFocusAfterWrite = false
        var transformTextAfterWrite = false

        override fun read() = state
        override fun setText(expected: AndroidHostTextState, value: String): Boolean {
            writes++
            if (!acceptText) return false
            state = if (loseFocusAfterWrite) null else {
                val written = if (transformTextAfterWrite) value.uppercase() else value
                AndroidHostTextState(written, written.length, written.length)
            }
            return true
        }
        override fun setSelection(expectedText: String, start: Int, end: Int): Boolean {
            selections++
            if (!acceptSelection) return false
            state = state?.copy(selectionStart = start, selectionEnd = end)
            return true
        }
    }

    @Test
    fun committedTextReplacesForwardAndReverseSelection() {
        for ((start, end) in listOf(1 to 3, 3 to 1)) {
            val state = AndroidHostTextState("abcd", start, end)
            assertEquals(AndroidHostTextState("aXd", 2, 2), state.replaceSelection("X"))
        }
    }

    @Test
    fun emojiAndCombiningTextUseUtf16SelectionWithoutTruncation() {
        val state = AndroidHostTextState("a\uD83D\uDE00b", 1, 3)
        assertEquals(AndroidHostTextState("ae\u0301\uD83D\uDE80b", 5, 5),
            state.replaceSelection("e\u0301\uD83D\uDE80"))
        assertNull(state.copy(selectionStart = 2).replaceSelection("X"))
        assertFalse(AndroidHostTextState("\uD800", 0, 0).isValid())
    }

    @Test
    fun unknownAndOutOfBoundsSelectionNeverReplaceWholeField() {
        for ((start, end) in listOf(-1 to -1, -1 to 2, 1 to 5, 5 to 1)) {
            assertNull(AndroidHostTextState("abcd", start, end).replaceSelection("X"))
        }
        assertEquals(AndroidHostTextState("X", 1, 1), AndroidHostTextState("", 0, 0).replaceSelection("X"))
    }

    @Test
    fun textBudgetRejectsWholeOperationAndDoesNotTruncate() {
        val maximum = "x".repeat(AndroidCommittedTextBounds.MAX_UTF8_BYTES)
        assertEquals(maximum, AndroidHostTextState("", 0, 0).replaceSelection(maximum)?.text)
        assertNull(AndroidHostTextState("x", 1, 1).replaceSelection(maximum))
        assertNull(AndroidHostTextState("", 0, 0).replaceSelection("\uD800"))
    }

    @Test
    fun successfulWriteAndSelectionOccurOnlyOnce() {
        val before = AndroidHostTextState("abcd", 1, 3)
        val after = AndroidHostTextState("aXd", 2, 2)
        val target = Target(before)
        assertEquals(AndroidHostEditResult.APPLIED, applyAndroidHostEdit(target, before, after))
        assertEquals(after, target.state)
        assertEquals(1, target.writes)
        assertEquals(1, target.selections)
    }

    @Test
    fun failedSelectionAfterTextDoesNotRepeatWrite() {
        val before = AndroidHostTextState("abcd", 1, 3)
        val target = Target(before).apply { acceptSelection = false }
        assertEquals(AndroidHostEditResult.TEXT_APPLIED_SELECTION_UNCONFIRMED,
            applyAndroidHostEdit(target, before, AndroidHostTextState("aXd", 2, 2)))
        assertEquals(1, target.writes)
        assertEquals(1, target.selections)
        assertEquals("aXd", target.state?.text)
    }

    @Test
    fun failedTextNeverAttemptsSelection() {
        val before = AndroidHostTextState("abcd", 1, 3)
        val target = Target(before).apply { acceptText = false }
        assertEquals(AndroidHostEditResult.REJECTED,
            applyAndroidHostEdit(target, before, AndroidHostTextState("aXd", 2, 2)))
        assertEquals(before, target.state)
        assertEquals(1, target.writes)
        assertEquals(0, target.selections)
    }

    @Test
    fun focusLossOrTransformedTextAfterWriteNeverAppliesStaleSelection() {
        val before = AndroidHostTextState("abcd", 1, 3)
        for (loseFocus in listOf(true, false)) {
            val target = Target(before).apply {
                loseFocusAfterWrite = loseFocus
                transformTextAfterWrite = !loseFocus
            }
            assertEquals(AndroidHostEditResult.TEXT_APPLIED_SELECTION_UNCONFIRMED,
                applyAndroidHostEdit(target, before, AndroidHostTextState("aXd", 2, 2)))
            assertEquals(1, target.writes)
            assertEquals(0, target.selections)
        }
    }

    @Test
    fun missingOrChangedTargetRejectsBeforeAnyAction() {
        val before = AndroidHostTextState("abcd", 1, 3)
        for (current in listOf(null, before.copy(selectionEnd = 2), before.copy(text = "wxyz"))) {
            val target = Target(current)
            assertEquals(AndroidHostEditResult.REJECTED,
                applyAndroidHostEdit(target, before, AndroidHostTextState("aXd", 2, 2)))
            assertEquals(0, target.writes)
            assertEquals(0, target.selections)
        }
    }

    @Test
    fun selectionOnlyEditDoesNotRewriteText() {
        val before = AndroidHostTextState("abcd", 1, 3)
        val target = Target(before)
        assertEquals(AndroidHostEditResult.APPLIED,
            applyAndroidHostEdit(target, before, before.copy(selectionStart = 0, selectionEnd = 4)))
        assertEquals(0, target.writes)
        assertEquals(1, target.selections)
    }

    @Test
    fun invalidResultCannotReachTarget() {
        val before = AndroidHostTextState("abcd", 1, 3)
        val target = Target(before)
        assertEquals(AndroidHostEditResult.REJECTED,
            applyAndroidHostEdit(target, before, before.copy(selectionEnd = 99)))
        assertEquals(0, target.writes)
        assertEquals(0, target.selections)
    }

    @Test
    fun absentConnectionUsesFallbackExactlyOnce() {
        var fallbacks = 0
        dispatchAndroidHostInput(null) { fallbacks++ }
        assertEquals(1, fallbacks)
    }

    @Test
    fun presentConnectionNeverUsesFallback() {
        var commits = 0
        var fallbacks = 0
        dispatchAndroidHostInput({ commits++ }) { fallbacks++ }
        assertEquals(1, commits)
        assertEquals(0, fallbacks)
    }

    @Test
    fun connectionExceptionNeverRetriesThroughFallback() {
        var fallbacks = 0
        var failed = false
        try {
            dispatchAndroidHostInput({ throw IllegalStateException() }) { fallbacks++ }
        } catch (_: IllegalStateException) {
            failed = true
        }
        assertTrue(failed)
        assertEquals(0, fallbacks)
    }
}
