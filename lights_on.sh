#!/bin/bash
# Day mode (LEDs on). Thin wrapper — all logic + error handling lives in lights.sh.
exec "$(dirname "$(readlink -f "$0")")/lights.sh" on
