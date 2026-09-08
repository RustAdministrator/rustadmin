package io.github.rustadministrator.rustadmin

import android.view.InputDevice
import android.view.KeyEvent

internal enum class AndroidKeyboardOrigin(val wireName: String) {
    HARDWARE("hardware"),
    IME("ime"),
    UNKNOWN("unknown"),
}

internal object AndroidKeyboardProvenance {
    fun classify(
        fromInputConnection: Boolean,
        flags: Int,
        deviceId: Int,
        eventSource: Int,
        deviceSources: Int,
        deviceIsVirtual: Boolean?,
    ): AndroidKeyboardOrigin {
        if (flags and (KeyEvent.FLAG_SOFT_KEYBOARD or KeyEvent.FLAG_EDITOR_ACTION) != 0) {
            return AndroidKeyboardOrigin.IME
        }
        if (flags and KeyEvent.FLAG_VIRTUAL_HARD_KEY != 0) return AndroidKeyboardOrigin.UNKNOWN
        val keyboard = InputDevice.SOURCE_KEYBOARD
        if (deviceId > 0 && deviceIsVirtual == false &&
            eventSource and keyboard == keyboard && deviceSources and keyboard == keyboard
        ) {
            return AndroidKeyboardOrigin.HARDWARE
        }
        // An editor delivery path is evidence of IME origin, not proof that a
        // key's Unicode value is committed text. Mode routing owns that choice.
        if (fromInputConnection) return AndroidKeyboardOrigin.IME
        return AndroidKeyboardOrigin.UNKNOWN
    }

    fun textCandidate(unicodeCodePoint: Int): String? {
        if (unicodeCodePoint !in 0x20..0x10ffff ||
            unicodeCodePoint in 0x7f..0x9f || unicodeCodePoint in 0xd800..0xdfff
        ) return null
        // Android dead-key values carry COMBINING_ACCENT in the high bit and
        // deliberately fail the scalar range check above.
        return String(Character.toChars(unicodeCodePoint))
    }
}
