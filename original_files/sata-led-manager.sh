#!/usr/bin/env bash
set -euo pipefail

# Confirmed on this board:
# gpio146=Disk1 RED, gpio147=Disk1 GREEN, gpio148=Disk2 RED, gpio149=Disk2 GREEN
# Active level: 1 = ON, 0 = OFF
R1=146
G1=147
R2=148
G2=149
SW=86   # switch_gpio keep enabled

SLOT1_PATH="/sys/devices/platform/fc400000.sata/ata*/host*/target*:*:*/*:*:*:*/block"
SLOT2_PATH="/sys/devices/platform/fc800000.sata/ata*/host*/target*:*:*/*:*:*:*/block"

ensure_gpio_out() {
  local n="$1" G="/sys/class/gpio/gpio$1"
  [ -e "$G" ] || echo "$n" > /sys/class/gpio/export 2>/dev/null || true
  [ -e "$G" ] || return 1
  echo out > "$G/direction" 2>/dev/null || true
  return 0
}

led_on()  { echo 1 > "/sys/class/gpio/gpio$1/value" 2>/dev/null || true; }
led_off() { echo 0 > "/sys/class/gpio/gpio$1/value" 2>/dev/null || true; }

slot_dev() {
  local p="$1" d
  d=$(ls $p 2>/dev/null | head -n 1 || true)
  printf '%s' "$d"
}

for g in "$R1" "$G1" "$R2" "$G2" "$SW"; do
  ensure_gpio_out "$g" || true
done
[ -e "/sys/class/gpio/gpio$SW/value" ] && echo 1 > "/sys/class/gpio/gpio$SW/value" 2>/dev/null || true

prev1=0
prev2=0

while true; do
  dev1=$(slot_dev "$SLOT1_PATH")
  dev2=$(slot_dev "$SLOT2_PATH")

  # SLOT1
  if [[ -n "$dev1" && -e "/sys/block/$dev1/stat" ]]; then
    io1=$(awk '{print $1+$5}' "/sys/block/$dev1/stat" 2>/dev/null || echo 0)
    smart_bad1=0
    if ! smartctl -H "/dev/$dev1" 2>/dev/null | awk '/SMART overall-health self-assessment test result/ {print $NF}' | grep -q '^PASSED$'; then
      smart_bad1=1
    fi

    if (( smart_bad1 == 1 )); then
      led_on "$R1";  led_off "$G1"
    else
      led_off "$R1"
      if (( prev1 > 0 && io1 > prev1 )); then
        led_off "$G1"; sleep 0.08; led_on "$G1"
      else
        led_on "$G1"
      fi
    fi
    prev1=$io1
  else
    led_on "$R1"; led_off "$G1"; prev1=0
  fi

  # SLOT2
  if [[ -n "$dev2" && -e "/sys/block/$dev2/stat" ]]; then
    io2=$(awk '{print $1+$5}' "/sys/block/$dev2/stat" 2>/dev/null || echo 0)
    smart_bad2=0
    if ! smartctl -H "/dev/$dev2" 2>/dev/null | awk '/SMART overall-health self-assessment test result/ {print $NF}' | grep -q '^PASSED$'; then
      smart_bad2=1
    fi

    if (( smart_bad2 == 1 )); then
      led_on "$R2";  led_off "$G2"
    else
      led_off "$R2"
      if (( prev2 > 0 && io2 > prev2 )); then
        led_off "$G2"; sleep 0.08; led_on "$G2"
      else
        led_on "$G2"
      fi
    fi
    prev2=$io2
  else
    led_on "$R2"; led_off "$G2"; prev2=0
  fi

  sleep 1
done
