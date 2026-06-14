#!/bin/bash
# Night mode (LEDs dark). Thin wrapper — all logic + error handling lives in lights.sh.
exec "$(dirname "$(readlink -f "$0")")/lights.sh" off
