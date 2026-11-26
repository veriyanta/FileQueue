#!/bin/zsh
# Runs the test suite. With only the Command Line Tools installed, SwiftPM doesn't find the
# Swift Testing macro plugin on its own, so point it there when it exists.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ -d "$PLUGINS" ]]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  swift test "$@"
fi
