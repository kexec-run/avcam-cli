import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import Foundation

private enum PreviewMode {
    case previewOnly
    case recording
}

private final class CameraPreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        super.init(frame: .zero)
        wantsLayer = true
        layer = previewLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

private final class PreviewWindowController: NSObject, NSWindowDelegate {
    private let session: AVCaptureSession
    private let mode: PreviewMode
    private let stopController: StopController
    private let output: AVCaptureMovieFileOutput?
    private let delegate: RecordingDelegate?
    private let finalizeTimeout: TimeInterval
    private let seconds: TimeInterval?
    private let outURL: URL?
    private let verbose: Bool

    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var stopButton: NSButton?
    private var timer: Timer?
    private var deadline: Date?
    private var startedAt = Date()
    private var stopStarted: Date?
    private var isStopping = false
    private var resultError: Error?

    init(
        session: AVCaptureSession,
        mode: PreviewMode,
        stopController: StopController,
        output: AVCaptureMovieFileOutput? = nil,
        delegate: RecordingDelegate? = nil,
        finalizeTimeout: TimeInterval = 0,
        seconds: TimeInterval? = nil,
        outURL: URL? = nil,
        verbose: Bool
    ) {
        self.session = session
        self.mode = mode
        self.stopController = stopController
        self.output = output
        self.delegate = delegate
        self.finalizeTimeout = finalizeTimeout
        self.seconds = seconds
        self.outURL = outURL
        self.verbose = verbose
    }

    func show() {
        guard window == nil else {
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        showWindow()
        app.activate(ignoringOtherApps: true)
    }

    func run() throws {
        let app = NSApplication.shared
        show()
        startedAt = Date()
        deadline = seconds.map { Date().addingTimeInterval($0) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        app.run()

        timer?.invalidate()
        timer = nil

        if let resultError {
            throw resultError
        }
    }

    private func showWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = mode == .recording ? "avcam-cli Recording" : "avcam-cli Preview"
        window.center()
        window.delegate = self

        let content = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 960, height: 600))
        content.autoresizingMask = [.width, .height]

        let controlsHeight: CGFloat = 56
        let previewView = CameraPreviewView(session: session)
        previewView.frame = NSRect(
            x: 0,
            y: controlsHeight,
            width: content.bounds.width,
            height: content.bounds.height - controlsHeight
        )
        previewView.autoresizingMask = [.width, .height]
        content.addSubview(previewView)

        let buttonTitle = mode == .recording ? "Stop Recording" : "Stop Preview"
        let stopButton = NSButton(title: buttonTitle, target: self, action: #selector(stopButtonPressed))
        stopButton.frame = NSRect(x: 16, y: 13, width: 140, height: 30)
        content.addSubview(stopButton)

        let statusLabel = NSTextField(labelWithString: initialStatusText())
        statusLabel.frame = NSRect(x: 172, y: 15, width: content.bounds.width - 188, height: 24)
        statusLabel.autoresizingMask = [.width]
        statusLabel.lineBreakMode = .byTruncatingMiddle
        content.addSubview(statusLabel)

        window.contentView = content
        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.statusLabel = statusLabel
        self.stopButton = stopButton
    }

    private func initialStatusText() -> String {
        switch mode {
        case .previewOnly:
            return "Preview running"
        case .recording:
            if let outURL {
                return "Recording to \(outURL.path)"
            }
            return "Recording"
        }
    }

    @objc private func stopButtonPressed() {
        stopController.request(mode == .recording ? "button" : "preview button")
        beginStopIfNeeded()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stopController.request("window")
        beginStopIfNeeded()
        return false
    }

    private func tick() {
        if let deadline, Date() >= deadline {
            stopController.request("duration")
        }

        if stopController.snapshot().requested {
            beginStopIfNeeded()
        }

        if isStopping {
            pollStopCompletion()
        } else {
            updateRunningStatus()
        }
    }

    private func updateRunningStatus() {
        let elapsed = AvcamCLI.trim(Date().timeIntervalSince(startedAt))
        switch mode {
        case .previewOnly:
            statusLabel?.stringValue = "Preview running \(elapsed)s"
        case .recording:
            statusLabel?.stringValue = "Recording \(elapsed)s"
        }
    }

    private func beginStopIfNeeded() {
        guard !isStopping else {
            return
        }

        isStopping = true
        stopButton?.isEnabled = false

        switch mode {
        case .previewOnly:
            statusLabel?.stringValue = "Stopping preview"
            finishPreview()
        case .recording:
            stopStarted = Date()
            let reason = stopController.snapshot().reason
            statusLabel?.stringValue = "Finalizing recording"
            if verbose {
                print("Recording stop requested by \(reason); waiting up to \(AvcamCLI.trim(finalizeTimeout))s for MovieFileOutput to finish writing.")
            }
            output?.stopRecording()
        }
    }

    private func pollStopCompletion() {
        guard mode == .recording else {
            return
        }
        guard let delegate, let stopStarted else {
            resultError = CLIError.recordingFailed("Recording stopped before MovieFileOutput was available.")
            finishPreview()
            return
        }

        let finish = delegate.finishStatus()
        if finish.finished {
            session.stopRunning()
            if let error = AvcamCLI.recordingFailure(from: finish.error) {
                resultError = CLIError.recordingFailed("Recording failed: \(error.localizedDescription)")
            } else if verbose {
                print("Recording finished in \(AvcamCLI.trim(Date().timeIntervalSince(stopStarted)))s after stopRecording().")
            }
            finishPreview()
            return
        }

        if Date().timeIntervalSince(stopStarted) >= finalizeTimeout {
            session.stopRunning()
            resultError = CLIError.recordingFailed("Recording did not finish within \(AvcamCLI.trim(finalizeTimeout)) seconds after stopRecording(). AVFoundation did not deliver didFinishRecordingTo before timeout.")
            finishPreview()
        }
    }

    private func finishPreview() {
        session.stopRunning()
        timer?.invalidate()
        timer = nil
        window?.delegate = nil
        window?.close()

        let app = NSApplication.shared
        app.stop(nil)
        if let event = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            app.postEvent(event, atStart: false)
        }
    }
}

extension AvcamCLI {
    static func preview(
        device: AVCaptureDevice,
        width: Int,
        height: Int,
        fps: Double,
        subtype: String?,
        formatIndex: Int?,
        exposure: ExposureConfig,
        verbose: Bool
    ) throws {
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
        session.commitConfiguration()

        print("Selected camera: \(device.localizedName)")
        print("Selected format: [\(choice.index)] \(choice.dimensions.width)x\(choice.dimensions.height) \(fourCC(choice.subtype)) @ \(trim(choice.matchingRange.minFrameRate))-\(trim(choice.matchingRange.maxFrameRate)) fps")
        print("Pinned min frame duration: \(choice.matchingRange.minFrameDuration.value)/\(choice.matchingRange.minFrameDuration.timescale)")
        print("Pinned max frame duration: \(choice.matchingRange.maxFrameDuration.value)/\(choice.matchingRange.maxFrameDuration.timescale)")

        let stopController = installStopSignalHandlers()
        let controller = PreviewWindowController(
            session: session,
            mode: .previewOnly,
            stopController: stopController,
            verbose: verbose
        )
        controller.show()

        session.startRunning()
        guard session.isRunning else {
            throw CLIError.recordingFailed("AVCaptureSession did not start.")
        }

        if stopController.snapshot().requested {
            session.stopRunning()
            throw CLIError.recordingFailed("Preview stopped before capture started.")
        }

        try configure(device: device, choice: choice, fps: fps, exposure: exposure)

        if verbose {
            print("Active format after session start: \(formatSummary(device.activeFormat))")
            print("Active min frame duration: \(device.activeVideoMinFrameDuration.value)/\(device.activeVideoMinFrameDuration.timescale)")
            print("Active max frame duration: \(device.activeVideoMaxFrameDuration.value)/\(device.activeVideoMaxFrameDuration.timescale)")
        }

        try controller.run()
    }

    static func recordWithPreview(
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
        let controller = PreviewWindowController(
            session: session,
            mode: .recording,
            stopController: stopController,
            output: output,
            delegate: delegate,
            finalizeTimeout: finalizeTimeout,
            seconds: seconds,
            outURL: outURL,
            verbose: verbose
        )
        controller.show()

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

        try controller.run()

        print("Finished recording: \(outURL.path)")
        print("Inspect with: ffprobe -v error -show_entries stream=index,codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,pix_fmt,duration,sample_rate,channels -of default=nw=1 \(shellQuote(outURL.path))")
    }
}
