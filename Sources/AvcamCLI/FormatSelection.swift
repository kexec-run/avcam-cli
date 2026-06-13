import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import Foundation

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

extension AvcamCLI {
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
}
