#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
check_directory=$(mktemp -d)
trap 'rm -rf "$check_directory"' EXIT
swiftc -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/microdlna-module-cache" \
    Tests/ReleaseRegression/main.swift -o "$check_directory/release-check"
"$check_directory/release-check"
