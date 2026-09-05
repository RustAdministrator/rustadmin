package io.github.rustadministrator.rustadmin

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.os.Build
import android.text.InputType
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import ffi.FFI
import java.util.Locale

internal sealed interface RemoteKeyboardEvent {
    data class PhysicalKey(
        val usbHidUsage: Int,
        val down: Boolean,
        val repeat: Boolean = false,
        val modifierUsages: List<Int> = emptyList(),
    ) : RemoteKeyboardEvent
    data class CommittedText(val text: String) : RemoteKeyboardEvent
}

internal data class AndroidInputLayoutInfo(
    val languageTag: String,
    val layoutType: String,
)

internal object AndroidInputLayoutMetadata {
    private const val MAX_CHARS = 64

    fun canonicalizeLanguageTag(rawTag: String): String =
        Locale.forLanguageTag(rawTag.replace('_', '-')).toLanguageTag()
            .takeUnless { it == "und" }
            .orEmpty()
            .take(MAX_CHARS)

    fun sanitizeLayoutType(rawLayout: String): String = rawLayout
        .filter { it.isLetterOrDigit() || it in "-_+." }
        .take(MAX_CHARS)
}

internal object AndroidCommittedTextBounds {
    const val MAX_UTF8_BYTES = 2048

    fun truncateUtf8(value: String): String {
        if (value.toByteArray(Charsets.UTF_8).size <= MAX_UTF8_BYTES) return value

        var index = 0
        var bytes = 0
        while (index < value.length) {
            val codePoint = value.codePointAt(index)
            val encodedBytes = when {
                codePoint <= 0x7f -> 1
                codePoint <= 0x7ff -> 2
                codePoint <= 0xffff -> 3
                else -> 4
            }
            if (bytes + encodedBytes > MAX_UTF8_BYTES) break
            bytes += encodedBytes
            index += Character.charCount(codePoint)
        }
        return value.substring(0, index)
    }
}

internal object AndroidKeyToUsbHid {
    fun map(keyCode: Int): Int? = when (keyCode) {
        in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z ->
            0x04 + keyCode - KeyEvent.KEYCODE_A

        in KeyEvent.KEYCODE_1..KeyEvent.KEYCODE_9 ->
            0x1e + keyCode - KeyEvent.KEYCODE_1

        KeyEvent.KEYCODE_0 -> 0x27
        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_DPAD_CENTER -> 0x28
        KeyEvent.KEYCODE_ESCAPE -> 0x29
        KeyEvent.KEYCODE_DEL -> 0x2a
        KeyEvent.KEYCODE_TAB -> 0x2b
        KeyEvent.KEYCODE_SPACE -> 0x2c
        KeyEvent.KEYCODE_MINUS -> 0x2d
        KeyEvent.KEYCODE_EQUALS -> 0x2e
        KeyEvent.KEYCODE_LEFT_BRACKET -> 0x2f
        KeyEvent.KEYCODE_RIGHT_BRACKET -> 0x30
        KeyEvent.KEYCODE_BACKSLASH -> 0x31
        KeyEvent.KEYCODE_SEMICOLON -> 0x33
        KeyEvent.KEYCODE_APOSTROPHE -> 0x34
        KeyEvent.KEYCODE_GRAVE -> 0x35
        KeyEvent.KEYCODE_COMMA -> 0x36
        KeyEvent.KEYCODE_PERIOD -> 0x37
        KeyEvent.KEYCODE_SLASH -> 0x38
        KeyEvent.KEYCODE_CAPS_LOCK -> 0x39
        in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12 ->
            0x3a + keyCode - KeyEvent.KEYCODE_F1

        KeyEvent.KEYCODE_SYSRQ -> 0x46
        KeyEvent.KEYCODE_SCROLL_LOCK -> 0x47
        KeyEvent.KEYCODE_BREAK -> 0x48
        KeyEvent.KEYCODE_INSERT -> 0x49
        KeyEvent.KEYCODE_MOVE_HOME -> 0x4a
        KeyEvent.KEYCODE_PAGE_UP -> 0x4b
        KeyEvent.KEYCODE_FORWARD_DEL -> 0x4c
        KeyEvent.KEYCODE_MOVE_END -> 0x4d
        KeyEvent.KEYCODE_PAGE_DOWN -> 0x4e
        KeyEvent.KEYCODE_DPAD_RIGHT -> 0x4f
        KeyEvent.KEYCODE_DPAD_LEFT -> 0x50
        KeyEvent.KEYCODE_DPAD_DOWN -> 0x51
        KeyEvent.KEYCODE_DPAD_UP -> 0x52
        KeyEvent.KEYCODE_NUM_LOCK -> 0x53
        KeyEvent.KEYCODE_NUMPAD_DIVIDE -> 0x54
        KeyEvent.KEYCODE_NUMPAD_MULTIPLY -> 0x55
        KeyEvent.KEYCODE_NUMPAD_SUBTRACT -> 0x56
        KeyEvent.KEYCODE_NUMPAD_ADD -> 0x57
        KeyEvent.KEYCODE_NUMPAD_ENTER -> 0x58
        in KeyEvent.KEYCODE_NUMPAD_1..KeyEvent.KEYCODE_NUMPAD_9 ->
            0x59 + keyCode - KeyEvent.KEYCODE_NUMPAD_1

        KeyEvent.KEYCODE_NUMPAD_0 -> 0x62
        KeyEvent.KEYCODE_NUMPAD_DOT -> 0x63
        KeyEvent.KEYCODE_MENU -> 0x65
        KeyEvent.KEYCODE_CTRL_LEFT -> 0xe0
        KeyEvent.KEYCODE_SHIFT_LEFT -> 0xe1
        KeyEvent.KEYCODE_ALT_LEFT -> 0xe2
        KeyEvent.KEYCODE_META_LEFT -> 0xe3
        KeyEvent.KEYCODE_CTRL_RIGHT -> 0xe4
        KeyEvent.KEYCODE_SHIFT_RIGHT -> 0xe5
        KeyEvent.KEYCODE_ALT_RIGHT -> 0xe6
        KeyEvent.KEYCODE_META_RIGHT -> 0xe7
        else -> null
    }
}

internal object AndroidMetaStateToUsbHid {
    fun modifiers(metaState: Int): List<Int> = buildList {
        addModifierPair(
            metaState = metaState,
            genericMask = KeyEvent.META_CTRL_ON,
            leftMask = KeyEvent.META_CTRL_LEFT_ON,
            rightMask = KeyEvent.META_CTRL_RIGHT_ON,
            leftUsage = 0xe0,
            rightUsage = 0xe4,
        )
        addModifierPair(
            metaState = metaState,
            genericMask = KeyEvent.META_SHIFT_ON,
            leftMask = KeyEvent.META_SHIFT_LEFT_ON,
            rightMask = KeyEvent.META_SHIFT_RIGHT_ON,
            leftUsage = 0xe1,
            rightUsage = 0xe5,
        )
        addModifierPair(
            metaState = metaState,
            genericMask = KeyEvent.META_ALT_ON,
            leftMask = KeyEvent.META_ALT_LEFT_ON,
            rightMask = KeyEvent.META_ALT_RIGHT_ON,
            leftUsage = 0xe2,
            rightUsage = 0xe6,
        )
        addModifierPair(
            metaState = metaState,
            genericMask = KeyEvent.META_META_ON,
            leftMask = KeyEvent.META_META_LEFT_ON,
            rightMask = KeyEvent.META_META_RIGHT_ON,
            leftUsage = 0xe3,
            rightUsage = 0xe7,
        )
    }

    private fun MutableList<Int>.addModifierPair(
        metaState: Int,
        genericMask: Int,
        leftMask: Int,
        rightMask: Int,
        leftUsage: Int,
        rightUsage: Int,
    ) {
        val hasLeft = metaState and leftMask != 0
        val hasRight = metaState and rightMask != 0
        if (hasLeft) add(leftUsage)
        if (hasRight) add(rightUsage)
        if (!hasLeft && !hasRight && metaState and genericMask != 0) add(leftUsage)
    }
}

internal class AndroidPhysicalKeyRouter {
    fun route(
        action: Int,
        keyCode: Int,
        metaState: Int,
        repeatCount: Int = 0,
    ): List<RemoteKeyboardEvent.PhysicalKey>? {
        val usage = AndroidKeyToUsbHid.map(keyCode) ?: return null
        val modifiers =
            if (usage in 0xe0..0xe7) emptyList()
            else AndroidMetaStateToUsbHid.modifiers(metaState)
        return when (action) {
            KeyEvent.ACTION_DOWN -> listOf(
                RemoteKeyboardEvent.PhysicalKey(
                    usage,
                    true,
                    repeat = repeatCount > 0,
                    modifierUsages = modifiers,
                ),
            )
            KeyEvent.ACTION_UP -> listOf(
                RemoteKeyboardEvent.PhysicalKey(
                    usage,
                    false,
                    modifierUsages = modifiers,
                ),
            )
            KeyEvent.ACTION_MULTIPLE -> List(
                repeatCount.coerceIn(1, MAX_SYNTHETIC_REPEAT_COUNT),
            ) {
                RemoteKeyboardEvent.PhysicalKey(
                    usage,
                    true,
                    repeat = true,
                    modifierUsages = modifiers,
                )
            }
            else -> null
        }
    }

    private companion object {
        const val MAX_SYNTHETIC_REPEAT_COUNT = 64
    }
}

internal class RemoteKeyboardInputView(
    context: Context,
    private val emit: (RemoteKeyboardEvent) -> Unit,
) : View(context) {
    private val physicalKeyRouter = AndroidPhysicalKeyRouter()
    private val fallbackConnection = object : BaseInputConnection(this, false) {
        override fun sendKeyEvent(event: KeyEvent): Boolean = routeKeyEvent(event)

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            repeat(beforeLength.coerceIn(0, MAX_SYNTHETIC_DELETE_COUNT)) {
                emitKeyClick(KeyEvent.KEYCODE_DEL)
            }
            repeat(afterLength.coerceIn(0, MAX_SYNTHETIC_DELETE_COUNT)) {
                emitKeyClick(KeyEvent.KEYCODE_FORWARD_DEL)
            }
            return true
        }

        override fun performEditorAction(actionCode: Int): Boolean {
            emitKeyClick(KeyEvent.KEYCODE_ENTER)
            return true
        }
    }

    init {
        setBackgroundColor(Color.TRANSPARENT)
        isFocusable = true
        isFocusableInTouchMode = true
    }

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): BaseInputConnection {
        outAttrs.inputType = InputType.TYPE_NULL
        outAttrs.imeOptions =
            EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
        return fallbackConnection
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean = routeKeyEvent(event)

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean = routeKeyEvent(event)

    @Suppress("DEPRECATION")
    private fun routeKeyEvent(event: KeyEvent): Boolean {
        when (event.action) {
            KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP, KeyEvent.ACTION_MULTIPLE -> {
                val routed = physicalKeyRouter.route(
                    event.action,
                    event.keyCode,
                    event.metaState,
                    event.repeatCount,
                )
                if (routed != null) {
                    routed.forEach(emit)
                    return true
                }
            }
        }

        val text = event.characters
        if (!text.isNullOrEmpty()) {
            val boundedText = AndroidCommittedTextBounds.truncateUtf8(text)
            if (boundedText.isNotEmpty()) {
                emit(RemoteKeyboardEvent.CommittedText(boundedText))
            }
            return true
        }
        return false
    }

    private fun emitKeyClick(keyCode: Int) {
        val usage = AndroidKeyToUsbHid.map(keyCode) ?: return
        emit(RemoteKeyboardEvent.PhysicalKey(usage, true))
        emit(RemoteKeyboardEvent.PhysicalKey(usage, false))
    }

    private companion object {
        const val MAX_SYNTHETIC_DELETE_COUNT = 64
    }
}

internal class RemoteKeyboardController(
    private val activity: Activity,
    private val emitToFlutter: (Map<String, Any>) -> Unit,
) {
    private var view: RemoteKeyboardInputView? = null
    private var sessionId = ""
    private var mode = "auto"
    private var physicalEvents = 0L
    private var syntheticModifierEvents = 0L
    private var textFallbacks = 0L

    fun show(sessionId: String, mode: String): Boolean {
        if (sessionId.isBlank()) return false
        if (this.sessionId == sessionId && view?.visibility == View.VISIBLE) {
            this.mode = mode
            return true
        }
        this.sessionId = sessionId
        this.mode = mode
        val inputView = view ?: createView().also { view = it }
        inputView.visibility = View.VISIBLE
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
        inputView.requestFocus()
        inputView.post {
            val inputMethodManager =
                activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            inputMethodManager.restartInput(inputView)
            inputMethodManager.showSoftInput(inputView, InputMethodManager.SHOW_IMPLICIT)
        }
        FFI.logDiagnostic(
            "info",
            "Android remote keyboard enabled: mode=$mode, route=fallback-input-connection",
        )
        return true
    }

    fun hide(requestedSessionId: String? = null) {
        if (requestedSessionId != null && requestedSessionId != sessionId) return
        val inputView = view ?: return
        val inputMethodManager =
            activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        inputMethodManager.hideSoftInputFromWindow(inputView.windowToken, 0)
        inputView.clearFocus()
        inputView.visibility = View.GONE
        if (sessionId.isNotEmpty()) {
            FFI.logDiagnostic(
                "info",
                "Android remote keyboard disabled: mode=$mode, physical_events=$physicalEvents, synthetic_modifier_events=$syntheticModifierEvents, text_fallbacks=$textFallbacks",
            )
        }
        sessionId = ""
        physicalEvents = 0
        syntheticModifierEvents = 0
        textFallbacks = 0
    }

    fun destroy() {
        hide()
        view?.let { inputView ->
            (inputView.parent as? ViewGroup)?.removeView(inputView)
        }
        view = null
    }

    private fun createView(): RemoteKeyboardInputView {
        val inputView = RemoteKeyboardInputView(activity) { event ->
            val currentSessionId = sessionId
            if (currentSessionId.isNotEmpty()) {
                when (event) {
                    is RemoteKeyboardEvent.PhysicalKey -> {
                        physicalEvents += 1
                        syntheticModifierEvents += event.modifierUsages.size
                        emitToFlutter(
                            mapOf(
                                "session_id" to currentSessionId,
                                "kind" to "physical",
                                "usb_hid_usage" to event.usbHidUsage,
                                "down" to event.down,
                                "repeat" to event.repeat,
                                "modifier_usages" to event.modifierUsages,
                            ),
                        )
                    }

                    is RemoteKeyboardEvent.CommittedText -> {
                        textFallbacks += 1
                        val layout = currentInputLayout()
                        emitToFlutter(
                            mapOf(
                                "session_id" to currentSessionId,
                                "kind" to "text",
                                "text" to event.text,
                                "source_language_tag" to layout.languageTag,
                                "source_layout_type" to layout.layoutType,
                            ),
                        )
                    }
                }
            }
        }
        val root = activity.findViewById<ViewGroup>(android.R.id.content)
        val layoutParams = FrameLayout.LayoutParams(1, 1, Gravity.TOP or Gravity.START)
        root.addView(inputView, layoutParams)
        return inputView
    }

    @Suppress("DEPRECATION")
    private fun currentInputLayout(): AndroidInputLayoutInfo {
        val inputMethodManager =
            activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        val subtype = inputMethodManager.currentInputMethodSubtype
            ?: return AndroidInputLayoutInfo("", "")
        val hintedTag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            subtype.physicalKeyboardHintLanguageTag?.toLanguageTag().orEmpty()
        } else {
            ""
        }
        val rawTag = hintedTag.ifEmpty {
            subtype.languageTag.ifEmpty { subtype.locale.replace('_', '-') }
        }
        val canonicalTag = AndroidInputLayoutMetadata.canonicalizeLanguageTag(rawTag)
        val hintedLayout = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            subtype.physicalKeyboardHintLayoutType
        } else {
            ""
        }
        val rawLayout = hintedLayout.ifEmpty {
            subtype.getExtraValueOf("KeyboardLayoutSet").orEmpty()
        }
        val layoutType = AndroidInputLayoutMetadata.sanitizeLayoutType(rawLayout)
        return AndroidInputLayoutInfo(canonicalTag, layoutType)
    }
}
