#!/bin/sh
# 只测蜂鸣、不关机；不中途 exit。
# 本板实测：GPIO0 line18 有源短脉冲最干净。
# 需要「快翻诊断」时：BUZZER_DIAG=1 sudo -E /usr/bin/buzzer-test.sh
set +e

log() { echo "$@"; }

beep_sysfs() {
  if [ -w /sys/devices/platform/gpio_ctrl/buzzer_gpio ]; then
    log "   -> sysfs OK"
    echo 'buzzer_en:2' > /sys/devices/platform/gpio_ctrl/buzzer_gpio
    sleep 0.35
    echo 'buzzer_en:0' > /sys/devices/platform/gpio_ctrl/buzzer_gpio
    return 0
  fi
  return 1
}

pwm_beep() {
  CHIP=$1; PER=$2; DUT=$3; label=$4
  [ -d "$CHIP" ] && [ -d "$CHIP/pwm0" ] || echo 0 > "$CHIP/export" 2>/dev/null
  [ -d "$CHIP/pwm0" ] || return 1
  echo 0 > "$CHIP/pwm0/enable" 2>/dev/null
  echo "$PER" > "$CHIP/pwm0/period" 2>/dev/null || return 1
  echo "$DUT" > "$CHIP/pwm0/duty_cycle" 2>/dev/null || return 1
  echo 1 > "$CHIP/pwm0/enable" 2>/dev/null || return 1
  sleep 0.35
  echo 0 > "$CHIP/pwm0/enable" 2>/dev/null
  log "   [寄存器] OK $CHIP $label period=${PER}ns"
  return 0
}

# 与 power-key 相同：有源蜂鸣器，音较干净
gpio18_clean_pulse() {
  G=/sys/class/gpio/gpio18
  [ -e "$G" ] && { log "   line18 已被占用，跳过"; return 1; }
  echo 18 > /sys/class/gpio/export 2>/dev/null || return 1
  echo out > "$G/direction" 2>/dev/null || { echo 18 > /sys/class/gpio/unexport 2>/dev/null; return 1; }
  log "  line18=1 约 0.28s 再拉低 (推荐/日常用)"
  echo 1 > "$G/value"
  sleep 0.28
  echo 0 > "$G/value"
  echo 18 > /sys/class/gpio/unexport 2>/dev/null
  return 0
}

# 仅诊断：无源蜂鸣/方波，Shell 快翻会沙啞嘈杂
gpio18_bitbang_diagnostic() {
  G=/sys/class/gpio/gpio18
  [ -e "$G" ] && return 1
  echo 18 > /sys/class/gpio/export 2>/dev/null || return 1
  echo out > "$G/direction" 2>/dev/null || { echo 18 > /sys/class/gpio/unexport 2>/dev/null; return 1; }
  log "  快翻约 0.2s (仅诊断、可能很吵)"
  t=0
  while [ "$t" -lt 2000 ]; do
    echo 1 > "$G/value"
    echo 0 > "$G/value"
    t=$((t + 1))
  done
  echo 0 > "$G/value"
  echo 18 > /sys/class/gpio/unexport 2>/dev/null
  return 0
}

log "=== 蜂鸣器扫描（请全程靠近板子听）==="
log ""

log "1) 厂商节点 gpio_ctrl/buzzer_gpio"
if beep_sysfs; then
  :
else
  log "   skip: 无节点或不可写"
fi
log "   停 1 秒…"; sleep 1
log ""

log "2) GPIO0 line18 — 与 long-press 蜂鸣相同 (清音短促)"
if gpio18_clean_pulse; then
  log "   完成"
else
  log "   未执行"
fi
log "   停 1 秒…"; sleep 1
log ""

n=2
for CHIP in /sys/class/pwm/pwmchip*; do
  n=$((n + 1))
  [ -d "$CHIP" ] || continue
  base=$(basename "$CHIP")
  log "$n) PWM $base  (多板子蜂鸣可能不接在 PWM 上，仅供参考)"
  pwm_beep "$CHIP" 25000 12500 "~40kHz" || log "   失败(忽略)"
  log "   停 0.5 秒…"; sleep 0.5
  pwm_beep "$CHIP" 2000000 1000000 "~500Hz" || true
  log "   停 0.5 秒…"; sleep 0.5
  pwm_beep "$CHIP" 1000000 500000 "1kHz" || true
  log "   停 1 秒…"; sleep 1
  log ""
done

if [ "${BUZZER_DIAG:-0}" = "1" ]; then
  log "最后) 快翻诊断 (嘈杂，仅 BUZZER_DIAG=1 时执行)"
  if gpio18_bitbang_diagnostic; then
    log "   诊断段结束"
  else
    log "   跳过"
  fi
else
  log "（未跑快翻诊断；需要时: BUZZER_DIAG=1 sudo -E $0）"
fi

log ""
log "=== 结束 ==="
log "日常/长按关机提示音 已用「GPIO18 短高脉冲」，与 2) 同逻辑。"
exit 0
