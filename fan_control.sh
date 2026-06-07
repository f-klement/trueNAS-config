#!/bin/bash
# fan-control.sh — proportional NAS fan control reacting to the HOTTEST of CPU and
# disk temperatures. Runs fast (every minute via cron, or as a loop daemon) and is
# SEPARATE from the HDD spindown script so fan response is decoupled from spindown.
#
# Runs on the TrueNAS SCALE physical host (UGREEN, it8620 super-IO fan controller).
#
# WHY: the old combined script only re-evaluated fans when the spindown cron fired
# (minutes apart) and only looked at CPU temp — so disks (what TrueNAS actually
# warns about) overheated to 60-70°C before anything ramped. This controller:
#   - discovers every sensor by NAME (hwmon indices are not stable across reboots)
#   - reads CPU (coretemp/k10temp) AND disk temps (drivetemp hwmon, smartctl fallback)
#   - drives a smooth proportional curve, separate thresholds for CPU vs disks
#   - hands control back to the BIOS on a panic temperature (fail-safe)
#   - fails safe to BIOS auto if no temperature can be read
#
# USAGE:
#   ./fan-control.sh           # one shot (use this from cron, every minute)
#   ./fan-control.sh 20        # daemon: re-evaluate every 20 seconds
#
# IMPORTANT: remove the fan logic from the spindown script (set_dynamic_fans /
# set_fans_silent / apply_blackout_fans and the trailing fan block) so the two jobs
# don't fight over the PWM registers. This script should OWN the fans.

set -uo pipefail

# ── Tunables (temperatures in millidegrees C) ─────────────────────────────────
# Curves stay at the whisper floor until *_MIN, ramp linearly to full by *_MAX, and
# hand control to the BIOS at *_PANIC. MINs are set high so the fans stay quiet at
# idle/light load and only spin up as temps approach the 50-60°C zone; MAXs keep
# them reaching full before the warning band. CPUs tolerate more heat than disks.
CPU_MIN=55000;  CPU_MAX=75000;  CPU_PANIC=85000
DISK_MIN=45000; DISK_MAX=55000; DISK_PANIC=60000

# Main case/CPU fans (pwm1, pwm2): 0-255.
# PWM_FLOOR = "whisper" idle speed. Lower = quieter; if a fan stalls and won't
# restart, raise it. Find the lowest stable value for your fans with the test
# snippet in the README. pwm3 stays fully OFF until there's load.
PWM_FLOOR=25;   PWM_CEIL=255
PWM3_FLOOR=0;   PWM3_CEIL=200

# Quiet hours: only lowers the IDLE floor further; the load curve still ramps to
# full, so thermal safety is never sacrificed for silence. Set QUIET_FLOOR<0 to disable.
QUIET_START=23; QUIET_END=6; QUIET_FLOOR=18

DISKS="sda sdb sdc sdd sde"        # data disks to poll for temperature

TMPDIR="/root/scripts/tmp"
LOGFILE="$TMPDIR/fan-control.log"
INTERVAL="${1:-0}"                  # 0 = run once; >0 = loop every N seconds

mkdir -p "$TMPDIR"
# Always append to the log; also echo to the terminal when run interactively (so a
# manual run shows output, but cron stays silent — no per-minute emails).
log(){ local m="[$(date '+%F %T')] $*"; echo "$m" >>"$LOGFILE"; [ -t 1 ] && echo "$m"; return 0; }
trim_log(){ [ -f "$LOGFILE" ] || return; local n; n=$(wc -l <"$LOGFILE"); [ "$n" -gt 10000 ] && { tail -n 4000 "$LOGFILE" > "$LOGFILE.tmp" && mv "$LOGFILE.tmp" "$LOGFILE"; }; }

# ── Sensor discovery (by name, not index) ─────────────────────────────────────
hwmon_by_name(){ local d; for d in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$d/name" 2>/dev/null)" = "$1" ] && { echo "$d"; return 0; }; done; return 1; }

FAN_NODE="$(hwmon_by_name it8620 || true)"
CPU_NODE="$(hwmon_by_name coretemp || hwmon_by_name k10temp || true)"

max_cpu_temp(){ [ -n "$CPU_NODE" ] || { echo 0; return; }
    cat "$CPU_NODE"/temp*_input 2>/dev/null | sort -nr | head -1; }

max_disk_temp(){
    local hi=0 t d
    # Preferred: drivetemp hwmon (one node per disk; never wakes a sleeping disk).
    for d in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$d/name" 2>/dev/null)" = "drivetemp" ] || continue
        t=$(cat "$d"/temp*_input 2>/dev/null | sort -nr | head -1)
        [ "${t:-0}" -gt "$hi" ] && hi=$t
    done
    # Fallback: smartctl, WITHOUT spinning up standby disks.
    if [ "$hi" -eq 0 ] && command -v smartctl >/dev/null 2>&1; then
        for d in $DISKS; do
            [ -b "/dev/$d" ] || continue
            t=$(smartctl -A -n standby "/dev/$d" 2>/dev/null | awk '
                $1==194 || $1==190 {print $10; exit}                 # SATA attr 194/190
                /Current Drive Temperature/ {print $4; exit}')      # SAS
            [ -n "${t:-}" ] && [ "$t" -gt 0 ] && { t=$((t*1000)); [ "$t" -gt "$hi" ] && hi=$t; }
        done
    fi
    echo "$hi"
}

# pct(temp,lo,hi) -> 0..100 demand
pct(){ local t=$1 lo=$2 hi=$3
    if   [ "$t" -le "$lo" ]; then echo 0
    elif [ "$t" -ge "$hi" ]; then echo 100
    else echo $(( (t-lo)*100/(hi-lo) )); fi; }

# scale(pct,floor,ceil) -> pwm
scale(){ echo $(( $2 + ($3-$2)*$1/100 )); }

apply_pwm(){ local p12=$1 p3=$2 ch
    for ch in 1 2; do echo 1 >"$FAN_NODE/pwm${ch}_enable" 2>/dev/null; echo "$p12" >"$FAN_NODE/pwm${ch}" 2>/dev/null; done
    echo 1 >"$FAN_NODE/pwm3_enable" 2>/dev/null; echo "$p3" >"$FAN_NODE/pwm3" 2>/dev/null; }

restore_auto(){ local ch; for ch in 1 2 3; do echo 2 >"$FAN_NODE/pwm${ch}_enable" 2>/dev/null; done; }

control_once(){
    trim_log
    [ -n "$FAN_NODE" ] || { log "FATAL: it8620 fan node not found — not touching fans"; return 1; }

    local cpu disk floor cpu_d disk_d d p12 p3 hour
    cpu=$(max_cpu_temp); disk=$(max_disk_temp)

    if [ "${cpu:-0}" -eq 0 ] && [ "${disk:-0}" -eq 0 ]; then
        log "WARN: no temperature readable (cpu+disk=0) — handing fans to BIOS auto"
        restore_auto; return
    fi

    if [ "${cpu:-0}" -ge "$CPU_PANIC" ] || [ "${disk:-0}" -ge "$DISK_PANIC" ]; then
        log "PANIC cpu=${cpu%000}C disk=${disk%000}C -> BIOS auto control"
        restore_auto; return
    fi

    cpu_d=$(pct "${cpu:-0}" "$CPU_MIN" "$CPU_MAX")
    disk_d=$(pct "${disk:-0}" "$DISK_MIN" "$DISK_MAX")
    d=$cpu_d; [ "$disk_d" -gt "$d" ] && d=$disk_d

    floor=$PWM_FLOOR
    hour=$(date +%H); hour=${hour#0}
    if [ "$QUIET_FLOOR" -ge 0 ] && { [ "$hour" -ge "$QUIET_START" ] || [ "$hour" -lt "$QUIET_END" ]; }; then
        floor=$QUIET_FLOOR
    fi

    p12=$(scale "$d" "$floor" "$PWM_CEIL")
    p3=$(scale "$d" "$PWM3_FLOOR" "$PWM3_CEIL")
    log "cpu=${cpu%000}C(${cpu_d}%) disk=${disk%000}C(${disk_d}%) demand=${d}% -> pwm1/2=$p12 pwm3=$p3 (floor=$floor)"
    apply_pwm "$p12" "$p3"
}

if [ "$INTERVAL" -gt 0 ]; then
    trap 'log "stopping daemon, restoring BIOS auto"; restore_auto; exit 0' INT TERM
    log "===== fan-control daemon every ${INTERVAL}s ====="
    while true; do control_once; sleep "$INTERVAL"; done
else
    control_once
fi
