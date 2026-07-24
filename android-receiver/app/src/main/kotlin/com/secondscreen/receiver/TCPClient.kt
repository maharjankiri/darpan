package com.secondscreen.receiver

import android.util.Log
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.IOException
import java.net.Socket
import java.nio.ByteBuffer

interface TCPClientListener {
    fun onConnected()
    fun onHandshakeResponse(response: HandshakeResponse)
    fun onVideoFrame(nalData: ByteArray, isKeyframe: Boolean, timestamp: Long)
    fun onDisconnected()
}

class TCPClient(
    private val host: String = "127.0.0.1",
    private val port: Int = 12345,
    private val listener: TCPClientListener
) {
    companion object {
        private const val TAG = "TCPClient"
    }

    private var socket: Socket? = null
    private var inputStream: BufferedInputStream? = null
    private var outputStream: BufferedOutputStream? = null
    @Volatile
    private var running = false

    fun connect() {
        running = true
        Thread({
            try {
                Log.i(TAG, "Connecting to $host:$port...")
                val sock = Socket(host, port)
                sock.tcpNoDelay = true
                sock.soTimeout = 0 // No read timeout
                socket = sock
                inputStream = BufferedInputStream(sock.getInputStream(), 256 * 1024)
                outputStream = BufferedOutputStream(sock.getOutputStream(), 64 * 1024)

                Log.i(TAG, "Connected")
                listener.onConnected()

                receiveLoop()
            } catch (e: IOException) {
                Log.e(TAG, "Connection failed: ${e.message}")
            } finally {
                running = false
                listener.onDisconnected()
            }
        }, "TCPClient-recv").start()
    }

    fun sendHandshake(request: HandshakeRequest) {
        val payload = request.serialize()
        val message = frameMessage(Protocol.TYPE_HANDSHAKE_REQ, payload)
        sendRaw(message)
    }

    fun sendTouchEvent(event: TouchEventData) {
        if (!running) return
        val payload = event.serialize()
        val message = frameMessage(Protocol.TYPE_TOUCH_EVENT, payload)
        sendRaw(message)
    }

    fun sendScrollEvent(event: ScrollEventData) {
        if (!running) return
        val payload = event.serialize()
        val message = frameMessage(Protocol.TYPE_SCROLL_EVENT, payload)
        sendRaw(message)
    }

    fun sendKeyboardEvent(event: KeyboardEventData) {
        if (!running) return
        val payload = event.serialize()
        val message = frameMessage(Protocol.TYPE_KEYBOARD_EVENT, payload)
        sendRaw(message)
    }

    fun disconnect() {
        running = false
        try {
            socket?.close()
        } catch (_: IOException) {}
    }

    private fun sendRaw(data: ByteArray) {
        try {
            val out = outputStream ?: return
            synchronized(out) {
                out.write(data)
                out.flush()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Send error: ${e.message}")
        }
    }

    private fun receiveLoop() {
        val input = inputStream ?: return
        val headerBuf = ByteArray(Protocol.HEADER_SIZE)

        while (running) {
            try {
                // Read header
                readFully(input, headerBuf, 0, Protocol.HEADER_SIZE)

                // Verify magic
                if (headerBuf[0] != Protocol.MAGIC[0] ||
                    headerBuf[1] != Protocol.MAGIC[1] ||
                    headerBuf[2] != Protocol.MAGIC[2] ||
                    headerBuf[3] != Protocol.MAGIC[3]
                ) {
                    Log.e(TAG, "Invalid magic, skipping")
                    continue
                }

                val type = headerBuf[4]
                val payloadLen = ByteBuffer.wrap(headerBuf, 5, 4).int

                // Read payload
                val payload = ByteArray(payloadLen)
                readFully(input, payload, 0, payloadLen)

                // Dispatch
                when (type) {
                    Protocol.TYPE_HANDSHAKE_RESP -> {
                        val resp = HandshakeResponse.deserialize(payload)
                        if (resp != null) {
                            Log.i(TAG, "Received handshake response, status=${resp.status}")
                            listener.onHandshakeResponse(resp)
                        }
                    }
                    Protocol.TYPE_VIDEO_FRAME -> {
                        if (payload.size > VideoFrameHeader.SIZE) {
                            val header = VideoFrameHeader.deserialize(payload)
                            val nalData = payload.copyOfRange(VideoFrameHeader.SIZE, payload.size)
                            listener.onVideoFrame(nalData, header.isKeyframe, header.timestamp)
                        }
                    }
                    else -> Log.w(TAG, "Unknown message type: $type")
                }
            } catch (e: IOException) {
                if (running) {
                    Log.e(TAG, "Receive error: ${e.message}")
                }
                break
            }
        }
    }

    private fun readFully(input: BufferedInputStream, buf: ByteArray, off: Int, len: Int) {
        var offset = off
        var remaining = len
        while (remaining > 0) {
            val read = input.read(buf, offset, remaining)
            if (read < 0) throw IOException("End of stream")
            offset += read
            remaining -= read
        }
    }
}
