#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

version="${1:-$(awk '/^version:/ {print $2}' pubspec.yaml | cut -d+ -f1)}"
app_path="build/macos/Build/Products/Release/BenchVault.app"
dist_dir="dist/releases/v${version}"
zip_name="BenchVault-macOS-v${version}-prerelease.zip"

flutter build macos

rm -rf "$dist_dir"
mkdir -p "$dist_dir"
ditto -c -k --keepParent "$app_path" "$dist_dir/$zip_name"
shasum -a 256 "$dist_dir/$zip_name" > "$dist_dir/SHA256SUMS.txt"

echo "$dist_dir/$zip_name"
cat "$dist_dir/SHA256SUMS.txt"
