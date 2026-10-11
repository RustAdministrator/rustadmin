package io.github.rustadministrator.rustadmin

import android.content.Intent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BootReceiverTest {
    @Test
    fun bootCompletedIsAcceptedInEveryBuild() {
        assertTrue(isBootTriggerAllowed(Intent.ACTION_BOOT_COMPLETED, debuggable = false))
        assertTrue(isBootTriggerAllowed(Intent.ACTION_BOOT_COMPLETED, debuggable = true))
    }

    @Test
    fun debugActionOnlyCountsInADebuggableBuild() {
        assertTrue(isBootTriggerAllowed(DEBUG_BOOT_COMPLETED, debuggable = true))
        assertFalse(isBootTriggerAllowed(DEBUG_BOOT_COMPLETED, debuggable = false))
    }

    @Test
    fun otherActionsAreNeverAccepted() {
        for (debuggable in listOf(false, true)) {
            assertFalse(isBootTriggerAllowed(null, debuggable))
            assertFalse(isBootTriggerAllowed("", debuggable))
            assertFalse(isBootTriggerAllowed("android.intent.action.MAIN", debuggable))
        }
    }
}
