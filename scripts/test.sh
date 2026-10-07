#!/bin/sh
# Runs the test suite. With Command Line Tools, SwiftPM's explicit-module dependency scan intermittently
# drops the swift-testing macro plugin ("plugin for module 'TestingMacros' not found"), so load it explicitly.
set -eu
cd "$(dirname "$0")/.."

PLUGIN="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$PLUGIN" ]; then
    exec swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
fi
exec swift test "$@"
