package com.secondscreen.receiver

import java.io.DataInputStream
import java.io.DataOutputStream
import java.nio.ByteBuffer

// Binary protocol matching the Mac host.
// Wire format: [4B magic "SS2S"][1B type][4B length (big-endian)][payload]

object Protocol {
    val MAGIC = byteArrayOf(0x53, 0x53, 0x32, 0x53) // "SS2S"
    const val HEADER_SIZE = 9 // 4 magic + 1 type + 4 length

    const val TYPE_HANDSHAKE_REQ: Byte = 0x01
    const val TYPE_HANDSHAKE_RESP: Byte = 0x02
    const val TYPE_VIDEO_FRAME: Byte = 0x03
    const val TYPE_TOUCH_EVENT: Byte = 0x04
    const val TYPE_SCROLL_EVENT: Byte = 0x05
    const val TYPE_KEYBOARD_EVENT: Byte = 0x06
}

data class HandshakeRequest(
    val width: Int,
    val height: Int,
    val dpi: Int,
    val refreshRate: Int
) {
    fun serialize(): ByteArray {
        val buf = ByteBuffer.allocate(16)
        buf.putInt(width)
        buf.putInt(height)
        buf.putInt(dpi)
        buf.putInt(refreshRate)
        return buf.array()
    }
}

data class HandshakeResponse(
    val status: Int,
    val sps: ByteArray,
    val pps: ByteArray
) {
    companion object {
        fun deserialize(data: ByteArray): HandshakeResponse? {
            if (data.isEmpty()) return null
            val buf = ByteBuffer.wrap(data)
            val status = buf.get().toInt() and 0xFF

            if (buf.remaining() < 4) return null
            val spsLen = buf.int
            if (buf.remaining() < spsLen) return null
            val sps = ByteArray(spsLen)
            buf.get(sps)

            if (buf.remaining() < 4) return null
            val ppsLen = buf.int
            if (buf.remaining() < ppsLen) return null
            val pps = ByteArray(ppsLen)
            buf.get(pps)

            return HandshakeResponse(status, sps, pps)
        }
    }
}

data class VideoFrameHeader(
    val timestamp: Long,  // microseconds
    val flags: Int
) {
    val isKeyframe: Boolean get() = flags and 1 != 0

    companion object {
        const val SIZE = 12 // 8 timestamp + 4 flags

        fun deserialize(data: ByteArray, offset: Int = 0): VideoFrameHeader {
            val buf = ByteBuffer.wrap(data, offset, SIZE)
            return VideoFrameHeader(
                timestamp = buf.long,
                flags = buf.int
            )
        }
    }
}

data class TouchEventData(
    val action: Int,      // 0=down, 1=move, 2=up, 3=rightDown, 4=rightUp
    val x: Float,         // 0.0–1.0
    val y: Float,         // 0.0–1.0
    val pressure: Float   // 0.0–1.0
) {
    fun serialize(): ByteArray {
        val buf = ByteBuffer.allocate(13)
        buf.put(action.toByte())
        buf.putFloat(x)
        buf.putFloat(y)
        buf.putFloat(pressure)
        return buf.array()
    }
}

data class ScrollEventData(
    val phase: Int,       // 0=began, 1=changed, 2=ended
    val deltaX: Float,    // normalized delta
    val deltaY: Float     // normalized delta
) {
    fun serialize(): ByteArray {
        val buf = ByteBuffer.allocate(9)
        buf.put(phase.toByte())
        buf.putFloat(deltaX)
        buf.putFloat(deltaY)
        return buf.array()
    }
}

data class KeyboardEventData(
    val action: Int,       // 0=keyDown, 1=keyUp
    val macKeyCode: Int,   // macOS virtual key code
    val modifiers: Int     // bitmask: bit0=shift, bit1=ctrl, bit2=alt, bit3=cmd
) {
    fun serialize(): ByteArray {
        val buf = ByteBuffer.allocate(4)
        buf.put(action.toByte())
        buf.put(macKeyCode.toByte())
        buf.putShort(modifiers.toShort())
        return buf.array()
    }
}

fun frameMessage(type: Byte, payload: ByteArray): ByteArray {
    val message = ByteArray(Protocol.HEADER_SIZE + payload.size)
    System.arraycopy(Protocol.MAGIC, 0, message, 0, 4)
    message[4] = type
    val lenBuf = ByteBuffer.allocate(4).putInt(payload.size).array()
    System.arraycopy(lenBuf, 0, message, 5, 4)
    System.arraycopy(payload, 0, message, Protocol.HEADER_SIZE, payload.size)
    return message
}
