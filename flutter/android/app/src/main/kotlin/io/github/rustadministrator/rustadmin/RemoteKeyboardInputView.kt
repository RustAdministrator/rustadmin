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
        val synthesizedModifier: Boolean = false,
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
    private data class ActiveKey(
        val usbHidUsage: Int,
        val syntheticModifiers: List<Int>,
    )

    private val activeKeys = linkedMapOf<Int, ActiveKey>()
    private val explicitModifiers = linkedSetOf<Int>()
    private val syntheticModifierReferences = mutableMapOf<Int, Int>()

    fun route(
        action: Int,
        keyCode: Int,
        metaState: Int,
        repeatCount: Int = 1,
    ): List<RemoteKeyboardEvent.PhysicalKey>? {
        val usage = AndroidKeyToUsbHid.map(keyCode) ?: return null
        return when (action) {
            KeyEvent.ACTION_DOWN -> routeDown(keyCode, usage, metaState)
            KeyEvent.ACTION_UP -> routeUp(keyCode, usage)
            KeyEvent.ACTION_MULTIPLE -> buildList {
                repeat(repeatCount.coerceIn(1, MAX_SYNTHETIC_REPEAT_COUNT)) {
                    addAll(routeDown(keyCode, usage, metaState))
                    addAll(routeUp(keyCode, usage))
                }
            }
            else -> null
        }
    }

    fun releaseAll(): List<RemoteKeyboardEvent.PhysicalKey> = buildList {
        activeKeys.entries.toList().asReversed().forEach { (keyCode, activeKey) ->
            add(RemoteKeyboardEvent.PhysicalKey(activeKey.usbHidUsage, false))
            activeKeys.remove(keyCode)
            activeKey.syntheticModifiers.asReversed().forEach { modifier ->
                releaseSyntheticModifier(modifier, this)
            }
        }
        explicitModifiers.toList().asReversed().forEach { modifier ->
            releaseExplicitModifier(modifier, this)
        }
        syntheticModifierReferences.keys.toList().asReversed().forEach { modifier ->
            syntheticModifierReferences.remove(modifier)
            add(RemoteKeyboardEvent.PhysicalKey(modifier, false, true))
        }
    }

    private fun routeDown(
        keyCode: Int,
        usage: Int,
        metaState: Int,
    ): List<RemoteKeyboardEvent.PhysicalKey> = buildList {
        if (isModifier(usage)) {
            acquireExplicitModifier(usage, this)
            return@buildList
        }
        if (!activeKeys.containsKey(keyCode)) {
            val syntheticModifiers = AndroidMetaStateToUsbHid.modifiers(metaState)
            syntheticModifiers.forEach { modifier ->
                acquireSyntheticModifier(modifier, this)
            }
            activeKeys[keyCode] = ActiveKey(usage, syntheticModifiers)
        }
        add(RemoteKeyboardEvent.PhysicalKey(usage, true))
    }

    private fun routeUp(
        keyCode: Int,
        usage: Int,
    ): List<RemoteKeyboardEvent.PhysicalKey> = buildList {
        if (isModifier(usage)) {
            releaseExplicitModifier(usage, this)
            return@buildList
        }
        add(RemoteKeyboardEvent.PhysicalKey(usage, false))
        activeKeys.remove(keyCode)?.syntheticModifiers?.asReversed()?.forEach { modifier ->
            releaseSyntheticModifier(modifier, this)
        }
    }

    private fun acquireExplicitModifier(
        usage: Int,
        output: MutableList<RemoteKeyboardEvent.PhysicalKey>,
    ) {
        if (usage in explicitModifiers) return
        val wasActive = isModifierActive(usage)
        explicitModifiers += usage
        if (!wasActive) output += RemoteKeyboardEvent.PhysicalKey(usage, true)
    }

    private fun releaseExplicitModifier(
        usage: Int,
        output: MutableList<RemoteKeyboardEvent.PhysicalKey>,
    ) {
        if (!explicitModifiers.remove(usage)) return
        if (!isModifierActive(usage)) output += RemoteKeyboardEvent.PhysicalKey(usage, false)
    }

    private fun acquireSyntheticModifier(
        usage: Int,
        output: MutableList<RemoteKeyboardEvent.PhysicalKey>,
    ) {
        val wasActive = isModifierActive(usage)
        syntheticModifierReferences[usage] = (syntheticModifierReferences[usage] ?: 0) + 1
        if (!wasActive) output += RemoteKeyboardEvent.PhysicalKey(usage, true, true)
    }

    private fun releaseSyntheticModifier(
        usage: Int,
        output: MutableList<RemoteKeyboardEvent.PhysicalKey>,
    ) {
        val references = syntheticModifierReferences[usage] ?: return
        if (references <= 1) {
            syntheticModifierReferences.remove(usage)
        } else {
            syntheticModifierReferences[usage] = references - 1
        }
        if (!isModifierActive(usage)) {
            output += RemoteKeyboardEvent.PhysicalKey(usage, false, true)
        }
    }

    private fun isModifierActive(usage: Int): Boolean =
        usage in explicitModifiers || (syntheticModifierReferences[usage] ?: 0) > 0

    private fun isModifier(usage: Int): Boolean = usage in 0xe0..0xe7

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
            emit(RemoteKeyboardEvent.CommittedText(text.take(MAX_FALLBACK_TEXT_CHARS)))
            return true
        }
        return false
    }

    fun releasePressedKeys() {
        physicalKeyRouter.releaseAll().forEach(emit)
    }

    private fun emitKeyClick(keyCode: Int) {
        val usage = AndroidKeyToUsbHid.map(keyCode) ?: return
        emit(RemoteKeyboardEvent.PhysicalKey(usage, true))
        emit(RemoteKeyboardEvent.PhysicalKey(usage, false))
    }

    private companion object {
        const val MAX_SYNTHETIC_DELETE_COUNT = 64
        const val MAX_FALLBACK_TEXT_CHARS = 2048
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
    private val sourceLayouts = linkedSetOf<String>()

    fun show(sessionId: String, mode: String): Boolean {
        if (sessionId.isBlank()) return false
        if (this.sessionId == sessionId && view?.visibility == View.VISIBLE) {
            this.mode = mode
            return true
        }
        if (this.sessionId.isNotEmpty() && this.sessionId != sessionId) {
            view?.releasePressedKeys()
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
        inputView.releasePressedKeys()
        val inputMethodManager =
            activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        inputMethodManager.hideSoftInputFromWindow(inputView.windowToken, 0)
        inputView.clearFocus()
        inputView.visibility = View.GONE
        if (sessionId.isNotEmpty()) {
            FFI.logDiagnostic(
                "info",
                "Android remote keyboard disabled: mode=$mode, physical_events=$physicalEvents, synthetic_modifier_events=$syntheticModifierEvents, text_fallbacks=$textFallbacks, source_layouts=${sourceLayouts.joinToString(";")}",
            )
        }
        sessionId = ""
        physicalEvents = 0
        syntheticModifierEvents = 0
        textFallbacks = 0
        sourceLayouts.clear()
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
                        if (event.synthesizedModifier) syntheticModifierEvents += 1
                        emitToFlutter(
                            mapOf(
                                "session_id" to currentSessionId,
                                "kind" to "physical",
                                "usb_hid_usage" to event.usbHidUsage,
                                "down" to event.down,
                            ),
                        )
                    }

                    is RemoteKeyboardEvent.CommittedText -> {
                        textFallbacks += 1
                        val layout = currentInputLayout()
                        if (layout.languageTag.isNotEmpty()) {
                            sourceLayouts += if (layout.layoutType.isEmpty()) {
                                layout.languageTag
                            } else {
                                "${layout.languageTag}/${layout.layoutType}"
                            }
                        }
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
