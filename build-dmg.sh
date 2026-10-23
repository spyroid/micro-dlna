#!/bin/sh
set -eu

cd "$(dirname "$0")"
./build-app.sh --arch arm64 --arch x86_64 "$@"

app_bundle="$PWD/.build/microDLNA.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Contents/Info.plist")
output_directory="$PWD/.build/releases/v$version"
staging_directory=$(mktemp -d "$PWD/.build/dmg-stage.XXXXXX")
trap 'rm -rf "$staging_directory"' EXIT

lipo "$app_bundle/Contents/MacOS/microdlna" -verify_arch arm64
lipo "$app_bundle/Contents/MacOS/microdlna" -verify_arch x86_64
mkdir -p "$output_directory"
ditto "$app_bundle" "$staging_directory/microDLNA.app"
ln -s /Applications "$staging_directory/Applications"
image_path="$output_directory/microDLNA-$version.dmg"
hdiutil create -volname "μDLNA server" -srcfolder "$staging_directory" -format UDZO -ov "$image_path"
hdiutil verify "$image_path"
printf 'Disk image built: %s\n' "$image_path"
