import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import Foundation

extension AvcamCLI {
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
    static func trim(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.3f", value)
    }
}
