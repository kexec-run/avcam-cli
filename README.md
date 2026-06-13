# avcam-cli

avcam-cli is a small native macOS AVFoundation webcam recorder.

It was built to solve a specific problem: FFmpeg's AVFoundation input can negotiate poor webcam formats or frame rates on macOS. This tool uses AVFoundation directly, lets you select the camera format and fps explicitly, and records to `.mov` through `AVCaptureMovieFileOutput`.

The current recording path is manually tested on Logitech Brio 100 with Brio audio: `1920x1080` `420v`/NV12 at 30 fps, H.264 video, and ALAC audio.

This is a working reference implementation for one tested capture path, not a universal camera compatibility layer.

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
```

Use the printed format table to choose a format index. For example, on the tested Brio 100, the `1920x1080 420v` 30 fps format was index `35`, so later commands use `--format-index 35`. Re-run `formats` on each machine instead of assuming the index is universal.

```bash
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
