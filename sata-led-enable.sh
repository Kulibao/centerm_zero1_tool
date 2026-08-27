#!/usr/bin/env bash
set -euo pipefail
# switch_gpio from DT: <&gpio2 22 0> => global GPIO86
G=/sys/class/gpio/gpio86
[ -e "$G" ] || echo 86 > /sys/class/gpio/export 2>/dev/null || true
if [ -e "$G" ]; then
  echo out > "$G/direction" 2>/dev/null || true
  echo 1 > "$G/value" 2>/dev/null || true
fi
exit 0
