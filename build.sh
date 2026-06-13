#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p .build/release

swiftc -O \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework CoreMedia \
  -framework CoreVideo \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker Sources/AvcamCLI/Info.plist \
  Sources/AvcamCLI/*.swift \
  -o .build/release/avcam-cli

echo ".build/release/avcam-cli"
