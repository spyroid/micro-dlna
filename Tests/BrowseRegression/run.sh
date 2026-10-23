#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
check_directory=$(mktemp -d)
trap 'rm -rf "$check_directory"' EXIT
swiftc -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/microdlna-module-cache" \
    Sources/MicroDLNA/Network.swift Sources/MicroDLNA/MediaIcon.swift Sources/MicroDLNA/MediaLibrary.swift \
    Sources/MicroDLNA/UPnP.swift Sources/MicroDLNA/HTTPServer.swift \
    Tests/BrowseRegression/main.swift -o "$check_directory/browse-check"
"$check_directory/browse-check"
