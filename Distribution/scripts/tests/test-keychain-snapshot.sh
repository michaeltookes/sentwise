#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Swift scripts have top-level entry points, so combine them into one source
# file and disable the production CLI while running the fixture tests.
cat "$SCRIPT_DIR/../keychain-snapshot.swift" "$SCRIPT_DIR/KeychainSnapshotTests.swift" > "$TEST_DIR/tests.swift"
PLATFORM_PATH=$(xcrun --show-sdk-platform-path)
xcrun swift -F "$PLATFORM_PATH/Developer/Library/Frameworks" \
  -I "$PLATFORM_PATH/Developer/usr/lib" \
  -L "$PLATFORM_PATH/Developer/usr/lib" -lXCTestSwiftSupport \
  -D KEYCHAIN_SNAPSHOT_TESTING "$TEST_DIR/tests.swift"
