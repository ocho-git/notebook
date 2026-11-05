#!/bin/bash
# Offscreen Mac Catalyst renderer. Does not launch an app, simulator or device.
set -euo pipefail
notebook_root="$(cd "$(dirname "$0")/.." && pwd)"
notebook_temp="$(mktemp -d "${TMPDIR:-/tmp}/notebook-render.XXXXXX")"
trap 'rm -rf "$notebook_temp"' EXIT
notebook_sdk="$(xcrun --sdk macosx --show-sdk-path)"
# Catalyst's AVFoundation overlay needs an explicit CoreAudio import in this CLI build.
{ echo 'import CoreAudio'; cat "$notebook_root/Sources/Notebook/BookSounds.swift"; } > "$notebook_temp/BookSounds.swift"
notebook_sources=()
for notebook_source in "$notebook_root"/Sources/Notebook/*.swift; do
    if [[ "$(basename "$notebook_source")" != BookSounds.swift ]]; then notebook_sources+=("$notebook_source"); fi
done
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-ios18.0-macabi" \
    -F "$notebook_sdk/System/iOSSupport/System/Library/Frameworks" \
    -I "$notebook_sdk/System/iOSSupport/usr/include" \
    -L "$notebook_sdk/System/iOSSupport/usr/lib" \
    "${notebook_sources[@]}" "$notebook_temp/BookSounds.swift" \
    "$notebook_root/scripts/render-examples.swift" -o "$notebook_temp/render-examples"
"$notebook_temp/render-examples" "$notebook_root/Documentation/Images"
