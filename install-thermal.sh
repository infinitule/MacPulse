#!/bin/zsh
# One-time root install for the MacPulse Thermal Governor.
# Run:  sudo zsh ~/MacPulse-src/install-thermal.sh
set -e
USERHOME=$(eval echo "~${SUDO_USER:-$USER}")
SRC="$USERHOME/MacPulse-src"
DIR="/Library/Application Support/MacPulse"
PLIST="/Library/LaunchDaemons/com.macpulse.thermal.plist"

echo "• building smc helper…"
/usr/bin/clang -O2 -framework IOKit -framework CoreFoundation "$SRC/smc.c" -o "$SRC/smc" 2>/dev/null || true

echo "• installing governor + helper into $DIR…"
mkdir -p "$DIR"
cp "$SRC/thermal.sh" "$DIR/thermal.sh"
[ -f "$SRC/smc" ] && cp "$SRC/smc" "$DIR/smc"
chown root:wheel "$DIR/thermal.sh" "$DIR/smc" 2>/dev/null || true
chmod 755 "$DIR/thermal.sh" "$DIR/smc" 2>/dev/null || true

echo "• installing launchd daemon…"
cp "$SRC/com.macpulse.thermal.plist" "$PLIST"
chown root:wheel "$PLIST"; chmod 644 "$PLIST"

echo "• (re)loading daemon…"
launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl kickstart -k system/com.macpulse.thermal 2>/dev/null || true

echo "• waiting for first thermal sample…"
sleep 3
if [ -f "$DIR/thermal.json" ]; then
  echo "──────── thermal.json ────────"
  cat "$DIR/thermal.json"
else
  echo "!! thermal.json not written yet — check $DIR/macpulse.log"
fi
