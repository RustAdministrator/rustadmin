package io.github.rustadministrator.rustadmin

import android.view.KeyEvent
import hbb.KeyEventConverter
import hbb.MessageOuterClass.ControlKey
import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidHostKeyMappingTest {
    @Test
    fun rightWinKeepsItsSideForKeysAndModifiers() {
        assertEquals(KeyEvent.KEYCODE_META_RIGHT, KeyEventConverter.convertControlKeyToKeyCode(ControlKey.RWin))
        assertEquals(KeyEvent.META_META_RIGHT_ON, KeyEventConverter.convertModifier(ControlKey.RWin))
        assertEquals(KeyEvent.KEYCODE_META_LEFT, KeyEventConverter.convertControlKeyToKeyCode(ControlKey.Meta))
        assertEquals(KeyEvent.META_META_ON, KeyEventConverter.convertModifier(ControlKey.Meta))
    }

    @Test
    fun navigationHomeRemainsDistinctFromAndroidSystemHome() {
        assertEquals(KeyEvent.KEYCODE_MOVE_HOME, KeyEventConverter.convertControlKeyToKeyCode(ControlKey.Home))
        assertEquals(KeyEvent.KEYCODE_MOVE_END, KeyEventConverter.convertControlKeyToKeyCode(ControlKey.End))
        assertEquals(KeyEvent.KEYCODE_DEL, KeyEventConverter.convertControlKeyToKeyCode(ControlKey.Backspace))
    }
}
