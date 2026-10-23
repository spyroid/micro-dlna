#!/bin/sh
set -eu

cd "$(dirname "$0")"
signing_identity="${SIGNING_IDENTITY:--}"
case "$signing_identity" in
    -|"Developer ID Application: "*) ;;
    *) echo 'SIGNING_IDENTITY must be a full Developer ID Application certificate name.' >&2; exit 1 ;;
esac
swift build -c release "$@"
binary_directory=$(swift build -c release "$@" --show-bin-path)
app_bundle="$PWD/.build/microDLNA.app"
sparkle_directory="$PWD/.build/artifacts/sparkle/Sparkle"

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Frameworks" "$app_bundle/Contents/Resources/Licenses"
cp "$binary_directory/microdlna" "$app_bundle/Contents/MacOS/microdlna"
cp App/Info.plist "$app_bundle/Contents/Info.plist"
cp App/Assets/AppIcon.icns App/Assets/MenuBarIcon.png App/Assets/MenuBarIcon@2x.png "$app_bundle/Contents/Resources/"
# Preserve Sparkle's framework symlinks and helper executables.
rm -rf "$app_bundle/Contents/Frameworks/Sparkle.framework"
ditto "$sparkle_directory/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app_bundle/Contents/Frameworks/Sparkle.framework"
cp "$sparkle_directory/LICENSE" "$app_bundle/Contents/Resources/Licenses/Sparkle.txt"
cp LICENSE "$app_bundle/Contents/Resources/Licenses/microDLNA.txt"
if [ "$signing_identity" = "-" ]; then
    # Local builds still work without an Apple Developer account.
    codesign --force --sign - "$app_bundle"
else
    # Sign nested code first; all components must use our team for library validation.
    sparkle_framework="$app_bundle/Contents/Frameworks/Sparkle.framework"
    for component in XPCServices/Installer.xpc Autoupdate Updater.app; do
        codesign --force --sign "$signing_identity" --options runtime --timestamp \
            "$sparkle_framework/Versions/B/$component"
    done
    codesign --force --sign "$signing_identity" --options runtime --timestamp \
        --preserve-metadata=entitlements "$sparkle_framework/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --sign "$signing_identity" --options runtime --timestamp "$sparkle_framework"
    codesign --force --sign "$signing_identity" --options runtime --timestamp "$app_bundle"
fi
codesign --verify --deep --strict "$app_bundle"
printf 'Application built: %s\n' "$app_bundle"
