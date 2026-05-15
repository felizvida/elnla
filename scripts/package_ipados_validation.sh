#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

version="${1:-$(awk '/^version:/ {print $2}' pubspec.yaml | cut -d+ -f1)}"
dist_dir="dist/releases/v${version}"
zip_name="BenchVault-iPadOS-v${version}-unsigned-validation.zip"
checksum_name="SHA256SUMS-iPadOS-validation.txt"

flutter build ios --release --no-codesign

app_path="build/ios/iphoneos/BenchVault.app"
if [[ ! -d "$app_path" ]]; then
  app_path="build/ios/iphoneos/Runner.app"
fi
if [[ ! -d "$app_path" ]]; then
  echo "iPadOS validation app bundle was not found." >&2
  exit 1
fi

rm -rf "$dist_dir"
mkdir -p "$dist_dir"
ditto -c -k --keepParent "$app_path" "$dist_dir/$zip_name"
shasum -a 256 "$dist_dir/$zip_name" > "$dist_dir/$checksum_name"

echo "$dist_dir/$zip_name"
cat "$dist_dir/$checksum_name"
