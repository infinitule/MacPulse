#!/bin/zsh
# MacPulse core — invoked by MacPulse.app.
# Admin modes (deep / tune / guard-install / guard-remove) are executed as
# root via the app's GUI password prompt, so there is no sudo in here.
set -u
MODE="${1:-audit}"
SUPPORT_DIR="/Library/Application Support/MacPulse"
DAEMON_LABEL="com.macpulse.guard"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
AGENT_LABEL="com.macpulse.agent"
AGENT_PLIST="/Library/LaunchDaemons/${AGENT_LABEL}.plist"

line() { printf '%s\n' "------------------------------------------------------------"; }

audit() {
  line; echo "MACPULSE AUDIT — $(date)"; line

  echo; echo "[1] Battery health"
  system_profiler SPPowerDataType 2>/dev/null | \
    grep -E "Cycle Count|Condition|Maximum Capacity|Charging|Fully Charged|State of Charge" | sed 's/^ *//'

  echo; echo "[2] Current power source + charge"
  pmset -g batt | sed 's/^ *//'

  echo; echo "[3] Active pmset profile (battery)"
  pmset -g custom | sed -n '/Battery Power/,/AC Power/p' | sed 's/^ *//'

  echo; echo "[4] Memory pressure"
  memory_pressure 2>/dev/null | tail -3
  vm_stat | awk '
    /page size of/ {ps=$8}
    /Pages free/ {free=$3}
    /Pages active/ {act=$3}
    /Pages inactive/ {inact=$3}
    /Pages wired/ {wired=$4}
    /Pages occupied by compressor/ {comp=$5}
    END {
      gsub(/\./,"",free); gsub(/\./,"",act); gsub(/\./,"",inact);
      gsub(/\./,"",wired); gsub(/\./,"",comp);
      gb = ps/1073741824;
      printf "  free: %.2f GB | active: %.2f GB | inactive: %.2f GB | wired: %.2f GB | compressed: %.2f GB\n",
        free*gb, act*gb, inact*gb, wired*gb, comp*gb
    }'

  echo; echo "[5] Top 10 RAM consumers"
  ps axo rss,comm | sort -rn | head -10 | awk '{printf "  %6.0f MB  %s\n", $1/1024, $2}'

  echo; echo "[6] Top 10 CPU consumers (energy proxy)"
  ps axo %cpu,comm | sort -rn | head -10 | awk '{printf "  %5.1f%%  %s\n", $1, $2}'

  echo; echo "[7] Login items (auto-launch bloat)"
  osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null || \
    echo "  (grant MacPulse automation permission to list these)"

  echo; echo "[8] Swap usage"
  sysctl vm.swapusage | sed 's/^/  /'
  line
}

deep() {
  OUT="${2:?output path required}"
  {
    line; echo "MACPULSE DEEP SCAN — $(date)"; line
    echo; echo "== CPU =="
    sysctl -n machdep.cpu.brand_string 2>/dev/null
    sysctl hw.ncpu hw.memsize 2>/dev/null
    echo; echo "== GPU inventory =="
    system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Chipset Model|VRAM|Metal|Bus" | sed 's/^ *//'
    echo; echo "== Thermal state (CPU speed limits) =="
    pmset -g therm 2>/dev/null
    echo; echo "== Kernel power model: frequency, residency, package power =="
    powermetrics -n 1 -i 1000 2>/dev/null || echo "(default powermetrics sample unavailable)"
    echo; echo "== SMC: die temperature & fans =="
    powermetrics --samplers smc -n 1 -i 500 2>/dev/null || echo "(smc sampler unavailable on this model)"
    echo; echo "== Kernel per-process energy impact (top of table) =="
    powermetrics --samplers tasks -n 1 -i 1000 2>/dev/null | head -45 || echo "(tasks sampler unavailable)"
    echo; echo "== Kernel memory =="
    vm_stat
    sysctl vm.swapusage vm.loadavg 2>/dev/null
    sysctl kern.memorystatus_level 2>/dev/null
    line
  } > "$OUT" 2>&1
  chmod 644 "$OUT"
}

tune() {
  pmset -b powernap 0
  pmset -b displaysleep 5
  pmset -b disksleep 5
  pmset -b womp 0 2>/dev/null
  pmset -b proximitywake 0 2>/dev/null
  pmset -b standbydelaylow 900 2>/dev/null
  pmset -b standbydelayhigh 3600 2>/dev/null
  # Dual-GPU Intel MBP: integrated-only on battery is the biggest single win
  pmset -b gpuswitch 0 2>/dev/null
  echo "Applied (battery only): Power Nap off, wake-on-network off, display sleep 5 min, disk sleep 5 min, hibernate after 15 min (<50%) / 1 h asleep, integrated GPU on battery."
  echo ""
  echo "Revert all: sudo pmset restoredefaults"
  echo "External display on battery: sudo pmset -b gpuswitch 2"
}

guard_install() {
  SRC="${2:?guard source path required}"
  AGENT_SRC="${3:?agent source path required}"
  mkdir -p "$SUPPORT_DIR" "$SUPPORT_DIR/spool"
  cp "$SRC" "$SUPPORT_DIR/guard.sh"
  cp "$AGENT_SRC" "$SUPPORT_DIR/agent.sh"
  # Root-owned and non-user-writable: these scripts run as root
  chown root:wheel "$SUPPORT_DIR" "$SUPPORT_DIR/guard.sh" "$SUPPORT_DIR/agent.sh"
  chmod 755 "$SUPPORT_DIR" "$SUPPORT_DIR/guard.sh" "$SUPPORT_DIR/agent.sh"
  # Spool is world-writable (sticky) so the app can drop request files
  chown root:wheel "$SUPPORT_DIR/spool"
  chmod 1777 "$SUPPORT_DIR/spool"

  cat > "$DAEMON_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${DAEMON_LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>${SUPPORT_DIR}/guard.sh</string></array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>${SUPPORT_DIR}/macpulse.log</string>
</dict></plist>
PLIST
  chown root:wheel "$DAEMON_PLIST"
  chmod 644 "$DAEMON_PLIST"

  cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>${SUPPORT_DIR}/agent.sh</string></array>
  <key>WatchPaths</key>
  <array><string>${SUPPORT_DIR}/spool</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
  chown root:wheel "$AGENT_PLIST"
  chmod 644 "$AGENT_PLIST"

  launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null
  launchctl bootstrap system "$DAEMON_PLIST"
  launchctl bootout "system/${AGENT_LABEL}" 2>/dev/null
  launchctl bootstrap system "$AGENT_PLIST"
  echo "installed"
}

thermal_install() {
  # $2 = thermal.sh source, $3 = prebuilt smc binary source
  T_SRC="${2:?thermal source path required}"
  SMC_SRC="${3:?smc source path required}"
  T_LABEL="com.macpulse.thermal"
  T_PLIST="/Library/LaunchDaemons/${T_LABEL}.plist"
  mkdir -p "$SUPPORT_DIR"
  cp "$T_SRC" "$SUPPORT_DIR/thermal.sh"
  [ -f "$SMC_SRC" ] && cp "$SMC_SRC" "$SUPPORT_DIR/smc"
  chown root:wheel "$SUPPORT_DIR/thermal.sh" "$SUPPORT_DIR/smc" 2>/dev/null
  chmod 755 "$SUPPORT_DIR/thermal.sh" "$SUPPORT_DIR/smc" 2>/dev/null
  cat > "$T_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${T_LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>${SUPPORT_DIR}/thermal.sh</string></array>
  <key>StartInterval</key><integer>10</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
</dict></plist>
PLIST
  chown root:wheel "$T_PLIST"; chmod 644 "$T_PLIST"
  launchctl bootout "system/${T_LABEL}" 2>/dev/null
  launchctl bootstrap system "$T_PLIST"
  launchctl kickstart -k "system/${T_LABEL}" 2>/dev/null
  echo "thermal-installed"
}

guard_remove() {
  launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null
  launchctl bootout "system/${AGENT_LABEL}" 2>/dev/null
  rm -f "$DAEMON_PLIST" "$AGENT_PLIST"
  rm -rf "$SUPPORT_DIR"
  pmset -a lowpowermode 0 2>/dev/null
  echo "removed"
}

case "$MODE" in
  audit)         audit ;;
  deep)          deep "$@" ;;
  tune)          tune ;;
  guard-install) guard_install "$@" ;;
  guard-remove)  guard_remove ;;
  thermal-install) thermal_install "$@" ;;
  *) echo "Usage: $0 {audit|deep <out>|tune|guard-install <src>|guard-remove|thermal-install <thermal> <smc>}" ;;
esac
