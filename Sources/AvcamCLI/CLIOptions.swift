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

extension AvcamCLI {
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
    static func exposureConfig(options: Options) throws -> ExposureConfig {
        ExposureConfig(
            mode: try options.string("exposure-mode", default: "auto").lowercased(),
            maxExposureFPS: try options.optionalDouble("max-exposure-fps"),
            exposureDuration: try options.optionalDouble("exposure-duration"),
            iso: try options.optionalDouble("iso"),
            disableLowLightBoost: try options.string("disable-low-light-boost", default: "true").lowercased() != "false"
        )
    }
}
