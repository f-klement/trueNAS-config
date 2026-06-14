#!/bin/bash
# lights.sh <on|off> — switch the UGREEN LED daemons between the day and night
# LED profiles, working around the upstream daemons' buggy lock/PID handling.
#
# PHILOSOPHY: best-effort, FAIL SOFT once committed. Two kinds of failure:
#   - Precondition failure (not root, profile missing) -> hard-exit 1 BEFORE we
#     touch the running daemons, so a bad invocation never leaves the LEDs worse off.
#   - Post-commit hiccup (a daemon doesn't restart) -> log it and exit 0. A static or
#     dark LED is always preferable to a "heart-attack red" error state or cron alarms.
# Everything is logged to $LOG so cron runs are auditable instead of silent.
#
# Usage:  lights.sh on     (day profile)
#         lights.sh off    (night profile / dark)

set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CONF_DIR="${CONF_DIR:-$SCRIPT_DIR/configs}"
LIVE_CONF="${LIVE_CONF:-/etc/ugreen-leds.conf}"
LOG="${LOG:-/var/log/ugreen-lights.log}"
START_SERVICES="ugreen-power-led.service ugreen-netdevmon-multi.service ugreen-diskiomon.service"
STOP_SERVICES="ugreen-diskiomon.service ugreen-power-led.service ugreen-netdevmon-multi.service ugreen-netdevmon@*.service"

log(){ local m="[$(date '+%F %T')] $*"; echo "$m" >>"$LOG" 2>/dev/null; [ -t 1 ] && echo "$m"; return 0; }
die(){ log "ABORT: $* (running daemons left untouched)"; exit 1; }

# ── Preconditions (fail HARD here — nothing has been disturbed yet) ────────────
[ "$(id -u)" -eq 0 ] || die "must run as root"

case "${1:-}" in
  on|day)    MODE=day;   PROFILE="$CONF_DIR/ugreen-leds-day.conf" ;;
  off|night) MODE=night; PROFILE="$CONF_DIR/ugreen-leds-night.conf" ;;
  *)         die "usage: ${0##*/} <on|off>" ;;
esac

# Refuse to point the daemons at a missing/empty profile (the dangling-symlink trap).
[ -s "$PROFILE" ] || die "profile missing or empty: $PROFILE"

log "switching LEDs to $MODE ($PROFILE)"

# ── Commit point (from here we FAIL SOFT — log, don't escalate) ────────────────
# Stop is synchronous; then clear the daemons' buggy lock/PID files for a clean slate.
systemctl stop $STOP_SERVICES 2>/dev/null || true
rm -f /var/run/ugreen-* /run/ugreen-* 2>/dev/null || true

# Point the live config at the chosen profile and confirm it resolved.
if ! ln -sfn "$PROFILE" "$LIVE_CONF" 2>>"$LOG"; then
    log "WARN: could not update $LIVE_CONF — attempting daemon restart anyway"
elif [ "$(readlink -f "$LIVE_CONF")" != "$(readlink -f "$PROFILE")" ]; then
    log "WARN: $LIVE_CONF did not resolve to $PROFILE after symlink"
fi

# Start the daemons; report any that don't come up, but never hard-fail.
rc=0
systemctl start $START_SERVICES 2>>"$LOG" || rc=$?
for svc in $START_SERVICES; do
    systemctl is-active --quiet "$svc" || { log "WARN: $svc is not active after start"; rc=1; }
done

if [ "$rc" -eq 0 ]; then
    log "$MODE applied — all LED daemons active"
else
    log "$MODE applied WITH WARNINGS — LEDs may be degraded (see entries above)"
fi
exit 0
