#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release >/dev/null
.build/release/avcam-cli probe \
  --camera "${AVCAM_CAMERA:-Brio}" \
  --format-index "${AVCAM_FORMAT_INDEX:-35}" \
  --fps "${AVCAM_FPS:-30}" \
  --seconds "${AVCAM_SECONDS:-10}" \
  --output-mode "${AVCAM_OUTPUT_MODE:-native}"
