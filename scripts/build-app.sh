#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/build/DevWatch.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/DevWatch" "$app_dir/Contents/MacOS/DevWatch"
cp Support/Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
printf 'App erstellt: %s\n' "$app_dir"
