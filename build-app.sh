#!/bin/sh
set -eu

cd "$(dirname "$0")"
swift build -c release "$@"
binary_directory=$(swift build -c release "$@" --show-bin-path)
app_bundle="$PWD/.build/microDLNA.app"
sparkle_directory="$PWD/.build/artifacts/sparkle/Sparkle"

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Frameworks" "$app_bundle/Contents/Resources/Licenses"
cp "$binary_directory/microdlna" "$app_bundle/Contents/MacOS/microdlna"
cp App/Info.plist "$app_bundle/Contents/Info.plist"
cp App/Assets/AppIcon.icns App/Assets/MenuBarIcon.png App/Assets/MenuBarIcon@2x.png "$app_bundle/Contents/Resources/"
# Preserve Sparkle's framework symlinks, helper executables, and vendor signatures.
rm -rf "$app_bundle/Contents/Frameworks/Sparkle.framework"
ditto "$sparkle_directory/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app_bundle/Contents/Frameworks/Sparkle.framework"
cp "$sparkle_directory/LICENSE" "$app_bundle/Contents/Resources/Licenses/Sparkle.txt"
cp LICENSE "$app_bundle/Contents/Resources/Licenses/microDLNA.txt"
# An ad-hoc signature supports local distribution without an Apple Developer account.
codesign --force --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
printf 'Application built: %s\n' "$app_bundle"
