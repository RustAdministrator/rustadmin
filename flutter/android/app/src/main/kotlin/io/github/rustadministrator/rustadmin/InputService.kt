package io.github.rustadministrator.rustadmin

/**
 * Handle remote input and dispatch android gesture
 *
 * Inspired by [droidVNC-NG] https://github.com/bk138/droidVNC-NG
 */

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.widget.EditText
import android.view.accessibility.AccessibilityEvent
import android.view.ViewGroup.LayoutParams
import android.view.accessibility.AccessibilityNodeInfo
import android.view.KeyEvent as KeyEventAndroid
import android.view.ViewConfiguration
import android.graphics.Rect
import android.media.AudioManager
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.AccessibilityServiceInfo.FLAG_INPUT_METHOD_EDITOR
import android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
import androidx.annotation.RequiresApi
import java.util.*
import java.lang.Character
import kotlin.math.abs
import kotlin.math.max
import hbb.MessageOuterClass.KeyEvent
import hbb.MessageOuterClass.KeyboardMode
import hbb.KeyEventConverter

// const val BUTTON_UP = 2
// const val BUTTON_BACK = 0x08

const val LEFT_DOWN = 9
const val LEFT_MOVE = 8
const val LEFT_UP = 10
const val RIGHT_UP = 18
// (BUTTON_BACK << 3) | BUTTON_UP
const val BACK_UP = 66
const val WHEEL_BUTTON_DOWN = 33
const val WHEEL_BUTTON_UP = 34
const val WHEEL_DOWN = 523331
const val WHEEL_UP = 963

const val TOUCH_SCALE_START = 1
const val TOUCH_SCALE = 2
const val TOUCH_SCALE_END = 3
const val TOUCH_PAN_START = 4
const val TOUCH_PAN_UPDATE = 5
const val TOUCH_PAN_END = 6

const val WHEEL_STEP = 120
const val WHEEL_DURATION = 50L
const val LONG_TAP_DELAY = 200L

class InputService : AccessibilityService() {

    companion object {
        var ctx: InputService? = null
        val isOpen: Boolean
            get() = ctx != null
    }

    private val diagnostics = AndroidInputDiagnostics()
    private val inputHandler = Handler(Looper.getMainLooper())
    private var leftIsDown = false
    private var touchPath = Path()
    private var stroke: GestureDescription.StrokeDescription? = null
    private var gestureActive = false
    private var lastTouchGestureStartTime = 0L
    private var mouseX = 0
    private var mouseY = 0
    private var timer = Timer()
    private var recentActionTask: TimerTask? = null
    // 100(tap timeout) + 400(long press timeout)
    private val longPressDuration = ViewConfiguration.getTapTimeout().toLong() + ViewConfiguration.getLongPressTimeout().toLong()

    private val wheelActionsQueue = LinkedList<GestureDescription>()
    private var isWheelActionsPolling = false
    private var isWaitingLongPress = false

    private var fakeEditTextForTextStateCalculation: EditText? = null

    private var lastX = 0
    private var lastY = 0

    private val volumeController: VolumeController by lazy { VolumeController(applicationContext.getSystemService(AUDIO_SERVICE) as AudioManager) }

    @RequiresApi(Build.VERSION_CODES.N)
    fun onMouseInput(mask: Int, _x: Int, _y: Int) {
        val x = max(0, _x)
        val y = max(0, _y)

        if (mask == 0 || mask == LEFT_MOVE) {
            val oldX = mouseX
            val oldY = mouseY
            mouseX = x * SCREEN_INFO.scale
            mouseY = y * SCREEN_INFO.scale
            if (isWaitingLongPress) {
                val delta = abs(oldX - mouseX) + abs(oldY - mouseY)
                if (delta > 8) {
                    isWaitingLongPress = false
                }
            }
        }

        // left button down, was up
        if (mask == LEFT_DOWN) {
            isWaitingLongPress = true
            timer.schedule(object : TimerTask() {
                override fun run() {
                    if (isWaitingLongPress) {
                        isWaitingLongPress = false
                        continueGesture(mouseX, mouseY)
                    }
                }
            }, longPressDuration)

            leftIsDown = true
            startGesture(mouseX, mouseY)
            return
        }

        // left down, was down
        if (leftIsDown) {
            continueGesture(mouseX, mouseY)
        }

        // left up, was down
        if (mask == LEFT_UP) {
            if (leftIsDown) {
                leftIsDown = false
                isWaitingLongPress = false
                endGesture(mouseX, mouseY)
                return
            }
        }

        if (mask == RIGHT_UP) {
            longPress(mouseX, mouseY)
            return
        }

        if (mask == BACK_UP) {
            performGlobalAction(GLOBAL_ACTION_BACK)
            return
        }

        // long WHEEL_BUTTON_DOWN -> GLOBAL_ACTION_RECENTS
        if (mask == WHEEL_BUTTON_DOWN) {
            timer.purge()
            recentActionTask = object : TimerTask() {
                override fun run() {
                    performGlobalAction(GLOBAL_ACTION_RECENTS)
                    recentActionTask = null
                }
            }
            timer.schedule(recentActionTask, LONG_TAP_DELAY)
        }

        // wheel button up
        if (mask == WHEEL_BUTTON_UP) {
            if (recentActionTask != null) {
                recentActionTask!!.cancel()
                performGlobalAction(GLOBAL_ACTION_HOME)
            }
            return
        }

        if (mask == WHEEL_DOWN) {
            if (mouseY < WHEEL_STEP) {
                return
            }
            val path = Path()
            path.moveTo(mouseX.toFloat(), mouseY.toFloat())
            path.lineTo(mouseX.toFloat(), (mouseY - WHEEL_STEP).toFloat())
            val stroke = GestureDescription.StrokeDescription(
                path,
                0,
                WHEEL_DURATION
            )
            val builder = GestureDescription.Builder()
            builder.addStroke(stroke)
            wheelActionsQueue.offer(builder.build())
            consumeWheelActions()

        }

        if (mask == WHEEL_UP) {
            if (mouseY < WHEEL_STEP) {
                return
            }
            val path = Path()
            path.moveTo(mouseX.toFloat(), mouseY.toFloat())
            path.lineTo(mouseX.toFloat(), (mouseY + WHEEL_STEP).toFloat())
            val stroke = GestureDescription.StrokeDescription(
                path,
                0,
                WHEEL_DURATION
            )
            val builder = GestureDescription.Builder()
            builder.addStroke(stroke)
            wheelActionsQueue.offer(builder.build())
            consumeWheelActions()
        }
    }

    @RequiresApi(Build.VERSION_CODES.N)
    fun onTouchInput(mask: Int, _x: Int, _y: Int) {
        when (mask) {
            TOUCH_PAN_UPDATE -> {
                mouseX -= _x * SCREEN_INFO.scale
                mouseY -= _y * SCREEN_INFO.scale
                mouseX = max(0, mouseX);
                mouseY = max(0, mouseY);
                continueGesture(mouseX, mouseY)
            }
            TOUCH_PAN_START -> {
                mouseX = max(0, _x) * SCREEN_INFO.scale
                mouseY = max(0, _y) * SCREEN_INFO.scale
                startGesture(mouseX, mouseY)
            }
            TOUCH_PAN_END -> {
                endGesture(mouseX, mouseY)
                mouseX = max(0, _x) * SCREEN_INFO.scale
                mouseY = max(0, _y) * SCREEN_INFO.scale
            }
            else -> {}
        }
    }

    @RequiresApi(Build.VERSION_CODES.N)
    fun releaseRemoteInputState() {
        isWaitingLongPress = false
        leftIsDown = false
        recentActionTask?.cancel()
        recentActionTask = null
        wheelActionsQueue.clear()
        timer.purge()
        if (gestureActive && stroke != null) {
            endGesture(mouseX, mouseY)
        } else {
            touchPath.reset()
            stroke = null
            gestureActive = false
        }
    }

    @RequiresApi(Build.VERSION_CODES.N)
    private fun consumeWheelActions() {
        if (isWheelActionsPolling) {
            return
        } else {
            isWheelActionsPolling = true
        }
        wheelActionsQueue.poll()?.let {
            dispatchGesture(it, null, null)
            timer.purge()
            timer.schedule(object : TimerTask() {
                override fun run() {
                    isWheelActionsPolling = false
                    consumeWheelActions()
                }
            }, WHEEL_DURATION + 10)
        } ?: let {
            isWheelActionsPolling = false
            return
        }
    }

    @RequiresApi(Build.VERSION_CODES.N)
    private fun performClick(x: Int, y: Int, duration: Long) {
        val path = Path()
        path.moveTo(x.toFloat(), y.toFloat())
        try {
            val longPressStroke = GestureDescription.StrokeDescription(path, 0, duration)
            val builder = GestureDescription.Builder()
            builder.addStroke(longPressStroke)
            dispatchGesture(builder.build(), null, null)
        } catch (e: Exception) {
            diagnostics.failure(AndroidInputFailure.CLICK, e)
        }
    }

    @RequiresApi(Build.VERSION_CODES.N)
    private fun longPress(x: Int, y: Int) {
        performClick(x, y, longPressDuration)
    }

    private fun startGesture(x: Int, y: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            touchPath.reset()
        } else {
            touchPath = Path()
        }
        touchPath.moveTo(x.toFloat(), y.toFloat())
        lastTouchGestureStartTime = SystemClock.uptimeMillis()
        lastX = x
        lastY = y
        gestureActive = true
    }

    @RequiresApi(Build.VERSION_CODES.N)
    private fun doDispatchGesture(x: Int, y: Int, willContinue: Boolean) {
        touchPath.lineTo(x.toFloat(), y.toFloat())
        var duration = SystemClock.uptimeMillis() - lastTouchGestureStartTime
        if (duration <= 0) {
            duration = 1
        }
        try {
            if (stroke == null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    stroke = GestureDescription.StrokeDescription(
                        touchPath,
                        0,
                        duration,
                        willContinue
                    )
                } else {
                    stroke = GestureDescription.StrokeDescription(
                        touchPath,
                        0,
                        duration
                    )
                }
            } else {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    stroke = stroke?.continueStroke(touchPath, 0, duration, willContinue)
                } else {
                    stroke = null
                    stroke = GestureDescription.StrokeDescription(
                        touchPath,
                        0,
                        duration
                    )
                }
            }
            stroke?.let {
                val builder = GestureDescription.Builder()
                builder.addStroke(it)
                dispatchGesture(builder.build(), null, null)
            }
        } catch (e: Exception) {
            diagnostics.failure(AndroidInputFailure.DISPATCH_GESTURE, e)
        }
    }

    @RequiresApi(Build.VERSION_CODES.N)
    private fun continueGesture(x: Int, y: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            doDispatchGesture(x, y, true)
            touchPath.reset()
            touchPath.moveTo(x.toFloat(), y.toFloat())
            lastTouchGestureStartTime = SystemClock.uptimeMillis()
            lastX = x
            lastY = y
        } else {
            touchPath.lineTo(x.toFloat(), y.toFloat())
        }
    }

    @RequiresApi(Build.VERSION_CODES.N)
    private fun endGestureBelowO(x: Int, y: Int) {
        try {
            touchPath.lineTo(x.toFloat(), y.toFloat())
            var duration = SystemClock.uptimeMillis() - lastTouchGestureStartTime
            if (duration <= 0) {
                duration = 1
            }
            val stroke = GestureDescription.StrokeDescription(
                touchPath,
                0,
                duration
            )
            val builder = GestureDescription.Builder()
            builder.addStroke(stroke)
            dispatchGesture(builder.build(), null, null)
        } catch (e: Exception) {
            diagnostics.failure(AndroidInputFailure.END_GESTURE, e)
        }
    }

    @RequiresApi(Build.VERSION_CODES.N)
    private fun endGesture(x: Int, y: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            doDispatchGesture(x, y, false)
            touchPath.reset()
            stroke = null
        } else {
            endGestureBelowO(x, y)
        }
        gestureActive = false
    }

    @RequiresApi(Build.VERSION_CODES.N)
    fun onKeyEvent(data: ByteArray) {
        val keyEvent = try {
            KeyEvent.parseFrom(data)
        } catch (error: Exception) {
            diagnostics.failure(AndroidInputFailure.HOST_KEY_DECODE, error)
            return
        }
        val textToCommit = when {
            keyEvent.hasSeq() -> keyEvent.seq
            keyEvent.mode == KeyboardMode.Legacy && keyEvent.hasChr() -> {
                if (!keyEvent.down && !keyEvent.press) return
                val scalar = keyEvent.chr
                if (!Character.isValidCodePoint(scalar) || scalar in 0xd800..0xdfff) {
                    diagnostics.rejected(AndroidInputRejection.INVALID_TEXT)
                    return
                }
                String(Character.toChars(scalar))
            }
            else -> null
        }
        if (textToCommit != null) {
            AndroidCommittedTextBounds.validate(textToCommit)?.let {
                diagnostics.rejected(it)
                return
            }
            if (textToCommit.isEmpty()) return
        }
        inputHandler.post {
            if (ctx !== this) return@post
            try {
                dispatchHostKey(keyEvent, textToCommit)
            } catch (error: Exception) {
                diagnostics.failure(AndroidInputFailure.HOST_KEY_DISPATCH, error)
            }
        }
    }

    private fun dispatchHostKey(keyEvent: KeyEvent, textToCommit: String?) {
        val event = if (textToCommit == null) KeyEventConverter.toAndroidKeyEvent(keyEvent) else null
        if (event != null) {
            if (tryHandleVolumeKeyEvent(event) || tryHandlePowerKeyEvent(event)) {
                if (keyEvent.press) tryHandlePowerKeyEvent(KeyEventAndroid.changeAction(event, KeyEventAndroid.ACTION_UP))
                return
            }
            if (event.keyCode == KeyEventAndroid.KEYCODE_UNKNOWN) {
                diagnostics.rejected(AndroidInputRejection.HOST_KEY)
                return
            }
        }
        val connectionDispatch: (() -> Unit)? = if (Build.VERSION.SDK_INT >= 33) {
            getInputMethod()?.getCurrentInputConnection()?.let { connection ->
                {
                    if (textToCommit != null) {
                        connection.commitText(textToCommit, 1, null)
                    } else if (event != null) {
                        connection.sendKeyEvent(event)
                        if (keyEvent.press) {
                            connection.sendKeyEvent(KeyEventAndroid.changeAction(event, KeyEventAndroid.ACTION_UP))
                        }
                    }
                }
            }
        } else null
        dispatchAndroidHostInput(connectionDispatch) {
            dispatchHostAccessibility(event, textToCommit, keyEvent.press)
        }
    }

    private fun tryHandleVolumeKeyEvent(event: KeyEventAndroid): Boolean {
        when (event.keyCode) {
            KeyEventAndroid.KEYCODE_VOLUME_UP -> {
                if (event.action == KeyEventAndroid.ACTION_DOWN) {
                    volumeController.raiseVolume(null, true, AudioManager.STREAM_SYSTEM)
                }
                return true
            }
            KeyEventAndroid.KEYCODE_VOLUME_DOWN -> {
                if (event.action == KeyEventAndroid.ACTION_DOWN) {
                    volumeController.lowerVolume(null, true, AudioManager.STREAM_SYSTEM)
                }
                return true
            }
            KeyEventAndroid.KEYCODE_VOLUME_MUTE -> {
                if (event.action == KeyEventAndroid.ACTION_DOWN) {
                    volumeController.toggleMute(true, AudioManager.STREAM_SYSTEM)
                }
                return true
            }
            else -> {
                return false
            }
        }
    }

    private fun tryHandlePowerKeyEvent(event: KeyEventAndroid): Boolean {
        if (event.keyCode == KeyEventAndroid.KEYCODE_POWER) {
            // Perform power dialog action when action is up
            if (event.action == KeyEventAndroid.ACTION_UP) {
                performGlobalAction(GLOBAL_ACTION_POWER_DIALOG);
            }
            return true
        }
        return false
    }

    private fun isCurrentInputFocus(node: AccessibilityNodeInfo): Boolean {
        if (!node.refresh() || !node.isFocused || !node.isEnabled || !node.isVisibleToUser) return false
        val current = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        try {
            return current == node
        } finally {
            if (Build.VERSION.SDK_INT < 33 && current !== node) current.recycle()
        }
    }

    private fun supportsAction(node: AccessibilityNodeInfo, action: Int): Boolean =
        node.actionList.any { it.id == action }

    private inner class FocusedTextTarget(private val node: AccessibilityNodeInfo) : AndroidHostTextTarget {
        private fun isEligible(): Boolean = isCurrentInputFocus(node) && node.isEditable &&
            !node.isPassword && supportsAction(node, AccessibilityNodeInfo.ACTION_SET_TEXT)

        override fun read(): AndroidHostTextState? {
            if (!isEligible()) return null
            val showingHint = Build.VERSION.SDK_INT >= 26 && node.isShowingHintText
            val rawText = if (showingHint) "" else node.text ?: ""
            if (rawText.length > AndroidCommittedTextBounds.MAX_UTF8_BYTES) return null
            val text = rawText.toString()
            return AndroidHostTextState(text, node.textSelectionStart, node.textSelectionEnd)
                .takeIf { it.isValid() }
        }

        override fun setText(expected: AndroidHostTextState, value: String): Boolean {
            if (read() != expected) return false
            return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value)
            })
        }

        override fun setSelection(expectedText: String, start: Int, end: Int): Boolean {
            if (read()?.text != expectedText || !supportsAction(node, AccessibilityNodeInfo.ACTION_SET_SELECTION)) return false
            return node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
            })
        }
    }

    private fun dispatchHostAccessibility(event: KeyEventAndroid?, text: String?, press: Boolean) {
        // Key-up does not reapply an edit or activate a newly focused control.
        if (text == null && event?.action != KeyEventAndroid.ACTION_DOWN) return
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (node == null) {
            diagnostics.rejected(AndroidInputRejection.HOST_TARGET)
            return
        }
        try {
            if (!isCurrentInputFocus(node)) {
                diagnostics.rejected(AndroidInputRejection.HOST_TARGET)
                return
            }
            if (!node.isEditable) {
                if (text != null || event == null || !performHostNodeAction(node, event)) {
                    diagnostics.rejected(AndroidInputRejection.HOST_ACTION)
                }
                return
            }
            if (text == null && event?.keyCode == KeyEventAndroid.KEYCODE_ENTER &&
                !event.isCtrlPressed && !event.isAltPressed && !event.isMetaPressed && !event.isShiftPressed &&
                Build.VERSION.SDK_INT >= 30 &&
                supportsAction(node, AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)) {
                if (!isCurrentInputFocus(node) ||
                    !node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)) {
                    diagnostics.rejected(AndroidInputRejection.HOST_ACTION)
                }
                return
            }
            val target = FocusedTextTarget(node)
            val before = target.read()
            if (before == null) {
                diagnostics.rejected(AndroidInputRejection.HOST_TARGET)
                return
            }
            val after = if (text != null) before.replaceSelection(text)
                else event?.let { calculateHostKeyEdit(node, before, it, press) }
            if (after == null) {
                diagnostics.rejected(AndroidInputRejection.HOST_EDIT)
                return
            }
            when (applyAndroidHostEdit(target, before, after)) {
                AndroidHostEditResult.REJECTED -> diagnostics.rejected(AndroidInputRejection.HOST_EDIT)
                AndroidHostEditResult.TEXT_APPLIED_SELECTION_UNCONFIRMED ->
                    diagnostics.rejected(AndroidInputRejection.HOST_SELECTION)
                AndroidHostEditResult.APPLIED -> Unit
            }
        } finally {
            fakeEditTextForTextStateCalculation?.setText(null)
            if (Build.VERSION.SDK_INT < 33) node.recycle()
        }
    }

    private fun performHostNodeAction(node: AccessibilityNodeInfo, event: KeyEventAndroid): Boolean {
        if (event.isCtrlPressed || event.isAltPressed || event.isMetaPressed || event.isShiftPressed) return false
        val action = when (event.keyCode) {
            KeyEventAndroid.KEYCODE_ENTER, KeyEventAndroid.KEYCODE_DPAD_CENTER,
            KeyEventAndroid.KEYCODE_SPACE -> AccessibilityNodeInfo.ACTION_CLICK
            KeyEventAndroid.KEYCODE_DPAD_DOWN, KeyEventAndroid.KEYCODE_PAGE_DOWN -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
            KeyEventAndroid.KEYCODE_DPAD_UP, KeyEventAndroid.KEYCODE_PAGE_UP -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
            KeyEventAndroid.KEYCODE_DPAD_LEFT -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id
            KeyEventAndroid.KEYCODE_DPAD_RIGHT -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id
            else -> return false
        }
        return isCurrentInputFocus(node) && supportsAction(node, action) && node.performAction(action)
    }

    private fun calculateHostKeyEdit(
        node: AccessibilityNodeInfo,
        before: AndroidHostTextState,
        event: KeyEventAndroid,
        press: Boolean,
    ): AndroidHostTextState? {
        val editingCommand = when (event.keyCode) {
            KeyEventAndroid.KEYCODE_DEL, KeyEventAndroid.KEYCODE_FORWARD_DEL,
            KeyEventAndroid.KEYCODE_DPAD_LEFT, KeyEventAndroid.KEYCODE_DPAD_RIGHT,
            KeyEventAndroid.KEYCODE_DPAD_UP, KeyEventAndroid.KEYCODE_DPAD_DOWN,
            KeyEventAndroid.KEYCODE_MOVE_HOME, KeyEventAndroid.KEYCODE_MOVE_END,
            KeyEventAndroid.KEYCODE_PAGE_UP, KeyEventAndroid.KEYCODE_PAGE_DOWN -> true
            else -> false
        }
        // Do not let the scratch editor execute clipboard or application shortcuts.
        val selectAll = event.keyCode == KeyEventAndroid.KEYCODE_A && event.isCtrlPressed
        if (event.isMetaPressed || (event.isCtrlPressed && !editingCommand && !selectAll) ||
            (!editingCommand && !selectAll && event.unicodeChar == 0)) return null
        val editor = fakeEditTextForTextStateCalculation ?: return null
        editor.inputType = node.inputType
        editor.setSingleLine(!node.isMultiLine)
        editor.setText(before.text)
        editor.setSelection(before.selectionStart, before.selectionEnd)
        val rect = Rect()
        node.getBoundsInScreen(rect)
        // Use the platform editor for navigation/deletion, including grapheme handling.
        editor.layout(0, 0, rect.width().coerceIn(1, 8192), rect.height().coerceIn(1, 8192))
        editor.onPreDraw()
        if (!editor.onKeyDown(event.keyCode, event)) return null
        if (press) editor.onKeyUp(event.keyCode, KeyEventAndroid.changeAction(event, KeyEventAndroid.ACTION_UP))
        return AndroidHostTextState(editor.text.toString(), editor.selectionStart, editor.selectionEnd)
            .takeIf { it.isValid() }
    }


    override fun onAccessibilityEvent(event: AccessibilityEvent) {
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        ctx = this
        val info = AccessibilityServiceInfo()
        if (Build.VERSION.SDK_INT >= 33) {
            info.flags = FLAG_INPUT_METHOD_EDITOR or FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        } else {
            info.flags = FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        }
        setServiceInfo(info)
        fakeEditTextForTextStateCalculation = EditText(this)
        // Size here doesn't matter, we won't show this view.
        fakeEditTextForTextStateCalculation?.layoutParams = LayoutParams(100, 100)
        fakeEditTextForTextStateCalculation?.onPreDraw()
        diagnostics.accessibilityConnected()
    }

    override fun onDestroy() {
        ctx = null
        inputHandler.removeCallbacksAndMessages(null)
        fakeEditTextForTextStateCalculation?.setText(null)
        fakeEditTextForTextStateCalculation = null
        super.onDestroy()
    }

    override fun onInterrupt() {}
}
