#!/bin/zsh
# MacPulse Thermal Governor — multi-band, T2-honest.
#
# WHY THIS SHAPE: On MacBookPro15,1 the T2 owns the fan controller and refuses
# user-space SMC fan writes (proven: Intel-side AppleSMC returns 0 for every
# fan/temp value while metadata reads fine). Fans already run near max under
# load. So the only real cooling lever is REDUCING the iGPU/compositing load
# that heats the shared die — not pushing air. This governor therefore does
# detection + honest telemetry + advice; the app self-limits its own glass,
# and the user acts on the named heat source. No surprise process killing.
#
# Launched one-shot by launchd every ~10 s (StartInterval). State (prev band,
# for hysteresis) persists in a file between launches. Cheap: one powermetrics
# smc sample (~0.15 s) + a ps snapshot. Writes thermal.json atomically.
#
# Bands (primary = CPU die °C; fallback = machdep.xcpm.cpu_thermal_level):
#   0 COOL   <62°C   (<95 level)     nothing
#   1 WARM  62-72°C  (95-108)        app may slow its poll
#   2 HOT   72-80°C  (108-118)       app drops to cheap opaque glass; advise
#   3 CRIT   >80°C   (>118)          throttle imminent/active; alert + name hog
# Hysteresis: step DOWN a band only when temp falls 3°C below its lower edge.

DIR="${MACPULSE_DIR:-/Library/Application Support/MacPulse}"   # override for self-test
OUT="$DIR/thermal.json"
BANDF="$DIR/thermal.band"
LOG="$DIR/macpulse.log"
log() { echo "$(date '+%F %T') THERMAL $1" >> "$LOG"; }

# ---- cheap signals (no powermetrics needed) ----
LEVEL=$(sysctl -n machdep.xcpm.cpu_thermal_level 2>/dev/null); LEVEL=${LEVEL:-0}
GLEVEL=$(sysctl -n machdep.xcpm.gpu_thermal_level 2>/dev/null); GLEVEL=${GLEVEL:-0}
THERM=$(pmset -g therm 2>/dev/null)
SPEED=$(print -r -- "$THERM" | awk -F'= *' '/CPU_Speed_Limit/{print $2+0}'); SPEED=${SPEED:-100}
SCHED=$(print -r -- "$THERM" | awk -F'= *' '/CPU_Scheduler_Limit/{print $2+0}'); SCHED=${SCHED:-100}
SRC="ac"; pmset -g batt 2>/dev/null | grep -q "'Battery Power'" && SRC="batt"

# ---- real °C + fan RPM (root powermetrics; the T2-blessed path) ----
CPUC=0; GPUC=0; RPM=0
PM=$(powermetrics --samplers smc -n1 -i150 2>/dev/null)
if [[ -n "$PM" ]]; then
  CPUC=$(print -r -- "$PM" | awk -F': *' '/CPU die temperature/{print $2+0; exit}')
  GPUC=$(print -r -- "$PM" | awk -F': *' '/GPU die temperature/{print $2+0; exit}')
  RPM=$(print -r -- "$PM"  | awk -F': *' '/^Fan:/{print $2+0; exit}')
fi
CPUC=${CPUC:-0}; GPUC=${GPUC:-0}; RPM=${RPM:-0}

# ---- top energy/heat source (cheap ps proxy) ----
read -r HPID HCPU HNAME <<< "$(ps -Aceo pid,%cpu,comm -r 2>/dev/null | awk 'NR==2{print $1, $2, $3}')"
HPID=${HPID:-0}; HCPU=${HCPU:-0}; HNAME=${HNAME:-unknown}

# ---- band from °C (fallback to thermal_level) ----
band_from_temp() { local t=$1
  if   (( t >= 80 )); then echo 3
  elif (( t >= 72 )); then echo 2
  elif (( t >= 62 )); then echo 1
  else echo 0; fi; }
band_from_level() { local l=$1
  if   (( l >= 118 )); then echo 3
  elif (( l >= 108 )); then echo 2
  elif (( l >= 95  )); then echo 1
  else echo 0; fi; }
if (( CPUC > 0 )); then RAWBAND=$(band_from_temp $CPUC); METRIC="degC"
else RAWBAND=$(band_from_level $LEVEL); METRIC="level"; fi

# ---- hysteresis: don't drop a band until 3°C under its lower edge ----
PREV=$(cat "$BANDF" 2>/dev/null); PREV=${PREV:-0}
BAND=$RAWBAND
if (( RAWBAND < PREV && CPUC > 0 )); then
  edge=0
  case $PREV in 3) edge=80;; 2) edge=72;; 1) edge=62;; *) edge=0;; esac
  if (( CPUC > edge - 3 )); then BAND=$PREV; fi
fi
print -r -- "$BAND" > "$BANDF"
BANDS=(COOL WARM HOT CRIT); BNAME=${BANDS[$((BAND+1))]}   # zsh arrays are 1-indexed

THROTTLING=false; (( SPEED < 100 )) && THROTTLING=true

# ---- band-appropriate advice ----
ADVICE=""
case $BAND in
  0) ADVICE="Thermals nominal." ;;
  1) ADVICE="Warming. MacPulse easing its own render." ;;
  2) ADVICE="Hot — iGPU/compositing load high. Top source: $HNAME. Close heavy GPU tabs or reduce transparency." ;;
  3) ADVICE="CRITICAL — die at throttle threshold. Biggest heat source: $HNAME (${HCPU}%). Quit or pause it to recover speed." ;;
esac

# ---- fan control verdict (honest, static for this machine) ----
FANCTL=false
FANREASON="T2 coprocessor mediates fans; user-space SMC writes are ignored on this model"

# ---- atomic write ----
TMP="$OUT.tmp.$$"
cat > "$TMP" <<JSON
{
  "ts": "$(date '+%F %T')",
  "cpu_c": $CPUC,
  "gpu_c": $GPUC,
  "fan_rpm": $RPM,
  "level": $LEVEL,
  "gpu_level": $GLEVEL,
  "speed_limit": $SPEED,
  "sched_limit": $SCHED,
  "throttling": $THROTTLING,
  "source": "$SRC",
  "band": $BAND,
  "band_name": "$BNAME",
  "metric": "$METRIC",
  "fan_control": $FANCTL,
  "fan_reason": "$FANREASON",
  "hog": { "name": "$HNAME", "pid": $HPID, "cpu": $HCPU },
  "advice": "$ADVICE"
}
JSON
mv -f "$TMP" "$OUT"; chmod 644 "$OUT"

if (( BAND != PREV )); then
  log "band $PREV->$BAND ($BNAME) cpu=${CPUC}degC level=$LEVEL speed=$SPEED src=$SRC hog=$HNAME"
fi
