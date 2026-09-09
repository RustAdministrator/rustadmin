package io.github.rustadministrator.rustadmin

import android.view.InputDevice
import android.view.KeyEvent
import android.view.KeyCharacterMap

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

    fun deadKeyAccent(value: Int): Int? {
        if (value and KeyCharacterMap.COMBINING_ACCENT == 0) return null
        val accent = value and KeyCharacterMap.COMBINING_ACCENT_MASK
        return accent.takeIf { textCandidate(it) != null && it != 0x2028 && it != 0x2029 }
    }

    fun composeDeadKey(
        accent: Int,
        base: Int,
        resolve: (Int, Int) -> Int = KeyCharacterMap::getDeadChar,
    ): Int {
        // AOSP getDeadChar narrows its input to char internally. Preserve
        // supplementary scalars through the caller's literal fallback.
        if (accent > 0xffff || base > 0xffff ||
            textCandidate(accent) == null || textCandidate(base) == null ||
            accent in 0x2028..0x2029 || base in 0x2028..0x2029
        ) return 0
        val composed = resolve(accent, base)
        return composed.takeIf {
            textCandidate(it) != null && it !in 0x2028..0x2029
        } ?: 0
    }
}
