# AVFoundation Notes

`avcam-cli` uses AVFoundation directly instead of FFmpeg's AVFoundation demuxer.

The core recording pipeline is:

```text
find AVCaptureDevice
create AVCaptureSession
add AVCaptureDeviceInput for camera
optionally add AVCaptureDeviceInput for microphone
add AVCaptureMovieFileOutput
configure movie output audio settings if requested
startRunning session
lock camera
set activeFormat
set activeVideoMinFrameDuration
set activeVideoMaxFrameDuration
unlock camera
startRecording to .mov
wait for duration or SIGINT/SIGTERM
stopRecording
wait for didFinishRecordingTo callback
stopRunning session
```

The probe pipeline is similar, but replaces `AVCaptureMovieFileOutput` with `AVCaptureVideoDataOutput` and counts delivered sample buffers.

## Chromium-Style Ordering

The working Brio path follows Chromium's practical ordering:

```text
configure explicit output width/height/pixel format
configure connection min/max frame duration when supported
startRunning session
apply activeFormat and frame durations
start recording or sample counting
```

This matters because setting the device format before the session is running produced misleading active-format state and approximately 24 fps delivery on the Brio 100. Applying format and frame duration after session start produced real 30 fps delivery in probe and recording tests.

## Frame Duration Pinning

AVFoundation expects these to be configured together while the device is locked:

```text
activeFormat
activeVideoMinFrameDuration
activeVideoMaxFrameDuration
```

The Brio 100 advertises nominal 30 fps as a precise Core Media time such as:

```text
1000000 / 30000030
```

The CLI uses the camera's advertised range duration rather than constructing an approximate `1/30` duration.

## One Session Owns Capture

Recording uses a single `AVCaptureSession`. If a preview mode is added later, it should attach an `AVCaptureVideoPreviewLayer` to the same session instead of opening a second camera session.

```text
AVCaptureSession
├── AVCaptureMovieFileOutput
└── AVCaptureVideoPreviewLayer  future optional preview
```

## Codec Boundary

Camera format FourCC and movie-file codec are separate layers.

Examples:

```text
Camera/sample format: 420v, yuvs, 2vuy
Movie video codec:    H.264 / avc1, possibly HEVC if reported available
Audio codec:          AAC, ALAC, PCM
```

Use `formats` to inspect camera formats and `codecs` to inspect movie-output codec availability.
