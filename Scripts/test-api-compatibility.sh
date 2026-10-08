#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/nowen-api-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

cd "$project_dir"
xcrun swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "${TMPDIR:-/tmp}/nowen-reader-swift-module-cache" \
    Core/Services/ReaderWarmupSession.swift \
    Core/Services/OfflineFileManager.swift \
    Core/Extensions/AppLogger.swift \
    Models/Comic.swift Models/ComicGroup.swift \
    Tests/APICompatibilityTests.swift \
    -o "$test_dir/api-compatibility-tests"
"$test_dir/api-compatibility-tests"
