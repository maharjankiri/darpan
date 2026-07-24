import Foundation

struct ADBHelper {
    static let port: UInt16 = 12345

    static func findADB() -> String? {
        // Check common locations
        let paths = [
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Try PATH via which
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["adb"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = output, !path.isEmpty {
                return path
            }
        }
        return nil
    }

    static func checkDevice(adbPath: String) -> Bool {
        let (status, output) = run(adbPath, arguments: ["devices"])
        guard status == 0 else { return false }
        // Parse "adb devices" output — look for lines with "device" (not "unauthorized")
        let lines = output.components(separatedBy: "\n")
        for line in lines.dropFirst() { // skip header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("device") && !trimmed.isEmpty {
                return true
            }
        }
        return false
    }

    static func setupReverseForward(adbPath: String) -> Bool {
        let (status, output) = run(adbPath, arguments: [
            "reverse", "tcp:\(port)", "tcp:\(port)"
        ])
        if status != 0 {
            print("[ADB] Failed to setup reverse forward: \(output)")
            return false
        }
        print("[ADB] Reverse forward: Android localhost:\(port) → Mac localhost:\(port)")
        return true
    }

    static func removeReverseForward(adbPath: String) {
        let _ = run(adbPath, arguments: ["reverse", "--remove", "tcp:\(port)"])
        print("[ADB] Removed reverse forward")
    }

    /// Polls `adb devices` on a timer. Fires callbacks only on state transitions.
    /// Returns the timer source — caller must keep a strong reference to keep polling alive.
    @discardableResult
    static func pollForDevice(adbPath: String,
                              interval: TimeInterval = 3.0,
                              onConnected: @escaping () -> Void,
                              onDisconnected: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: interval)

        var wasConnected = false

        timer.setEventHandler {
            let connected = checkDevice(adbPath: adbPath)
            if connected && !wasConnected {
                wasConnected = true
                onConnected()
            } else if !connected && wasConnected {
                wasConnected = false
                onDisconnected()
            }
        }

        timer.resume()
        return timer
    }

    private static func run(_ executable: String, arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
