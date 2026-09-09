package io.github.rustadministrator.rustadmin

import android.view.InputDevice
import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidKeyboardProvenanceTest {
    @Test
    fun deadAccentIsSeparatedFromCandidateForEveryPhysicalAction() {
        val router = AndroidPhysicalKeyRouter()
        for (action in listOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP, KeyEvent.ACTION_MULTIPLE)) {
            val event = router.route(action, KeyEvent.KEYCODE_APOSTROPHE, 0,
                2, AndroidKeyboardOrigin.IME, Int.MIN_VALUE or 0x2c6)!!.single()
            when (event) {
                is RemoteKeyboardEvent.PhysicalKey -> {
                    assertEquals(0x2c6, event.deadKeyAccent)
                    assertNull(event.textCandidate)
                }
                is RemoteKeyboardEvent.PhysicalPressBatch -> {
                    assertEquals(0x2c6, event.deadKeyAccent)
                    assertNull(event.textCandidate)
                }
                else -> throw AssertionError("Expected physical key")
            }
        }
        assertNull(AndroidKeyboardProvenance.deadKeyAccent(0x5e))
        for (value in listOf(0, 9, 0x7f, 0xd800, 0x2028, 0x110000)) {
            assertNull(AndroidKeyboardProvenance.deadKeyAccent(Int.MIN_VALUE or value))
        }
    }

    @Test
    fun deadCompositionGuardsNativeCharNarrowingAndInvalidResults() {
        for (value in listOf(-1, 0, 9, 0x7f, 0xd800, 0x2028, 0x1f642, 0x110000)) {
            val forbidden: (Int, Int) -> Int = { _, _ -> throw AssertionError("Resolver must not run") }
            assertEquals(0, AndroidKeyboardProvenance.composeDeadKey(0x5e, value, forbidden))
            assertEquals(0, AndroidKeyboardProvenance.composeDeadKey(value, 0x65, forbidden))
        }
        assertEquals(0xea, AndroidKeyboardProvenance.composeDeadKey(0x5e, 0x65) { accent, base ->
            assertEquals(0x5e, accent)
            assertEquals(0x65, base)
            0xea
        })
        for (invalid in listOf(0, 9, 0xd800, 0x2029, 0x110000)) {
            assertEquals(0, AndroidKeyboardProvenance.composeDeadKey(0x5e, 0x65) { _, _ -> invalid })
        }
    }

    private fun classify(
        connection: Boolean = false,
        flags: Int = 0,
        id: Int = 7,
        source: Int = InputDevice.SOURCE_KEYBOARD,
        deviceSources: Int = InputDevice.SOURCE_KEYBOARD,
        virtual: Boolean? = false,
    ) = AndroidKeyboardProvenance.classify(connection, flags, id, source, deviceSources, virtual)

    @Test
    fun hardwareNeedsDeviceAndKeyboardEvidence() {
        assertEquals(AndroidKeyboardOrigin.HARDWARE, classify())
        assertEquals(AndroidKeyboardOrigin.HARDWARE, classify(connection = true))
        for (id in listOf(-1, 0)) {
            assertEquals(AndroidKeyboardOrigin.UNKNOWN, classify(id = id))
        }
        assertEquals(AndroidKeyboardOrigin.UNKNOWN, classify(virtual = null))
        assertEquals(AndroidKeyboardOrigin.UNKNOWN, classify(virtual = true))
        assertEquals(AndroidKeyboardOrigin.UNKNOWN, classify(source = 0))
        assertEquals(AndroidKeyboardOrigin.UNKNOWN, classify(deviceSources = InputDevice.SOURCE_GAMEPAD))
    }

    @Test
    fun softFlagsAndEditorPathIdentifyImeWithoutTrustingVirtualIdAlone() {
        for (id in listOf(-1, 0, 7)) {
            assertEquals(AndroidKeyboardOrigin.IME, classify(id = id, flags = KeyEvent.FLAG_SOFT_KEYBOARD))
        }
        assertEquals(AndroidKeyboardOrigin.IME, classify(connection = true, id = -1, source = 0, virtual = null))
        assertEquals(AndroidKeyboardOrigin.IME, classify(flags = KeyEvent.FLAG_EDITOR_ACTION))
        assertEquals(AndroidKeyboardOrigin.UNKNOWN, classify(id = -1, source = 0, virtual = null))
        assertEquals(AndroidKeyboardOrigin.UNKNOWN, classify(flags = KeyEvent.FLAG_VIRTUAL_HARD_KEY))
        assertEquals(AndroidKeyboardOrigin.UNKNOWN, classify(connection = true, flags = KeyEvent.FLAG_VIRTUAL_HARD_KEY))
    }

    @Test
    fun unicodeCandidateIsNotSynthesizedFromHidOrControlValues() {
        assertEquals("@", AndroidKeyboardProvenance.textCandidate(0x40))
        assertEquals("?", AndroidKeyboardProvenance.textCandidate(0x3f))
        assertEquals("\uD83D\uDE42", AndroidKeyboardProvenance.textCandidate(0x1f642))
        for (value in listOf(0, 9, 10, 13, 0x7f, 0x9f, 0xd800, 0x110000, Int.MIN_VALUE or 0x60)) {
            assertNull(AndroidKeyboardProvenance.textCandidate(value))
        }
    }

    @Test
    fun keyRouterCarriesOriginAndCandidateOnDownRepeatUpAndBatch() {
        val router = AndroidPhysicalKeyRouter()
        for (origin in AndroidKeyboardOrigin.entries) {
            for ((action, count) in listOf(KeyEvent.ACTION_DOWN to 0, KeyEvent.ACTION_DOWN to 2, KeyEvent.ACTION_UP to 0)) {
                val event = router.route(action, KeyEvent.KEYCODE_Q, KeyEvent.META_CAPS_LOCK_ON,
                    count, origin, 0x40)!!.single() as RemoteKeyboardEvent.PhysicalKey
                assertEquals(origin, event.origin)
                assertEquals("@", event.textCandidate)
                assertEquals(0x14, event.usbHidUsage)
                assertEquals(2, event.lockModes)
            }
            val batch = router.route(KeyEvent.ACTION_MULTIPLE, KeyEvent.KEYCODE_Q, 0,
                3, origin, 0x40)!!.single() as RemoteKeyboardEvent.PhysicalPressBatch
            assertEquals(origin, batch.origin)
            assertEquals("@", batch.textCandidate)
            assertEquals(3, batch.count)
        }
    }
}
