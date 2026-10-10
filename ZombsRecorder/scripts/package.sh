#!/bin/bash
# Builds dist/ZombsRecorder.app (ad-hoc signed) and dist/ZombsRecorder.zip to send to friends.
set -euo pipefail
cd "$(dirname "$0")/.."
archs=()
for arch in arm64 x86_64; do
  if bash scripts/swift.sh build -c release --product ZombsRecorder --triple "$arch-apple-macosx14.0"; then
    archs+=("$arch")
  else
    echo "warning: no $arch build; the app will not run on Macs that need it" >&2
  fi
done
[[ ${#archs[@]} -gt 0 ]] || { echo "error: release build failed" >&2; exit 1; }
binaries=()
for arch in "${archs[@]}"; do binaries+=(".build/$arch-apple-macosx/release/ZombsRecorder"); done
app="$PWD/dist/ZombsRecorder.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/ZombsRecorder"
cp packaging/Info.plist "$app/Contents/Info.plist"
cp "packaging/Setup Guide.html" "$app/Contents/Resources/SetupGuide.html"  # Menu bar → Setup guide
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
rm -f dist/ZombsRecorder.zip
ditto -c -k --keepParent "$app" dist/ZombsRecorder.zip
printf 'Built %s (%s) and dist/ZombsRecorder.zip\n' "$app" "$(lipo -archs "$app/Contents/MacOS/ZombsRecorder")"
