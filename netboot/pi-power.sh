#!/usr/bin/env bash
# Power-cycle / switch the Pi via per-port power switching on the MEGA4 hub (VIA VL817, 2109:2817).
# Runs uhubctl in a privileged container (no host install or sudo needed).
# -e matters: without it uhubctl pairs 3-2 with VIA hub 6-1.4.4 (Ethernet adapters, storage) as its
# "USB3 half" and would switch that hub's port too.
#   ./pi-power.sh cycle | off | on | status
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
: "${PI_HUB:?set PI_HUB (e.g. 3-2) in .env}" "${PI_HUB_PORT:?set PI_HUB_PORT (1-4) in .env}"
action=${1:-status}
case $action in
  cycle) args=(-a cycle -d "${PI_POWER_OFF_SECS:-3}") ;;
  off)   args=(-a off) ;;
  on)    args=(-a on) ;;
  status) args=() ;;
  *) echo "usage: $0 cycle|off|on|status"; exit 1 ;;
esac
docker run --rm --privileged -v /dev/bus/usb:/dev/bus/usb pi-uhubctl \
  uhubctl -e -l "$PI_HUB" -p "$PI_HUB_PORT" "${args[@]}"   # -e: exact hub only, no USB3-companion pairing
