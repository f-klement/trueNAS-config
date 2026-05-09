#!/bin/bash

# 1. Stop all daemons gracefully
systemctl stop ugreen-diskiomon.service ugreen-power-led.service ugreen-netdevmon-multi.service ugreen-netdevmon@*.service || true

# 2. RUTHLESSLY delete the buggy lock/PID files so the daemons don't commit suicide
rm -f /var/run/ugreen-* 2>/dev/null
rm -f /run/ugreen-* 2>/dev/null

# 3. Swap to the Day Mode profile

ln -sf /mnt/fastpool-sys/scripts/configs/ugreen-leds-day.conf /etc/ugreen-leds.conf

# 4. Start the daemons with a perfectly clean slate
systemctl start ugreen-power-led.service ugreen-netdevmon-multi.service ugreen-diskiomon.service

exit 0
