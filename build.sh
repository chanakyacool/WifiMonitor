#!/bin/bash
# Builds "WiFi Monitor.app". Usage: ./build.sh [--install]   (--install moves it to /Applications, leaving no copy in build/)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/WiFi Monitor.app"
# The macOS 27 SDK turns @State into a macro whose plugin only ships with full Xcode.
# With Command Line Tools only, build against the newest SDK that still uses the classic wrapper.
if [ -z "${SDKROOT:-}" ] && [ ! -d /Applications/Xcode.app ]; then
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do [ -d "$sdk" ] && export SDKROOT="$sdk"; done
fi
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WiFiMonitor "$APP/Contents/MacOS/WiFiMonitor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/oui.tsv "$APP/Contents/Resources/"

codesign --force --deep --sign - "$APP"
echo "Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "WiFi Monitor"' 2>/dev/null || true
  rm -rf "/Applications/WiFi Monitor.app"
  cp -R "$APP" /Applications/
  rm -rf "$APP"   # keep only one copy of the app: the one in /Applications
  echo "Installed to /Applications/WiFi Monitor.app"
  open "/Applications/WiFi Monitor.app"
fi
