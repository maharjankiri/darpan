import Foundation
import CoreGraphics
import CoreMedia

// MARK: - Logger

/// Dual-output logger: writes to stdout and optionally to a log file.
/// Rotates the log file when it exceeds 10 MB.
enum Log {
    private static let maxLogSize: UInt64 = 10 * 1024 * 1024 // 10 MB
    private static var fileHandle: FileHandle?
    private static let queue = DispatchQueue(label: "com.secondscreen.log")

    static func setup() {
        // stdout is redirected to a file by launchd — line-buffer it so
        // print() output appears immediately instead of in 4KB chunks
        setvbuf(stdout, nil, _IOLBF, 0)

        let logDir = NSHomeDirectory() + "/Library/Logs/SecondScreen"
        let logPath = logDir + "/host.log"

        // Create log directory if needed
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        // Rotate if too large
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? UInt64, size > maxLogSize {
            try? FileManager.default.removeItem(atPath: logPath)
        }

        // Open (or create) log file for appending
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: logPath)
        fileHandle?.seekToEndOfFile()
    }

    static func info(_ message: String) { write("[Info] \(message)") }
    static func ok(_ message: String) { write("[OK] \(message)") }
    static func warn(_ message: String) { write("[Warning] \(message)") }
    static func error(_ message: String) { write("[Error] \(message)") }

    private static func write(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        // Always write to stdout
        print(message)
        // Write to file if available
        queue.async {
            if let data = line.data(using: .utf8) {
                fileHandle?.write(data)
            }
        }
    }
}

// MARK: - App Orchestrator

final class SecondScreenHost: NSObject, TCPServerDelegate, ScreenCaptureDelegate, VideoEncoderDelegate {
    private let server = TCPServer(port: ADBHelper.port)
    private var displayManager = VirtualDisplayManager()
    private var capture: ScreenCapture?
    private var encoder: VideoEncoder?
    private var inputInjector: InputInjector?
    private var adbPath: String?

    private var spsData: Data?
    private var ppsData: Data?
    private var pendingHandshake: HandshakeRequest?
    private var pipelineRunning = false

    private var devicePoller: DispatchSourceTimer?
    private var deviceConnected = false

    func run() {
        Log.info("=== SecondScreen Host (background service) ===")

        // 1. Find ADB
        guard let adb = ADBHelper.findADB() else {
            Log.error("adb not found. Install Android SDK platform-tools.")
            exit(1)
        }
        adbPath = adb
        Log.ok("Found adb: \(adb)")

        // 2. Start TCP server immediately (always listening)
        server.delegate = self
        do {
            try server.start()
        } catch {
            Log.error("Failed to start TCP server: \(error)")
            exit(1)
        }
        Log.ok("TCP server listening on port \(ADBHelper.port)")

        // 3. Start device polling
        Log.info("Polling for Android device every 3 seconds...")
        devicePoller = ADBHelper.pollForDevice(adbPath: adb,
            onConnected: { [weak self] in
                self?.handleDeviceConnected()
            },
            onDisconnected: { [weak self] in
                self?.handleDeviceDisconnected()
            }
        )

        // 4. Handle SIGINT and SIGTERM for clean shutdown
        let shutdownHandler: @convention(c) (Int32) -> Void = { sig in
            Log.info("Caught signal \(sig), shutting down...")
            DispatchQueue.main.async {
                exit(0)
            }
        }
        signal(SIGINT, shutdownHandler)
        signal(SIGTERM, shutdownHandler)

        // Keep running
        RunLoop.main.run()
    }

    // MARK: - Device State Changes

    private func handleDeviceConnected() {
        guard let adb = adbPath else { return }
        deviceConnected = true
        Log.ok("Android device connected")

        // Setup ADB reverse port forwarding
        if ADBHelper.setupReverseForward(adbPath: adb) {
            Log.ok("ADB reverse forward configured")
        } else {
            Log.error("Failed to setup ADB reverse forwarding")
        }

        Log.info("Waiting for Android app to connect...")
    }

    private func handleDeviceDisconnected() {
        deviceConnected = false
        Log.info("Android device disconnected")

        // Tear down pipeline if running
        if pipelineRunning {
            stopPipeline()
        }

        // Remove reverse forward
        if let adb = adbPath {
            ADBHelper.removeReverseForward(adbPath: adb)
        }

        Log.info("Resumed polling for device...")
    }

    func cleanup() {
        devicePoller?.cancel()
        devicePoller = nil
        if pipelineRunning {
            stopPipeline()
        }
        server.stop()
        if let adb = adbPath {
            ADBHelper.removeReverseForward(adbPath: adb)
        }
    }

    // MARK: - Pipeline Setup

    private func startPipeline(request: HandshakeRequest) {
        let width = Int(request.width)
        let height = Int(request.height)
        let fps = Int(request.refreshRate)

        // Create virtual display at half logical resolution with HiDPI (Retina 2x).
        let logicalWidth = width / 2
        let logicalHeight = height / 2

        guard displayManager.create(width: logicalWidth, height: logicalHeight, refreshRate: Double(fps), hiDPI: true) else {
            Log.error("Failed to create virtual display")
            return
        }

        // Setup input injector
        inputInjector = InputInjector(displayID: displayManager.displayID)
        if !inputInjector!.checkAccessibility() {
            Log.warn("Accessibility not granted — touch input will not work")
        }

        // Start encoder
        encoder = VideoEncoder(width: width, height: height, frameRate: fps, bitrateMbps: 45)
        encoder?.delegate = self
        do {
            try encoder?.start()
        } catch {
            Log.error("Failed to start encoder: \(error)")
            return
        }

        // Start screen capture (need to wait a moment for display to register)
        Task {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            capture = ScreenCapture(
                displayID: displayManager.displayID,
                width: width,
                height: height,
                frameRate: fps
            )
            capture?.delegate = self

            do {
                try await capture?.start()
                pipelineRunning = true
                Log.ok("Pipeline running: capture → encode → stream")
            } catch {
                Log.error("Failed to start screen capture: \(error)")
                Log.error("Grant screen recording permission in: System Settings → Privacy & Security → Screen Recording")
            }
        }
    }

    private func stopPipeline() {
        Task {
            await capture?.stop()
        }
        capture = nil
        encoder?.stop()
        encoder = nil
        inputInjector = nil
        displayManager.destroy()
        spsData = nil
        ppsData = nil
        pipelineRunning = false
        Log.info("Pipeline stopped")
    }

    // MARK: - TCPServerDelegate

    func serverDidAcceptConnection(_ server: TCPServer) {
        Log.info("Android client connected, waiting for handshake...")
    }

    func server(_ server: TCPServer, didReceiveHandshake request: HandshakeRequest) {
        Log.info("Handshake received: \(request.width)x\(request.height) @\(request.refreshRate)Hz")
        pendingHandshake = request
        startPipeline(request: request)
    }

    func server(_ server: TCPServer, didReceiveTouchEvent event: TouchEvent) {
        inputInjector?.handleTouchEvent(event)
    }

    func server(_ server: TCPServer, didReceiveScrollEvent event: ScrollEvent) {
        inputInjector?.handleScrollEvent(event)
    }

    func server(_ server: TCPServer, didReceiveKeyboardEvent event: KeyboardEvent) {
        inputInjector?.handleKeyboardEvent(event)
    }

    func serverDidDisconnect(_ server: TCPServer) {
        Log.info("Android client disconnected")
        if pipelineRunning {
            stopPipeline()
        }
    }

    // MARK: - ScreenCaptureDelegate

    func screenCapture(_ capture: ScreenCapture, didOutputSampleBuffer sampleBuffer: CMSampleBuffer) {
        encoder?.encode(sampleBuffer: sampleBuffer)
    }

    // MARK: - VideoEncoderDelegate

    func videoEncoder(_ encoder: VideoEncoder, didEncodeNALUnits nalData: Data, isKeyframe: Bool, timestamp: UInt64) {
        let sent = server.sendVideoFrame(nalData: nalData, isKeyframe: isKeyframe, timestamp: timestamp)
        if !sent {
            // Frame dropped under backlog — force a keyframe so the decoder recovers
            encoder.forceKeyframe()
        }
    }

    func videoEncoder(_ encoder: VideoEncoder, didExtractSPS sps: Data, pps: Data) {
        spsData = sps
        ppsData = pps

        let response = HandshakeResponse(status: 0, sps: sps, pps: pps)
        server.sendHandshakeResponse(response)
        Log.info("Sent handshake response with SPS/PPS to client")
    }
}

// MARK: - Entry Point

// Check for --dump-api flag to introspect private API
if CommandLine.arguments.contains("--dump-api") {
    dumpVirtualDisplayAPI()
    exit(0)
}

Log.setup()

let host = SecondScreenHost()

// Register cleanup on exit
atexit {
    host.cleanup()
}

host.run()
