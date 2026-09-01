#!/usr/bin/bash
# Regression test for the it87 auto-load and the exit-status contract, added 2026-09-01.
#
# The bug it guards: on 2026-09-01 fan_control.sh was found to have exited 1 on EVERY run,
# once a minute, for at least 2,712 consecutive runs. The it87 module had never been loaded
# (it lived only in a TrueNAS Post-Init script, which had gone), so there was no it8620
# hwmon node, FAN_NODE was empty and the script bailed at its first guard without touching
# anything. The fans sat on BIOS defaults for days on the box that holds every dataset.
#
# Two things make that class of failure possible, and both are under test here:
#
#   1. The script ASSUMED a precondition that something else, elsewhere, invisible, was
#      supposed to have established. It now establishes it itself (ensure_fan_node).
#   2. Its exit status was accidental — control_once returned whatever apply_pwm's last
#      redirection evaluated to — so the one signal a one-shot cron script leaves behind
#      could not be trusted in either direction. It is now explicit, and Wazuh rule 100928
#      in the k3s repo pages on it, so "non-zero" has to mean exactly "the fans were not
#      driven".
#
# We cannot load a kernel module here, so the fake sysfs and the fake modprobe model the
# only thing that matters to the shell: whether an it8620 node exists after the attempt.
# What is under test is the branch logic and the status contract.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
fails=0

ok()   { echo "  PASS: $1"; }
bad()  { echo "  FAIL: $1"; fails=$((fails+1)); }
check(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

# Load the SHIPPED script rather than a copy, repointed at the fake tree and truncated
# before its trailing dispatch block so sourcing defines the functions without running a
# control cycle. Same principle as test-led-trigger-reassert.sh: the test must not be able
# to drift away from the code it guards.
mkdir -p "$FAKE/hwmon" "$FAKE/tmp"
sed -e "s#/sys/class/hwmon#$FAKE/hwmon#g" \
    -e "s#/root/scripts/tmp#$FAKE/tmp#g" \
    -e '/^if \[ "\$INTERVAL" -gt 0 \]; then/,$d' \
    "$ROOT/fan_control.sh" > "$FAKE/lib.sh"

# shellcheck disable=SC1090
source "$FAKE/lib.sh"

# ── fake hwmon plumbing ───────────────────────────────────────────────────────
mk_node(){ local d="$FAKE/hwmon/hwmon$1"; mkdir -p "$d"; echo "$2" > "$d/name"; echo "$d"; }
clear_nodes(){ rm -rf "$FAKE/hwmon"; mkdir -p "$FAKE/hwmon"; }

# fake modprobe: MODPROBE_RESULT decides the exit code, MODPROBE_CREATES whether the node
# appears, and every call is recorded so we can assert it is NOT called on the happy path.
MODPROBE_CALLS=0; MODPROBE_RESULT=0; MODPROBE_CREATES=1; MODPROBE_ARGS=""
modprobe(){ MODPROBE_CALLS=$((MODPROBE_CALLS+1)); MODPROBE_ARGS="$*"
    [ "$MODPROBE_RESULT" -eq 0 ] || return "$MODPROBE_RESULT"
    [ "$MODPROBE_CREATES" -eq 1 ] && mk_node 10 it8620 >/dev/null
    return 0; }
# ensure_fan_node gates on `command -v modprobe`, which does find a shell function.
export -f modprobe 2>/dev/null || true

echo "== ensure_fan_node =="

# 1. Node already present: no module work at all. This is the every-minute path, so it
#    mattering that it stays cheap is the point, not an aside.
clear_nodes; mk_node 3 it8620 >/dev/null; MODPROBE_CALLS=0; FAN_NODE=""
ensure_fan_node >/dev/null 2>&1; rc=$?
check "present -> rc 0"            "$rc" "0"
check "present -> node found"      "$FAN_NODE" "$FAKE/hwmon/hwmon3"
check "present -> no modprobe"     "$MODPROBE_CALLS" "0"

# 2. Absent, load works: the actual fix. This is the state the NAS was in for days.
clear_nodes; MODPROBE_CALLS=0; MODPROBE_RESULT=0; MODPROBE_CREATES=1; FAN_NODE=""
ensure_fan_node >/dev/null 2>&1; rc=$?
check "absent+load -> rc 0"        "$rc" "0"
check "absent+load -> node found"  "$FAN_NODE" "$FAKE/hwmon/hwmon10"
check "absent+load -> modprobed"   "$MODPROBE_CALLS" "1"
case "$MODPROBE_ARGS" in
  *it87*force_id=0x8620*ignore_resource_conflict=1*) ok "absent+load -> correct modprobe args" ;;
  *) bad "absent+load -> correct modprobe args (got '$MODPROBE_ARGS')" ;;
esac

# 3. Absent, modprobe fails (module not built for this kernel). Must report failure, not
#    pretend success, and must not leave a stale FAN_NODE behind.
clear_nodes; MODPROBE_CALLS=0; MODPROBE_RESULT=1; FAN_NODE=""
ensure_fan_node >/dev/null 2>&1; rc=$?
check "absent+fail -> rc 1"        "$rc" "1"
check "absent+fail -> node empty"  "$FAN_NODE" ""

# 4. modprobe "succeeds" but no node appears (ACPI still holding the region). The subtle
#    one: a zero exit from modprobe is not evidence the chip is usable.
clear_nodes; MODPROBE_CALLS=0; MODPROBE_RESULT=0; MODPROBE_CREATES=0; FAN_NODE=""
ensure_fan_node >/dev/null 2>&1; rc=$?
check "load-but-no-node -> rc 1"   "$rc" "1"
check "load-but-no-node -> empty"  "$FAN_NODE" ""

# 5. A stale FAN_NODE from a previous cycle must not survive the chip going away, or a
#    daemon-mode process would keep writing to a path that no longer exists.
clear_nodes; MODPROBE_RESULT=1; FAN_NODE="$FAKE/hwmon/hwmon99"
ensure_fan_node >/dev/null 2>&1
check "stale node cleared"         "$FAN_NODE" ""

echo "== apply_pwm status contract =="

# 6. Writable node: every write lands, status 0. Previously this was whatever the final
#    pwm3 redirection happened to return.
clear_nodes; FAN_NODE="$(mk_node 4 it8620)"
for f in pwm1_enable pwm1 pwm2_enable pwm2 pwm3_enable pwm3; do : > "$FAN_NODE/$f"; done
apply_pwm 120 80 >/dev/null 2>&1; rc=$?
check "writable -> rc 0"           "$rc" "0"
check "writable -> pwm1 written"   "$(cat "$FAN_NODE/pwm1")" "120"
check "writable -> pwm3 written"   "$(cat "$FAN_NODE/pwm3")" "80"

# 7. An unwritable PWM must surface. A silent failure here is the fans not moving while
#    the cron status says everything is fine, which is the whole failure mode being fixed.
chmod a-w "$FAN_NODE/pwm3"
apply_pwm 120 80 >/dev/null 2>&1; rc=$?
check "unwritable pwm3 -> rc 1"    "$rc" "1"
chmod u+w "$FAN_NODE/pwm3"

# The case that pins the actual defect. The OLD apply_pwm ended on the pwm3 redirection and
# so returned ITS status, which meant a failing pwm3 was reported correctly BY ACCIDENT
# while a failing pwm1 or pwm2 — the two main case/CPU fans, i.e. the ones that matter —
# was reported as success. Verified: against the pre-fix script the pwm3 check above passes
# and this one fails. Any future rewrite that goes back to leaking a single redirection's
# status gets caught here rather than in a month of silence.
chmod a-w "$FAN_NODE/pwm1"
apply_pwm 120 80 >/dev/null 2>&1; rc=$?
check "unwritable pwm1 -> rc 1"    "$rc" "1"
chmod u+w "$FAN_NODE/pwm1"

# 8. restore_auto is a deliberate, correct outcome on both its call paths and must never
#    be a source of failure status.
clear_nodes; FAN_NODE="$(mk_node 5 it8620)"
for f in pwm1_enable pwm2_enable pwm3_enable; do : > "$FAN_NODE/$f"; done
restore_auto >/dev/null 2>&1; rc=$?
check "restore_auto -> rc 0"       "$rc" "0"
# Even when it cannot write, it must still report 0: an unwritable node is reported by
# apply_pwm and by ensure_fan_node, and restore_auto returning non-zero here would page
# for a hand-off to the BIOS that is working exactly as designed.
chmod a-w "$FAN_NODE"/pwm*_enable
restore_auto >/dev/null 2>&1; rc=$?
check "restore_auto (unwritable) -> rc 0" "$rc" "0"
chmod u+w "$FAN_NODE"/pwm*_enable

echo
if [ "$fails" -eq 0 ]; then echo "All checks passed."; else echo "$fails check(s) FAILED."; fi
exit "$fails"
