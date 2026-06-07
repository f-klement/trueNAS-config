# UGREEN DXP4800 Plus | Hybrid K3s & Storage Cluster

This repository contains the automation scripts, hardware-specific configurations, and kernel-level overrides for a hybrid Kubernetes (K3s) and ZFS storage environment for a TrueNAS SCALE / Incus (LXC) worker machine on a UGREEN NAS.


## Hardware Integration: UGREEN DXP4800 Plus
This node leverages the UGREEN DXP4800 Plus (Intel Pentium Gold 8505) through specific kernel-level interventions to bypass proprietary appliance restrictions.

1. Fan Control (IT8620E)
The system uses the it87 driver to hijack the proprietary fan controller. By booting with acpi_enforce_resources=lax, we gain manual PWM control over the chassis and CPU fans.

Module: it87 forced with ID 0x8620.

Path: Accessible via /sys/class/hwmon/hwmon10/.


## Front-Panel LEDs
Controlled via a custom kernel module (led-ugreen.ko). The cluster switches between Day Mode (Visual Telemetry) and Night Mode (Full Blackout) by swapping symlinks in /etc/ that point to the persistent configurations in this repo.

## Core Automation
### hdd_spin_down.sh
Parks idle HDD groups by watching `/sys/block/sdX/stat` for IO increments. A group is
spun down (`hdparm -y`) only when every present, spinning disk in it has been idle longer
than the threshold; disks already in standby don't block the group.

Threshold: Configurable (defaulting to 7200s for a 2-hour spin-down) — `./hdd_spin_down.sh [idle_seconds] ["grpA disks;grpB disks"]`.

Robustness: idle time is tracked by a timestamp stored inside the per-disk state file
(`tmp/<disk>.io`), not the file's mtime; non-rotational devices (SSD/NVMe) are never spun
down; unreadable disks/power states are skipped rather than parked; output goes to the log
file only (no cron email spam).

> Fan control is **not** done here — `fan_control.sh` owns the fans and reacts to CPU+disk
> temps every minute, independent of spin-down. (The old combined version also called
> undefined `apply_blackout_fans`/`set_fans_silent` functions.)

### fan_control.sh
Proportional fan control reacting to the hottest of CPU (`coretemp`/`k10temp`) and disk
(`drivetemp` hwmon, `smartctl` fallback) temperatures. Sensors are discovered by name
(hwmon indices aren't stable across reboots). Separate CPU/disk curves, a panic temperature
that hands control back to the BIOS, and a fail-safe to BIOS auto if no sensor is readable.
Run every minute from cron (`fan_control.sh`) or as a fast loop daemon (`fan_control.sh 20`).

### lights_on.sh / lights_out.sh
Handles the atomic switching of the LED daemon profiles.

Uses ln -sf to flip /etc/ugreen-leds.conf between the Day and Night profiles stored in configs/.

Gracefully restarts the UGREEN monitoring daemons to apply the new state.


## Persistence on TrueNAS SCALE
TrueNAS SCALE utilizes a volatile root filesystem. To ensure these configurations survive updates and reboots, the following Post-Init script must be configured in the Web UI:

```Bash
# Load hardware drivers
modprobe it87 force_id=0x8620 ignore_resource_conflict=1

# Re-establish volatile symlinks
ln -sf /mnt/fastpool-sys/scripts/configs/ugreen-leds-day.conf /etc/ugreen-leds-day.conf
ln -sf /mnt/fastpool-sys/scripts/configs/ugreen-leds-night.conf /etc/ugreen-leds-night.conf
ln -sf /etc/ugreen-leds-day.conf /etc/ugreen-leds.conf
```

```Plaintext
.
├── hdd_spin_down.sh      # Reactive IO monitoring -> HDD spin-down (no fan logic)
├── lights_on.sh          # Manual/Automated switch to Day Mode
├── lights_out.sh         # Manual/Automated switch to Night Mode
├── fan_control.sh        # Reactive load based Fan control
├── configs/              # Master configuration profiles
│   ├── ugreen-leds-day.conf
│   └── ugreen-leds-night.conf
└── led_controller/       # Backups of the led_controller installer
```

## Operating

### Reading the logs
Both scripts log to files under `/root/scripts/tmp/` (they print to the terminal only when
run interactively, so cron stays silent — that's why a cron run shows nothing on the CLI):

```bash
# follow live
tail -f /root/scripts/tmp/fan-control.log
tail -f /root/scripts/tmp/hdd_spin_down.log

# last N lines
tail -n 50 /root/scripts/tmp/hdd_spin_down.log

# run by hand to watch the decision live (prints to the terminal AND the log)
/root/scripts/hdd_spin_down.sh 7200 "sda sdc sdd;sdb;sde"
/root/scripts/fan_control.sh          # one cycle
```
A fan-control line reads: `cpu=46C(0%) disk=41C(0%) demand=0% -> pwm1/2=25 pwm3=0 (floor=25)`.
The logs self-trim to the last few thousand lines.

### Finding the quietest stable fan floor (PWM_FLOOR)
Lower `PWM_FLOOR` in `fan_control.sh` = quieter idle, but too low and a fan stalls (0 RPM)
and may not restart. Find the lowest value that still spins, then set `PWM_FLOOR` a notch
above it:

```bash
FAN=$(for i in /sys/class/hwmon/hwmon*; do [ "$(cat $i/name 2>/dev/null)" = it8620 ] && echo $i; done)
echo 1 > "$FAN/pwm1_enable"; echo 1 > "$FAN/pwm2_enable"
for p in 0 12 16 20 25 30 40; do echo $p > "$FAN/pwm1"; echo $p > "$FAN/pwm2"; sleep 6; \
  echo "PWM=$p -> fan1=$(cat $FAN/fan1_input 2>/dev/null) fan2=$(cat $FAN/fan2_input 2>/dev/null) RPM"; done
# restore automatic control to fan_control.sh afterwards (next cron cycle takes over)
```
