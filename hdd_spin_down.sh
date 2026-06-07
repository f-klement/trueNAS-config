#!/bin/bash
# hdd_spin_down.sh — park idle HDD groups on the UGREEN NAS.
#
# Robust rewrite. Changes vs. the old version:
#   - Fan control REMOVED — fan_control.sh now owns the fans (it reacts to temps
#     every minute). The old in-script fan logic also called undefined functions
#     (apply_blackout_fans / set_fans_silent) and errored every run.
#   - Idle time is tracked by a timestamp stored INSIDE the state file, not by the
#     file's mtime (which any backup/rsync/touch would reset).
#   - Skips non-rotational devices (never spins down an SSD/NVMe).
#   - Power state parsed safely; unknown/unreadable disks are skipped, not parked.
#   - Logs to a file only (no per-run cron email spam).
#
# A disk group is parked only when EVERY present, spinning disk in it has been idle
# longer than the threshold (disks already in standby don't block the group).
#
# Usage:  ./hdd_spin_down.sh [idle_seconds] [ "grpA disks;grpB disks" ]
#   e.g.  ./hdd_spin_down.sh 7200 "sda sdc sdd;sdb;sde"

set -uo pipefail

THRESHOLD="${1:-7200}"                          # idle seconds before spin-down (default 2h)
DISK_GROUPS_STR="${2:-sda sdc sdd;sdb;sde}"     # ';'-separated groups of space-separated disks

TMPDIR="/root/scripts/tmp"
LOGFILE="$TMPDIR/$(basename "$0" .sh).log"
HDPARM="$(command -v hdparm || echo /usr/sbin/hdparm)"
mkdir -p "$TMPDIR"

log(){ echo "[$(date '+%F %T')] $*" >>"$LOGFILE"; }

IFS=';' read -ra DISK_GROUPS <<< "$DISK_GROUPS_STR"
now=$(date +%s)

log "===== spindown run (threshold ${THRESHOLD}s) ====="
[ -x "$HDPARM" ] || { log "FATAL: hdparm not found at '$HDPARM'"; exit 1; }

# Resolve a disk token (by-id name or sdX) to a device path, or "" if absent.
get_disk_path(){ local d=$1
    if   [ -e "/dev/disk/by-id/$d" ]; then echo "/dev/disk/by-id/$d"
    elif [ -b "/dev/$d" ];            then echo "/dev/$d"
    else echo ""; fi; }

block_name(){ basename "$(readlink -f "$1")"; }                       # path -> kernel name (sdX)
is_rotational(){ [ "$(cat "/sys/block/$1/queue/rotational" 2>/dev/null)" = "1" ]; }
read_io(){ local s="/sys/block/$1/stat"; [ -r "$s" ] || return 1; awk '{print $1+$5}' "$s"; }
power_state(){ "$HDPARM" -C "$1" 2>/dev/null | awk '/drive state/{print $NF}'; }  # standby|active/idle|...

for group in "${DISK_GROUPS[@]}"; do
    read -ra disks <<< "$group"
    [ ${#disks[@]} -gt 0 ] || continue
    log "group: ${disks[*]}"

    group_blocked=false        # any present, spinning disk still active or below threshold
    spin_candidates=()

    for d in "${disks[@]}"; do
        path=$(get_disk_path "$d")
        [ -n "$path" ] || { log "  $d: not present, skipping"; continue; }
        bn=$(block_name "$path")

        is_rotational "$bn" || { log "  $d ($bn): non-rotational, never spinning down"; continue; }

        statefile="$TMPDIR/${d}.io"
        io=$(read_io "$bn") || { log "  $d ($bn): cannot read IO stats — skipping (blocks group)"; group_blocked=true; continue; }

        prev_io=""; prev_ts=""
        [ -r "$statefile" ] && read -r prev_io prev_ts < "$statefile"

        # Activity, cold start, or legacy/garbled state file -> (re)baseline and block.
        if [ "$io" != "$prev_io" ] || ! [[ "$prev_ts" =~ ^[0-9]+$ ]] || [ "$prev_ts" -eq 0 ]; then
            echo "$io $now" > "$statefile"
            log "  $d ($bn): active/new (io '${prev_io:-?}' -> $io) — idle timer reset"
            group_blocked=true
            continue
        fi

        idle=$(( now - prev_ts ))
        state=$(power_state "$path"); state=${state:-unknown}
        log "  $d ($bn): idle ${idle}s, power=$state"

        case "$state" in
            standby)                continue ;;                  # already parked
            active/idle|active|idle) ;;                          # spinning: evaluate below
            *) log "  $d ($bn): unreadable power state — skipping"; continue ;;
        esac

        if [ "$idle" -gt "$THRESHOLD" ]; then
            spin_candidates+=("$d")
        else
            group_blocked=true
        fi
    done

    if [ "$group_blocked" = false ] && [ ${#spin_candidates[@]} -gt 0 ]; then
        paths=(); for d in "${spin_candidates[@]}"; do paths+=("$(get_disk_path "$d")"); done
        log "  -> parking idle group: ${spin_candidates[*]}"
        if "$HDPARM" -y "${paths[@]}" >>"$LOGFILE" 2>&1; then
            for d in "${spin_candidates[@]}"; do
                bn=$(block_name "$(get_disk_path "$d")")
                echo "$(read_io "$bn") $now" > "$TMPDIR/${d}.io"   # rebaseline post-spindown
            done
        else
            log "  -> hdparm -y FAILED for: ${spin_candidates[*]}"
        fi
    else
        log "  -> no spin-down (group active or nothing eligible)"
    fi
done

log "done."
