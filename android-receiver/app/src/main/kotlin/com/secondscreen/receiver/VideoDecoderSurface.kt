package com.secondscreen.receiver

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

class VideoDecoderSurface(
    private val surface: Surface,
    private val width: Int,
    private val height: Int
) {
    companion object {
        private const val TAG = "VideoDecoder"
        private const val MIME_TYPE = "video/avc"
        private const val INPUT_WAIT_MS = 100L
    }

    private var codec: MediaCodec? = null
    private var isConfigured = false
    private val inputIndices = ArrayBlockingQueue<Int>(32)
    private var callbackThread: HandlerThread? = null

    fun configure(sps: ByteArray, pps: ByteArray) {
        try {
            val format = MediaFormat.createVideoFormat(MIME_TYPE, width, height)

            // Set codec-specific data (SPS with start code prefix)
            val startCode = byteArrayOf(0x00, 0x00, 0x00, 0x01)
            val csd0 = ByteArray(startCode.size + sps.size)
            System.arraycopy(startCode, 0, csd0, 0, startCode.size)
            System.arraycopy(sps, 0, csd0, startCode.size, sps.size)

            val csd1 = ByteArray(startCode.size + pps.size)
            System.arraycopy(startCode, 0, csd1, 0, startCode.size)
            System.arraycopy(pps, 0, csd1, startCode.size, pps.size)

            format.setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(csd0))
            format.setByteBuffer("csd-1", java.nio.ByteBuffer.wrap(csd1))

            // Low latency mode (Android 11+)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            // Vendor low-latency flags — ignored by codecs that don't know them
            format.setInteger("vendor.rtc-ext-dec-low-latency.enable", 1) // Qualcomm
            format.setInteger("vendor.low-latency.enable", 1)             // Exynos

            val decoder = MediaCodec.createDecoderByType(MIME_TYPE)

            // Async mode: output buffers render the moment decoding finishes,
            // instead of waiting for the next network frame to drain them.
            val thread = HandlerThread("VideoDecoderCallback").apply { start() }
            callbackThread = thread
            decoder.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                    inputIndices.offer(index)
                }

                override fun onOutputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                    info: MediaCodec.BufferInfo
                ) {
                    try {
                        // Release to surface for rendering (true = render)
                        codec.releaseOutputBuffer(index, true)
                    } catch (e: IllegalStateException) {
                        Log.e(TAG, "releaseOutputBuffer error: ${e.message}")
                    }
                }

                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                    Log.i(TAG, "Output format changed: $format")
                }

                override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                    Log.e(TAG, "Codec error: ${e.message}")
                }
            }, Handler(thread.looper))

            decoder.configure(format, surface, null, 0)
            decoder.start()

            codec = decoder
            isConfigured = true
            Log.i(TAG, "Decoder configured (async): ${width}x${height}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to configure decoder: ${e.message}")
        }
    }

    fun decodeFrame(nalData: ByteArray, timestamp: Long) {
        val decoder = codec ?: return
        if (!isConfigured) return

        try {
            // Wait briefly for a free input buffer instead of dropping the NAL —
            // blocking the TCP receive thread applies backpressure to the sender.
            val inputIndex = inputIndices.poll(INPUT_WAIT_MS, TimeUnit.MILLISECONDS)
            if (inputIndex == null) {
                Log.w(TAG, "No input buffer available, dropping frame")
                return
            }
            val inputBuffer = decoder.getInputBuffer(inputIndex) ?: return
            inputBuffer.clear()
            inputBuffer.put(nalData)
            decoder.queueInputBuffer(inputIndex, 0, nalData.size, timestamp, 0)
        } catch (e: Exception) {
            Log.e(TAG, "Decode error: ${e.message}")
        }
    }

    fun release() {
        try {
            isConfigured = false
            codec?.stop()
            codec?.release()
            codec = null
            inputIndices.clear()
            callbackThread?.quitSafely()
            callbackThread = null
            Log.i(TAG, "Decoder released")
        } catch (e: Exception) {
            Log.e(TAG, "Release error: ${e.message}")
        }
    }
}
