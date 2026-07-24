import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

protocol ScreenCaptureDelegate: AnyObject {
    func screenCapture(_ capture: ScreenCapture, didOutputSampleBuffer sampleBuffer: CMSampleBuffer)
}

final class ScreenCapture: NSObject, SCStreamOutput {
    weak var delegate: ScreenCaptureDelegate?

    private var stream: SCStream?
    private let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let frameRate: Int

    init(displayID: CGDirectDisplayID, width: Int, height: Int, frameRate: Int = 60) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.frameRate = frameRate
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            // List available displays to help debug
            let ids = content.displays.map { $0.displayID }
            throw ScreenCaptureError.displayNotFound(
                "Display \(displayID) not found. Available: \(ids)"
            )
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // NV12
        config.queueDepth = 3
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()

        self.stream = stream
        print("[ScreenCapture] Started capturing display \(displayID) at \(width)x\(height)@\(frameRate)fps")
    }

    func stop() async {
        if let stream = stream {
            try? await stream.stopCapture()
            self.stream = nil
            print("[ScreenCapture] Stopped")
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }

        // Check for status — ScreenCaptureKit sends status frames we should skip
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue else {
            return
        }

        delegate?.screenCapture(self, didOutputSampleBuffer: sampleBuffer)
    }
}

enum ScreenCaptureError: Error, CustomStringConvertible {
    case displayNotFound(String)

    var description: String {
        switch self {
        case .displayNotFound(let msg): return msg
        }
    }
}
