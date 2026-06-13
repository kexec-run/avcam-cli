#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release >/dev/null
.build/release/avcam-cli list
