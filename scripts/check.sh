#!/bin/bash
set -euo pipefail
notebook_root="$(cd "$(dirname "$0")/.." && pwd)"
notebook_derived="${TMPDIR:-/tmp}/notebook-check-derived"
swift test --package-path "$notebook_root"
for notebook_destination in 'generic/platform=iOS' 'generic/platform=iOS Simulator'; do
    xcodebuild -project "$notebook_root/Demo/NotebookDemo.xcodeproj" \
        -scheme NotebookDemo -destination "$notebook_destination" \
        -derivedDataPath "$notebook_derived" CODE_SIGNING_ALLOWED=NO build
done
