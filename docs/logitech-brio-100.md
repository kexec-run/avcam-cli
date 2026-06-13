# Logitech Brio 100 Notes

Observed device identity on macOS:

```text
localizedName: Brio 100
modelID: UVC Camera VendorID_1133 ProductID_2380
deviceType: AVCaptureDeviceTypeExternal
```

The tested camera exposed no MJPEG camera format through AVFoundation. The useful high-resolution format was NV12 video-range:

```text
[35] 1920x1080 420v
    fps: 30, 24, 20, 15, 10, 7.5, 5
```

It also exposed a raw-looking 1080p `yuvs` format, but only at 5 fps:

```text
[36] 1920x1080 yuvs
    fps: 5
```

## Working 1080p30 Probe

```bash
.build/release/avcam-cli probe --camera "Brio" --format-index 35 --fps 30 --seconds 10 --output-mode native
```

The working path delivered approximately 30 fps with sample duration near `0.033s`.

## Working 1080p30 ALAC Record

```bash
.build/release/avcam-cli record --camera "Brio" --audio "Brio" --audio-codec alac --format-index 35 --fps 30 --out brio-1080p30-alac.mov
```

Stop with `Ctrl+C` for open-ended recording.

## Linux Control Comparison

On Linux, equivalent camera stability often depends on V4L2 controls such as power-line frequency and exposure dynamic framerate. macOS AVFoundation does not expose the same UVC controls through this CLI. The macOS fix here is format/timing/session ordering, not Linux-style V4L2 control writes.
