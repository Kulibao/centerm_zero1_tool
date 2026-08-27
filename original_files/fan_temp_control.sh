#!/bin/bash
# Centerm NAS RK3568 风扇控制脚本（PWM7 占空比分档）
# 参考：https://zhuanlan.zhihu.com/p/5767112601

# ========== 核心配置（已确认有效） ==========
USE_GPIO_FORCE=0     # 1=强制 GPIO；0=PWM 占空比（已确认有效）
PWM_CHIP=0
PWM_CHANNEL=0
PWM_PERIOD=40000     # 25kHz，period=40000ns
PWM_POLARITY="normal"
FAN_DUTY_MIN=60      # 最低占空比 %，此风扇 50% 以下不转
FAN_GPIO=22          # GPIO 备用
CHECK_INTERVAL=3
FACTORY_TEST_CYCLE=10

# 温控曲线（speed 1-15 映射到 60%-100% 占空比）
# < 60℃  停转  0%
# 60-65℃ 低速 60%
# 65-80℃ 中速 60-80%
# > 80℃  全速 100%
TEMP_OFF=60
TEMP_LOW=65
TEMP_MID=80
TEMP_CRITICAL=100
# =======================================

LOG_FILE="/var/log/fan_control.log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 只保留 1 天内的日志
trim_log() {
    [ -f "$LOG_FILE" ] || return 0
    local cutoff
    cutoff=$(date -d '1 day ago' '+%Y-%m-%d %H:%M' 2>/dev/null)
    [ -z "$cutoff" ] && return 0
    awk -v c="$cutoff" '/^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]/ {
        if (substr($0,2,16) >= c) print; next
    } {print}' "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE"
}

# 探测 PWM7 芯片（fe6e0030 = RK3568 PWM7）
find_pwm7_chip() {
    local chip path
    for chip in 0 1 2 3 4 5 6 7; do
        path="/sys/class/pwm/pwmchip${chip}"
        [ -d "$path" ] || continue
        # PWM7 对应 fe6e0030
        if [ -e "${path}/device" ] && readlink -f "${path}/device" 2>/dev/null | grep -q "fe6e0030"; then
            echo $chip
            return 0
        fi
    done
    # 若无法匹配，尝试第一个可导出的
    for chip in 0 1 2 3 4 5 6 7; do
        [ -d "/sys/class/pwm/pwmchip${chip}" ] || continue
        if echo $PWM_CHANNEL > /sys/class/pwm/pwmchip${chip}/export 2>/dev/null; then
            echo $chip
            return 0
        fi
    done
    echo ""
    return 1
}

init_pwm() {
    if [ -n "$PWM_CHIP" ] && [ -d "/sys/class/pwm/pwmchip${PWM_CHIP}" ]; then
        FOUND_CHIP=$PWM_CHIP
    else
        FOUND_CHIP=$(find_pwm7_chip)
    fi

    if [ -n "$FOUND_CHIP" ]; then
        PWM_PATH="/sys/class/pwm/pwmchip${FOUND_CHIP}/pwm${PWM_CHANNEL}"
        if [ ! -d "$PWM_PATH" ]; then
            echo $PWM_CHANNEL > /sys/class/pwm/pwmchip${FOUND_CHIP}/export 2>/dev/null
        fi
        if [ -d "$PWM_PATH" ]; then
            echo $PWM_PERIOD > "${PWM_PATH}/period" 2>/dev/null
            echo "$PWM_POLARITY" > "${PWM_PATH}/polarity" 2>/dev/null
            log "PWM 初始化成功 (pwmchip${FOUND_CHIP}, ${PWM_PERIOD}ns=25kHz, polarity=$PWM_POLARITY)"
            return 0
        fi
    fi
    log "PWM 不可用，将使用 GPIO${FAN_GPIO} 备用"
    return 1
}

init_gpio() {
    local gpio_path="/sys/class/gpio/gpio${FAN_GPIO}"
    if [ -d "$gpio_path" ]; then
        log "GPIO${FAN_GPIO} 已存在，直接使用"
    else
        echo $FAN_GPIO > /sys/class/gpio/export 2>/dev/null
    fi
    echo out > "${gpio_path}/direction" 2>/dev/null
    echo 0 > "${gpio_path}/value" 2>/dev/null
}

set_fan_speed_pwm() {
    local speed=$1
    local duty=0 duty_pct=0
    if [ $speed -gt 0 ]; then
        duty_pct=$(( FAN_DUTY_MIN + (speed - 1) * (100 - FAN_DUTY_MIN) / 14 ))
        [ $duty_pct -gt 100 ] && duty_pct=100
        if [ "$PWM_POLARITY" = "inverted" ]; then
            duty=$(( PWM_PERIOD * (100 - duty_pct) / 100 ))
        else
            duty=$(( PWM_PERIOD * duty_pct / 100 ))
        fi
        [ $duty -gt $PWM_PERIOD ] && duty=$PWM_PERIOD
    else
        duty=$([ "$PWM_POLARITY" = "inverted" ] && echo $PWM_PERIOD || echo 0)
    fi
    echo $duty > "${PWM_PATH}/duty_cycle" 2>/dev/null
    if [ $speed -eq 0 ]; then
        echo 0 > "${PWM_PATH}/enable" 2>/dev/null
        log "风扇关闭 (PWM duty=0)"
    else
        echo 1 > "${PWM_PATH}/enable" 2>/dev/null
        log "风扇 PWM 档位=$speed 占空比=${duty_pct}%"
    fi
}

set_fan_speed_gpio() {
    local speed=$1
    if [ $speed -eq 0 ]; then
        echo 0 > /sys/class/gpio/gpio${FAN_GPIO}/value 2>/dev/null
        log "风扇关闭 (GPIO)"
    else
        echo 1 > /sys/class/gpio/gpio${FAN_GPIO}/value 2>/dev/null
        log "风扇开启 (GPIO 档位=$speed)"
    fi
}

set_fan_speed() {
    local speed=$1
    speed=$(( speed < 0 ? 0 : speed > 15 ? 15 : speed ))

    if [ -n "$PWM_PATH" ] && [ -d "$PWM_PATH" ]; then
        set_fan_speed_pwm $speed
    else
        set_fan_speed_gpio $speed
    fi
}

get_cpu_temp() {
    local temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{print int($1/1000)}')
    [ -z "$temp" ] && temp=60
    echo $temp
}

auto_speed_control() {
    local temp=$(get_cpu_temp)
    local speed=0

    if [ "$temp" -lt "$TEMP_OFF" ]; then
        speed=0
    elif [ "$temp" -lt "$TEMP_LOW" ]; then
        speed=1
    elif [ "$temp" -lt "$TEMP_MID" ]; then
        speed=$(( 6 + (temp - TEMP_LOW) * 4 / (TEMP_MID - TEMP_LOW) ))
        speed=$(( speed > 10 ? 10 : speed ))
    else
        speed=15
    fi

    [ "$temp" -ge "$TEMP_CRITICAL" ] && log "警告：CPU过温 ${temp}℃ >= ${TEMP_CRITICAL}℃"

    set_fan_speed $speed
    log "CPU ${temp}℃ → ${speed}档"
}

factory_test_mode() {
    log "工厂测试：0%→60%→80%→100%"
    while true; do
        set_fan_speed 0;  sleep $FACTORY_TEST_CYCLE
        set_fan_speed 1;  sleep $FACTORY_TEST_CYCLE
        set_fan_speed 10; sleep $FACTORY_TEST_CYCLE
        set_fan_speed 15; sleep $FACTORY_TEST_CYCLE
    done
}

# 占空比测试：0%→60%→70%→80%→90%→100%（匹配 FAN_DUTY_MIN）
pwm_test_cycle() {
    if [ -z "$PWM_PATH" ] || [ ! -d "$PWM_PATH" ]; then
        init_pwm || { echo "PWM 不可用，请确认 PWM7 已启用"; return 1; }
    fi
    [ -z "$PWM_PATH" ] && { echo "PWM 不可用"; return 1; }
    echo "占空比测试：0%→${FAN_DUTY_MIN}%→70%→80%→90%→100%，每档 5 秒"
    for pct in 0 $FAN_DUTY_MIN 70 80 90 100; do
        if [ "$PWM_POLARITY" = "inverted" ]; then
            duty=$(( PWM_PERIOD * (100 - pct) / 100 ))
        else
            duty=$(( PWM_PERIOD * pct / 100 ))
        fi
        echo $duty > "${PWM_PATH}/duty_cycle" 2>/dev/null
        [ $pct -eq 0 ] && echo 0 > "${PWM_PATH}/enable" 2>/dev/null || echo 1 > "${PWM_PATH}/enable" 2>/dev/null
        echo "  → ${pct}%"
        sleep 5
    done
    echo "测试结束"
}

main() {
    touch "$LOG_FILE"
    trim_log
    PWM_PATH=""

    if [ "$USE_GPIO_FORCE" = "1" ]; then
        init_gpio
        set_fan_speed 0
        log "风扇控制启动 (GPIO 模式) - 温控: <60℃停 ≥60℃转"
    elif init_pwm; then
        set_fan_speed 0
        log "风扇控制启动 (PWM 模式) - 温控: <60℃停 <65℃低速 <80℃中速 >80℃全速"
    else
        init_gpio
        set_fan_speed 0
        log "风扇控制启动 (GPIO 备用) - 温控: <60℃停 ≥60℃转"
    fi

    log "温控曲线: <60℃停 <65℃低速 <80℃中速 >80℃全速"

    case "$1" in
        auto)   local n=0; while true; do
                    auto_speed_control
                    n=$((n+1)); [ $((n % 400)) -eq 0 ] && trim_log  # 约 20 分钟清理一次
                    sleep $CHECK_INTERVAL
                done ;;
        manual) set_fan_speed "${2:-15}" ;;
        factory) factory_test_mode ;;
        test)   pwm_test_cycle ;;
        off)    set_fan_speed 0 ;;
        full)   set_fan_speed 15 ;;
        *)      echo "用法: $0 {auto|manual 0-15|factory|test|off|full}"; exit 1 ;;
    esac
}

main "$@"
