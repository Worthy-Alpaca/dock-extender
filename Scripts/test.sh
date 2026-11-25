#!/bin/bash
# Runs the tests. Extra arguments go to `swift test` (e.g. --filter Layout).
set -euo pipefail
cd "$(dirname "$0")/.."

# With only the Command Line Tools installed, the compiler does not find the
# macros of the Swift Testing library by itself. With Xcode it does.
flags=()
developer="$(xcode-select -p)"
if [[ "$developer" == */CommandLineTools ]]; then
    flags+=(-Xswiftc -plugin-path -Xswiftc "$developer/usr/lib/swift/host/plugins/testing")
fi

swift test ${flags[@]+"${flags[@]}"} "$@"
