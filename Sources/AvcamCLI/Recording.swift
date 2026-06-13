import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import Foundation

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

extension AvcamCLI {
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
        if let error = recordingFailure(from: finish.error) {
            throw CLIError.recordingFailed("Recording failed: \(error.localizedDescription)")
        }
        if verbose {
            print("Recording finished in \(trim(Date().timeIntervalSince(stopStarted)))s after stopRecording().")
        }
        print("Finished recording: \(outURL.path)")
        print("Inspect with: ffprobe -v error -show_entries stream=index,codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,pix_fmt,duration,sample_rate,channels -of default=nw=1 \(shellQuote(outURL.path))")
    }
    static func outputURL(for path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
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

    static func recordingFailure(from error: Error?) -> Error? {
        guard let error else {
            return nil
        }

        let nsError = error as NSError
        if let finished = nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool, finished {
            return nil
        }
        return error
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
