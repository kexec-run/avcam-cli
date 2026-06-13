import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import Foundation

extension AvcamCLI {
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
}
