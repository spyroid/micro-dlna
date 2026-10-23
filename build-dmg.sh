#!/bin/sh
set -eu

cd "$(dirname "$0")"
if [ -n "${NOTARY_PROFILE:-}" ] && [ "${SIGNING_IDENTITY:--}" = "-" ]; then
    echo 'Set SIGNING_IDENTITY before requesting notarization.' >&2
    exit 1
fi

# Keep submission reports for diagnostics, including rejected submissions.
notarize() {
    report="$PWD/.build/notarization/$(basename "$2").json"
    mkdir -p "$(dirname "$report")"
    if ! xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json > "$report"; then
        cat "$report" >&2
        return 1
    fi
    if [ "$(plutil -extract status raw -o - "$report")" != "Accepted" ]; then
        cat "$report" >&2
        return 1
    fi
    xcrun stapler staple "$2"
    xcrun stapler validate "$2"
}

./build-app.sh --arch arm64 --arch x86_64 "$@"

app_bundle="$PWD/.build/microDLNA.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Contents/Info.plist")
output_directory="$PWD/.build/releases/v$version"
staging_directory=$(mktemp -d "$PWD/.build/dmg-stage.XXXXXX")
trap 'rm -rf "$staging_directory"' EXIT

lipo "$app_bundle/Contents/MacOS/microdlna" -verify_arch arm64
lipo "$app_bundle/Contents/MacOS/microdlna" -verify_arch x86_64
mkdir -p "$output_directory"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    # Staple the app before packaging so it can also launch offline after installation.
    app_archive="$PWD/.build/notarization/microDLNA.zip"
    mkdir -p "$(dirname "$app_archive")"
    ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$app_archive"
    notarize "$app_archive" "$app_bundle"
    spctl --assess --type execute "$app_bundle"
fi
ditto "$app_bundle" "$staging_directory/microDLNA.app"
ln -s /Applications "$staging_directory/Applications"
image_path="$output_directory/microDLNA-$version.dmg"
hdiutil create -volname "μDLNA server" -srcfolder "$staging_directory" -format UDZO -ov "$image_path"
hdiutil verify "$image_path"
if [ "${SIGNING_IDENTITY:--}" != "-" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$image_path"
    codesign --verify --strict "$image_path"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
    notarize "$image_path" "$image_path"
fi
printf 'Disk image built: %s\n' "$image_path"
