#!/bin/zsh
# MacPulse build — compiles the single-file SwiftUI app and assembles the
# bundle at ~/Applications/MacPulse.app. Needs Xcode command-line tools.
set -e
cd "$(dirname "$0")"

swiftc -O main.swift -o MacPulse
clang -O2 -framework IOKit -framework CoreFoundation smc.c -o smc   # SMC helper for the thermal governor

APP="$HOME/Applications/MacPulse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp MacPulse "$APP/Contents/MacOS/MacPulse"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns macpulse-core.sh guard-root.sh agent-root.sh thermal.sh smc "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh "$APP/Contents/Resources/smc"
codesign --force --deep -s - "$APP"

echo "Built $APP"
open "$APP"
