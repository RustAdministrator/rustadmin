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
    fun mapsGenericAndSideSpecificMetaStateModifiers() {
        assertEquals(
            listOf(0xe1),
            AndroidMetaStateToUsbHid.modifiers(KeyEvent.META_SHIFT_ON),
        )
        assertEquals(
            listOf(0xe5),
            AndroidMetaStateToUsbHid.modifiers(
                KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_RIGHT_ON,
            ),
        )
        assertEquals(
            listOf(0xe0, 0xe6, 0xe3),
            AndroidMetaStateToUsbHid.modifiers(
                KeyEvent.META_CTRL_ON or
                    KeyEvent.META_ALT_ON or KeyEvent.META_ALT_RIGHT_ON or
                    KeyEvent.META_META_ON,
            ),
        )
    }

    @Test
    fun synthesizesShiftAroundSlashForQuestionMark() {
        val router = AndroidPhysicalKeyRouter()

        val events = buildList {
            addAll(
                router.route(
                    KeyEvent.ACTION_DOWN,
                    KeyEvent.KEYCODE_SLASH,
                    KeyEvent.META_SHIFT_ON,
                ).orEmpty(),
            )
            addAll(
                router.route(
                    KeyEvent.ACTION_UP,
                    KeyEvent.KEYCODE_SLASH,
                    KeyEvent.META_SHIFT_ON,
                ).orEmpty(),
            )
        }

        assertEquals(
            listOf(
                RemoteKeyboardEvent.PhysicalKey(0xe1, true, true),
                RemoteKeyboardEvent.PhysicalKey(0x38, true),
                RemoteKeyboardEvent.PhysicalKey(0x38, false),
                RemoteKeyboardEvent.PhysicalKey(0xe1, false, true),
            ),
            events,
        )
    }

    @Test
    fun doesNotDuplicateExplicitShiftEvents() {
        val router = AndroidPhysicalKeyRouter()

        val events = buildList {
            addAll(
                router.route(
                    KeyEvent.ACTION_DOWN,
                    KeyEvent.KEYCODE_SHIFT_LEFT,
                    KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON,
                ).orEmpty(),
            )
            addAll(
                router.route(
                    KeyEvent.ACTION_DOWN,
                    KeyEvent.KEYCODE_SLASH,
                    KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON,
                ).orEmpty(),
            )
            addAll(
                router.route(
                    KeyEvent.ACTION_UP,
                    KeyEvent.KEYCODE_SLASH,
                    KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON,
                ).orEmpty(),
            )
            addAll(
                router.route(
                    KeyEvent.ACTION_UP,
                    KeyEvent.KEYCODE_SHIFT_LEFT,
                    0,
                ).orEmpty(),
            )
        }

        assertEquals(
            listOf(
                RemoteKeyboardEvent.PhysicalKey(0xe1, true),
                RemoteKeyboardEvent.PhysicalKey(0x38, true),
                RemoteKeyboardEvent.PhysicalKey(0x38, false),
                RemoteKeyboardEvent.PhysicalKey(0xe1, false),
            ),
            events,
        )
    }

    @Test
    fun releasesPressedKeysAndSyntheticModifiersOnKeyboardClose() {
        val router = AndroidPhysicalKeyRouter()
        router.route(
            KeyEvent.ACTION_DOWN,
            KeyEvent.KEYCODE_SLASH,
            KeyEvent.META_SHIFT_ON,
        )

        assertEquals(
            listOf(
                RemoteKeyboardEvent.PhysicalKey(0x38, false),
                RemoteKeyboardEvent.PhysicalKey(0xe1, false, true),
            ),
            router.releaseAll(),
        )
        assertEquals(emptyList<RemoteKeyboardEvent.PhysicalKey>(), router.releaseAll())
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
