package com.secondscreen.receiver

import android.app.Activity
import android.os.Bundle
import android.util.DisplayMetrics
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.TextView

class MainActivity : Activity(), SurfaceHolder.Callback, TCPClientListener {
    companion object {
        private const val TAG = "SecondScreen"
    }

    private lateinit var surfaceView: SurfaceView
    private lateinit var statusText: TextView

    private var tcpClient: TCPClient? = null
    private var decoder: VideoDecoderSurface? = null
    private var touchHandler: TouchInputHandler? = null
    private var surfaceReady = false
    private var pendingResponse: HandshakeResponse? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Fullscreen immersive
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        )

        setContentView(R.layout.activity_main)

        surfaceView = findViewById(R.id.surfaceView)
        statusText = findViewById(R.id.statusText)

        surfaceView.holder.addCallback(this)

        // Setup touch handler
        touchHandler = TouchInputHandler(
            sendEvent = { event -> tcpClient?.sendTouchEvent(event) },
            sendScroll = { event -> tcpClient?.sendScrollEvent(event) },
            sendKeyboard = { event -> tcpClient?.sendKeyboardEvent(event) }
        )
        surfaceView.setOnTouchListener(touchHandler)
        surfaceView.setOnHoverListener(touchHandler)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        Log.i(TAG, "Surface created")
        surfaceReady = true
        startConnection()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        Log.i(TAG, "Surface changed: ${width}x${height}")
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        Log.i(TAG, "Surface destroyed")
        surfaceReady = false
        disconnect()
    }

    private fun startConnection() {
        updateStatus("Connecting...")

        tcpClient = TCPClient(listener = this)
        tcpClient?.connect()
    }

    private fun disconnect() {
        decoder?.release()
        decoder = null
        tcpClient?.disconnect()
        tcpClient = null
    }

    private fun updateStatus(text: String) {
        runOnUiThread {
            statusText.text = text
            statusText.visibility = View.VISIBLE
        }
    }

    private fun hideStatus() {
        runOnUiThread {
            statusText.visibility = View.GONE
        }
    }

    // MARK: - TCPClientListener

    override fun onConnected() {
        Log.i(TAG, "Connected to Mac host")
        updateStatus("Connected, sending handshake...")

        // Get display metrics
        val metrics = DisplayMetrics()
        windowManager.defaultDisplay.getRealMetrics(metrics)

        // 60fps, not the panel's 120Hz: 2960x1848@120 exceeds most tablet
        // H.264 decoders' throughput, so frames queue up and add latency.
        val request = HandshakeRequest(
            width = metrics.widthPixels,
            height = metrics.heightPixels,
            dpi = metrics.densityDpi,
            refreshRate = 60
        )

        Log.i(TAG, "Sending handshake: ${request.width}x${request.height} @${request.refreshRate}Hz, DPI=${request.dpi}")
        tcpClient?.sendHandshake(request)
    }

    override fun onHandshakeResponse(response: HandshakeResponse) {
        Log.i(TAG, "Handshake response: status=${response.status}, SPS=${response.sps.size}B, PPS=${response.pps.size}B")

        if (response.status != 0) {
            updateStatus("Handshake failed (status=${response.status})")
            return
        }

        if (!surfaceReady) {
            pendingResponse = response
            return
        }

        initDecoder(response)
    }

    private fun initDecoder(response: HandshakeResponse) {
        val metrics = DisplayMetrics()
        windowManager.defaultDisplay.getRealMetrics(metrics)

        decoder = VideoDecoderSurface(
            surface = surfaceView.holder.surface,
            width = metrics.widthPixels,
            height = metrics.heightPixels
        )
        decoder?.configure(response.sps, response.pps)

        hideStatus()
        Log.i(TAG, "Decoder initialized, ready to receive frames")
    }

    override fun onVideoFrame(nalData: ByteArray, isKeyframe: Boolean, timestamp: Long) {
        decoder?.decodeFrame(nalData, timestamp)
    }

    override fun onDisconnected() {
        Log.i(TAG, "Disconnected from Mac host")
        decoder?.release()
        decoder = null
        updateStatus("Disconnected. Reconnecting...")

        // Auto-reconnect after delay
        surfaceView.postDelayed({
            if (surfaceReady) {
                startConnection()
            }
        }, 2000)
    }

    override fun onDestroy() {
        super.onDestroy()
        touchHandler?.shutdown()
        disconnect()
    }
}
