# Troubleshooting

## macOS Camera or Microphone Permission

If AVFoundation cannot open the device, grant camera and microphone access to the terminal app that launches `avcam-cli`.

Common terminals:

```text
Terminal.app
Kitty
iTerm2
Codex or another wrapper process, if it directly launches the binary
```

After permission changes, restart the terminal process.

## Find the Brio Format Index

```bash
.build/release/avcam-cli formats --camera "Brio"
```

For the tested Brio 100, `1920x1080 420v @ 30 fps` was format index `35`.

Do not assume that index is universal across macOS releases or camera firmware. Re-run `formats` on a new machine.

## Probe Before Recording

```bash
.build/release/avcam-cli probe --camera "Brio" --format-index 35 --fps 30 --seconds 10 --output-mode native
```

A healthy 30 fps result should show approximately:

```text
First sample duration: 1000/30000 (0.033s)
Frame interval avg seconds: 0.033
Probe media fps: 29.9...
```

If you see `0.042s` sample durations and about 24 fps, check that you are using the current Chromium-style ordering build.

## FFmpeg AVFoundation Comparison

FFmpeg may select raw UYVY and report a synthetic `1000k tbr` while only delivering about 5 fps:

```bash
ffmpeg -hide_banner -f avfoundation -framerate 30 -video_size 1920x1080 -i "0:none" -t 10 -f null -
```

This tool exists because native AVFoundation can make different format and timing choices than FFmpeg's demuxer path.

## File Finalization

On stop, the CLI calls `stopRecording()` and waits for `fileOutput(_:didFinishRecordingTo:from:error:)`.

If finalization times out, the media file may exist but should be treated as suspect:

```text
error: Recording did not finish within ... seconds after stopRecording()
```

Increase timeout for slow storage or large files:

```bash
.build/release/avcam-cli record --camera "Brio" --format-index 35 --fps 30 --finalize-timeout 10 --out out.mov
```

## Inspect Output

```bash
ffprobe -v error -show_entries stream=index,codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,pix_fmt,duration,sample_rate,channels -of default=nw=1 out.mov
```

For Brio 1080p30 ALAC, expect H.264 video at 30/1 and ALAC audio at 48 kHz mono when using `AVCaptureMovieFileOutput` defaults plus `--audio-codec alac`.
