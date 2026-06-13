# Usage

Build first:

```bash
./build.sh
```

Run from the repository root:

```bash
.build/release/avcam-cli <command> [options]
```

## Commands

### List Devices

```bash
.build/release/avcam-cli list
```

Lists video and audio capture devices visible to AVFoundation.

### List Camera Formats

```bash
.build/release/avcam-cli formats --camera "Brio"
```

Prints each `AVCaptureDevice.Format` with a stable format index, dimensions, FourCC subtype, and supported frame-rate ranges.

Use the format index in later probe or record commands:

```bash
.build/release/avcam-cli record --camera "Brio" --format-index 35 --fps 30 --out brio.mov
```

### Check Available Movie Codecs

```bash
.build/release/avcam-cli codecs --camera "Brio" --format-index 35 --fps 30
```

Prints the video codec types that `AVCaptureMovieFileOutput` reports for the selected output path/file type.

### Probe Capture Timing

```bash
.build/release/avcam-cli probe --camera "Brio" --format-index 35 --fps 30 --seconds 10 --output-mode native
```

Probe uses `AVCaptureVideoDataOutput` and prints detailed diagnostics:

- selected camera and active format
- output pixel format request
- connection frame durations
- delivered sample format
- sample duration and PTS timeline
- delivered frame count and measured fps
- dropped-frame callback count

Output modes:

```text
native  request the selected format's native pixel format
nv12    request 420v / video-range NV12
```

### Record Video

Open-ended recording:

```bash
.build/release/avcam-cli record --camera "Brio" --format-index 35 --fps 30 --out brio-1080p30.mov
```

Duration-limited recording:

```bash
.build/release/avcam-cli record --camera "Brio" --format-index 35 --fps 30 --seconds 10 --out brio-1080p30.mov
```

Record video plus Brio microphone audio using ALAC:

```bash
.build/release/avcam-cli record --camera "Brio" --audio "Brio" --audio-codec alac --format-index 35 --fps 30 --out brio-1080p30-alac.mov
```

If `--out` points to an existing file, `avcam-cli` deletes that file before starting the new recording. Use a fresh output path when you need to preserve a previous take.
Supported audio codec options:

```text
aac
alac
pcm
```

Use `--finalize-timeout` to control how long the CLI waits for AVFoundation's file-finalization callback after stop:

```bash
.build/release/avcam-cli record --camera "Brio" --format-index 35 --fps 30 --seconds 10 --finalize-timeout 10 --out brio.mov
```

Use `--verbose` for session and connection diagnostics during record:

```bash
.build/release/avcam-cli record --camera "Brio" --format-index 35 --fps 30 --seconds 10 --out brio.mov --verbose
```

## Format Selection

You can select by exact format index:

```bash
--format-index 35
```

Or by width, height, fps, and optional subtype:

```bash
--width 1920 --height 1080 --fps 30
--width 1920 --height 1080 --fps 30 --subtype 420v
```

The implementation pins `activeFormat`, `activeVideoMinFrameDuration`, and `activeVideoMaxFrameDuration` together. Requested fps is matched to the nearest supported frame-rate neighbor rather than relying on a fragile exact decimal comparison.

## Exit Codes

```text
0  success
1  usage error
2  permission or device lookup error
3  format/session setup error
4  recording/probe runtime error
```
