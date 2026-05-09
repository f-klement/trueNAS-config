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
A reactive management script that monitors /sys/block/sdX/stat for IO increments.

Threshold: Configurable (defaulting to 7200s for a 2-hour spin-down).

Reactive Logic: If all drives are in standby, it commands the IT8620E to drop fans to a silent "whisper" floor (PWM 40-45). If IO is detected, it restores the factory "Auto" fan curve to ensure thermal safety.

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
├── hdd_spin_down.sh      # Reactive IO monitoring & Fan control
├── lights_on.sh          # Manual/Automated switch to Day Mode
├── lights_out.sh         # Manual/Automated switch to Night Mode
├── configs/              # Master configuration profiles
│   ├── ugreen-leds-day.conf
│   └── ugreen-leds-night.conf
└── system_configs/       # Backups of systemd units and modules
```
