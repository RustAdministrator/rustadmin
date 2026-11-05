package io.github.rustadministrator.rustadmin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RdClipboardTextTest {
    @Test
    fun webUriSuppliesTextWhenItemHasNoText() {
        assertEquals(
            "HTTP://example.test/path",
            RdClipboardText.selectText(null, "HTTP://example.test/path"),
        )
        assertEquals(
            "https://example.test/path",
            RdClipboardText.selectText(null, "https://example.test/path"),
        )
    }

    @Test
    fun existingItemTextHasPriorityOverWebUri() {
        assertEquals(
            "copied text",
            RdClipboardText.selectText("copied text", "https://example.test/path"),
        )
    }

    @Test
    fun pairedPlainAndHtmlTextRemainTogether() {
        assertEquals(
            RdClipboardText("plain text", "<p>plain text</p>"),
            RdClipboardText.fromItem("plain text", null, "<p>plain text</p>"),
        )
    }

    @Test
    fun nonWebUrisAreNotCoercedToText() {
        for (uri in listOf("file:///tmp/example.txt", "content://provider/item", "ftp://example.test/path", "custom://item")) {
            assertNull(RdClipboardText.selectText(null, uri))
        }
    }

    @Test
    fun emptyItemTextIsPreservedButEmptyClipHasNoText() {
        assertEquals("", RdClipboardText.selectText("", "https://example.test/path"))
        assertNull(RdClipboardText.fromItem(null, null, null))
        assertNull(RdClipboardText.fromItem(null, "", null))
    }
}
