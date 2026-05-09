#!/bin/bash

# 1. Stop all daemons gracefully
systemctl stop ugreen-diskiomon.service ugreen-power-led.service ugreen-netdevmon-multi.service ugreen-netdevmon@*.service || true

# 2. RUTHLESSLY delete the buggy lock/PID files 
rm -f /var/run/ugreen-* 2>/dev/null
rm -f /run/ugreen-* 2>/dev/null

# 3. Swap to the Night Mode profile

ln -sf /mnt/fastpool-sys/scripts/configs/ugreen-leds-night.conf /etc/ugreen-leds.conf

# 4. Start the daemons with a perfectly clean slate
# They will read the night config and safely command the hardware to go dark
systemctl start ugreen-power-led.service ugreen-netdevmon-multi.service ugreen-diskiomon.service

exit 0
