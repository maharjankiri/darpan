import Foundation

// Binary protocol for communication between Mac host and Android receiver.
//
// Wire format: [4B magic "SS2S"][1B type][4B length (big-endian)][payload]
// All multi-byte integers are big-endian.

enum MessageType: UInt8 {
    case handshakeRequest  = 0x01  // Android → Mac
    case handshakeResponse = 0x02  // Mac → Android
    case videoFrame        = 0x03  // Mac → Android
    case touchEvent        = 0x04  // Android → Mac
    case scrollEvent       = 0x05  // Android → Mac
    case keyboardEvent     = 0x06  // Android → Mac
}

let protocolMagic: [UInt8] = [0x53, 0x53, 0x32, 0x53] // "SS2S"
let headerSize = 9 // 4 magic + 1 type + 4 length

// MARK: - Handshake

struct HandshakeRequest {
    let width: UInt32
    let height: UInt32
    let dpi: UInt32
    let refreshRate: UInt32

    func serialize() -> Data {
        var data = Data(capacity: 16)
        data.appendBigEndian(width)
        data.appendBigEndian(height)
        data.appendBigEndian(dpi)
        data.appendBigEndian(refreshRate)
        return data
    }

    static func deserialize(from data: Data) -> HandshakeRequest? {
        guard data.count >= 16 else { return nil }
        return HandshakeRequest(
            width: data.readBigEndianUInt32(at: 0),
            height: data.readBigEndianUInt32(at: 4),
            dpi: data.readBigEndianUInt32(at: 8),
            refreshRate: data.readBigEndianUInt32(at: 12)
        )
    }
}

struct HandshakeResponse {
    let status: UInt8  // 0 = OK, non-zero = error
    let sps: Data
    let pps: Data

    func serialize() -> Data {
        var data = Data()
        data.append(status)
        data.appendBigEndian(UInt32(sps.count))
        data.append(sps)
        data.appendBigEndian(UInt32(pps.count))
        data.append(pps)
        return data
    }

    static func deserialize(from data: Data) -> HandshakeResponse? {
        guard data.count >= 1 else { return nil }
        let status = data[0]
        var offset = 1

        guard data.count >= offset + 4 else { return nil }
        let spsLen = Int(data.readBigEndianUInt32(at: offset))
        offset += 4
        guard data.count >= offset + spsLen else { return nil }
        let sps = data.subdata(in: offset..<offset + spsLen)
        offset += spsLen

        guard data.count >= offset + 4 else { return nil }
        let ppsLen = Int(data.readBigEndianUInt32(at: offset))
        offset += 4
        guard data.count >= offset + ppsLen else { return nil }
        let pps = data.subdata(in: offset..<offset + ppsLen)

        return HandshakeResponse(status: status, sps: sps, pps: pps)
    }
}

// MARK: - Video Frame

struct VideoFrameHeader {
    let timestamp: UInt64    // microseconds
    let flags: UInt32        // bit 0 = keyframe
    // followed by H.264 NAL data (length is message length - 12)

    var isKeyframe: Bool { flags & 1 != 0 }

    func serialize() -> Data {
        var data = Data(capacity: 12)
        data.appendBigEndian(timestamp)
        data.appendBigEndian(flags)
        return data
    }
}

// MARK: - Touch Event

struct TouchEvent {
    let action: UInt8       // 0=down, 1=move, 2=up, 3=rightDown, 4=rightUp
    let x: Float            // 0.0–1.0 normalized
    let y: Float            // 0.0–1.0 normalized
    let pressure: Float     // 0.0–1.0

    func serialize() -> Data {
        var data = Data(capacity: 13)
        data.append(action)
        data.appendBigEndian(x.bitPattern)
        data.appendBigEndian(y.bitPattern)
        data.appendBigEndian(pressure.bitPattern)
        return data
    }

    static func deserialize(from data: Data) -> TouchEvent? {
        guard data.count >= 13 else { return nil }
        let action = data[0]
        let xBits = data.readBigEndianUInt32(at: 1)
        let yBits = data.readBigEndianUInt32(at: 5)
        let pBits = data.readBigEndianUInt32(at: 9)
        return TouchEvent(
            action: action,
            x: Float(bitPattern: xBits),
            y: Float(bitPattern: yBits),
            pressure: Float(bitPattern: pBits)
        )
    }
}

// MARK: - Scroll Event

struct ScrollEvent {
    let phase: UInt8      // 0=began, 1=changed, 2=ended
    let deltaX: Float     // normalized delta
    let deltaY: Float     // normalized delta

    static func deserialize(from data: Data) -> ScrollEvent? {
        guard data.count >= 9 else { return nil }
        let phase = data[0]
        let dxBits = data.readBigEndianUInt32(at: 1)
        let dyBits = data.readBigEndianUInt32(at: 5)
        return ScrollEvent(
            phase: phase,
            deltaX: Float(bitPattern: dxBits),
            deltaY: Float(bitPattern: dyBits)
        )
    }
}

// MARK: - Keyboard Event

struct KeyboardEvent {
    let action: UInt8     // 0=keyDown, 1=keyUp
    let macKeyCode: UInt8 // macOS virtual key code
    let modifiers: UInt16 // bitmask: bit0=shift, bit1=ctrl, bit2=alt, bit3=cmd

    static func deserialize(from data: Data) -> KeyboardEvent? {
        guard data.count >= 4 else { return nil }
        let action = data[0]
        let keyCode = data[1]
        let modifiers = UInt16(data[2]) << 8 | UInt16(data[3])
        return KeyboardEvent(action: action, macKeyCode: keyCode, modifiers: modifiers)
    }
}

// MARK: - Message Framing

func frameMessage(type: MessageType, payload: Data) -> Data {
    var message = Data(capacity: headerSize + payload.count)
    message.append(contentsOf: protocolMagic)
    message.append(type.rawValue)
    message.appendBigEndian(UInt32(payload.count))
    message.append(payload)
    return message
}

// MARK: - Data Helpers

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var big = value.bigEndian
        append(Data(bytes: &big, count: 4))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        var big = value.bigEndian
        append(Data(bytes: &big, count: 8))
    }

    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        let slice = self.subdata(in: offset..<offset + 4)
        return slice.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    func readBigEndianUInt64(at offset: Int) -> UInt64 {
        let slice = self.subdata(in: offset..<offset + 8)
        return slice.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
    }
}
