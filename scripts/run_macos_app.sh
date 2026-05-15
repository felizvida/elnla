#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export BENCHVAULT_PROJECT_ROOT="$PWD"
if [[ "${1:-}" == "--demo" ]]; then
  export BENCHVAULT_DEMO_MODE=1
fi

app="build/macos/Build/Products/Release/BenchVault.app/Contents/MacOS/BenchVault"
if [[ ! -x "$app" ]]; then
  flutter build macos
fi

exec "$app"
