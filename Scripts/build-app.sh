#!/bin/bash
# Builds an optimized binary and wraps it in build/DockExtender.app.
# With --install, also replaces the copy in /Applications and relaunches it.
# With APP_VERSION set (1.2.0 or v1.2.0), the app carries that version
# instead of the one in Resources/Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/DockExtender.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/DockExtender" "$APP/Contents/MacOS/DockExtender"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${APP_VERSION:-}" ]]; then
    for key in CFBundleShortVersionString CFBundleVersion; do
        /usr/libexec/PlistBuddy -c "Set :$key ${APP_VERSION#v}" "$APP/Contents/Info.plist"
    done
fi

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
