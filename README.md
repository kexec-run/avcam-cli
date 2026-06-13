# avcam-cli

Native macOS AVFoundation camera recorder and probe tool.

`avcam-cli` bypasses FFmpeg's `-f avfoundation` demuxer and talks to Apple's capture APIs directly. It can list cameras, inspect camera formats, probe actual delivered frame timing, and record QuickTime `.mov` files using `AVCaptureSession` and `AVCaptureMovieFileOutput`.

The first target device is Logitech Brio 100 at `1920x1080@30`, where Chromium/WebRTC can capture real 30 fps but FFmpeg's AVFoundation path may fall back to slow raw UYVY behavior.

## Requirements

- macOS 13 or newer
- Xcode command line tools with Swift 5.10-compatible toolchain
- Camera and microphone permission for the built binary or terminal app
- Optional: `ffprobe` / `mediainfo` for inspecting output files

## Build

```bash
./build.sh
```

The binary is written to:

```text
.build/release/avcam-cli
```

You can also use Swift Package Manager directly:

```bash
swift build -c release
```

## Quick Start

```bash
.build/release/avcam-cli list
.build/release/avcam-cli formats --camera "Brio"
.build/release/avcam-cli probe --camera "Brio" --format-index 35 --fps 30 --seconds 10 --output-mode native
.build/release/avcam-cli record --camera "Brio" --audio "Brio" --audio-codec alac --format-index 35 --fps 30 --out brio-1080p30-alac.mov
```

Stop an open-ended recording with `Ctrl+C`. The tool catches `SIGINT`, asks `AVCaptureMovieFileOutput` to stop recording, and waits for the file-finalization callback.

## Documentation

- [Usage](docs/usage.md)
- [AVFoundation notes](docs/avfoundation-notes.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Logitech Brio 100 notes](docs/logitech-brio-100.md)

## Examples

```bash
examples/list.sh
examples/probe-brio-1080p30.sh
examples/record-brio-1080p30-alac.sh
```

## Status

This is a practical debug recorder. The stable path is headless recording through `AVCaptureMovieFileOutput`. Probe mode intentionally prints verbose timing and format details so capture behavior can be compared with Chromium and FFmpeg.
