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
SMART_CHECK_INTERVAL=300  # seconds; SMART health is not checked every loop
POWER_CHECK_INTERVAL=1    # hdparm power-state check; does not read SMART data
LOOP_INTERVAL=0.2          # faster activity sampling / green LED flash rate
SLOW_BLINK_TICKS=5         # 5 x 0.2s on, 5 x 0.2s off = approximately 0.5Hz
HDPARM=/sbin/hdparm
CONFIG_FILE=/etc/zero1-tool/sata-led.conf
STANDBY_BLINK=1
RELOAD_CONFIG=0

SLOT1_PATH="/sys/devices/platform/fc400000.sata/ata*/host*/target*:*:*/*:*:*:*/block"
SLOT2_PATH="/sys/devices/platform/fc800000.sata/ata*/host*/target*:*:*/*:*:*:*/block"

load_config() {
  local key value
  [ -r "$CONFIG_FILE" ] || return 0
  while IFS='=' read -r key value; do
    key="${key//[[:space:]]/}"
    value="${value//[[:space:]]/}"
    case "$key" in
      STANDBY_BLINK) [[ "$value" == 0 || "$value" == 1 ]] && STANDBY_BLINK="$value";;
    esac
  done < "$CONFIG_FILE"
}

handle_hup() { RELOAD_CONFIG=1; }

ensure_gpio_out() {
  local n="$1" G="/sys/class/gpio/gpio$1"
  [ -e "$G" ] || echo "$n" > /sys/class/gpio/export 2>/dev/null || true
  [ -e "$G" ] || return 1
  echo out > "$G/direction" 2>/dev/null || true
  return 0
}

led_on()  { echo 1 > "/sys/class/gpio/gpio$1/value" 2>/dev/null || true; }
led_off() { echo 0 > "/sys/class/gpio/gpio$1/value" 2>/dev/null || true; }

# Return 0 for PASSED, 1 for a failed/unknown health check, and 2 when the
# drive is asleep.  smartctl -n standby checks the power state first and
# skips the SMART command while the drive is in standby, so this path cannot
# wake a sleeping disk.
smart_health() {
  local dev="$1" output rc
  output=$(smartctl -H -n standby "/dev/$dev" 2>&1) && rc=0 || rc=$?

  if printf '%s\n' "$output" | grep -Eiq 'device is in standby|device is in sleep'; then
    return 2
  fi
  if [ "$rc" -eq 0 ] && printf '%s\n' "$output" | grep -Eiq 'SMART overall-health self-assessment test result: *PASSED|SMART Health Status: *OK'; then
    return 0
  fi
  return 1
}

# Return 0 for standby/sleeping, 1 for active/idle, 2 when the state cannot be
# read.  hdparm -C only checks the ATA power state; it does not issue a SMART
# read and is safe to poll without spinning a standby disk up.
disk_power_state() {
  local dev="$1" output
  [ -x "$HDPARM" ] || return 2
  output=$("$HDPARM" -C "/dev/$dev" 2>&1) || return 2
  if printf '%s\n' "$output" | grep -Eiq 'standby|sleeping'; then
    return 0
  fi
  if printf '%s\n' "$output" | grep -Eiq 'active/idle'; then
    return 1
  fi
  return 2
}

slot_dev() {
  local p="$1" d
  d=$(ls $p 2>/dev/null | head -n 1 || true)
  printf '%s' "$d"
}

for g in "$R1" "$G1" "$R2" "$G2" "$SW"; do
  ensure_gpio_out "$g" || true
done
load_config
trap handle_hup HUP
[ -e "/sys/class/gpio/gpio$SW/value" ] && echo 1 > "/sys/class/gpio/gpio$SW/value" 2>/dev/null || true

prev1=0
prev2=0
smart_bad1=0
smart_bad2=0
smart_sleep1=0
smart_sleep2=0
last_smart_check1=0
last_smart_check2=0
last_power_check1=0
last_power_check2=0
tick=0

while true; do
  tick=$((tick + 1))
  slow_phase=$(( (tick / SLOW_BLINK_TICKS) % 2 ))
  dev1=$(slot_dev "$SLOT1_PATH")
  dev2=$(slot_dev "$SLOT2_PATH")

  # SLOT1
  if [[ -n "$dev1" && -e "/sys/block/$dev1/stat" ]]; then
    io1=$(awk '{print $1+$5}' "/sys/block/$dev1/stat" 2>/dev/null || echo 0)
    now=$(date +%s)
    if (( now - last_power_check1 >= POWER_CHECK_INTERVAL )); then
      if disk_power_state "$dev1"; then
        smart_sleep1=1
      else
        power_rc=$?
        if (( power_rc == 1 )); then smart_sleep1=0; fi
      fi
      last_power_check1=$now
    fi
    if (( now - last_smart_check1 >= SMART_CHECK_INTERVAL )); then
      if smart_health "$dev1"; then
        smart_bad1=0
        smart_sleep1=0
        last_smart_check1=$now
      else
        smart_rc=$?
        if (( smart_rc == 1 )); then
          smart_bad1=1
          smart_sleep1=0
          last_smart_check1=$now
        else
          # Standby/sleep: retain health state, but show a slow green blink.
          smart_sleep1=1
          last_smart_check1=$now
        fi
      fi
    fi

    if (( smart_bad1 == 1 )); then
      led_on "$R1";  led_off "$G1"
    elif (( smart_sleep1 == 1 )); then
      led_off "$R1"
      if (( STANDBY_BLINK == 1 )); then
        if (( slow_phase == 0 )); then led_on "$G1"; else led_off "$G1"; fi
      else
        led_on "$G1"
      fi
    else
      led_off "$R1"
      if (( prev1 > 0 && io1 > prev1 )); then
        led_off "$G1"; sleep 0.04; led_on "$G1"
      else
        led_on "$G1"
      fi
    fi
    prev1=$io1
  else
    if (( slow_phase == 0 )); then led_on "$R1"; else led_off "$R1"; fi
    led_off "$G1"; prev1=0
    smart_bad1=0; smart_sleep1=0; last_smart_check1=0; last_power_check1=0
  fi

  # SLOT2
  if [[ -n "$dev2" && -e "/sys/block/$dev2/stat" ]]; then
    io2=$(awk '{print $1+$5}' "/sys/block/$dev2/stat" 2>/dev/null || echo 0)
    now=$(date +%s)
    if (( now - last_power_check2 >= POWER_CHECK_INTERVAL )); then
      if disk_power_state "$dev2"; then
        smart_sleep2=1
      else
        power_rc=$?
        if (( power_rc == 1 )); then smart_sleep2=0; fi
      fi
      last_power_check2=$now
    fi
    if (( now - last_smart_check2 >= SMART_CHECK_INTERVAL )); then
      if smart_health "$dev2"; then
        smart_bad2=0
        smart_sleep2=0
        last_smart_check2=$now
      else
        smart_rc=$?
        if (( smart_rc == 1 )); then
          smart_bad2=1
          smart_sleep2=0
          last_smart_check2=$now
        else
          smart_sleep2=1
          last_smart_check2=$now
        fi
      fi
    fi

    if (( smart_bad2 == 1 )); then
      led_on "$R2";  led_off "$G2"
    elif (( smart_sleep2 == 1 )); then
      led_off "$R2"
      if (( STANDBY_BLINK == 1 )); then
        if (( slow_phase == 0 )); then led_on "$G2"; else led_off "$G2"; fi
      else
        led_on "$G2"
      fi
    else
      led_off "$R2"
      if (( prev2 > 0 && io2 > prev2 )); then
        led_off "$G2"; sleep 0.04; led_on "$G2"
      else
        led_on "$G2"
      fi
    fi
    prev2=$io2
  else
    if (( slow_phase == 0 )); then led_on "$R2"; else led_off "$R2"; fi
    led_off "$G2"; prev2=0
    smart_bad2=0; smart_sleep2=0; last_smart_check2=0; last_power_check2=0
  fi

  if (( RELOAD_CONFIG == 1 )); then
    load_config
    RELOAD_CONFIG=0
  fi
  sleep "$LOOP_INTERVAL"
done
