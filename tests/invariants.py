#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def check(name: str, condition: bool, detail: str) -> bool:
    if condition:
        print(f"ok - {name}")
        return True

    print(f"not ok - {name}")
    print(f"  {detail}")
    return False


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise AssertionError(f"missing function signature: {signature}")

    brace = source.find("{", start)
    if brace < 0:
        raise AssertionError(f"missing function body for: {signature}")

    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1 : index]

    raise AssertionError(f"unterminated function body for: {signature}")


def main() -> int:
    package = read("Package.swift")
    cli = read("Sources/AvcamCLI/CLIOptions.swift")
    recording = read("Sources/AvcamCLI/Recording.swift")
    preview = read("Sources/AvcamCLI/Preview.swift")
    av_notes = read("docs/avfoundation-notes.md")

    docs_and_examples = "\n".join(
        read(path)
        for path in [
            "README.md",
            "docs/usage.md",
            "docs/avfoundation-notes.md",
            "docs/troubleshooting.md",
            "docs/logitech-brio-100.md",
            "examples/list.sh",
            "examples/probe-brio-1080p30.sh",
            "examples/record-brio-1080p30-alac.sh",
        ]
    )

    preview_only_body = function_body(preview, "static func preview(")
    record_preview_body = function_body(preview, "static func recordWithPreview(")
    headless_record_body = function_body(recording, "static func record(")

    results = [
        check(
            "AppKit linked for preview UI",
            '.linkedFramework("AppKit"' in package and "import AppKit" in preview,
            "Package.swift must link AppKit and Preview.swift must import AppKit.",
        ),
        check(
            "preview layer uses the provided session",
            "AVCaptureVideoPreviewLayer(session: session)" in preview,
            "Preview must attach AVCaptureVideoPreviewLayer to the existing AVCaptureSession.",
        ),
        check(
            "preview-only creates exactly one capture session",
            preview_only_body.count("AVCaptureSession()") == 1,
            "preview command should own one session and no hidden second camera session.",
        ),
        check(
            "record-with-preview creates exactly one capture session",
            record_preview_body.count("AVCaptureSession()") == 1,
            "record --preview should share one session across movie output and preview layer.",
        ),
        check(
            "record-with-preview has both movie output and preview controller",
            "AVCaptureMovieFileOutput()" in record_preview_body
            and "PreviewWindowController(" in record_preview_body,
            "record --preview must combine AVCaptureMovieFileOutput with PreviewWindowController.",
        ),
        check(
            "headless record path stays AppKit-free",
            "PreviewWindowController" not in headless_record_body and "AppKit" not in recording,
            "plain record should remain a non-GUI automation path.",
        ),
        check(
            "Ctrl+C routes through StopController in GUI paths",
            preview.count("installStopSignalHandlers()") >= 2
            and "stopController.snapshot().requested" in preview,
            "preview and record --preview should use the shared StopController signal path.",
        ),
        check(
            "successful stopRecording delegate error is normalized",
            "AVErrorRecordingSuccessfullyFinishedKey" in recording
            and "recordingFailure(from: finish.error)" in preview,
            "AVFoundation may report a successful stop as an error object; both paths must normalize it.",
        ),
        check(
            "CLI exposes preview command and flag",
            'case "preview"' in cli
            and '"--preview"' in cli
            and "recordWithPreview(" in cli,
            "CLI dispatch must expose avcam-cli preview and avcam-cli record --preview.",
        ),
        check(
            "AVFoundation notes document one-session preview boundary",
            "Recording and preview use a single `AVCaptureSession`" in av_notes
            and "optional preview / record --preview" in av_notes,
            "Docs should preserve the one-session architecture invariant.",
        ),
        check(
            "SwiftPM is the only documented build path",
            "build.sh" not in docs_and_examples
            and docs_and_examples.count("swift build -c release") >= 2,
            "Docs/examples should not refer to the removed build.sh path.",
        ),
        check(
            "record output replacement remains documented",
            re.search(r"`--out` points to an existing file.*deletes that file", docs_and_examples),
            "Docs should warn that record replaces an existing --out target.",
        ),
    ]

    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
