#!/bin/sh
set -eu

cd "$(dirname "$0")"
if [ "${SIGNING_IDENTITY:--}" != "-" ] && [ -z "${NOTARY_PROFILE:-}" ]; then
    echo 'Set NOTARY_PROFILE to notarize a Developer ID release before signing its appcast.' >&2
    exit 1
fi
./build-dmg.sh "$@"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)
release_directory="$PWD/.build/releases/v$version"

# Keep the public name in new feeds instead of deriving it from the ASCII app filename.
if [ ! -f "$release_directory/appcast.xml" ]; then
    cat > "$release_directory/appcast.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel><title>μDLNA server</title></channel>
</rss>
XML
fi

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
