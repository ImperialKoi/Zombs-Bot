#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift.sh build -c release
app="$PWD/dist/ZombsAssistant.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/ZombsAssistant "$app/Contents/MacOS/ZombsAssistant"
rm -rf "$app/Contents/Resources/ZombsAssistant_ZombsAssistant.bundle"  # Earlier builds bundled items.json.
cp packaging/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
