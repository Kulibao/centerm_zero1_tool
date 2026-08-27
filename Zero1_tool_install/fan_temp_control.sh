#!/usr/bin/env bash
set -euo pipefail

# T-NAS Zero1 RK3568 fan controller. Optional UI config: /etc/zero1-tool/fan.conf
USE_GPIO_FORCE=0
PWM_CHIP=""
PWM_CHANNEL=0
PWM_PERIOD=40000
PWM_POLARITY="normal"
FAN_GPIO=22
FACTORY_TEST_CYCLE=10
CONFIG_FILE="/etc/zero1-tool/fan.conf"
STATUS_DIR="/run/zero1-tool"
STATUS_FILE="${STATUS_DIR}/fan-status.json"
LOG_FILE="/var/log/fan_control.log"

MODE="auto"
MANUAL_SPEED=8
TEMP_OFF=50
TEMP_LOW=55
TEMP_FULL=70
TEMP_CRITICAL=90
FAN_DUTY_MIN=60
CHECK_INTERVAL=3
# Startup always uses full speed. These values are retained for config compatibility.
STARTUP_SPEED=15
STARTUP_HOLD=0

PWM_PATH=""
FOUND_CHIP=""
CONTROL_BACKEND="none"
LAST_SPEED=""
LAST_DUTY_PERCENT=0
RELOAD_CONFIG=0

log() { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"; }

trim_log() {
    [ -f "$LOG_FILE" ] || return 0
    local cutoff
    cutoff=$(date -d '1 day ago' '+%Y-%m-%d %H:%M' 2>/dev/null || true)
    [ -n "$cutoff" ] || return 0
    awk -v c="$cutoff" '/^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]/ { if (substr($0,2,16) >= c) print; next } { print }' "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE"
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

load_config() {
    local key value
    local m="$MODE" ms="$MANUAL_SPEED" off="$TEMP_OFF" low="$TEMP_LOW" full="$TEMP_FULL" critical="$TEMP_CRITICAL" min="$FAN_DUTY_MIN" interval="$CHECK_INTERVAL" startup="$STARTUP_SPEED" hold="$STARTUP_HOLD"
    if [ -r "$CONFIG_FILE" ]; then
        while IFS='=' read -r key value; do
            key="${key//[[:space:]]/}"; value="${value//[[:space:]]/}"
            case "$key" in
                MODE) m="$value";; MANUAL_SPEED) ms="$value";; TEMP_OFF) off="$value";; TEMP_LOW) low="$value";; TEMP_FULL) full="$value";; TEMP_CRITICAL) critical="$value";; FAN_DUTY_MIN) min="$value";; CHECK_INTERVAL) interval="$value";; STARTUP_SPEED) startup="$value";; STARTUP_HOLD) hold="$value";;
            esac
        done < "$CONFIG_FILE"
    fi
    [[ "$m" =~ ^(auto|manual|full|off)$ ]] || m=auto
    is_uint "$ms" && (( ms <= 15 )) || ms=8
    is_uint "$off" && (( off >= 30 && off <= 75 )) || off=50
    is_uint "$low" && (( low > off && low <= 80 )) || low=55
    is_uint "$full" && (( full > low && full <= 90 )) || full=70
    is_uint "$critical" && (( critical >= full && critical <= 105 )) || critical=90
    is_uint "$min" && (( min >= 40 && min <= 100 )) || min=60
    is_uint "$interval" && (( interval >= 1 && interval <= 30 )) || interval=3
    is_uint "$startup" && (( startup >= 1 && startup <= 15 )) || startup=6
    is_uint "$hold" && (( hold <= 30 )) || hold=5
    MODE="$m"; MANUAL_SPEED="$ms"; TEMP_OFF="$off"; TEMP_LOW="$low"; TEMP_FULL="$full"; TEMP_CRITICAL="$critical"; FAN_DUTY_MIN="$min"; CHECK_INTERVAL="$interval"; STARTUP_SPEED="$startup"; STARTUP_HOLD="$hold"
}

find_pwm7_chip() {
    local chip path resolved
    for chip in 0 1 2 3 4 5 6 7; do
        path="/sys/class/pwm/pwmchip${chip}"; [ -d "$path" ] || continue
        resolved=$(readlink -f "${path}/device" 2>/dev/null || true)
        [[ "$resolved" == *fe6e0030* ]] && { printf '%s\n' "$chip"; return 0; }
    done
    return 1
}

init_pwm() {
    if [ -n "$PWM_CHIP" ] && [ -d "/sys/class/pwm/pwmchip${PWM_CHIP}" ]; then FOUND_CHIP="$PWM_CHIP"; else FOUND_CHIP="$(find_pwm7_chip || true)"; fi
    [ -n "$FOUND_CHIP" ] || return 1
    PWM_PATH="/sys/class/pwm/pwmchip${FOUND_CHIP}/pwm${PWM_CHANNEL}"
    [ -d "$PWM_PATH" ] || printf '%s\n' "$PWM_CHANNEL" > "/sys/class/pwm/pwmchip${FOUND_CHIP}/export" 2>/dev/null || true
    [ -d "$PWM_PATH" ] || { PWM_PATH=""; return 1; }
    printf '0\n' > "${PWM_PATH}/enable" 2>/dev/null || true
    printf '%s\n' "$PWM_PERIOD" > "${PWM_PATH}/period" 2>/dev/null || { PWM_PATH=""; return 1; }
    printf '%s\n' "$PWM_POLARITY" > "${PWM_PATH}/polarity" 2>/dev/null || true
    CONTROL_BACKEND=pwm; log "PWM initialized: pwmchip${FOUND_CHIP}, period=${PWM_PERIOD}ns, polarity=${PWM_POLARITY}"; return 0
}

init_gpio() {
    local gpio_path="/sys/class/gpio/gpio${FAN_GPIO}"
    [ -d "$gpio_path" ] || printf '%s\n' "$FAN_GPIO" > /sys/class/gpio/export 2>/dev/null || true
    [ -d "$gpio_path" ] || return 1
    printf 'out\n' > "${gpio_path}/direction" 2>/dev/null || true
    CONTROL_BACKEND=gpio
}

set_fan_speed_pwm() {
    local speed="$1" duty=0 duty_pct=0
    if (( speed > 0 )); then
        duty_pct=$(( FAN_DUTY_MIN + (speed - 1) * (100 - FAN_DUTY_MIN) / 14 )); (( duty_pct > 100 )) && duty_pct=100
        if [ "$PWM_POLARITY" = inverted ]; then duty=$(( PWM_PERIOD * (100-duty_pct) / 100 )); else duty=$(( PWM_PERIOD * duty_pct / 100 )); fi
    elif [ "$PWM_POLARITY" = inverted ]; then duty="$PWM_PERIOD"; fi
    printf '0\n' > "${PWM_PATH}/enable" 2>/dev/null || true
    printf '%s\n' "$duty" > "${PWM_PATH}/duty_cycle" 2>/dev/null || return 1
    (( speed > 0 )) && printf '1\n' > "${PWM_PATH}/enable" 2>/dev/null || true
    LAST_DUTY_PERCENT="$duty_pct"
}

set_fan_speed_gpio() { local speed="$1" value=0; (( speed > 0 )) && value=1; printf '%s\n' "$value" > "/sys/class/gpio/gpio${FAN_GPIO}/value" 2>/dev/null || return 1; (( speed > 0 )) && LAST_DUTY_PERCENT=100 || LAST_DUTY_PERCENT=0; }

set_fan_speed() {
    local speed="$1"; speed=$(( speed < 0 ? 0 : speed > 15 ? 15 : speed ))
    if [ "$CONTROL_BACKEND" = pwm ] && [ -d "$PWM_PATH" ]; then set_fan_speed_pwm "$speed"; else set_fan_speed_gpio "$speed"; fi
    if [ "$LAST_SPEED" != "$speed" ]; then log "Fan speed=${speed}, duty=${LAST_DUTY_PERCENT}%, mode=${MODE}"; LAST_SPEED="$speed"; fi
}

get_cpu_temp() {
    local temp; temp=$(awk '{ printf "%d", $1 / 1000 }' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || true)
    if ! is_uint "$temp" || (( temp < 10 || temp > 150 )); then log "WARNING: CPU temperature unavailable; keeping fail-safe full speed"; temp=100; fi
    printf '%s\n' "$temp"
}

auto_speed_for_temp() {
    local temp="$1" speed
    if (( temp < TEMP_OFF )); then speed=0
    elif (( temp < TEMP_LOW )); then speed=1
    elif (( temp < TEMP_FULL )); then speed=$(( 6 + (temp-TEMP_LOW)*8/(TEMP_FULL-TEMP_LOW) )); (( speed < 6 )) && speed=6; (( speed > 14 )) && speed=14
    else speed=15; fi
    printf '%s\n' "$speed"
}

write_status() {
    local temp="$1" speed="$2" tmp="${STATUS_FILE}.tmp.$$"
    mkdir -p "$STATUS_DIR"
    printf '{"timestamp":"%s","temperature":%d,"mode":"%s","speed":%d,"duty_percent":%d,"backend":"%s","pwm_chip":"%s","temp_off":%d,"temp_low":%d,"temp_full":%d,"temp_critical":%d,"manual_speed":%d,"check_interval":%d}\n' "$(date -Iseconds)" "$temp" "$MODE" "$speed" "$LAST_DUTY_PERCENT" "$CONTROL_BACKEND" "$FOUND_CHIP" "$TEMP_OFF" "$TEMP_LOW" "$TEMP_FULL" "$TEMP_CRITICAL" "$MANUAL_SPEED" "$CHECK_INTERVAL" > "$tmp"
    mv "$tmp" "$STATUS_FILE"
}

control_once() {
    local temp="$1" speed
    if (( temp >= TEMP_CRITICAL )); then speed=15; log "WARNING: CPU temperature ${temp}C reached critical limit; forcing full speed"
    else case "$MODE" in auto) speed="$(auto_speed_for_temp "$temp")";; manual) speed="$MANUAL_SPEED";; full) speed=15;; off) speed=0;; esac; fi
    set_fan_speed "$speed"; write_status "$temp" "$speed"
}

factory_test_mode() { log "Factory test started"; while true; do set_fan_speed 0; sleep "$FACTORY_TEST_CYCLE"; set_fan_speed 1; sleep "$FACTORY_TEST_CYCLE"; set_fan_speed 10; sleep "$FACTORY_TEST_CYCLE"; set_fan_speed 15; sleep "$FACTORY_TEST_CYCLE"; done; }
pwm_test_cycle() { local speed; echo 'PWM speed test: 0, 1, 6, 10, 15'; for speed in 0 1 6 10 15; do set_fan_speed "$speed"; echo "  -> speed ${speed}, duty ${LAST_DUTY_PERCENT}%"; sleep 5; done; set_fan_speed 0; }
handle_hup() { RELOAD_CONFIG=1; }
shutdown_fan() { log 'Fan controller stopping; setting full speed for safety'; set_fan_speed 15 || true; exit 0; }

main() {
    touch "$LOG_FILE"; mkdir -p "$STATUS_DIR"; trim_log; load_config
    trap handle_hup HUP; trap shutdown_fan INT TERM
    if [ "$USE_GPIO_FORCE" = 1 ]; then init_gpio || { echo "GPIO${FAN_GPIO} unavailable"; exit 1; }; elif ! init_pwm; then init_gpio || { echo 'PWM and GPIO are unavailable'; exit 1; }; log 'PWM unavailable; started with GPIO fallback'; fi
    case "${1:-}" in
        auto)
            local n=0 temp; set_fan_speed 15; log "Fan controller started with ${CONTROL_BACKEND}; startup speed=15 (fail-safe)"
            while true; do load_config; temp="$(get_cpu_temp)"; control_once "$temp"; n=$((n+1)); if (( n % 20 == 0 )) && [ "$CONTROL_BACKEND" = gpio ] && [ "$USE_GPIO_FORCE" != 1 ] && init_pwm; then log 'PWM became available; switched from GPIO to PWM'; LAST_SPEED=''; fi; (( n % 400 == 0 )) && trim_log; sleep "$CHECK_INTERVAL"; done;;
        manual) set_fan_speed "${2:-15}";; factory) factory_test_mode;; test) pwm_test_cycle;; off) set_fan_speed 0;; full) set_fan_speed 15;; *) echo "Usage: $0 {auto|manual 0-15|factory|test|off|full}"; exit 1;;
    esac
}
main "$@"
