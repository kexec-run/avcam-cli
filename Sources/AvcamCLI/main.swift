import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import Foundation

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case cameraPermission(String)
    case cameraNotFound(String)
    case noMatchingFormat(String)
    case cannotAddInput(String)
    case cannotAddOutput(String)
    case recordingFailed(String)

    var description: String {
        switch self {
        case .usage(let message),
             .cameraPermission(let message),
             .cameraNotFound(let message),
             .noMatchingFormat(let message),
             .cannotAddInput(let message),
             .cannotAddOutput(let message),
             .recordingFailed(let message):
            return message
        }
    }


    var exitCode: Int32 {
        switch self {
        case .usage:
            return 1
        case .cameraPermission, .cameraNotFound:
            return 2
        case .noMatchingFormat, .cannotAddInput, .cannotAddOutput:
            return 3
        case .recordingFailed:
            return 4
        }
    }
}


final class StopController: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var requestReason = "unknown"
    private var signalSources: [DispatchSourceSignal] = []

    func request(_ reason: String) {
        lock.lock()
        if !requested {
            requested = true
            requestReason = reason
        }
        lock.unlock()
    }

    func snapshot() -> (requested: Bool, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        return (requested, requestReason)
    }


    func retain(_ source: DispatchSourceSignal) {
        lock.lock()
        signalSources.append(source)
        lock.unlock()
    }
}
struct Options {
    let values: [String: String]

    init(_ args: ArraySlice<String>) throws {
        var parsed: [String: String] = [:]
        var index = args.startIndex

        while index < args.endIndex {
            let key = args[index]
            guard key.hasPrefix("--") else {
                throw CLIError.usage("Unexpected argument: \(key)")
            }

            if key == "--verbose" {
                parsed["verbose"] = "true"
                index = args.index(after: index)
                continue
            }

            let valueIndex = args.index(after: index)
            guard valueIndex < args.endIndex else {
                throw CLIError.usage("Missing value for \(key)")
            }

            parsed[String(key.dropFirst(2))] = args[valueIndex]
            index = args.index(after: valueIndex)
        }

        values = parsed
    }

    func string(_ name: String, default defaultValue: String? = nil) throws -> String {
        if let value = values[name] {
            return value
        }
        if let defaultValue {
            return defaultValue
        }
        throw CLIError.usage("Missing required option --\(name)")
    }

    func int(_ name: String, default defaultValue: Int? = nil) throws -> Int {
        let raw = try string(name, default: defaultValue.map(String.init))
        guard let value = Int(raw) else {
            throw CLIError.usage("Invalid integer for --\(name): \(raw)")
        }
        return value
    }

    func optionalInt(_ name: String) throws -> Int? {
        guard let raw = values[name] else {
            return nil
        }
        guard let value = Int(raw) else {
            throw CLIError.usage("Invalid integer for --\(name): \(raw)")
        }
        return value
    }

    func double(_ name: String, default defaultValue: Double? = nil) throws -> Double {
        let raw = try string(name, default: defaultValue.map { String($0) })
        guard let value = Double(raw) else {
            throw CLIError.usage("Invalid number for --\(name): \(raw)")
        }
        return value
    }

    func optionalDouble(_ name: String) throws -> Double? {
        guard let raw = values[name] else {
            return nil
        }
        guard let value = Double(raw) else {
            throw CLIError.usage("Invalid number for --\(name): \(raw)")
        }
        return value
    }
}

struct FormatChoice {
    let index: Int
    let format: AVCaptureDevice.Format
    let dimensions: CMVideoDimensions
    let subtype: FourCharCode
    let matchingRange: AVFrameRateRange
}

struct ExposureConfig {
    let mode: String
    let maxExposureFPS: Double?
    let exposureDuration: Double?
    let iso: Double?
    let disableLowLightBoost: Bool
}

final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let startedSemaphore = DispatchSemaphore(value: 0)
    private let finishedSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finishError: Error?
    private var didStart = false
    private var didFinish = false

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        lock.lock()
        didStart = true
        lock.unlock()
        startedSemaphore.signal()
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        lock.lock()
        finishError = error
        didFinish = true
        lock.unlock()
        finishedSemaphore.signal()
    }

    func waitUntilStarted(timeout: DispatchTime) -> Bool {
        if startedSemaphore.wait(timeout: timeout) == .success {
            return true
        }

        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    func finishStatus() -> (finished: Bool, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (didFinish, finishError)
    }
}

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

struct AvcamCLI {
    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            throw CLIError.usage("Missing command")
        }

        switch command {
        case "list":
            try ensureCameraAccess()
            listDevices()
        case "formats":
            try ensureCameraAccess()
            let options = try Options(args.dropFirst())
            let device = try selectDevice(matching: try options.string("camera"))
            printFormats(for: device)
        case "codecs":
            try ensureCameraAccess()
            let options = try Options(args.dropFirst())
            let device = try selectDevice(matching: try options.string("camera"))
            let width = try options.int("width", default: 1920)
            let height = try options.int("height", default: 1080)
            let fps = try options.double("fps", default: 30)
            let subtype = options.values["subtype"]
            let formatIndex = try options.optionalInt("format-index")
            let exposure = try exposureConfig(options: options)
            try printVideoCodecs(device: device, width: width, height: height, fps: fps, subtype: subtype, formatIndex: formatIndex, exposure: exposure)
        case "record":
            try ensureCameraAccess()
            let options = try Options(args.dropFirst())
            let device = try selectDevice(matching: try options.string("camera"))
            let audioDevice: AVCaptureDevice?
            if let audioName = options.values["audio"] {
                try ensureMicrophoneAccess()
                audioDevice = try selectAudioDevice(matching: audioName)
            } else {
                if options.values["audio-codec"] != nil {
                    throw CLIError.usage("--audio-codec requires --audio")
                }
                audioDevice = nil
            }
            let width = try options.int("width", default: 1920)
            let height = try options.int("height", default: 1080)
            let fps = try options.double("fps", default: 30)
            let seconds = try options.optionalDouble("seconds")
            let finalizeTimeout = try options.double("finalize-timeout", default: 5)
            let outPath = try options.string("out")
            let subtype = options.values["subtype"]
            let formatIndex = try options.optionalInt("format-index")
            let exposure = try exposureConfig(options: options)
            let verbose = options.values["verbose"] == "true"
            let audioCodec = audioDevice == nil ? nil : try options.string("audio-codec", default: "aac").lowercased()
            try record(device: device, audioDevice: audioDevice, audioCodec: audioCodec, width: width, height: height, fps: fps, seconds: seconds, finalizeTimeout: finalizeTimeout, outPath: outPath, subtype: subtype, formatIndex: formatIndex, exposure: exposure, verbose: verbose)
        case "probe":
            try ensureCameraAccess()
            let options = try Options(args.dropFirst())
            let device = try selectDevice(matching: try options.string("camera"))
            let width = try options.int("width", default: 1920)
            let height = try options.int("height", default: 1080)
            let fps = try options.double("fps", default: 30)
            let seconds = try options.double("seconds")
            let subtype = options.values["subtype"]
            let formatIndex = try options.optionalInt("format-index")
            let outputMode = try options.string("output-mode", default: "nv12")
            let exposure = try exposureConfig(options: options)
            try probe(device: device, width: width, height: height, fps: fps, seconds: seconds, subtype: subtype, formatIndex: formatIndex, outputMode: outputMode, exposure: exposure)
        case "-h", "--help", "help":
            print(usage)
        default:
            throw CLIError.usage("Unknown command: \(command)")
        }
    }

    static let usage = """
    Usage:
      avcam-cli list
      avcam-cli formats --camera "Brio"
      avcam-cli codecs --camera "Brio" --format-index 35 --fps 30
      avcam-cli record --camera "Brio" --audio "Brio" --audio-codec alac --format-index 35 --fps 30 --out brio-1080p30-alac.mov
      avcam-cli record --camera "Brio" --audio "Brio" --audio-codec alac --format-index 35 --fps 30 --seconds 10 --out brio-1080p30-alac.mov
      avcam-cli record --camera "Brio" --audio "Brio" --audio-codec aac --format-index 35 --fps 30 --seconds 10 --out brio-1080p30-aac.mov
      avcam-cli record --camera "Brio" --audio "Brio" --audio-codec pcm --format-index 35 --fps 30 --seconds 10 --out brio-1080p30-pcm.mov
      avcam-cli record --camera "Brio" --format-index 35 --fps 30 --seconds 10 --out brio-1080p30.mov --verbose
      avcam-cli record --camera "Brio" --format-index 35 --fps 30 --seconds 10 --finalize-timeout 10 --out brio-1080p30.mov
      avcam-cli probe --camera "Brio" --width 1920 --height 1080 --fps 30 --seconds 10
      avcam-cli probe --camera "Brio" --width 1920 --height 1080 --fps 30 --seconds 10 --subtype MJPG
      avcam-cli probe --camera "Brio" --format-index 12 --fps 30 --seconds 10
      avcam-cli probe --camera "Brio" --format-index 35 --fps 30 --seconds 10 --output-mode native
      avcam-cli probe --camera "Brio" --format-index 35 --fps 30 --seconds 10 --output-mode native --exposure-mode locked
    """

    static func ensureCameraAccess() throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { isGranted in
                granted = isGranted
                semaphore.signal()
            }
            semaphore.wait()
            guard granted else {
                throw CLIError.cameraPermission("Camera access was not granted. Enable access in System Settings > Privacy & Security > Camera.")
            }
        case .denied:
            throw CLIError.cameraPermission("Camera access is denied. Enable access in System Settings > Privacy & Security > Camera.")
        case .restricted:
            throw CLIError.cameraPermission("Camera access is restricted by system policy.")
        @unknown default:
            throw CLIError.cameraPermission("Camera access is unavailable for an unknown authorization state.")
        }
    }

    static func ensureMicrophoneAccess() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                granted = isGranted
                semaphore.signal()
            }
            semaphore.wait()
            guard granted else {
                throw CLIError.cameraPermission("Microphone access was not granted. Enable access in System Settings > Privacy & Security > Microphone.")
            }
        case .denied:
            throw CLIError.cameraPermission("Microphone access is denied. Enable access in System Settings > Privacy & Security > Microphone.")
        case .restricted:
            throw CLIError.cameraPermission("Microphone access is restricted by system policy.")
        @unknown default:
            throw CLIError.cameraPermission("Microphone access is unavailable for an unknown authorization state.")
        }
    }

    static func discoverDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.builtInWideAngleCamera, .external, .continuityCamera]
        } else {
            deviceTypes = [.builtInWideAngleCamera, .externalUnknown]
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )

        return discovery.devices
    }

    static func discoverAudioDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone]
        } else {
            deviceTypes = [.builtInMicrophone]
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )

        return discovery.devices
    }

    static func listDevices() {
        let devices = discoverDevices()
        if devices.isEmpty {
            print("No video capture devices found.")
        } else {
            print("Video capture devices:")
            for (index, device) in devices.enumerated() {
                print("[\(index)] \(device.localizedName)")
                print("    uniqueID: \(device.uniqueID)")
                print("    modelID: \(device.modelID)")
                print("    type: \(device.deviceType.rawValue)")
            }
        }

        let audioDevices = discoverAudioDevices()
        if audioDevices.isEmpty {
            print("No audio capture devices found.")
            return
        }

        print("Audio capture devices:")
        for (index, device) in audioDevices.enumerated() {
            print("[\(index)] \(device.localizedName)")
            print("    uniqueID: \(device.uniqueID)")
            print("    modelID: \(device.modelID)")
            print("    type: \(device.deviceType.rawValue)")
        }
    }

    static func selectDevice(matching partialName: String) throws -> AVCaptureDevice {
        let lowerName = partialName.lowercased()
        let matches = discoverDevices().filter {
            $0.localizedName.lowercased().contains(lowerName)
                || $0.uniqueID.lowercased().contains(lowerName)
                || $0.modelID.lowercased().contains(lowerName)
        }

        guard let device = matches.first else {
            throw CLIError.cameraNotFound("No video capture device matched '\(partialName)'. Run `avcam-cli list` to inspect available devices.")
        }

        if matches.count > 1 {
            fputs("warning: multiple cameras matched '\(partialName)', using \(device.localizedName)\n", stderr)
        }

        return device
    }

    static func selectAudioDevice(matching partialName: String) throws -> AVCaptureDevice {
        let lowerName = partialName.lowercased()
        let matches = discoverAudioDevices().filter {
            $0.localizedName.lowercased().contains(lowerName)
                || $0.uniqueID.lowercased().contains(lowerName)
                || $0.modelID.lowercased().contains(lowerName)
        }

        guard let device = matches.first else {
            throw CLIError.cameraNotFound("No audio capture device matched '\(partialName)'. Run `avcam-cli list` to inspect available devices.")
        }

        if matches.count > 1 {
            fputs("warning: multiple audio devices matched '\(partialName)', using \(device.localizedName)\n", stderr)
        }

        return device
    }

    static func printFormats(for device: AVCaptureDevice) {
        print("Camera: \(device.localizedName)")
        print("uniqueID: \(device.uniqueID)")

        for (index, format) in device.formats.enumerated() {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges
                .map { "\(trim($0.minFrameRate))-\(trim($0.maxFrameRate)) fps" }
                .joined(separator: ", ")

            print("[\(index)] \(dimensions.width)x\(dimensions.height) \(fourCC(subtype)) (\(subtype))")
            print("    fps: \(ranges)")
        }
    }

    static func record(
        device: AVCaptureDevice,
        audioDevice: AVCaptureDevice?,
        audioCodec: String?,
        width: Int,
        height: Int,
        fps: Double,
        seconds: Double?,
        finalizeTimeout: Double,
        outPath: String,
        subtype: String?,
        formatIndex: Int?,
        exposure: ExposureConfig,
        verbose: Bool
    ) throws {
        if let seconds, seconds <= 0 {
            throw CLIError.usage("--seconds must be greater than 0")
        }
        guard finalizeTimeout > 0 else {
            throw CLIError.usage("--finalize-timeout must be greater than 0")
        }

        let choice = try selectFormat(device: device, width: width, height: height, fps: fps, subtype: subtype, formatIndex: formatIndex)
        let session = AVCaptureSession()
        session.beginConfiguration()
        setInputPriorityPresetIfAvailable(session, verbose: verbose)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CLIError.cannotAddInput("Cannot add input for camera \(device.localizedName).")
        }
        session.addInput(input)

        if let audioDevice {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            guard session.canAddInput(audioInput) else {
                session.commitConfiguration()
                throw CLIError.cannotAddInput("Cannot add audio input for \(audioDevice.localizedName).")
            }
            session.addInput(audioInput)
        }

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CLIError.cannotAddOutput("Cannot add AVCaptureMovieFileOutput.")
        }
        session.addOutput(output)

        configureOutputConnections(output, choice: choice)
        try configureAudioOutputSettings(output, audioCodec: audioCodec)
        session.commitConfiguration()

        let outURL = outputURL(for: outPath)
        if FileManager.default.fileExists(atPath: outURL.path) {
            try FileManager.default.removeItem(at: outURL)
        }
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        print("Selected camera: \(device.localizedName)")
        if let audioDevice {
            print("Selected audio: \(audioDevice.localizedName) (\(audioCodec ?? "aac"))")
        }
        print("Selected format: [\(choice.index)] \(choice.dimensions.width)x\(choice.dimensions.height) \(fourCC(choice.subtype)) @ \(trim(choice.matchingRange.minFrameRate))-\(trim(choice.matchingRange.maxFrameRate)) fps")
        print("Pinned min frame duration: \(choice.matchingRange.minFrameDuration.value)/\(choice.matchingRange.minFrameDuration.timescale)")
        print("Pinned max frame duration: \(choice.matchingRange.maxFrameDuration.value)/\(choice.matchingRange.maxFrameDuration.timescale)")
        print("Output: \(outURL.path)")

        let delegate = RecordingDelegate()
        let stopController = installStopSignalHandlers()
        if verbose {
            print("Chromium-style record ordering: connection frame durations, startRunning(), activeFormat, then startRecording().")
        }
        session.startRunning()
        guard session.isRunning else {
            throw CLIError.recordingFailed("AVCaptureSession did not start.")
        }

        if stopController.snapshot().requested {
            session.stopRunning()
            throw CLIError.recordingFailed("Recording stopped before capture started.")
        }
        try configure(device: device, choice: choice, fps: fps, exposure: exposure)
        configureOutputConnections(output, choice: choice)
        try configureAudioOutputSettings(output, audioCodec: audioCodec)
        if verbose {
            print("Active format after session start: \(formatSummary(device.activeFormat))")
            print("Active min frame duration: \(device.activeVideoMinFrameDuration.value)/\(device.activeVideoMinFrameDuration.timescale)")
            print("Active max frame duration: \(device.activeVideoMaxFrameDuration.value)/\(device.activeVideoMaxFrameDuration.timescale)")
            for (index, connection) in output.connections.enumerated() {
                print("Movie output connection [\(index)] minFrameDuration supported=\(connection.isVideoMinFrameDurationSupported) value=\(timeSummary(connection.videoMinFrameDuration))")
                print("Movie output connection [\(index)] maxFrameDuration supported=\(connection.isVideoMaxFrameDurationSupported) value=\(timeSummary(connection.videoMaxFrameDuration))")
            }
        }

        if stopController.snapshot().requested {
            session.stopRunning()
            throw CLIError.recordingFailed("Recording stopped before file output started.")
        }
        output.startRecording(to: outURL, recordingDelegate: delegate)
        guard delegate.waitUntilStarted(timeout: .now() + 10) else {
            session.stopRunning()
            throw CLIError.recordingFailed("Recording did not start within 10 seconds.")
        }

        waitForStopRequest(seconds: seconds, stopController: stopController)
        let stop = stopController.snapshot()
        let stopStarted = Date()
        output.stopRecording()
        if verbose {
            print("Recording stop requested by \(stop.reason); waiting up to \(trim(finalizeTimeout))s for MovieFileOutput to finish writing.")
        }

        let finish = waitForRecordingToFinish(delegate: delegate, timeoutSeconds: finalizeTimeout)
        session.stopRunning()
        guard finish.finished else {
            throw CLIError.recordingFailed("Recording did not finish within \(trim(finalizeTimeout)) seconds after stopRecording(). AVFoundation did not deliver didFinishRecordingTo before timeout.")
        }
        if let error = finish.error {
            throw CLIError.recordingFailed("Recording failed: \(error.localizedDescription)")
        }
        if verbose {
            print("Recording finished in \(trim(Date().timeIntervalSince(stopStarted)))s after stopRecording().")
        }
        print("Finished recording: \(outURL.path)")
        print("Inspect with: ffprobe -v error -show_entries stream=index,codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,pix_fmt,duration,sample_rate,channels -of default=nw=1 \(shellQuote(outURL.path))")
    }

    static func printVideoCodecs(
        device: AVCaptureDevice,
        width: Int,
        height: Int,
        fps: Double,
        subtype: String?,
        formatIndex: Int?,
        exposure: ExposureConfig
    ) throws {
        let choice = try selectFormat(device: device, width: width, height: height, fps: fps, subtype: subtype, formatIndex: formatIndex)
        let session = AVCaptureSession()
        session.beginConfiguration()
        setInputPriorityPresetIfAvailable(session, verbose: false)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CLIError.cannotAddInput("Cannot add input for camera \(device.localizedName).")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferWidthKey as String: Int(choice.dimensions.width),
            kCVPixelBufferHeightKey as String: Int(choice.dimensions.height),
            kCVPixelBufferPixelFormatTypeKey as String: Int(choice.subtype),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill
        ]
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CLIError.cannotAddOutput("Cannot add AVCaptureVideoDataOutput.")
        }
        session.addOutput(output)
        session.commitConfiguration()

        try configure(device: device, choice: choice, fps: fps, exposure: exposure)

        let fileType: AVFileType = .mov
        let codecs = output.availableVideoCodecTypesForAssetWriter(writingTo: fileType)
        print("Selected camera: \(device.localizedName)")
        print("Selected format: [\(choice.index)] \(choice.dimensions.width)x\(choice.dimensions.height) \(fourCC(choice.subtype)) @ \(trim(choice.matchingRange.minFrameRate))-\(trim(choice.matchingRange.maxFrameRate)) fps")
        print("AssetWriter file type: \(fileType.rawValue)")
        print("Available video codecs:")
        for codec in codecs {
            print("  \(codec.rawValue)")
        }
        print("HEVC available: \(codecs.contains(.hevc) ? "true" : "false")")

        if codecs.contains(.hevc) {
            let settings = output.recommendedVideoSettings(forVideoCodecType: .hevc, assetWriterOutputFileType: fileType) ?? [:]
            print("HEVC recommended settings:")
            print(formatSettings(settings, indentation: "  "))
        }
    }

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

    static func selectFormat(
        device: AVCaptureDevice,
        width: Int,
        height: Int,
        fps: Double,
        subtype: String?,
        formatIndex: Int?
    ) throws -> FormatChoice {
        let requestedFPS = roundedFPS(fps)
        let subtypeFilter = subtype?.lowercased()
        let candidates = device.formats.enumerated().flatMap { index, format -> [FormatChoice] in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)

            if let formatIndex, index != formatIndex {
                return []
            }

            if formatIndex == nil {
                guard dimensions.width == width, dimensions.height == height else {
                    return []
                }
            }

            let mediaSubtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let mediaSubtypeText = fourCC(mediaSubtype).lowercased()
            if let subtypeFilter, !mediaSubtypeText.contains(subtypeFilter) {
                return []
            }

            return format.videoSupportedFrameRateRanges.compactMap { range in
                guard roundedFPS(range.maxFrameRate) >= requestedFPS else {
                    return nil
                }

                return FormatChoice(
                    index: index,
                    format: format,
                    dimensions: dimensions,
                    subtype: mediaSubtype,
                    matchingRange: range
                )
            }
        }

        guard let best = candidates.sorted(by: compareFormatPreference).first else {
            throw CLIError.noMatchingFormat("No format matched \(formatRequestDescription(width: width, height: height, fps: fps, subtype: subtype, formatIndex: formatIndex)) on \(device.localizedName). Run `avcam-cli formats --camera \"\(device.localizedName)\"`.")
        }

        return best
    }

    static func compareFormatPreference(_ lhs: FormatChoice, _ rhs: FormatChoice) -> Bool {
        let leftFPS = roundedFPS(lhs.matchingRange.maxFrameRate)
        let rightFPS = roundedFPS(rhs.matchingRange.maxFrameRate)
        if leftFPS != rightFPS {
            return leftFPS < rightFPS
        }

        let leftScore = subtypePreference(lhs.subtype)
        let rightScore = subtypePreference(rhs.subtype)
        if leftScore != rightScore {
            return leftScore > rightScore
        }
        return lhs.matchingRange.maxFrameRate > rhs.matchingRange.maxFrameRate
    }

    static func subtypePreference(_ subtype: FourCharCode) -> Int {
        switch fourCC(subtype).lowercased() {
        case "dmb1", "mjpg", "jpeg":
            return 100
        default:
            return 0
        }
    }

    static func configure(device: AVCaptureDevice, choice: FormatChoice, fps: Double, exposure: ExposureConfig) throws {
        try device.lockForConfiguration()
        defer {
            device.unlockForConfiguration()
        }

        device.activeFormat = choice.format
        device.activeVideoMinFrameDuration = choice.matchingRange.minFrameDuration
        device.activeVideoMaxFrameDuration = choice.matchingRange.maxFrameDuration

        switch exposure.mode {
        case "auto":
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        case "locked":
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
        case "custom":
            throw CLIError.usage("Custom exposure duration/ISO is unavailable in macOS AVFoundation. Try --exposure-mode locked.")
        default:
            throw CLIError.usage("--exposure-mode must be auto, locked, or custom")
        }
    }

    static func setInputPriorityPresetIfAvailable(_ session: AVCaptureSession, verbose: Bool) {
        let inputPriority = AVCaptureSession.Preset(rawValue: "AVCaptureSessionPresetInputPriority")
        if session.canSetSessionPreset(inputPriority) {
            session.sessionPreset = inputPriority
        } else if verbose {
            fputs("warning: AVCaptureSessionPresetInputPriority is not directly settable on this macOS SDK; activeFormat still drives input-priority capture behavior.\n", stderr)
        }
    }

    static func configureOutputConnections(_ output: AVCaptureOutput, choice: FormatChoice) {
        for connection in output.connections {
            if connection.isVideoMinFrameDurationSupported {
                connection.videoMinFrameDuration = choice.matchingRange.minFrameDuration
            }
            if connection.isVideoMaxFrameDurationSupported {
                connection.videoMaxFrameDuration = choice.matchingRange.maxFrameDuration
            }
        }
    }

    static func configureAudioOutputSettings(_ output: AVCaptureMovieFileOutput, audioCodec: String?) throws {
        guard let audioCodec else {
            return
        }

        let audioConnections = output.connections.filter { connectionContains($0, mediaType: .audio) }
        guard !audioConnections.isEmpty else {
            throw CLIError.recordingFailed("Audio input was added, but AVCaptureMovieFileOutput has no audio connection.")
        }

        let settings = try audioOutputSettings(codec: audioCodec)
        for connection in audioConnections {
            output.setOutputSettings(settings, for: connection)
        }
    }

    static func connectionContains(_ connection: AVCaptureConnection, mediaType: AVMediaType) -> Bool {
        connection.inputPorts.contains { $0.mediaType == mediaType }
    }

    static func audioOutputSettings(codec: String) throws -> [String: Any] {
        switch codec {
        case "aac":
            return [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 192_000
            ]
        case "alac":
            return [
                AVFormatIDKey: Int(kAudioFormatAppleLossless),
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitDepthHintKey: 16
            ]
        case "pcm":
            return [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        default:
            throw CLIError.usage("--audio-codec must be aac, alac, or pcm")
        }
    }

    static func formatSettings(_ value: Any, indentation: String) -> String {
        if let dict = value as? [String: Any] {
            if dict.isEmpty {
                return "\(indentation){}"
            }
            return dict.keys.sorted().map { key in
                let child = dict[key]!
                if child is [String: Any] {
                    return "\(indentation)\(key):\n\(formatSettings(child, indentation: indentation + "  "))"
                }
                return "\(indentation)\(key): \(child)"
            }.joined(separator: "\n")
        }
        return "\(indentation)\(value)"
    }

    static func exposureConfig(options: Options) throws -> ExposureConfig {
        ExposureConfig(
            mode: try options.string("exposure-mode", default: "auto").lowercased(),
            maxExposureFPS: try options.optionalDouble("max-exposure-fps"),
            exposureDuration: try options.optionalDouble("exposure-duration"),
            iso: try options.optionalDouble("iso"),
            disableLowLightBoost: try options.string("disable-low-light-boost", default: "true").lowercased() != "false"
        )
    }

    static func exposureDuration(for exposure: ExposureConfig, requestedFPS: Double) -> CMTime {
        if let seconds = exposure.exposureDuration {
            return secondsToCMTime(seconds)
        }

        let fps = exposure.maxExposureFPS ?? requestedFPS
        return secondsToCMTime(1.0 / fps)
    }

    static func secondsToCMTime(_ seconds: Double) -> CMTime {
        let timescale: Int32 = 1_000_000_000
        return CMTime(value: CMTimeValue((seconds * Double(timescale)).rounded()), timescale: timescale)
    }

    static func roundedFPS(_ fps: Double) -> Int {
        Int(fps.rounded(.toNearestOrAwayFromZero))
    }

    static func formatRequestDescription(width: Int, height: Int, fps: Double, subtype: String?, formatIndex: Int?) -> String {
        if let formatIndex {
            return "format index \(formatIndex) at nearest rounded fps >= \(trim(fps))"
        }

        var parts = ["\(width)x\(height)", "nearest rounded fps >= \(trim(fps))"]
        if let subtype {
            parts.append("subtype containing \(subtype)")
        }
        return parts.joined(separator: ", ")
    }

    static func outputURL(for path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
    }


    static func formatSummary(_ format: AVCaptureDevice.Format) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let ranges = format.videoSupportedFrameRateRanges
            .map { "\(trim($0.minFrameRate))-\(trim($0.maxFrameRate)) fps" }
            .joined(separator: ", ")
        return "\(dimensions.width)x\(dimensions.height) \(fourCC(subtype)) fps: \(ranges)"
    }

    static func printDeviceDebugInfo(_ device: AVCaptureDevice) {
        print("Device debug:")
        print("  localizedName: \(device.localizedName)")
        print("  uniqueID: \(device.uniqueID)")
        print("  modelID: \(device.modelID)")
        print("  deviceType: \(device.deviceType.rawValue)")
        print("  position: \(device.position.rawValue)")
        print("  has video: \(device.hasMediaType(.video))")
        print("  format count: \(device.formats.count)")
        print("  activeFormat: \(formatSummary(device.activeFormat))")
        print("  activeVideoMinFrameDuration: \(timeSummary(device.activeVideoMinFrameDuration))")
        print("  activeVideoMaxFrameDuration: \(timeSummary(device.activeVideoMaxFrameDuration))")
        print("  exposureMode: \(exposureModeName(device.exposureMode))")
        print("  exposureDuration: unavailable in macOS AVFoundation")
        print("  iso: unavailable in macOS AVFoundation")
        print("  lowLightBoost: unavailable in macOS AVFoundation")
        print("  exposure support: continuous=\(device.isExposureModeSupported(.continuousAutoExposure)) locked=\(device.isExposureModeSupported(.locked)) custom=\(device.isExposureModeSupported(.custom))")
        print("  all formats:")
        for (index, format) in device.formats.enumerated() {
            print("    [\(index)] \(formatSummary(format))")
        }
    }

    static func printSessionDebugInfo(
        _ session: AVCaptureSession,
        input: AVCaptureDeviceInput,
        output: AVCaptureVideoDataOutput,
        outputMode: String
    ) {
        print("Session debug:")
        print("  sessionPreset: \(session.sessionPreset.rawValue)")
        print("  isRunning: \(session.isRunning)")
        print("  inputs: \(session.inputs.count)")
        print("  outputs: \(session.outputs.count)")
        print("  input ports: \(input.ports.count)")
        for (index, port) in input.ports.enumerated() {
            print("    input port [\(index)] mediaType=\(port.mediaType.rawValue) enabled=\(port.isEnabled)")
        }
        print("  output mode: \(outputMode)")
        print("  output alwaysDiscardsLateVideoFrames: \(output.alwaysDiscardsLateVideoFrames)")
        print("  output videoSettings: \(output.videoSettings ?? [:])")
        print("  output available pixel formats:")
        for value in output.availableVideoPixelFormatTypes {
            let code = FourCharCode(value)
            print("    \(fourCC(code)) (\(code)) \(pixelFormatName(code))")
        }
        print("  output connections: \(output.connections.count)")
        for (index, connection) in output.connections.enumerated() {
            print("    connection [\(index)] enabled=\(connection.isEnabled) active=\(connection.isActive) inputPorts=\(connection.inputPorts.count)")
            print("      videoMinFrameDuration supported=\(connection.isVideoMinFrameDurationSupported) value=\(timeSummary(connection.videoMinFrameDuration))")
            print("      videoMaxFrameDuration supported=\(connection.isVideoMaxFrameDurationSupported) value=\(timeSummary(connection.videoMaxFrameDuration))")
            for (portIndex, port) in connection.inputPorts.enumerated() {
                print("      port [\(portIndex)] mediaType=\(port.mediaType.rawValue) enabled=\(port.isEnabled)")
            }
        }
    }

    static func activeFPSDescription(_ device: AVCaptureDevice) -> String {
        let duration = device.activeVideoMinFrameDuration
        guard duration.value > 0 else {
            return "unknown"
        }
        return trim(Double(duration.timescale) / Double(duration.value))
    }

    static func sampleFormatSummary(_ formatDescription: CMFormatDescription) -> String {
        let subtype = CMFormatDescriptionGetMediaSubType(formatDescription)
        if CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Video {
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            return "\(dimensions.width)x\(dimensions.height) \(fourCC(subtype)) (\(subtype)) \(pixelFormatName(subtype))"
        }
        return "mediaType=\(CMFormatDescriptionGetMediaType(formatDescription)) subtype=\(subtype)"
    }

    static func sampleAttachmentsSummary(_ sampleBuffer: CMSampleBuffer) -> String {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              !attachments.isEmpty else {
            return "none"
        }

        return attachments.enumerated().map { index, attachment in
            let pairs = attachment.map { key, value in
                "\(key)=\(value)"
            }.sorted().joined(separator: ", ")
            return "[\(index)] \(pairs)"
        }.joined(separator: " | ")
    }

    static func sampleTimingSummary(_ sampleBuffer: CMSampleBuffer) -> String {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let outputPTS = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        return "pts=\(timeSummary(pts)) outputPTS=\(timeSummary(outputPTS)) dts=\(timeSummary(dts)) duration=\(timeSummary(duration))"
    }

    static func timeSummary(_ time: CMTime) -> String {
        if !time.isValid {
            return "invalid"
        }
        if time.isIndefinite {
            return "indefinite"
        }
        if time.isPositiveInfinity {
            return "+inf"
        }
        if time.isNegativeInfinity {
            return "-inf"
        }
        return "\(time.value)/\(time.timescale) (\(trim(CMTimeGetSeconds(time)))s)"
    }

    static func exposureModeName(_ mode: AVCaptureDevice.ExposureMode) -> String {
        switch mode {
        case .locked:
            return "locked"
        case .autoExpose:
            return "autoExpose"
        case .continuousAutoExposure:
            return "continuousAutoExposure"
        case .custom:
            return "custom"
        @unknown default:
            return "unknown(\(mode.rawValue))"
        }
    }

    static func pixelFormatName(_ code: FourCharCode) -> String {
        switch fourCC(code).lowercased() {
        case "420v":
            return "nv12/video-range"
        case "420f":
            return "nv12/full-range"
        case "yuvs":
            return "uyvy422"
        case "2vuy":
            return "uyvy422"
        default:
            return fourCC(code).lowercased()
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = Double(whole % 60) + (clamped - Double(whole))
        return String(format: "%02d:%02d:%05.2f", hours, minutes, secs)
    }

    static func runLoopSleep(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let nextTick = min(Date().addingTimeInterval(0.05), deadline)
            RunLoop.current.run(mode: .default, before: nextTick)
        }
    }

    static func installStopSignalHandlers() -> StopController {
        let stopController = StopController()

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interruptSource.setEventHandler {
            stopController.request("SIGINT")
        }
        interruptSource.resume()

        let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminateSource.setEventHandler {
            stopController.request("SIGTERM")
        }
        terminateSource.resume()

        stopController.retain(interruptSource)
        stopController.retain(terminateSource)
        return stopController
    }

    static func waitForStopRequest(seconds: TimeInterval?, stopController: StopController) {
        let deadline = seconds.map { Date().addingTimeInterval($0) }
        while true {
            let stop = stopController.snapshot()
            if stop.requested {
                return
            }

            if let deadline, Date() >= deadline {
                stopController.request("duration")
                return
            }

            let nextTick: Date
            if let deadline {
                nextTick = min(Date().addingTimeInterval(0.05), deadline)
            } else {
                nextTick = Date().addingTimeInterval(0.05)
            }
            RunLoop.current.run(mode: .default, before: nextTick)
        }
    }

    static func waitForRecordingToFinish(
        delegate: RecordingDelegate,
        timeoutSeconds: TimeInterval
    ) -> (finished: Bool, error: Error?) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let status = delegate.finishStatus()
            if status.finished {
                return status
            }

            let nextTick = min(Date().addingTimeInterval(0.05), deadline)
            RunLoop.current.run(mode: .default, before: nextTick)
        }

        return delegate.finishStatus()
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]

        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
            return String(bytes: bytes, encoding: .ascii) ?? String(code)
        }

        return String(code)
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func trim(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.3f", value)
    }
}

do {
    try AvcamCLI.run()
} catch let error as CLIError {
    fputs("error: \(error.description)\n", stderr)
    if case .usage = error {
        fputs("\n\(AvcamCLI.usage)\n", stderr)
    }
    exit(error.exitCode)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
