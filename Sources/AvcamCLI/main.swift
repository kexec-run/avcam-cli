import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import Foundation

struct AvcamCLI {}

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
