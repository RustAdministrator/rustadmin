package io.github.rustadministrator.rustadmin

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidKeyToUsbHidTest {
    @Test
    fun mapsPrintableKeyPositionsIndependentlyOfLanguage() {
        assertEquals(0x04, AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_A))
        assertEquals(0x14, AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_Q))
        assertEquals(0x1d, AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_Z))
        assertEquals(0x1e, AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_1))
        assertEquals(0x27, AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_0))
        assertEquals(0x2d, AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_MINUS))
    }

    @Test
    fun mapsControlNavigationAndModifierKeys() {
        assertEquals(0x28, AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_ENTER))
        assertEquals(0x2a, AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_DEL))
        assertEquals(0x4f, AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_DPAD_RIGHT))
        assertEquals(0x3a, AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_F1))
        assertEquals(0xe0, AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_CTRL_LEFT))
        assertEquals(0xe6, AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_ALT_RIGHT))
    }

    @Test
    fun rejectsKeysWithoutAStablePhysicalPosition() {
        assertNull(AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_UNKNOWN))
        assertNull(AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_AT))
        assertNull(AndroidKeyToUsbHid.map(KeyEvent.KEYCODE_LANGUAGE_SWITCH))
    }

    @Test
    fun normalizesImeLayoutMetadataBeforeItLeavesAndroid() {
        assertEquals(
            "ru-RU",
            AndroidInputLayoutMetadata.canonicalizeLanguageTag("ru_RU"),
        )
        assertEquals(
            "zh-Hans-CN",
            AndroidInputLayoutMetadata.canonicalizeLanguageTag("zh-Hans-CN"),
        )
        assertEquals("", AndroidInputLayoutMetadata.canonicalizeLanguageTag("bad tag"))
        assertEquals(
            "qwerty.cyrillic",
            AndroidInputLayoutMetadata.sanitizeLayoutType("qwerty.cyrillic"),
        )
        assertEquals(
            "qwertybad",
            AndroidInputLayoutMetadata.sanitizeLayoutType("qwerty bad!"),
        )
    }
}
