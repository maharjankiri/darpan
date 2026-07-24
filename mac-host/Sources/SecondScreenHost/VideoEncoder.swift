import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didEncodeNALUnits nalData: Data, isKeyframe: Bool, timestamp: UInt64)
    func videoEncoder(_ encoder: VideoEncoder, didExtractSPS sps: Data, pps: Data)
}

final class VideoEncoder {
    weak var delegate: VideoEncoderDelegate?

    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let frameRate: Int
    private let bitrate: Int
    private var hasExtractedParameterSets = false
    private let forceKeyframeFlag = NSLock()
    private var forceNextKeyframe = false
    private var usingLowLatency = false
    private var fallbackRequested = false
    private var encodeErrorCount = 0

    init(width: Int, height: Int, frameRate: Int = 60, bitrateMbps: Int = 15) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.frameRate = frameRate
        self.bitrate = bitrateMbps * 1_000_000
    }

    func start() throws {
        // Low-latency rate control removes internal encoder frame queueing
        // (strict 1-in-1-out). Fall back to a regular session if the hardware
        // rejects it — either at creation or later at encode time (see
        // fallbackRequested in encode()).
        if startSession(lowLatency: true) {
            usingLowLatency = true
        } else {
            print("[Encoder] Low-latency rate control unavailable, falling back")
            guard startSession(lowLatency: false) else {
                throw EncoderError.createFailed(-1)
            }
            usingLowLatency = false
        }
    }

    private func startSession(lowLatency: Bool) -> Bool {
        guard let session = createSession(lowLatency: lowLatency) else { return false }

        // Configure for low latency real-time encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)
        // Keyframes are large and cause periodic latency bursts; keep them
        // rare — forceKeyframe() covers recovery after dropped frames.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (frameRate * 10) as CFNumber)

        if !lowLatency {
            // The low-latency encoder picks its own profile; forcing High or
            // data-rate limits there can make it reject every frame.
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
            let byteLimit = Double(bitrate / 8)
            let duration = 1.0
            let dataRateLimit: [CFNumber] = [byteLimit as CFNumber, duration as CFNumber]
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimit as CFArray)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)

        self.session = session
        print("[Encoder] Started H.264 encoder: \(width)x\(height)@\(frameRate)fps, \(bitrate/1_000_000)Mbps, lowLatency=\(lowLatency)")
        return true
    }

    /// Request that the next encoded frame be a keyframe (used to recover
    /// after the sender drops frames under network backpressure).
    func forceKeyframe() {
        forceKeyframeFlag.lock()
        forceNextKeyframe = true
        forceKeyframeFlag.unlock()
    }

    private func createSession(lowLatency: Bool) -> VTCompressionSession? {
        var spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        if lowLatency {
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr else { return nil }
        return session
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        // Low-latency session accepted frames but its callbacks are erroring —
        // recreate as a standard session before any keyframe has been produced.
        forceKeyframeFlag.lock()
        let needsFallback = fallbackRequested
        fallbackRequested = false
        forceKeyframeFlag.unlock()
        if needsFallback {
            print("[Encoder] Low-latency session failing at encode time, recreating without it")
            if let old = self.session {
                VTCompressionSessionInvalidate(old)
                self.session = nil
            }
            if startSession(lowLatency: false) {
                usingLowLatency = false
            } else {
                print("[Encoder] Fallback session creation failed")
                return
            }
        }

        guard let session = session else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        forceKeyframeFlag.lock()
        let wantKeyframe = forceNextKeyframe
        forceNextKeyframe = false
        forceKeyframeFlag.unlock()

        let frameProperties: CFDictionary? = wantKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
            : nil

        var flags = VTEncodeInfoFlags()

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            infoFlagsOut: &flags
        ) { [weak self] status, infoFlags, sampleBuffer in
            guard let self = self else { return }

            if status == noErr, let sampleBuffer = sampleBuffer {
                self.forceKeyframeFlag.lock()
                self.encodeErrorCount = 0
                self.forceKeyframeFlag.unlock()
                self.handleEncodedFrame(sampleBuffer)
                return
            }

            // status == noErr with no buffer: encoder dropped the frame.
            // Occasional drops are normal under rate control, but a session
            // that drops everything before producing its first keyframe is
            // broken (observed with low-latency rate control) — fall back.
            guard status != noErr else {
                if !self.hasExtractedParameterSets {
                    self.forceKeyframeFlag.lock()
                    self.encodeErrorCount += 1
                    let drops = self.encodeErrorCount
                    if drops >= 30 && self.usingLowLatency {
                        self.fallbackRequested = true
                    }
                    self.forceKeyframeFlag.unlock()
                    if drops == 30 {
                        print("[Encoder] \(drops) consecutive frame drops before first keyframe")
                    }
                }
                return
            }

            self.forceKeyframeFlag.lock()
            self.encodeErrorCount += 1
            let count = self.encodeErrorCount
            // Low-latency session erroring repeatedly before producing any
            // frame — ask encode() to rebuild without it
            if count >= 3 && self.usingLowLatency && !self.hasExtractedParameterSets {
                self.fallbackRequested = true
            }
            self.forceKeyframeFlag.unlock()
            if count == 3 || count % 120 == 1 {
                print("[Encoder] Encode callback error: \(status) (count=\(count))")
            }
        }

        if status != noErr {
            print("[Encoder] Encode failed: \(status)")
        }
    }

    func stop() {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
            print("[Encoder] Stopped")
        }
    }

    // MARK: - Private

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Check if keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isKeyframe = false
        if let attachments = attachments as? [[CFString: Any]],
           let first = attachments.first {
            isKeyframe = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }

        // Extract SPS/PPS on first keyframe
        if isKeyframe && !hasExtractedParameterSets {
            extractParameterSets(from: sampleBuffer)
        }

        // Get timestamp in microseconds
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = UInt64(CMTimeGetSeconds(pts) * 1_000_000)

        // Convert AVCC to Annex B format
        guard let annexBData = convertToAnnexB(dataBuffer: dataBuffer) else { return }

        delegate?.videoEncoder(self, didEncodeNALUnits: annexBData, isKeyframe: isKeyframe, timestamp: timestamp)
    }

    private func extractParameterSets(from sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        var spsSize = 0, spsCount = 0
        var ppsSize = 0, ppsCount = 0
        var spsPtr: UnsafePointer<UInt8>?
        var ppsPtr: UnsafePointer<UInt8>?

        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, let sps = spsPtr else { return }

        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: &ppsCount, nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, let pps = ppsPtr else { return }

        let spsData = Data(bytes: sps, count: spsSize)
        let ppsData = Data(bytes: pps, count: ppsSize)

        hasExtractedParameterSets = true
        print("[Encoder] Extracted SPS (\(spsSize)B) + PPS (\(ppsSize)B)")
        delegate?.videoEncoder(self, didExtractSPS: spsData, pps: ppsData)
    }

    private func convertToAnnexB(dataBuffer: CMBlockBuffer) -> Data? {
        var length = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr)
        guard status == noErr, let ptr = dataPtr else { return nil }

        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var annexBData = Data()
        var offset = 0

        while offset < length - 4 {
            // Read 4-byte AVCC length prefix (big-endian)
            var nalLength: UInt32 = 0
            memcpy(&nalLength, ptr + offset, 4)
            nalLength = UInt32(bigEndian: nalLength)
            offset += 4

            guard offset + Int(nalLength) <= length else { break }

            // Replace with Annex B start code
            annexBData.append(contentsOf: startCode)
            annexBData.append(Data(bytes: ptr + offset, count: Int(nalLength)))
            offset += Int(nalLength)
        }

        return annexBData
    }

    deinit {
        stop()
    }
}

enum EncoderError: Error {
    case createFailed(OSStatus)
}
