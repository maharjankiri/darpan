import Foundation
import Network

protocol TCPServerDelegate: AnyObject {
    func serverDidAcceptConnection(_ server: TCPServer)
    func server(_ server: TCPServer, didReceiveHandshake request: HandshakeRequest)
    func server(_ server: TCPServer, didReceiveTouchEvent event: TouchEvent)
    func server(_ server: TCPServer, didReceiveScrollEvent event: ScrollEvent)
    func server(_ server: TCPServer, didReceiveKeyboardEvent event: KeyboardEvent)
    func serverDidDisconnect(_ server: TCPServer)
}

final class TCPServer {
    weak var delegate: TCPServerDelegate?

    private var listener: NWListener?
    private var connection: NWConnection?
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.secondscreen.tcp", qos: .userInteractive)
    private var receiveBuffer = Data()
    private(set) var isConnected = false

    // Video send backpressure: when the link can't keep up, drop frames
    // instead of queueing them (queued frames = accumulating latency).
    private let sendStateLock = NSLock()
    private var pendingVideoBytes = 0
    private var droppingUntilKeyframe = false
    private var droppedFrameCount = 0
    private let maxPendingVideoBytes = 400_000 // ~2-4 frames at 45Mbps

    init(port: UInt16 = 12345) {
        self.port = port
    }

    func start() throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[TCP] Server listening on port \(self?.port ?? 0)")
            case .failed(let error):
                print("[TCP] Server failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
    }

    /// Returns false if the frame was dropped due to send backlog — the
    /// caller should force a keyframe so the decoder can recover.
    @discardableResult
    func sendVideoFrame(nalData: Data, isKeyframe: Bool, timestamp: UInt64) -> Bool {
        guard isConnected, let connection = connection else { return true }

        sendStateLock.lock()
        // After dropping a frame the H.264 reference chain is broken, so keep
        // dropping until the next keyframe arrives.
        if !isKeyframe && (droppingUntilKeyframe || pendingVideoBytes > maxPendingVideoBytes) {
            droppingUntilKeyframe = true
            droppedFrameCount += 1
            let dropped = droppedFrameCount
            let backlog = pendingVideoBytes
            sendStateLock.unlock()
            if dropped % 30 == 1 {
                print("[TCP] Send backlog \(backlog)B — dropped \(dropped) frames total")
            }
            return false
        }
        if isKeyframe {
            droppingUntilKeyframe = false
        }
        let messageSize: Int
        let header = VideoFrameHeader(timestamp: timestamp, flags: isKeyframe ? 1 : 0)
        var payload = header.serialize()
        payload.append(nalData)
        let message = frameMessage(type: .videoFrame, payload: payload)
        messageSize = message.count
        pendingVideoBytes += messageSize
        sendStateLock.unlock()

        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            if let self = self {
                self.sendStateLock.lock()
                self.pendingVideoBytes = max(0, self.pendingVideoBytes - messageSize)
                self.sendStateLock.unlock()
            }
            if let error = error {
                print("[TCP] Send error: \(error)")
            }
        })
        return true
    }

    func sendHandshakeResponse(_ response: HandshakeResponse) {
        guard let connection = connection else { return }

        let message = frameMessage(type: .handshakeResponse, payload: response.serialize())
        connection.send(content: message, completion: .contentProcessed { error in
            if let error = error {
                print("[TCP] Failed to send handshake response: \(error)")
            }
        })
    }

    func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        isConnected = false
        print("[TCP] Server stopped")
    }

    // MARK: - Private

    private func handleNewConnection(_ connection: NWConnection) {
        // Only allow one connection
        self.connection?.cancel()
        self.connection = connection
        receiveBuffer = Data()

        sendStateLock.lock()
        pendingVideoBytes = 0
        droppingUntilKeyframe = false
        droppedFrameCount = 0
        sendStateLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[TCP] Client connected")
                self.isConnected = true
                self.delegate?.serverDidAcceptConnection(self)
                self.startReceiving()
            case .failed(let error):
                print("[TCP] Connection failed: \(error)")
                self.isConnected = false
                self.delegate?.serverDidDisconnect(self)
            case .cancelled:
                self.isConnected = false
                self.delegate?.serverDidDisconnect(self)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content {
                self.receiveBuffer.append(data)
                self.processReceiveBuffer()
            }

            if isComplete {
                print("[TCP] Connection closed by client")
                self.isConnected = false
                self.delegate?.serverDidDisconnect(self)
                return
            }

            if let error = error {
                print("[TCP] Receive error: \(error)")
                return
            }

            // Continue receiving
            self.startReceiving()
        }
    }

    private func processReceiveBuffer() {
        while receiveBuffer.count >= headerSize {
            // Check magic
            guard receiveBuffer[0] == protocolMagic[0],
                  receiveBuffer[1] == protocolMagic[1],
                  receiveBuffer[2] == protocolMagic[2],
                  receiveBuffer[3] == protocolMagic[3] else {
                print("[TCP] Invalid magic, resetting buffer")
                receiveBuffer.removeAll()
                return
            }

            let type = receiveBuffer[4]
            let payloadLength = Int(receiveBuffer.readBigEndianUInt32(at: 5))

            guard receiveBuffer.count >= headerSize + payloadLength else {
                return // Wait for more data
            }

            let payload = receiveBuffer.subdata(in: headerSize..<headerSize + payloadLength)
            receiveBuffer.removeSubrange(0..<headerSize + payloadLength)

            switch MessageType(rawValue: type) {
            case .handshakeRequest:
                if let request = HandshakeRequest.deserialize(from: payload) {
                    print("[TCP] Received handshake: \(request.width)x\(request.height) @\(request.refreshRate)Hz, DPI=\(request.dpi)")
                    delegate?.server(self, didReceiveHandshake: request)
                }
            case .touchEvent:
                if let event = TouchEvent.deserialize(from: payload) {
                    delegate?.server(self, didReceiveTouchEvent: event)
                }
            case .scrollEvent:
                if let event = ScrollEvent.deserialize(from: payload) {
                    delegate?.server(self, didReceiveScrollEvent: event)
                }
            case .keyboardEvent:
                if let event = KeyboardEvent.deserialize(from: payload) {
                    delegate?.server(self, didReceiveKeyboardEvent: event)
                }
            default:
                print("[TCP] Unknown message type: \(type)")
            }
        }
    }
}
