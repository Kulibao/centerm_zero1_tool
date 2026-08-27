#!/bin/sh
# Force power LED green solid ON at boot/runtime.
GREEN=/sys/class/leds/power:green
RED=/sys/class/leds/power:red

if [ -d "$GREEN" ]; then
  echo none > "$GREEN/trigger" 2>/dev/null || true
  echo 1 > "$GREEN/brightness" 2>/dev/null || true
fi
if [ -d "$RED" ]; then
  echo none > "$RED/trigger" 2>/dev/null || true
  echo 0 > "$RED/brightness" 2>/dev/null || true
fi

exit 0
