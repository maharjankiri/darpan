import Foundation
import CoreGraphics
import ApplicationServices

final class InputInjector {
    private let displayID: CGDirectDisplayID
    private var displayBounds: CGRect = .zero
    private var isMouseDown = false

    private let scrollSpeedMultiplier: CGFloat = 8000.0

    // Key codes that need AppleScript for system-level actions
    private static let vkLeftArrow: UInt8 = 0x7B   // 123
    private static let vkRightArrow: UInt8 = 0x7C  // 124
    private static let vkUpArrow: UInt8 = 0x7E     // 126
    private static let vkDownArrow: UInt8 = 0x7D    // 125
    private static let vkF11: UInt8 = 0x67          // 103

    // Set of Ctrl+Arrow combos that trigger system Spaces/Mission Control
    private static let systemArrows: Set<UInt8> = [vkLeftArrow, vkRightArrow, vkUpArrow, vkDownArrow]

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        updateDisplayBounds()
    }

    func updateDisplayBounds() {
        displayBounds = CGDisplayBounds(displayID)
        print("[Input] Display bounds: \(displayBounds)")
    }

    func checkAccessibility() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("[Input] Accessibility permission required. Please grant in:")
            print("        System Settings → Privacy & Security → Accessibility")
            // Prompt the user
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        return trusted
    }

    func handleTouchEvent(_ event: TouchEvent) {
        // Map normalized coordinates to global display coordinates
        let globalX = displayBounds.origin.x + CGFloat(event.x) * displayBounds.width
        let globalY = displayBounds.origin.y + CGFloat(event.y) * displayBounds.height
        let point = CGPoint(x: globalX, y: globalY)

        switch event.action {
        case 0: // Left down
            isMouseDown = true
            postMouseEvent(.leftMouseDown, at: point)
        case 1: // Move
            if isMouseDown {
                postMouseEvent(.leftMouseDragged, at: point)
            } else {
                postMouseEvent(.mouseMoved, at: point)
            }
        case 2: // Left up
            isMouseDown = false
            postMouseEvent(.leftMouseUp, at: point)
        case 3: // Right down
            postMouseEvent(.rightMouseDown, at: point, button: .right)
        case 4: // Right up
            postMouseEvent(.rightMouseUp, at: point, button: .right)
        default:
            break
        }
    }

    func handleScrollEvent(_ event: ScrollEvent) {
        // Natural scrolling: finger moves down = content scrolls down (positive delta)
        let pixelDeltaY = Int32(CGFloat(event.deltaY) * scrollSpeedMultiplier)
        let pixelDeltaX = Int32(CGFloat(event.deltaX) * scrollSpeedMultiplier)

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: pixelDeltaY,
            wheel2: pixelDeltaX,
            wheel3: 0
        ) else { return }

        cgEvent.post(tap: .cghidEventTap)
    }

    func handleKeyboardEvent(_ event: KeyboardEvent) {
        let keyDown = event.action == 0
        print("[Input] Keyboard event: keyCode=\(event.macKeyCode) keyDown=\(keyDown) modifiers=0x\(String(event.modifiers, radix: 16))")

        // System-level shortcuts must use AppleScript because CGEvent
        // keyboard shortcuts don't trigger macOS system actions.

        // Ctrl+Arrow: Spaces switching, Mission Control, App Exposé
        if event.modifiers == 0x02 && Self.systemArrows.contains(event.macKeyCode) {
            if keyDown {
                runAppleScript(keyCode: Int(event.macKeyCode), modifiers: "control down")
            }
            return // Skip key-up too, AppleScript handles full press
        }

        // F11 with no modifier: Show Desktop
        if event.macKeyCode == Self.vkF11 && event.modifiers == 0 {
            if keyDown {
                runAppleScript(keyCode: Int(event.macKeyCode), modifiers: nil)
            }
            return
        }

        // All other keyboard events: use CGEvent
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(event.macKeyCode),
            keyDown: keyDown
        ) else {
            print("[Input] Failed to create keyboard CGEvent")
            return
        }

        var flags: CGEventFlags = []
        if event.modifiers & 0x01 != 0 { flags.insert(.maskShift) }
        if event.modifiers & 0x02 != 0 { flags.insert(.maskControl) }
        if event.modifiers & 0x04 != 0 { flags.insert(.maskAlternate) }
        if event.modifiers & 0x08 != 0 { flags.insert(.maskCommand) }
        cgEvent.flags = flags

        cgEvent.post(tap: .cghidEventTap)
    }

    private func runAppleScript(keyCode: Int, modifiers: String?) {
        let usingClause = modifiers != nil ? " using \(modifiers!)" : ""
        let script = """
        tell application "System Events"
            key code \(keyCode)\(usingClause)
        end tell
        """
        print("[Input] Running AppleScript: key code \(keyCode)\(usingClause)")
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = nil
            process.standardError = nil
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    print("[Input] AppleScript failed with status \(process.terminationStatus)")
                }
            } catch {
                print("[Input] AppleScript error: \(error)")
            }
        }
    }

    private func postMouseEvent(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }

        event.post(tap: .cghidEventTap)
    }
}
