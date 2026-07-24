package com.secondscreen.receiver

import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import kotlin.math.abs

class TouchInputHandler(
    private val sendEvent: (TouchEventData) -> Unit,
    private val sendScroll: (ScrollEventData) -> Unit,
    private val sendKeyboard: (KeyboardEventData) -> Unit
) : View.OnTouchListener, View.OnHoverListener {

    private val sendThread = HandlerThread("TouchSend").apply { start() }
    private val sendHandler = Handler(sendThread.looper)

    // Long-press state
    private val LONG_PRESS_TIMEOUT_MS = 500L
    private val LONG_PRESS_SLOP_SQ = 20f * 20f // ~20px movement threshold squared
    private var longPressRunnable: Runnable? = null
    private var downX = 0f
    private var downY = 0f
    private var isLongPressTriggered = false
    private var touchView: View? = null

    // Scroll state
    private var isScrolling = false
    private var lastScrollMidX = 0f
    private var lastScrollMidY = 0f

    // Three-finger gesture state
    private var isThreeFingerGesture = false
    private var threeFingerStartX = 0f
    private var threeFingerStartY = 0f
    private var threeFingerDownTime = 0L
    private var threeFingerSwipeFired = false
    private val THREE_FINGER_SWIPE_THRESHOLD = 100f // px minimum distance
    private val THREE_FINGER_TAP_TIMEOUT = 400L     // ms max for tap

    // Four-finger gesture state
    private var isFourFingerGesture = false
    private var fourFingerStartX = 0f
    private var fourFingerSwipeFired = false
    private val FOUR_FINGER_SWIPE_THRESHOLD = 120f // px minimum distance

    // S Pen button + swipe = scroll state
    private var isSpenScrolling = false
    private var spenLastX = 0f
    private var spenLastY = 0f

    companion object {
        private const val TAG = "TouchInput"

        // macOS virtual key codes
        private const val MAC_VK_LEFT_ARROW: Int = 0x7B  // 123
        private const val MAC_VK_RIGHT_ARROW: Int = 0x7C // 124
        private const val MAC_VK_UP_ARROW: Int = 0x7E    // 126
        private const val MAC_VK_DOWN_ARROW: Int = 0x7D   // 125
        private const val MAC_VK_F11: Int = 0x67           // 103
        private const val MAC_VK_TAB: Int = 0x30           // 48

        // Modifier bitmasks
        private const val MODIFIER_CONTROL: Int = 0x02
        private const val MODIFIER_COMMAND: Int = 0x08
        private const val MODIFIER_SHIFT_COMMAND: Int = 0x09
    }

    override fun onTouch(view: View, event: MotionEvent): Boolean {
        touchView = view
        val viewWidth = view.width.toFloat()
        val viewHeight = view.height.toFloat()

        // Detect S Pen button held while touching screen
        val spenButtonDown = event.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // Deliver move events as they arrive instead of batched to vsync —
                // saves up to a frame of input latency
                view.requestUnbufferedDispatch(event)

                isLongPressTriggered = false
                isScrolling = false
                downX = event.x
                downY = event.y

                if (spenButtonDown) {
                    // S Pen button + touch = scroll mode
                    isSpenScrolling = true
                    spenLastX = event.x
                    spenLastY = event.y
                    sendHandler.post { sendScroll(ScrollEventData(0, 0f, 0f)) }
                    return true
                }

                // Send left-mouse-down immediately
                val x = event.x / viewWidth
                val y = event.y / viewHeight
                val pressure = event.pressure.coerceIn(0f, 1f)
                sendHandler.post { sendEvent(TouchEventData(0, x, y, pressure)) }

                // Schedule long-press
                val lpX = x
                val lpY = y
                longPressRunnable = Runnable {
                    isLongPressTriggered = true
                    // Cancel left-mouse-down, then send right-click
                    sendEvent(TouchEventData(2, lpX, lpY, 0f))
                    sendEvent(TouchEventData(3, lpX, lpY, pressure))
                    sendEvent(TouchEventData(4, lpX, lpY, 0f))
                    // Haptic feedback on UI thread
                    view.post { view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) }
                }
                sendHandler.postDelayed(longPressRunnable!!, LONG_PRESS_TIMEOUT_MS)
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                // Four-finger gesture detection
                if (event.pointerCount >= 4) {
                    // Cancel any three-finger gesture
                    if (isThreeFingerGesture) {
                        isThreeFingerGesture = false
                        threeFingerSwipeFired = false
                    }
                    if (isScrolling) {
                        sendHandler.post { sendScroll(ScrollEventData(2, 0f, 0f)) }
                        isScrolling = false
                    }
                    cancelLongPress()

                    if (!isFourFingerGesture) {
                        isFourFingerGesture = true
                        fourFingerSwipeFired = false
                        fourFingerStartX = averageX(event, 4)
                        Log.i(TAG, "Four-finger mode entered")
                    }
                }
                // Three-finger gesture detection
                else if (event.pointerCount >= 3 && !isFourFingerGesture) {
                    if (isScrolling) {
                        sendHandler.post { sendScroll(ScrollEventData(2, 0f, 0f)) }
                        isScrolling = false
                    }
                    cancelLongPress()

                    if (!isThreeFingerGesture) {
                        isThreeFingerGesture = true
                        threeFingerSwipeFired = false
                        threeFingerStartX = averageX(event, 3)
                        threeFingerStartY = averageY(event, 3)
                        threeFingerDownTime = System.currentTimeMillis()
                        Log.i(TAG, "Three-finger mode entered")
                    }
                }
                // Two-finger scroll
                else if (event.pointerCount == 2 && !isThreeFingerGesture && !isFourFingerGesture) {
                    cancelLongPress()

                    // Release left-mouse if it was down
                    val x = event.getX(0) / viewWidth
                    val y = event.getY(0) / viewHeight
                    sendHandler.post { sendEvent(TouchEventData(2, x, y, 0f)) }

                    isScrolling = true
                    lastScrollMidX = (event.getX(0) + event.getX(1)) / 2f
                    lastScrollMidY = (event.getY(0) + event.getY(1)) / 2f
                    sendHandler.post { sendScroll(ScrollEventData(0, 0f, 0f)) }
                }
            }

            MotionEvent.ACTION_MOVE -> {
                when {
                    // S Pen button + touch drag = scroll
                    isSpenScrolling -> {
                        val dx = (event.x - spenLastX) / viewWidth
                        val dy = (event.y - spenLastY) / viewHeight
                        spenLastX = event.x
                        spenLastY = event.y
                        if (dx != 0f || dy != 0f) {
                            sendHandler.post { sendScroll(ScrollEventData(1, dx, dy)) }
                        }
                    }

                    // Four-finger swipe: app switching
                    isFourFingerGesture && event.pointerCount >= 4 && !fourFingerSwipeFired -> {
                        val currentMidX = averageX(event, 4)
                        val deltaX = currentMidX - fourFingerStartX
                        if (abs(deltaX) > FOUR_FINGER_SWIPE_THRESHOLD) {
                            fourFingerSwipeFired = true
                            if (deltaX > 0) {
                                // Swipe right -> Cmd+Shift+Tab (previous app)
                                Log.i(TAG, "Four-finger swipe right: Cmd+Shift+Tab")
                                sendKeyPress(MAC_VK_TAB, MODIFIER_SHIFT_COMMAND)
                            } else {
                                // Swipe left -> Cmd+Tab (next app)
                                Log.i(TAG, "Four-finger swipe left: Cmd+Tab")
                                sendKeyPress(MAC_VK_TAB, MODIFIER_COMMAND)
                            }
                            view.post { view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) }
                        }
                    }

                    // Three-finger swipe: directional gestures
                    isThreeFingerGesture && event.pointerCount >= 3 && !threeFingerSwipeFired -> {
                        val currentMidX = averageX(event, 3)
                        val currentMidY = averageY(event, 3)
                        val deltaX = currentMidX - threeFingerStartX
                        val deltaY = currentMidY - threeFingerStartY

                        val absX = abs(deltaX)
                        val absY = abs(deltaY)

                        if (absX > THREE_FINGER_SWIPE_THRESHOLD && absX > absY) {
                            // Horizontal swipe: switch Spaces
                            threeFingerSwipeFired = true
                            val keyCode = if (deltaX > 0) MAC_VK_LEFT_ARROW else MAC_VK_RIGHT_ARROW
                            Log.i(TAG, "Three-finger horizontal swipe: Ctrl+Arrow keyCode=$keyCode")
                            sendKeyPress(keyCode, MODIFIER_CONTROL)
                            view.post { view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) }
                        } else if (absY > THREE_FINGER_SWIPE_THRESHOLD && absY > absX) {
                            // Vertical swipe
                            threeFingerSwipeFired = true
                            if (deltaY > 0) {
                                // Swipe down: Mission Control (Ctrl+Up Arrow)
                                Log.i(TAG, "Three-finger swipe down: Mission Control")
                                sendKeyPress(MAC_VK_UP_ARROW, MODIFIER_CONTROL)
                            } else {
                                // Swipe up: Show Desktop (F11)
                                Log.i(TAG, "Three-finger swipe up: Show Desktop")
                                sendKeyPress(MAC_VK_F11, 0)
                            }
                            view.post { view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) }
                        }
                    }

                    // Two-finger scroll
                    isScrolling && event.pointerCount >= 2 -> {
                        val midX = (event.getX(0) + event.getX(1)) / 2f
                        val midY = (event.getY(0) + event.getY(1)) / 2f
                        val dx = (midX - lastScrollMidX) / viewWidth
                        val dy = (midY - lastScrollMidY) / viewHeight
                        lastScrollMidX = midX
                        lastScrollMidY = midY
                        if (dx != 0f || dy != 0f) {
                            sendHandler.post { sendScroll(ScrollEventData(1, dx, dy)) }
                        }
                    }

                    // Single-finger move
                    !isScrolling && !isLongPressTriggered && !isThreeFingerGesture && !isFourFingerGesture -> {
                        val dx = event.x - downX
                        val dy = event.y - downY
                        if (dx * dx + dy * dy > LONG_PRESS_SLOP_SQ) {
                            cancelLongPress()
                        }

                        val x = event.x / viewWidth
                        val y = event.y / viewHeight
                        val pressure = event.pressure.coerceIn(0f, 1f)
                        sendHandler.post { sendEvent(TouchEventData(1, x, y, pressure)) }
                    }
                }
            }

            MotionEvent.ACTION_POINTER_UP -> {
                if (isFourFingerGesture && event.pointerCount <= 4) {
                    isFourFingerGesture = false
                    fourFingerSwipeFired = false
                } else if (isThreeFingerGesture && event.pointerCount <= 3) {
                    // Check for three-finger tap (no swipe fired, quick touch)
                    if (!threeFingerSwipeFired) {
                        val elapsed = System.currentTimeMillis() - threeFingerDownTime
                        if (elapsed < THREE_FINGER_TAP_TIMEOUT) {
                            Log.i(TAG, "Three-finger tap: App Exposé")
                            sendKeyPress(MAC_VK_DOWN_ARROW, MODIFIER_CONTROL)
                            touchView?.post { touchView?.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) }
                        }
                    }
                    isThreeFingerGesture = false
                    threeFingerSwipeFired = false
                } else if (isScrolling) {
                    sendHandler.post { sendScroll(ScrollEventData(2, 0f, 0f)) }
                    isScrolling = false
                }
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                cancelLongPress()

                if (isSpenScrolling) {
                    isSpenScrolling = false
                    sendHandler.post { sendScroll(ScrollEventData(2, 0f, 0f)) }
                } else if (isFourFingerGesture) {
                    isFourFingerGesture = false
                    fourFingerSwipeFired = false
                } else if (isThreeFingerGesture) {
                    if (!threeFingerSwipeFired) {
                        val elapsed = System.currentTimeMillis() - threeFingerDownTime
                        if (elapsed < THREE_FINGER_TAP_TIMEOUT) {
                            Log.i(TAG, "Three-finger tap: App Exposé")
                            sendKeyPress(MAC_VK_DOWN_ARROW, MODIFIER_CONTROL)
                            view.post { view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) }
                        }
                    }
                    isThreeFingerGesture = false
                    threeFingerSwipeFired = false
                } else if (isScrolling) {
                    sendHandler.post { sendScroll(ScrollEventData(2, 0f, 0f)) }
                    isScrolling = false
                } else if (!isLongPressTriggered) {
                    val x = event.x / viewWidth
                    val y = event.y / viewHeight
                    sendHandler.post { sendEvent(TouchEventData(2, x, y, 0f)) }
                }
                isLongPressTriggered = false
            }

            else -> return false
        }
        return true
    }

    override fun onHover(view: View, event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_HOVER_MOVE) {
            val x = event.x / view.width.toFloat()
            val y = event.y / view.height.toFloat()
            sendHandler.post { sendEvent(TouchEventData(1, x, y, 0f)) }
            return true
        }
        return false
    }

    private fun sendKeyPress(keyCode: Int, modifiers: Int) {
        sendHandler.post { sendKeyboard(KeyboardEventData(0, keyCode, modifiers)) }
        sendHandler.postDelayed({ sendKeyboard(KeyboardEventData(1, keyCode, modifiers)) }, 50)
    }

    private fun averageX(event: MotionEvent, count: Int): Float {
        var sum = 0f
        for (i in 0 until count.coerceAtMost(event.pointerCount)) {
            sum += event.getX(i)
        }
        return sum / count
    }

    private fun averageY(event: MotionEvent, count: Int): Float {
        var sum = 0f
        for (i in 0 until count.coerceAtMost(event.pointerCount)) {
            sum += event.getY(i)
        }
        return sum / count
    }

    private fun cancelLongPress() {
        longPressRunnable?.let { sendHandler.removeCallbacks(it) }
        longPressRunnable = null
    }

    fun shutdown() {
        cancelLongPress()
        sendThread.quitSafely()
    }
}
