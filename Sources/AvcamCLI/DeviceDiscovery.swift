import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import Foundation

extension AvcamCLI {
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
}
