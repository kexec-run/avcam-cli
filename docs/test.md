# Tests

Run the current invariant test with:

```bash
python3 tests/invariants.py
```

This is a static source/docs test. It does not build the package, open AppKit windows, touch camera or microphone permissions, start an `AVCaptureSession`, or record media.

The test currently guards project invariants around:

- AppKit linkage for preview UI
- `AVCaptureVideoPreviewLayer` using the provided session
- one capture session per preview or `record --preview` flow
- headless `record` staying AppKit-free
- `Ctrl+C` routing through `StopController`
- successful `stopRecording` delegate errors being normalized
- CLI exposure of `preview` and `record --preview`
- documentation for one-session preview architecture
- SwiftPM being the documented build path
- `--out` replacement behavior being documented

