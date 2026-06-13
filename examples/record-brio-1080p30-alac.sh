#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
./build.sh >/dev/null

OUT="${1:-brio-1080p30-alac.mov}"

.build/release/avcam-cli record \
  --camera "${AVCAM_CAMERA:-Brio}" \
  --audio "${AVCAM_AUDIO:-Brio}" \
  --audio-codec "${AVCAM_AUDIO_CODEC:-alac}" \
  --format-index "${AVCAM_FORMAT_INDEX:-35}" \
  --fps "${AVCAM_FPS:-30}" \
  --finalize-timeout "${AVCAM_FINALIZE_TIMEOUT:-5}" \
  --out "${OUT}"
