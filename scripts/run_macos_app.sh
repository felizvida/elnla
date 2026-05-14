#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export ELNLA_PROJECT_ROOT="$PWD"

app="build/macos/Build/Products/Release/elnla.app/Contents/MacOS/elnla"
if [[ ! -x "$app" ]]; then
  flutter build macos
fi

exec "$app"
