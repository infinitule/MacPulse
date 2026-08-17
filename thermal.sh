#!/bin/zsh
# MacPulse Thermal Governor v2 — multi-band bands + VERIFIED fan floors.
#
# v1's verdict "T2 blocks fan control" was proven only for USER-space SMC
# access. Root is a different story: helper-based fan tools (TG Pro, Macs
# Fan Control) drive T2 fans from root helpers. v2 therefore probes as
# root: read fan min/max → write a floor → READ BACK. thermal.json's
# fan_control reports what was PROVEN this run, never assumed.
#
# Floors, not forced speeds: we only raise F#Mn (the minimum). Apple's own
# curve keeps ownership above the floor, so cooling can never get worse
# than stock. Floors are capped at 92% of max, restore to factory base at
# COOL, and never go below base. Bands (die °C, 3°C stepdown hysteresis):
#   0 COOL <62   floor = base            1 WARM 62-72  floor = base+25% span
#   2 HOT 72-80  floor = base+55% span   3 CRIT ≥80    floor = base+85% span
DIR="${MACPULSE_DIR:-/Library/Application Support/MacPulse}"
OUT="$DIR/thermal.json"
BANDF="$DIR/thermal.band"
FANBASE="$DIR/fanbase"
FANSTATE="$DIR/thermal.fanctl"
LOG="$DIR/macpulse.log"
SMC="$DIR/smc"
log() { echo "$(date '+%F %T') THERMAL $1" >> "$LOG"; }

# ---- cheap signals (no root needed) ----
LEVEL=$(sysctl -n machdep.xcpm.cpu_thermal_level 2>/dev/null); LEVEL=${LEVEL:-0}
GLEVEL=$(sysctl -n machdep.xcpm.gpu_thermal_level 2>/dev/null); GLEVEL=${GLEVEL:-0}
THERM=$(pmset -g therm 2>/dev/null)
SPEED=$(print -r -- "$THERM" | awk -F'= *' '/CPU_Speed_Limit/{print $2+0}'); SPEED=${SPEED:-100}
SCHED=$(print -r -- "$THERM" | awk -F'= *' '/CPU_Scheduler_Limit/{print $2+0}'); SCHED=${SCHED:-100}
SRC="ac"; pmset -g batt 2>/dev/null | grep -q "'Battery Power'" && SRC="batt"

# ---- die °C: prefer instant root SMC read; fall back to powermetrics ----
CPUC=0; GPUC=0; RPM=0
if [[ -x "$SMC" ]]; then
  TR=$("$SMC" tempraw 2>/dev/null)
  SC=$(print -r -- "$TR" | awk '{print $1+0}')
  SG=$(print -r -- "$TR" | awk '{print $2+0}')
  if awk -v c="$SC" 'BEGIN{exit !(c>10 && c<120)}'; then CPUC=$SC; GPUC=$SG; fi
fi
if ! awk -v c="$CPUC" 'BEGIN{exit !(c>10)}'; then
  PM=$(powermetrics --samplers smc -n1 -i150 2>/dev/null)
  if [[ -n "$PM" ]]; then
    CPUC=$(print -r -- "$PM" | awk -F': *' '/CPU die temperature/{print $2+0; exit}')
    GPUC=$(print -r -- "$PM" | awk -F': *' '/GPU die temperature/{print $2+0; exit}')
    RPM=$(print -r -- "$PM"  | awk -F': *' '/^Fan:/{print $2+0; exit}')
  fi
fi
CPUC=${CPUC:-0}; GPUC=${GPUC:-0}; RPM=${RPM:-0}

# ---- band from °C (fallback: kernel thermal level) ----
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
if awk -v c="$CPUC" 'BEGIN{exit !(c>10)}'; then
  RAWBAND=$(band_from_temp ${CPUC%%.*}); METRIC="degC"
else
  RAWBAND=$(band_from_level $LEVEL); METRIC="level"
fi

# ---- hysteresis: hold a band until 3°C under its lower edge ----
PREV=$(cat "$BANDF" 2>/dev/null); PREV=${PREV:-0}
BAND=$RAWBAND
if (( RAWBAND < PREV )) && awk -v c="$CPUC" 'BEGIN{exit !(c>10)}'; then
  edge=0
  case $PREV in 3) edge=80;; 2) edge=72;; 1) edge=62;; *) edge=0;; esac
  if awk -v c="$CPUC" -v e="$edge" 'BEGIN{exit !(c > e-3)}'; then BAND=$PREV; fi
fi
print -r -- "$BAND" > "$BANDF"
BANDS=(COOL WARM HOT CRIT); BNAME=${BANDS[$((BAND+1))]}   # zsh arrays are 1-indexed

THROTTLING=false; (( SPEED < 100 )) && THROTTLING=true

# ---- MULTI-BAND FAN FLOORS (root, verified by read-back) ----
target_for() { # base max band -> floor rpm (int)
  awk -v b="$1" -v m="$2" -v k="$3" 'BEGIN{
    f=(k==1)?0.25:(k==2)?0.55:(k==3)?0.85:0
    t=b+f*(m-b); c=0.92*m; if(t>c)t=c; if(t<b)t=b; printf "%.0f", t }'
}
setfloor() { # key target -> 0 if read-back within 75 rpm
  "$SMC" set "$1" "$2" >/dev/null 2>&1
  local rb=$("$SMC" get "$1" 2>/dev/null)
  awk -v r="$rb" -v t="$2" 'BEGIN{d=r-t; if(d<0)d=-d; exit !(d<=75)}'
}
FANCTL=false; FLOOR=0; B0=0
FANREASON="smc helper missing — floors unavailable"
if [[ -x "$SMC" ]]; then
  FS=$("$SMC" fanstat 2>/dev/null)
  SRPM=$(print -r -- "$FS" | awk 'NR==1{print $2+0}')
  MN0=$(print -r --  "$FS" | awk 'NR==1{print $3+0}')
  MX0=$(print -r --  "$FS" | awk 'NR==1{print $4+0}')
  MN1=$(print -r --  "$FS" | awk 'NR==2{print $3+0}')
  MX1=$(print -r --  "$FS" | awk 'NR==2{print $4+0}')
  awk -v r="$SRPM" 'BEGIN{exit !(r>100)}' && RPM=$SRPM
  # Sanity gate: refuse to write unless values are believable. If sensors
  # read zero even as root, floors are skipped entirely — never write a
  # floor derived from garbage.
  if awk -v mn="$MN0" -v mx="$MX0" 'BEGIN{exit !(mx>1000 && mn>=400 && mn<mx)}'; then
    [[ -f "$FANBASE" ]] || print -r -- "${MN0} ${MN1:-0}" > "$FANBASE"   # factory base, captured once
    read -r B0 B1 < "$FANBASE"
    T0=$(target_for "$B0" "$MX0" "$BAND")
    if setfloor F0Mn "$T0"; then
      FANCTL=true; FLOOR=$T0
      FANREASON="root floor writes verified by read-back"
      if awk -v mn="$MN1" -v mx="$MX1" 'BEGIN{exit !(mx>1000 && mn>=400 && mn<mx)}'; then
        T1=$(target_for "${B1:-$B0}" "$MX1" "$BAND")
        setfloor F1Mn "$T1" && (( T1 > FLOOR )) && FLOOR=$T1
      fi
    else
      FANREASON="T2 accepted the write but ignored it (read-back mismatch)"
    fi
  else
    FANREASON="fan values unreadable even as root — floors skipped for safety"
  fi
fi
# log capability transitions once, not every 10 s
PREVFC=$(cat "$FANSTATE" 2>/dev/null)
if [[ "$FANCTL" != "$PREVFC" ]]; then
  print -r -- "$FANCTL" > "$FANSTATE"
  log "fan-control => $FANCTL ($FANREASON)"
fi

# ---- top heat source (cheap ps proxy) ----
read -r HPID HCPU HNAME <<< "$(ps -Aceo pid,%cpu,comm -r 2>/dev/null | awk 'NR==2{print $1, $2, $3}')"
HPID=${HPID:-0}; HCPU=${HCPU:-0}; HNAME=${HNAME:-unknown}

# ---- band-appropriate advice ----
BOOST=""; [[ "$FANCTL" == true ]] && (( BAND >= 1 )) && BOOST=" Fan floor ${FLOOR} rpm."
case $BAND in
  0) ADVICE="Thermals nominal." ;;
  1) ADVICE="Warming. MacPulse easing its own render.${BOOST}" ;;
  2) ADVICE="Hot — compositing load high. Top source: $HNAME.${BOOST}" ;;
  3) ADVICE="CRITICAL — near throttle. Biggest source: $HNAME (${HCPU}%). Quit or pause it.${BOOST}" ;;
esac

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
  "fan_floor": ${FLOOR:-0},
  "fan_base": ${B0:-0},
  "fan_reason": "$FANREASON",
  "hog": { "name": "$HNAME", "pid": $HPID, "cpu": $HCPU },
  "advice": "$ADVICE"
}
JSON
mv -f "$TMP" "$OUT"; chmod 644 "$OUT"

if (( BAND != PREV )); then
  log "band $PREV->$BAND ($BNAME) cpu=${CPUC}degC level=$LEVEL speed=$SPEED src=$SRC floor=$FLOOR hog=$HNAME"
fi
