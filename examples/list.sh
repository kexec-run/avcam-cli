#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
./build.sh >/dev/null
.build/release/avcam-cli list
