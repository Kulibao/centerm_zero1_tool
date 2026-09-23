#!/usr/bin/env bash
set -u

# Keep the power LED synchronized with its saved toggle and daily schedule.
GREEN=/sys/class/leds/power:green
RED=/sys/class/leds/power:red
CONFIG=/etc/zero1-tool/sata-led.conf

POWER_LED_ENABLED=1
LED_SCHEDULE_ENABLED=0
LED_SCHEDULE_POWER=0
LED_SCHEDULE_START=23:00
LED_SCHEDULE_END=07:00

load_config() {
  local key value
  POWER_LED_ENABLED=1
  LED_SCHEDULE_ENABLED=0
  LED_SCHEDULE_POWER=0
  LED_SCHEDULE_START=23:00
  LED_SCHEDULE_END=07:00
  [ -r "$CONFIG" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      POWER_LED_ENABLED) [[ "$value" == 0 || "$value" == 1 ]] && POWER_LED_ENABLED="$value";;
      LED_SCHEDULE_ENABLED) [[ "$value" == 0 || "$value" == 1 ]] && LED_SCHEDULE_ENABLED="$value";;
      LED_SCHEDULE_POWER) [[ "$value" == 0 || "$value" == 1 ]] && LED_SCHEDULE_POWER="$value";;
      LED_SCHEDULE_START) LED_SCHEDULE_START="$value";;
      LED_SCHEDULE_END) LED_SCHEDULE_END="$value";;
    esac
  done < "$CONFIG"
}

if [ -d "$GREEN" ]; then
  echo none > "$GREEN/trigger" 2>/dev/null || true
fi
if [ -d "$RED" ]; then
  echo none > "$RED/trigger" 2>/dev/null || true
  echo 0 > "$RED/brightness" 2>/dev/null || true
fi

load_config
while true; do
  load_config
  scheduled_off=0
  if [[ "$LED_SCHEDULE_ENABLED" == 1 && "$LED_SCHEDULE_POWER" == 1 &&
        "$LED_SCHEDULE_START" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ &&
        "$LED_SCHEDULE_END" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    current=$(date +%H:%M)
    now_hour="${current%:*}"; now_minute="${current#*:}"
    start_hour="${LED_SCHEDULE_START%:*}"; start_minute="${LED_SCHEDULE_START#*:}"
    end_hour="${LED_SCHEDULE_END%:*}"; end_minute="${LED_SCHEDULE_END#*:}"
    now_value=$((10#$now_hour * 60 + 10#$now_minute))
    start_value=$((10#$start_hour * 60 + 10#$start_minute))
    end_value=$((10#$end_hour * 60 + 10#$end_minute))
    if (( start_value != end_value )); then
      if (( start_value < end_value )); then
        (( now_value >= start_value && now_value < end_value )) && scheduled_off=1
      else
        (( now_value >= start_value || now_value < end_value )) && scheduled_off=1
      fi
    fi
  fi

  if [ -d "$GREEN" ]; then
    if [[ "$POWER_LED_ENABLED" == 1 && "$scheduled_off" == 0 ]]; then
      echo 1 > "$GREEN/brightness" 2>/dev/null || true
    else
      echo 0 > "$GREEN/brightness" 2>/dev/null || true
    fi
  fi
  sleep 2
done
