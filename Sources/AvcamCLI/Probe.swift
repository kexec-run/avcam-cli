import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import Foundation

final class SampleCounterDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sampleCount = 0
    private var dropCount = 0
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var previousPTS: CMTime?
    private var firstWallTime: Date?
    private var lastWallTime: Date?
    private var lastDropReason = "none"
    private var firstFormatSummary = "unseen"
    private var firstDuration = "unseen"
    private var firstAttachments = "none"
    private var firstTiming = "none"
    private var firstFrameLines: [String] = []
    private var intervalMin = Double.greatestFiniteMagnitude
    private var intervalMax = 0.0
    private var intervalSum = 0.0
    private var intervalCount = 0

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        let now = Date()

        lock.lock()
        if sampleCount == 0 {
            firstPTS = pts
            firstWallTime = now
            if let formatDescription {
                firstFormatSummary = AvcamCLI.sampleFormatSummary(formatDescription)
            }
            firstDuration = AvcamCLI.timeSummary(duration)
            firstAttachments = AvcamCLI.sampleAttachmentsSummary(sampleBuffer)
            firstTiming = AvcamCLI.sampleTimingSummary(sampleBuffer)
        }
        if let previousPTS {
            let delta = CMTimeGetSeconds(CMTimeSubtract(pts, previousPTS))
            intervalMin = min(intervalMin, delta)
            intervalMax = max(intervalMax, delta)
            intervalSum += delta
            intervalCount += 1
        }
        if firstFrameLines.count < 30 {
            let delta: String
            if let previousPTS {
                delta = AvcamCLI.trim(CMTimeGetSeconds(CMTimeSubtract(pts, previousPTS)))
            } else {
                delta = "N/A"
            }
            firstFrameLines.append("frame=\(sampleCount + 1) pts=\(AvcamCLI.timeSummary(pts)) delta=\(delta) duration=\(AvcamCLI.timeSummary(duration)) attachments=\(AvcamCLI.sampleAttachmentsSummary(sampleBuffer))")
        }
        sampleCount += 1
        previousPTS = pts
        lastPTS = pts
        lastWallTime = now
        lock.unlock()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let reason = attachments?.first?[kCMSampleBufferAttachmentKey_DroppedFrameReason] as? String

        lock.lock()
        dropCount += 1
        lastDropReason = reason ?? "unreported"
        lock.unlock()
    }

    func snapshot() -> (
        count: Int,
        drops: Int,
        firstPTS: Double,
        lastPTS: Double,
        mediaSeconds: Double,
        mediaFPS: Double,
        wallSeconds: Double,
        wallFPS: Double,
        lastDropReason: String,
        firstFormatSummary: String,
        firstDuration: String,
        firstAttachments: String,
        firstTiming: String,
        intervalMin: Double,
        intervalMax: Double,
        intervalAvg: Double,
        firstFrameLines: [String]
    ) {
        lock.lock()
        defer { lock.unlock() }

        let firstPTSSeconds = firstPTS.map(CMTimeGetSeconds) ?? 0
        let lastPTSSeconds = lastPTS.map(CMTimeGetSeconds) ?? 0

        let mediaSeconds: Double
        if let firstPTS, let lastPTS {
            mediaSeconds = max(0, CMTimeGetSeconds(CMTimeSubtract(lastPTS, firstPTS)))
        } else {
            mediaSeconds = 0
        }

        let wallSeconds: Double
        if let firstWallTime, let lastWallTime {
            wallSeconds = max(0, lastWallTime.timeIntervalSince(firstWallTime))
        } else {
            wallSeconds = 0
        }

        let mediaFPS = sampleCount > 1 && mediaSeconds > 0 ? Double(sampleCount - 1) / mediaSeconds : 0
        let wallFPS = sampleCount > 1 && wallSeconds > 0 ? Double(sampleCount - 1) / wallSeconds : 0
        let avg = intervalCount > 0 ? intervalSum / Double(intervalCount) : 0
        let minInterval = intervalMin == Double.greatestFiniteMagnitude ? 0 : intervalMin
        return (
            sampleCount,
            dropCount,
            firstPTSSeconds,
            lastPTSSeconds,
            mediaSeconds,
            mediaFPS,
            wallSeconds,
            wallFPS,
            lastDropReason,
            firstFormatSummary,
            firstDuration,
            firstAttachments,
            firstTiming,
            minInterval,
            intervalMax,
            avg,
            firstFrameLines
        )
    }
}

extension AvcamCLI {
    static func probe(
        device: AVCaptureDevice,
        width: Int,
        height: Int,
        fps: Double,
        seconds: Double,
        subtype: String?,
        formatIndex: Int?,
        outputMode: String,
        exposure: ExposureConfig
    ) throws {
        guard seconds > 0 else {
            throw CLIError.usage("--seconds must be greater than 0")
        }

        let choice = try selectFormat(device: device, width: width, height: height, fps: fps, subtype: subtype, formatIndex: formatIndex)
        let session = AVCaptureSession()
        session.beginConfiguration()
        setInputPriorityPresetIfAvailable(session, verbose: true)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CLIError.cannotAddInput("Cannot add input for camera \(device.localizedName).")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = false
        let normalizedOutputMode = outputMode.lowercased()
        let outputPixelFormat: String
        let requestedOutputPixelFormat: FourCharCode
        switch normalizedOutputMode {
        case "native":
            requestedOutputPixelFormat = choice.subtype
            outputPixelFormat = fourCC(choice.subtype)
        case "nv12":
            requestedOutputPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            outputPixelFormat = fourCC(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        default:
            throw CLIError.usage("--output-mode must be native or nv12")
        }
        output.videoSettings = [
            kCVPixelBufferWidthKey as String: Int(choice.dimensions.width),
            kCVPixelBufferHeightKey as String: Int(choice.dimensions.height),
            kCVPixelBufferPixelFormatTypeKey as String: Int(requestedOutputPixelFormat),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill
        ]

        let delegate = SampleCounterDelegate()
        let queue = DispatchQueue(label: "avcam-cli.video-data")
        output.setSampleBufferDelegate(delegate, queue: queue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CLIError.cannotAddOutput("Cannot add AVCaptureVideoDataOutput.")
        }
        session.addOutput(output)

        configureOutputConnections(output, choice: choice)
        session.commitConfiguration()

        print("Chromium-style probe ordering: explicit output width/height/pixel-format, connection frame durations, then activeFormat after startRunning().")
        print("")
        print("Selected camera: \(device.localizedName)")
        print("Selected format: [\(choice.index)] \(choice.dimensions.width)x\(choice.dimensions.height) \(fourCC(choice.subtype)) @ \(trim(choice.matchingRange.minFrameRate))-\(trim(choice.matchingRange.maxFrameRate)) fps")
        print("Requested fps: \(trim(fps))")
        print("Pinned min frame duration: \(choice.matchingRange.minFrameDuration.value)/\(choice.matchingRange.minFrameDuration.timescale)")
        print("Pinned max frame duration: \(choice.matchingRange.maxFrameDuration.value)/\(choice.matchingRange.maxFrameDuration.timescale)")
        print("Output settings requested pixel format: \(outputPixelFormat)")
        print("")
        print("Before session start:")
        printDeviceDebugInfo(device)
        printSessionDebugInfo(session, input: input, output: output, outputMode: normalizedOutputMode)
        print("")

        session.startRunning()
        guard session.isRunning else {
            throw CLIError.recordingFailed("AVCaptureSession did not start.")
        }

        try configure(device: device, choice: choice, fps: fps, exposure: exposure)
        configureOutputConnections(output, choice: choice)

        print("After session start and activeFormat apply:")
        printDeviceDebugInfo(device)
        printSessionDebugInfo(session, input: input, output: output, outputMode: normalizedOutputMode)
        print("")
        print("Input #0, avfoundation-native, from '\(device.localizedName)':")
        print("  Duration: N/A, start: N/A, bitrate: N/A")
        print("  Stream #0:0: Video: rawvideo (\(fourCC(choice.subtype)) / \(choice.subtype)), \(pixelFormatName(choice.subtype)), \(choice.dimensions.width)x\(choice.dimensions.height), requested \(trim(fps)) tbr, active \(activeFPSDescription(device)) tbr")
        print("  Format index: \(choice.index)")
        print("  Supported frame-rate ranges:")
        for range in choice.format.videoSupportedFrameRateRanges {
            print("    \(trim(range.minFrameRate))-\(trim(range.maxFrameRate)) fps (\(range.minFrameDuration.value) / \(range.minFrameDuration.timescale) - \(range.maxFrameDuration.value) / \(range.maxFrameDuration.timescale))")
        }
        print("Stream mapping:")
        print("  Stream #0:0 -> #0:0 (rawvideo (\(pixelFormatName(choice.subtype))) -> sample_counter (native))")
        print("Output #0, null, to 'probe':")
        print("  Stream #0:0: Video: sample_counter, requested \(normalizedOutputMode == "native" ? "native" : pixelFormatName(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)), \(choice.dimensions.width)x\(choice.dimensions.height)")
        print("    requested output pixel format: \(outputPixelFormat)")
        print("")
        print("Active format after session commit: \(formatSummary(device.activeFormat))")
        print("Active min frame duration: \(device.activeVideoMinFrameDuration.value)/\(device.activeVideoMinFrameDuration.timescale)")
        print("Active max frame duration: \(device.activeVideoMaxFrameDuration.value)/\(device.activeVideoMaxFrameDuration.timescale)")

        Thread.sleep(forTimeInterval: seconds)
        session.stopRunning()
        queue.sync {}

        let stats = delegate.snapshot()
        let elapsed = stats.wallSeconds
        print("[out#0/probe] video:\(stats.count)f drops:\(stats.drops) other streams:0 global headers:0 muxing overhead: unknown")
        print("frame=\(stats.count) fps=\(trim(stats.wallFPS)) time=\(formatDuration(stats.mediaSeconds)) speed=\(trim(elapsed > 0 ? stats.mediaSeconds / elapsed : 0))x elapsed=\(formatDuration(elapsed))")
        print("First video PTS: \(trim(stats.firstPTS))")
        print("Last video PTS: \(trim(stats.lastPTS))")
        print("First sample format: \(stats.firstFormatSummary)")
        print("First sample duration: \(stats.firstDuration)")
        print("First sample timing: \(stats.firstTiming)")
        print("First sample attachments: \(stats.firstAttachments)")
        print("Frame interval min seconds: \(trim(stats.intervalMin))")
        print("Frame interval max seconds: \(trim(stats.intervalMax))")
        print("Frame interval avg seconds: \(trim(stats.intervalAvg))")
        print("Dropped frames: \(stats.drops)")
        print("Last drop reason: \(stats.lastDropReason)")
        print("First sample timeline:")
        for line in stats.firstFrameLines {
            print("  \(line)")
        }
        print("Probe seconds requested: \(trim(seconds))")
        print("Probe samples: \(stats.count)")
        print("Probe media span seconds: \(trim(stats.mediaSeconds))")
        print("Probe media fps: \(trim(stats.mediaFPS))")
        print("Probe wall span seconds: \(trim(stats.wallSeconds))")
        print("Probe wall fps: \(trim(stats.wallFPS))")
    }
}
