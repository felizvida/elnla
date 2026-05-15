#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

dart format --set-exit-if-changed lib test tool
flutter test
flutter analyze
flutter build macos
git diff --check

home_path_pattern='/'"Users"'/'
private_path_pattern='/'"private"'/'
scan_pattern="${home_path_pattern}|${private_path_pattern}|LABARCHIVES_GOV_(LOGIN_ID|ACCESS_KEY)=[A-Za-z0-9_+/=-]{20,}|OPENAI_API_KEY=sk-[A-Za-z0-9_-]+|[A-Za-z0-9._%+-]+@nih\\.gov"

rg -n "$scan_pattern" \
  .github .gitignore README.md docs lib scripts test tool pubspec.yaml && {
    echo "Secret or absolute-path scan found a match." >&2
    exit 1
  }

if [[ -f docs/user/BenchVault_Quickstart.pdf ]]; then
  strings docs/user/BenchVault_Quickstart.pdf | \
    rg -n "$scan_pattern" && {
      echo "Quickstart PDF scan found a match." >&2
      exit 1
    }
fi

python3 scripts/labarchives_seed_bio_test_notebook.py --dry-run

echo "BenchVault release smoke check passed."
