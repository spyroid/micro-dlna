#!/bin/sh
set -eu

cd "$(dirname "$0")"
./build-dmg.sh "$@"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)
release_directory="$PWD/.build/releases/v$version"

# Sign both the archive and the update feed using the key held in macOS Keychain.
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --account local.microdlna \
    --maximum-versions 1 --maximum-deltas 0 \
    --download-url-prefix "https://github.com/spyroid/micro-dlna/releases/download/v$version/" \
    --link "https://github.com/spyroid/micro-dlna" \
    "$release_directory"
.build/artifacts/sparkle/Sparkle/bin/sign_update \
    --verify --account local.microdlna "$release_directory/appcast.xml"
printf 'Upload the DMG and appcast.xml from %s to GitHub Release v%s.\n' "$release_directory" "$version"
