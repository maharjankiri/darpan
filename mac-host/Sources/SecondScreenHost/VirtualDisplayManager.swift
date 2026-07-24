import CoreGraphics
import CGVirtualDisplayBridge

final class VirtualDisplayManager {
    private var handle: VirtualDisplayHandle?
    private(set) var displayID: CGDirectDisplayID = 0

    func create(width: Int, height: Int, refreshRate: Double = 60.0, hiDPI: Bool = false) -> Bool {
        guard handle == nil else {
            print("[VirtualDisplay] Already created (displayID=\(displayID))")
            return true
        }

        let result = CreateVirtualDisplay(
            UInt(width),
            UInt(height),
            refreshRate,
            "SecondScreen",
            hiDPI
        )

        if result.displayID == 0 {
            print("[VirtualDisplay] Failed to create virtual display")
            return false
        }

        handle = result
        displayID = result.displayID
        print("[VirtualDisplay] Created: \(width)x\(height)@\(Int(refreshRate))Hz, displayID=\(displayID)")
        return true
    }

    func destroy() {
        guard let h = handle else { return }
        DestroyVirtualDisplay(h)
        print("[VirtualDisplay] Destroyed displayID=\(displayID)")
        handle = nil
        displayID = 0
    }

    deinit {
        destroy()
    }
}
