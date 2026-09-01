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
# hand control to the BIOS at *_PANIC. MINs sit ABOVE the normal operating range so the
# fans stay silent through everyday temps and only spin up as the hardware approaches its
# real warning band. HDDs run happily to ~50°C and are only a concern near 60°C, so the
# disk ramp starts at 50°C (was 45°C, which made the fans audible at perfectly normal
# temps and held them there because drives shed heat slowly). CPUs tolerate more heat.
# Tune DISK_MIN to ~2°C above your drives' real ceiling — check the log for actual temps.
CPU_MIN=60000;  CPU_MAX=80000;  CPU_PANIC=85000
DISK_MIN=50000; DISK_MAX=58000; DISK_PANIC=62000

# Main case/CPU fans (pwm1, pwm2): 0-255.
# PWM_FLOOR = "whisper" idle speed. Lower = quieter; if a fan stalls and won't
# restart, raise it. Find the lowest stable value for your fans with the test
# snippet in the README. pwm3 stays fully OFF until there's load.
PWM_FLOOR=25;   PWM_CEIL=255
PWM3_FLOOR=0;   PWM3_CEIL=200

# Quiet hours: only lowers the IDLE floor further; the load curve still ramps to
# full, so thermal safety is never sacrificed for silence. Set QUIET_FLOOR<0 to disable.
QUIET_START=23; QUIET_END=6; QUIET_FLOOR=18

# ── Spike rejection (this is what stops the fan hunting) ──────────────────────
# The Pentium Gold boosts hard: package temp jumps ~45C -> 85C for a fraction of a
# second on any burst (including this script's own cron wakeup) and falls straight
# back. A single instantaneous read therefore lands on a random point of that spike,
# which drove the fans full->idle->full every minute (the audible hunting). Two
# filters tame it:
#   1. Per-run MEDIAN of several CPU reads taken a beat apart — rejects the sub-second
#      boost spikes seen within one invocation.
#   2. An EMA (exponential moving average) carried across runs in a state file — low-
#      passes the remaining minute-to-minute jitter. EMA_ALPHA = weight (0-100) given
#      to the newest reading; lower = smoother/slower to react.
CPU_SAMPLES=5; CPU_SAMPLE_GAP=0.6; EMA_ALPHA=40
# Final guard: hard cap on how far pwm1/2 may move per cycle, so the fan can never snap
# between idle and full in one step (e.g. on first run or when returning from a panic).
# Up faster than down: answer real load promptly, then glide back down quietly.
PWM_UP_STEP=70; PWM_DOWN_STEP=25

DISKS="sda sdb sdc sdd sde"        # data disks to poll for temperature

TMPDIR="/root/scripts/tmp"
LOGFILE="$TMPDIR/fan-control.log"
INTERVAL="${1:-0}"                  # 0 = run once; >0 = loop every N seconds

mkdir -p "$TMPDIR"
# Always append to the log; also echo to the terminal when run interactively (so a
# manual run shows output, but cron stays silent — no per-minute emails).
log(){ local m="[$(date '+%F %T')] $*"; echo "$m" >>"$LOGFILE"; [ -t 1 ] && echo "$m"; return 0; }
trim_log(){ [ -f "$LOGFILE" ] || return; local n; n=$(wc -l <"$LOGFILE"); [ "$n" -gt 10000 ] && { tail -n 4000 "$LOGFILE" > "$LOGFILE.tmp" && mv "$LOGFILE.tmp" "$LOGFILE"; }; }

# State persisted across one-shot runs (cron fires us fresh each minute, so the EMA and
# the last applied PWM have to live on disk to survive between invocations).
EMA_FILE="$TMPDIR/cpu.ema"; PWM_FILE="$TMPDIR/pwm.last"
read_state(){ local v; [ -r "$1" ] && read -r v < "$1"; [[ "${v:-}" =~ ^[0-9]+$ ]] && echo "$v" || echo "$2"; }
write_state(){ echo "$2" > "$1" 2>/dev/null || true; }

# ── Sensor discovery (by name, not index) ─────────────────────────────────────
hwmon_by_name(){ local d; for d in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$d/name" 2>/dev/null)" = "$1" ] && { echo "$d"; return 0; }; done; return 1; }

# ── Make sure the fan controller is actually there ────────────────────────────
# The it8620 is a super-IO chip behind an ACPI-claimed resource region, so it only appears
# as an hwmon node once the it87 driver has been told to take it: the chip is not in the
# driver's ID table (hence force_id) and ACPI holds the ports (hence the lax boot flag,
# set on the kernel command line, plus ignore_resource_conflict for the driver itself).
#
# That modprobe used to live ONLY in the TrueNAS Post-Init script (see README), and on
# 2026-09-01 it was found not to have run: no it87 in /proc/modules, no it8620 in
# /sys/class/hwmon, so FAN_NODE below was empty and control_once bailed at its first
# guard. It had done so on EVERY run, once a minute, for at least the 2,712 runs that
# could still be accounted for — the fans were on BIOS defaults for days on the box that
# holds every dataset here, and the only trace was this script's exit status, which
# nothing read.
#
# So the script now establishes its own precondition rather than assuming someone else
# did. It runs as root from cron every minute, which is exactly what is needed to load a
# module, and a script that can guarantee the thing it depends on should not instead fail
# because a separate, invisible, easily-lost UI setting did not. The Post-Init entry stays
# in the README as the belt to this braces; either alone is now sufficient.
#
# Cheap and idempotent: the modprobe is attempted ONLY when the node is missing, so the
# normal path is one hwmon_by_name scan and no module work at all. When the module genuinely
# cannot be loaded (not built for this kernel, say) this costs one failed modprobe per
# minute and then falls through to the same fail-safe as before — it does not spin, retry
# in a loop, or mask the failure.
ensure_fan_node(){
    FAN_NODE="$(hwmon_by_name it8620 || true)"
    [ -n "$FAN_NODE" ] && return 0

    command -v modprobe >/dev/null 2>&1 || { log "it8620 absent and modprobe unavailable"; return 1; }
    log "it8620 hwmon node absent — loading it87 (force_id=0x8620)"
    if ! modprobe it87 force_id=0x8620 ignore_resource_conflict=1 2>/dev/null; then
        log "modprobe it87 FAILED — is the module built for $(uname -r), and is acpi_enforce_resources=lax on the kernel command line?"
        return 1
    fi

    FAN_NODE="$(hwmon_by_name it8620 || true)"
    if [ -n "$FAN_NODE" ]; then
        log "it87 loaded, fan node is now $FAN_NODE"
        return 0
    fi
    log "it87 loaded but no it8620 hwmon node appeared — chip may be claimed by ACPI"
    return 1
}

FAN_NODE=""
CPU_NODE="$(hwmon_by_name coretemp || hwmon_by_name k10temp || true)"

# Per-run CPU temperature: take CPU_SAMPLES reads a beat apart and return their MEDIAN,
# so a lone sub-second boost spike during this invocation can't dominate the result.
max_cpu_temp(){ [ -n "$CPU_NODE" ] || { echo 0; return; }
    local i peak vals=()
    for ((i=0; i<CPU_SAMPLES; i++)); do
        peak=$(cat "$CPU_NODE"/temp*_input 2>/dev/null | sort -nr | head -1)
        [ -n "$peak" ] && vals+=("$peak")
        [ "$i" -lt $((CPU_SAMPLES-1)) ] && sleep "$CPU_SAMPLE_GAP"
    done
    [ ${#vals[@]} -gt 0 ] || { echo 0; return; }
    printf '%s\n' "${vals[@]}" | sort -n | awk '{a[NR]=$0} END{print a[int((NR+1)/2)]}'; }

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

# Returns non-zero if any PWM write failed. This USED to return whatever its last
# redirection happened to evaluate to, which then became control_once's status and so the
# script's exit status — meaning a perfectly good run could exit non-zero on an unrelated
# pwm3 hiccup, and a failed run could exit 0. That status is now alerted on (Wazuh rule
# 100928 in the k3s repo pages when a NAS CronTask exits non-zero), so it has to mean
# exactly one thing: the fans were driven, or they were not.
apply_pwm(){ local p12=$1 p3=$2 ch rc=0
    for ch in 1 2; do
        echo 1     >"$FAN_NODE/pwm${ch}_enable" 2>/dev/null || rc=1
        echo "$p12" >"$FAN_NODE/pwm${ch}"        2>/dev/null || rc=1
    done
    echo 1    >"$FAN_NODE/pwm3_enable" 2>/dev/null || rc=1
    echo "$p3" >"$FAN_NODE/pwm3"        2>/dev/null || rc=1
    [ "$rc" -eq 0 ] || log "WARN: one or more PWM writes failed under $FAN_NODE"
    return "$rc"; }

# Always 0: handing the fans back to the BIOS is a deliberate, correct outcome on both of
# its call paths (panic, and no readable sensor), never a failure in itself. Explicit so it
# cannot leak the status of its last redirection into control_once's.
restore_auto(){ local ch; for ch in 1 2 3; do echo 2 >"$FAN_NODE/pwm${ch}_enable" 2>/dev/null; done; return 0; }

control_once(){
    trim_log
    # Re-checked EVERY run, not once at startup: in daemon mode the old top-level assignment
    # meant a node that appeared later was never picked up, and one that vanished was never
    # reported again. This also makes the module load self-healing across a reboot.
    ensure_fan_node || { log "FATAL: it8620 fan node not available — not touching fans"; return 1; }

    local cpu disk cpu_prev cpu_ema floor cpu_d disk_d d p12 p3 p12_prev hour
    cpu=$(max_cpu_temp); disk=$(max_disk_temp)

    if [ "${cpu:-0}" -eq 0 ] && [ "${disk:-0}" -eq 0 ]; then
        log "WARN: no temperature readable (cpu+disk=0) — handing fans to BIOS auto"
        # Non-zero deliberately. The BIOS taking over is safe, but this script is not doing
        # its job, and failing safe is not the same as working — with the exit status now
        # alerted on, that distinction is the whole point.
        restore_auto; return 1
    fi

    # Low-pass the (already per-run-median) CPU temp across runs with an EMA, seeded from
    # the current read on cold start. EVERY decision below uses cpu_ema, not the raw read,
    # so a single boost spike no longer slams the fans or trips a spurious panic.
    cpu_prev=$(read_state "$EMA_FILE" "${cpu:-0}")
    cpu_ema=$(( (EMA_ALPHA*${cpu:-0} + (100-EMA_ALPHA)*cpu_prev) / 100 ))
    write_state "$EMA_FILE" "$cpu_ema"

    if [ "$cpu_ema" -ge "$CPU_PANIC" ] || [ "${disk:-0}" -ge "$DISK_PANIC" ]; then
        log "PANIC cpu=$((cpu_ema/1000))C disk=$((disk/1000))C -> BIOS auto control"
        # Zero: an over-temperature hand-off to the BIOS is this script's fail-safe
        # operating correctly, not a malfunction of it. The log line and the fans being
        # audible are the signal here; the cron status is not the right channel for it.
        restore_auto; write_state "$PWM_FILE" "$PWM_CEIL"; return 0   # seed full so we glide DOWN on return
    fi

    cpu_d=$(pct "$cpu_ema" "$CPU_MIN" "$CPU_MAX")
    disk_d=$(pct "${disk:-0}" "$DISK_MIN" "$DISK_MAX")
    d=$cpu_d; [ "$disk_d" -gt "$d" ] && d=$disk_d

    floor=$PWM_FLOOR
    hour=$(date +%H); hour=${hour#0}
    if [ "$QUIET_FLOOR" -ge 0 ] && { [ "$hour" -ge "$QUIET_START" ] || [ "$hour" -lt "$QUIET_END" ]; }; then
        floor=$QUIET_FLOOR
    fi

    p12=$(scale "$d" "$floor" "$PWM_CEIL")
    p3=$(scale "$d" "$PWM3_FLOOR" "$PWM3_CEIL")

    # Slew-limit pwm1/2 against the last applied value: a final hard guard so the main
    # fans can never jump idle<->full in a single cycle. pwm3 is the load-only fan that
    # idles fully off, so it tracks demand directly.
    p12_prev=$(read_state "$PWM_FILE" "$p12")
    [ "$p12" -gt $((p12_prev + PWM_UP_STEP))   ] && p12=$((p12_prev + PWM_UP_STEP))
    [ "$p12" -lt $((p12_prev - PWM_DOWN_STEP)) ] && p12=$((p12_prev - PWM_DOWN_STEP))
    [ "$p12" -lt "$floor" ]    && p12=$floor
    [ "$p12" -gt "$PWM_CEIL" ] && p12=$PWM_CEIL
    write_state "$PWM_FILE" "$p12"

    log "cpu=$((cpu/1000))C ema=$((cpu_ema/1000))C(${cpu_d}%) disk=$((disk/1000))C(${disk_d}%) demand=${d}% -> pwm1/2=$p12 pwm3=$p3 (floor=$floor)"
    apply_pwm "$p12" "$p3"
}

if [ "$INTERVAL" -gt 0 ]; then
    trap 'log "stopping daemon, restoring BIOS auto"; restore_auto; exit 0' INT TERM
    log "===== fan-control daemon every ${INTERVAL}s ====="
    while true; do control_once; sleep "$INTERVAL"; done
else
    control_once
fi
