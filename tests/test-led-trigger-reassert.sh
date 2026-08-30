#!/usr/bin/bash
# Regression test for the LED trigger re-assert added 2026-08-30.
#
# The bug it guards: both daemons set their LED trigger exactly once at startup.
# `shot` (oneshot) and `device_name` (netdev) are attributes of the TRIGGER, so if
# the LED class device is re-registered underneath a running daemon the trigger
# reverts to `none`, those attributes vanish, and every subsequent write fails for
# the life of the process. It fails as EACCES, not ENOENT, because `>` opens with
# O_CREAT and sysfs has no ->create, so the symptom is a wall of "Permission denied"
# that reads like a privilege problem and is not one.
#
# We cannot exercise the kernel here, so the fake sysfs models the only thing that
# matters to the shell: whether the trigger-owned attribute exists after the write.
# What is under test is the branch logic and the throttle, which is what turned one
# recoverable event into an unbounded log.

set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leds_controller/scripts"
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
fails=0

ok()   { echo "  PASS: $1"; }
bad()  { echo "  FAIL: $1"; fails=$((fails+1)); }
check(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

# Lift each function out of the daemon and repoint it at the fake tree, so the test
# runs the shipped code rather than a copy that can drift away from it.
extract() { sed -n "/^$2() {/,/^}/p" "$SRC/$1" | sed "s#/sys/class/leds#$FAKE#g"; }

mkled() { mkdir -p "$FAKE/$1"; printf '[none] oneshot netdev\n' > "$FAKE/$1/trigger"; }

echo "reassert_oneshot (ugreen-diskiomon)"
eval "$(extract ugreen-diskiomon reassert_oneshot)"
TRIGGER_RECHECK_INTERVAL=60; declare -A trigger_retry_after; SECONDS=1000

# 1. trigger accepts the write and `shot` appears -> success
mkled disk1; : > "$FAKE/disk1/shot"
reassert_oneshot disk1 >/dev/null 2>&1
check "restores a reverted trigger" "$?" "0"

# 2. same LED again inside the throttle window -> refuses without touching sysfs
rm -f "$FAKE/disk1/shot"
reassert_oneshot disk1 >/dev/null 2>&1
check "throttles repeat attempts" "$?" "1"

# 3. throttle expires -> tries again
SECONDS=$((SECONDS + 61))
reassert_oneshot disk1 >/dev/null 2>&1
check "retries once the window passes" "$?" "1"

# 4. trigger genuinely unwritable -> reports, does not claim success
mkled disk2; chmod 0444 "$FAKE/disk2/trigger"
out="$(reassert_oneshot disk2 2>&1)"; rc=$?
check "fails closed when trigger is read-only" "$rc" "1"
[[ "$out" == *"not accepting writes"* ]] && ok "names the real cause" || bad "names the real cause (got '$out')"

# 5. LED absent entirely -> no crash
SECONDS=$((SECONDS + 61))
reassert_oneshot disk9 >/dev/null 2>&1
check "tolerates a missing LED" "$?" "1"

echo "ensure_netdev_trigger (ugreen-netdevmon-multi)"
eval "$(extract ugreen-netdevmon-multi ensure_netdev_trigger)"
NETDEV_BLINK_TX=1; NETDEV_BLINK_RX=1; NETDEV_BLINK_INTERVAL=200

# 6. attribute already present -> early return, no writes at all
led=netdev; mkled netdev; : > "$FAKE/netdev/device_name"
before="$(cat "$FAKE/netdev/trigger")"
ensure_netdev_trigger >/dev/null 2>&1
check "no-ops when the trigger is already right" "$?" "0"
check "leaves the trigger untouched on the happy path" "$(cat "$FAKE/netdev/trigger")" "$before"

# 7. attribute gone and restore works
rm -f "$FAKE/netdev/device_name"
( echo netdev > "$FAKE/netdev/trigger"; : > "$FAKE/netdev/device_name" )
ensure_netdev_trigger >/dev/null 2>&1
check "restores a reverted netdev trigger" "$?" "0"

# 8. attribute gone and restore impossible
mkled netdev2; chmod 0444 "$FAKE/netdev2/trigger"; led=netdev2
ensure_netdev_trigger >/dev/null 2>&1
check "fails closed when netdev trigger is read-only" "$?" "1"

echo
if (( fails )); then echo "$fails test(s) failed"; exit 1; fi
echo "all tests passed"
