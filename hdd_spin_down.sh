#!/bin/bash

TMPDIR="/root/scripts/tmp"
mkdir -p "$TMPDIR"

LOGFILE="$TMPDIR/$(basename $0 .sh).log"

THRESHOLD="${1:-300}"  # 5 by default. For production, increase or use parameter
DISK_GROUPS_STR="${2:-"sda sdc sdd;sdb;sde"}"

# --- Thermal Thresholds ---
TEMP_LIMIT=65000  # 65°C: The point where we start caring about heat
PANIC_LIMIT=80000 # 80°C: The point where we hand control back to BIOS (Safety)

IFS=';' read -ra DISK_GROUPS <<< "$DISK_GROUPS_STR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

log "===== Starting HDD spin down script ====="
log "Threshold: $THRESHOLD seconds"
log "Disk groups:"
for group in "${DISK_GROUPS[@]}"; do
    log "  - $group"
done

# UGREEN Fan Node (confirmed as hwmon10/it8620)
FAN_NODE=$(for i in /sys/class/hwmon/hwmon*; do if [ "$(cat $i/name 2>/dev/null)" = "it8620" ]; then echo $i; break; fi; done)

set_dynamic_fans() {
    # Read the highest CPU core temperature
    local current_temp=$(cat /sys/class/hwmon/hwmon5/temp*_input | sort -nr | head -n1)
    
    if [ "$current_temp" -lt "$TEMP_LIMIT" ]; then
        log "Temp is ${current_temp%000}°C. Maintaining Whisper Floor (PWM 40)."
        echo 1 > "$FAN_NODE/pwm1_enable" && echo 40 > "$FAN_NODE/pwm1"
        echo 1 > "$FAN_NODE/pwm2_enable" && echo 40 > "$FAN_NODE/pwm2"
        echo 1 > "$FAN_NODE/pwm3_enable" && echo 0 > "$FAN_NODE/pwm3"
    elif [ "$current_temp" -ge "$PANIC_LIMIT" ]; then
        log "CRITICAL TEMP: ${current_temp%000}°C. Restoring Factory Auto Control."
        echo 2 > "$FAN_NODE/pwm1_enable"
        echo 2 > "$FAN_NODE/pwm2_enable"
        echo 2 > "$FAN_NODE/pwm3_enable"
    else
        # Moderate Load: Set fans to a medium-high manual value (e.g., PWM 120)
        log "Moderate Load: ${current_temp%000}°C. Ramping fans to Medium."
        echo 1 > "$FAN_NODE/pwm1_enable" && echo 120 > "$FAN_NODE/pwm1"
        echo 1 > "$FAN_NODE/pwm2_enable" && echo 120 > "$FAN_NODE/pwm2"
        echo 1 > "$FAN_NODE/pwm3_enable" && echo 80 > "$FAN_NODE/pwm3"
    fi
}

# Add a toggle or time-check to call this function
if [ "$(date +%H)" -ge 23 ] || [ "$(date +%H)" -lt 06 ]; then
    apply_blackout_fans
fi


# Détermine le chemin correct du disque, by-id ou /dev/sdX
get_disk_path() {
    local d=$1
    if [ -e "/dev/disk/by-id/$d" ]; then
        echo "/dev/disk/by-id/$d"
    elif [ -b "/dev/$d" ]; then
        echo "/dev/$d"
    else
        echo ""  # disque non trouvé
    fi
}

read_io() {
    local disk=$1
    local path=$(get_disk_path "$disk")
    if [ -z "$path" ]; then
        log "WARNING: Disk $disk does not exist!"
        return 1
    fi
    local real_disk=$(basename $(readlink -f "$path"))
    awk '{print $1+$5}' /sys/block/${real_disk}/stat
}

# Global state tracking for fans
ANY_ACTIVE=false

for group in "${DISK_GROUPS[@]}"; do
    read -ra disks <<< "$group"
    valid_disks=()

    for d in "${disks[@]}"; do
        disk_path=$(get_disk_path "$d")
        if [ -n "$disk_path" ]; then
            valid_disks+=("$d")
        else
            log "Skipping non-existent disk: $d"
        fi
    done

    if [ ${#valid_disks[@]} -eq 0 ]; then
        log "No valid disks in group, skipping..."
        continue
    fi

    log "Checking group: ${valid_disks[*]}"

    disks_idle_ok=()
    all_idle=true
    for d in "${valid_disks[@]}"; do
        disk_statfile="$TMPDIR/${d}_io"

        io=$(read_io "$d")
        if [ $? -ne 0 ]; then
            continue
        fi

        prev=$(cat "$disk_statfile" 2>/dev/null || echo 0)
        log "Disk $d: current IO=$io, previous IO=$prev"

        if [ "$io" -ne "$prev" ]; then
            log "Disk $d has activity. Resetting idle."
            echo "$io" > "$disk_statfile"
            all_idle=false
            break
        fi

        ts=$(stat -c %Y "$disk_statfile" 2>/dev/null || echo 0)
        idle=$(( $(date +%s) - ts ))
        log "Disk $d idle time: $idle s"

        if [ "$idle" -gt $THRESHOLD ]; then
            disk_path=$(get_disk_path "$d")
            state=$(/usr/sbin/hdparm -C "$disk_path" 2>/dev/null | awk '/drive state/ {print $NF}')
            if [ "$state" != "standby" ]; then
                disks_idle_ok+=("$d")
            else
                log "Disk $d already in STANDBY. Skipping."
            fi
        else
            all_idle=false
	    # Check if disk is currently spinning (not in standby)
            state=$(/usr/sbin/hdparm -C $(get_disk_path "$d") 2>/dev/null | awk '/drive state/ {print $NF}')
            if [ "$state" != "standby" ]; then
                ANY_ACTIVE=true # Platter is still spinning and hasn't met threshold
            fi
        fi
    done

    if [ "$all_idle" = true ] && [ ${#disks_idle_ok[@]} -gt 0 ]; then
        cmd="/usr/sbin/hdparm -y $(printf '%s ' "$(for d in "${disks_idle_ok[@]}"; do get_disk_path "$d"; done)")"
        log "ALL disks in group idle > $THRESHOLD s. Running: $cmd"
        $cmd >>"$LOGFILE" 2>&1
        log "Spin down command sent for entire group: ${disks_idle_ok[*]}."

        for d in "${disks_idle_ok[@]}"; do
            disk_statfile="$TMPDIR/${d}_io"
            echo "$(read_io "$d")" > "$disk_statfile" 2>/dev/null
        done
    else
        log "At least one disk is ACTIVE or below threshold. No spin down for this group."
    fi
done

# Apply reactive fan control
if [ "$ANY_ACTIVE" = true ]; then
    set_dynamic_fans
else
    set_fans_silent
fi

log "Script execution finished."
