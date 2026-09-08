package io.github.rustadministrator.rustadmin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidInputDiagnosticsTest {
    private class SensitiveFailure : IllegalStateException("private-test-content") {
        override fun toString(): String = throw AssertionError("Do not format exceptions")
    }

    @Test
    fun errorDiagnosticsIncludeOnlyKnownOperationAndType() {
        val emitted = mutableListOf<Pair<String, String>>()
        val diagnostics = AndroidInputDiagnostics { level, message -> emitted.add(level to message) }
        for (operation in AndroidInputFailure.entries) {
            diagnostics.failure(operation, SensitiveFailure())
        }
        assertEquals(AndroidInputFailure.entries.size, emitted.size)
        for ((index, entry) in emitted.withIndex()) {
            assertEquals("error", entry.first)
            assertEquals(
                "Android input failure: operation=${AndroidInputFailure.entries[index].diagnosticName}, type=SensitiveFailure",
                entry.second,
            )
            assertFalse(entry.second.contains("private-test-content"))
        }
    }

    @Test
    fun unrecognizedModeIsNeverWrittenToDiagnostics() {
        val emitted = mutableListOf<String>()
        val diagnostics = AndroidInputDiagnostics { _, message -> emitted.add(message) }
        diagnostics.keyboardEnabled("private-test-content")
        diagnostics.keyboardDisabled("private-test-content", 4, 2, 1)
        assertEquals(2, emitted.size)
        for (message in emitted) {
            assertFalse(message.contains("private-test-content"))
            assertTrue(message.contains("mode=unknown"))
        }
    }

    @Test
    fun lifecycleDiagnosticsKeepOnlyModeAndBoundedCounters() {
        val emitted = mutableListOf<String>()
        val diagnostics = AndroidInputDiagnostics { _, message -> emitted.add(message) }
        diagnostics.accessibilityConnected()
        for (mode in listOf("auto", "text", "physical")) {
            diagnostics.keyboardEnabled(mode)
            diagnostics.keyboardDisabled(mode, -1, 8, 3)
        }
        assertEquals("Android input service connected", emitted.first())
        assertEquals(7, emitted.size)
        assertEquals(
            "Android remote keyboard disabled: mode=physical, physical_events=0, synthetic_modifier_events=8, text_fallbacks=3",
            emitted.last(),
        )
    }
}
