#!/bin/bash
# Builds an optimized binary and wraps it in build/DockExtender.app.
# With --install, also replaces the copy in /Applications and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/DockExtender.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/DockExtender" "$APP/Contents/MacOS/DockExtender"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run locally and to register as a login item.
codesign --force --sign - "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    INSTALLED="/Applications/DockExtender.app"
    pkill -x DockExtender || true
    rm -rf "$INSTALLED"
    ditto "$APP" "$INSTALLED"
    open "$INSTALLED"
    echo "Installed and launched $INSTALLED"
fi
