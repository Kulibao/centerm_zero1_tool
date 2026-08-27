#!/bin/sh
set -eu

CONFIG=/etc/zero1-tool/fan.conf
SATA_CONFIG=/etc/zero1-tool/sata-led.conf
BUZZER_CONFIG=/etc/zero1-tool/buzzer.conf
STATUS=/run/zero1-tool/fan-status.json
LOG=/var/log/fan_control.log
KERNEL_FIX=/home/anna/Zero1_tool_install/fnos_kernel_fix.sh
KERNEL_FIX_DIR=/run/zero1-tool
KERNEL_FIX_PID=${KERNEL_FIX_DIR}/kernel-fix.pid
KERNEL_FIX_LOG=${KERNEL_FIX_DIR}/kernel-fix.log
KERNEL_FIX_RESULT=${KERNEL_FIX_DIR}/kernel-fix.result
NPU_FIX=/home/anna/Zero1_tool_install/fnos_npu_fix.sh
NPU_FIX_PID=${KERNEL_FIX_DIR}/npu-fix.pid
NPU_FIX_LOG=${KERNEL_FIX_DIR}/npu-fix.log
NPU_FIX_RESULT=${KERNEL_FIX_DIR}/npu-fix.result

header() { printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nStatus: %s\r\n\r\n' "${1:-200 OK}"; }
error() { header "400 Bad Request"; printf '{"error":"%s"}\n' "$1"; exit 0; }
conflict() { header "409 Conflict"; printf '{"error":"%s"}\n' "$1"; exit 0; }
json_escape() { sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r//g;s/\n/\\n/g'; }
get_value() { sed -n "s/^$1=//p" "$CONFIG" 2>/dev/null | tail -n 1; }
get_sata_value() { sed -n "s/^$1=//p" "$SATA_CONFIG" 2>/dev/null | tail -n 1; }
get_buzzer_value() { sed -n "s/^$1=//p" "$BUZZER_CONFIG" 2>/dev/null | tail -n 1; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
in_range() { is_uint "$1" && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
urldecode() { printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g;s/%/\\x/g')"; }
kernel_fix_running() {
  [ -s "$KERNEL_FIX_PID" ] || return 1
  pid=$(cat "$KERNEL_FIX_PID" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  kill -0 "$pid" 2>/dev/null
}
kernel_fix_json() {
  running=false; kernel_fix_running && running=true
  result='null'
  if [ -s "$KERNEL_FIX_RESULT" ]; then
    result=$(cat "$KERNEL_FIX_RESULT" 2>/dev/null | head -n 1)
    is_uint "$result" || result='null'
  fi
  started=''
  [ -s "${KERNEL_FIX_LOG}.started" ] && started=$(cat "${KERNEL_FIX_LOG}.started" 2>/dev/null | head -n 1 || true)
  text=''
  [ -r "$KERNEL_FIX_LOG" ] && text=$(tail -n 160 "$KERNEL_FIX_LOG" | json_escape)
  printf '{"running":%s,"started_at":"%s","exit_code":%s,"text":"%s"}\n' "$running" "$started" "$result" "$text"
}
npu_fix_running() {
  [ -s "$NPU_FIX_PID" ] || return 1
  pid=$(cat "$NPU_FIX_PID" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  kill -0 "$pid" 2>/dev/null
}
npu_fix_json() {
  running=false; npu_fix_running && running=true
  result='null'
  if [ -s "$NPU_FIX_RESULT" ]; then
    result=$(cat "$NPU_FIX_RESULT" 2>/dev/null | head -n 1)
    is_uint "$result" || result='null'
  fi
  started=''
  [ -s "${NPU_FIX_LOG}.started" ] && started=$(cat "${NPU_FIX_LOG}.started" 2>/dev/null | head -n 1 || true)
  text=''
  [ -r "$NPU_FIX_LOG" ] && text=$(tail -n 160 "$NPU_FIX_LOG" | json_escape)
  printf '{"running":%s,"started_at":"%s","exit_code":%s,"text":"%s"}\n' "$running" "$started" "$result" "$text"
}

action=$(printf '%s' "${QUERY_STRING:-}" | sed -n 's/^action=\([^&]*\).*$/\1/p')
case "$action" in
  status)
    header
    if [ -r "$STATUS" ]; then
      body=$(cat "$STATUS")
    else
      body='{"temperature":null,"speed":null,"duty_percent":null,"backend":"unknown"}'
    fi
    service=inactive
    systemctl is-active --quiet fan-control.service 2>/dev/null && service=active
    printf '%s' "$body" | sed 's/}[[:space:]]*$//' | awk -v s="$service" '{ printf "%s,\"service\":\"%s\"}\n", $0, s }'
    printf '\n'
    ;;
  config)
    header
    printf '{"MODE":"%s","MANUAL_SPEED":"%s","TEMP_OFF":"%s","TEMP_LOW":"%s","TEMP_FULL":"%s","TEMP_CRITICAL":"%s","FAN_DUTY_MIN":"%s","CHECK_INTERVAL":"%s","STANDBY_BLINK":"%s","BOOT_BEEP":"%s"}\n' \
      "$(get_value MODE)" "$(get_value MANUAL_SPEED)" "$(get_value TEMP_OFF)" "$(get_value TEMP_LOW)" "$(get_value TEMP_FULL)" "$(get_value TEMP_CRITICAL)" "$(get_value FAN_DUTY_MIN)" "$(get_value CHECK_INTERVAL)" "$(get_sata_value STANDBY_BLINK)" "$(get_buzzer_value BOOT_BEEP)"
    ;;
  logs)
    header
    if [ -r "$LOG" ]; then text=$(tail -n 80 "$LOG" | json_escape); else text=''; fi
    printf '{"text":"%s"}\n' "$text"
    ;;
  kernel_fix_start)
    [ "${REQUEST_METHOD:-}" = POST ] || error '只允许POST请求'
    [ -f "$KERNEL_FIX" ] || error '未找到内核修复脚本'
    [ -x "$KERNEL_FIX" ] || chmod 755 "$KERNEL_FIX" 2>/dev/null || error '内核修复脚本不可执行'
    kernel_fix_running && conflict '内核修复正在运行，请等待当前任务完成'
    npu_fix_running && conflict 'NPU修复正在运行，不能同时执行内核修复'
    mkdir -p "$KERNEL_FIX_DIR"
    : > "$KERNEL_FIX_LOG"
    : > "$KERNEL_FIX_RESULT"
    date '+%Y-%m-%d %H:%M:%S' > "${KERNEL_FIX_LOG}.started"
    (
      set +e
      /bin/bash "$KERNEL_FIX" > "$KERNEL_FIX_LOG" 2>&1
      rc=$?
      printf '%s\n' "$rc" > "$KERNEL_FIX_RESULT"
      rm -f "$KERNEL_FIX_PID"
    ) >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$KERNEL_FIX_PID"
    header; printf '{"ok":true,"message":"内核修复已启动"}\n'
    ;;
  kernel_fix_status)
    header
    kernel_fix_json
    ;;
  npu_fix_start)
    [ "${REQUEST_METHOD:-}" = POST ] || error '只允许POST请求'
    [ -f "$NPU_FIX" ] || error '未找到NPU修复脚本'
    [ -x "$NPU_FIX" ] || chmod 755 "$NPU_FIX" 2>/dev/null || error 'NPU修复脚本不可执行'
    npu_fix_running && conflict 'NPU修复正在运行，请等待设备重启'
    kernel_fix_running && conflict '内核修复正在运行，不能同时执行NPU修复'
    mkdir -p "$KERNEL_FIX_DIR"
    : > "$NPU_FIX_LOG"
    : > "$NPU_FIX_RESULT"
    date '+%Y-%m-%d %H:%M:%S' > "${NPU_FIX_LOG}.started"
    (
      set +e
      /bin/bash "$NPU_FIX" > "$NPU_FIX_LOG" 2>&1
      rc=$?
      printf '%s\n' "$rc" > "$NPU_FIX_RESULT"
      rm -f "$NPU_FIX_PID"
    ) >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$NPU_FIX_PID"
    header; printf '{"ok":true,"message":"NPU修复已启动，完成后设备将自动重启"}\n'
    ;;
  npu_fix_status)
    header
    npu_fix_json
    ;;
  save_sata)
    [ "${REQUEST_METHOD:-}" = POST ] || error '只允许POST请求'
    length=${CONTENT_LENGTH:-0}; in_range "$length" 1 1024 || error '请求大小无效'
    body=$(dd bs=1 count="$length" 2>/dev/null)
    SATA_STANDBY_BLINK=''
    oldifs=$IFS; IFS='&'
    for item in $body; do
      key=${item%%=*}; value=${item#*=}; value=$(urldecode "$value")
      [ "$key" = SATA_STANDBY_BLINK ] && SATA_STANDBY_BLINK="$value"
    done
    IFS=$oldifs
    [ "$SATA_STANDBY_BLINK" = 0 ] || [ "$SATA_STANDBY_BLINK" = 1 ] || error '休眠闪烁开关无效'
    mkdir -p /etc/zero1-tool
    sata_tmp="${SATA_CONFIG}.tmp.$$"
    { echo '# Managed by T-NAS Zero1tool'; echo "STANDBY_BLINK=$SATA_STANDBY_BLINK"; } > "$sata_tmp"
    mv "$sata_tmp" "$SATA_CONFIG"
    systemctl kill -s HUP sata-led-manager.service 2>/dev/null || systemctl restart sata-led-manager.service 2>/dev/null || true
    header; printf '{"ok":true}\n'
    ;;
  save_buzzer)
    [ "${REQUEST_METHOD:-}" = POST ] || error '只允许POST请求'
    length=${CONTENT_LENGTH:-0}; in_range "$length" 1 1024 || error '请求大小无效'
    body=$(dd bs=1 count="$length" 2>/dev/null)
    BOOT_BEEP=''
    oldifs=$IFS; IFS='&'
    for item in $body; do
      key=${item%%=*}; value=${item#*=}; value=$(urldecode "$value")
      case "$key" in
        BOOT_BEEP) BOOT_BEEP="$value";;
      esac
    done
    IFS=$oldifs
    [ "$BOOT_BEEP" = 0 ] || [ "$BOOT_BEEP" = 1 ] || error '开机蜂鸣开关无效'
    mkdir -p /etc/zero1-tool
    buzzer_tmp="${BUZZER_CONFIG}.tmp.$$"
    {
      echo '# Managed by T-NAS Zero1tool'
      echo "BOOT_BEEP=$BOOT_BEEP"
    } > "$buzzer_tmp"
    mv "$buzzer_tmp" "$BUZZER_CONFIG"
    header; printf '{"ok":true}\n'
    ;;
  test_buzzer)
    [ "${REQUEST_METHOD:-}" = POST ] || error '只允许POST请求'
    if /usr/local/sbin/zero1-buzzer-test.sh >/dev/null 2>&1; then
      header; printf '{"ok":true}\n'
    else
      error '蜂鸣器测试失败，请检查蜂鸣器节点或权限'
    fi
    ;;
  save)
    [ "${REQUEST_METHOD:-}" = POST ] || error '只允许POST请求'
    length=${CONTENT_LENGTH:-0}; in_range "$length" 1 8192 || error '请求大小无效'
    body=$(dd bs=1 count="$length" 2>/dev/null)
    MODE=''; MANUAL_SPEED=''; TEMP_OFF=''; TEMP_LOW=''; TEMP_FULL=''; TEMP_CRITICAL=''; FAN_DUTY_MIN=''; CHECK_INTERVAL=''; SATA_STANDBY_BLINK="$(get_sata_value STANDBY_BLINK)"
    [ "$SATA_STANDBY_BLINK" = 0 ] || SATA_STANDBY_BLINK=1
    oldifs=$IFS; IFS='&'
    for item in $body; do
      key=${item%%=*}; value=${item#*=}; value=$(urldecode "$value")
      case "$key" in
        MODE) MODE="$value";; MANUAL_SPEED) MANUAL_SPEED="$value";; TEMP_OFF) TEMP_OFF="$value";; TEMP_LOW) TEMP_LOW="$value";; TEMP_FULL) TEMP_FULL="$value";; TEMP_CRITICAL) TEMP_CRITICAL="$value";; FAN_DUTY_MIN) FAN_DUTY_MIN="$value";; CHECK_INTERVAL) CHECK_INTERVAL="$value";; SATA_STANDBY_BLINK) SATA_STANDBY_BLINK="$value";;
      esac
    done
    IFS=$oldifs
    case "$MODE" in auto|manual|full|off) :;; *) error '模式无效';; esac
    in_range "$MANUAL_SPEED" 0 15 || error '手动档位必须是0到15'
    in_range "$TEMP_OFF" 30 75 || error '关闭温度必须是30到75'
    in_range "$TEMP_LOW" 31 80 || error '低速温度必须是31到80'
    in_range "$TEMP_FULL" 32 90 || error '全速温度必须是32到90'
    in_range "$TEMP_CRITICAL" 33 105 || error '过热温度必须是33到105'
    in_range "$FAN_DUTY_MIN" 40 100 || error '最低占空比必须是40到100'
    in_range "$CHECK_INTERVAL" 1 30 || error '检测间隔必须是1到30秒'
    [ "$SATA_STANDBY_BLINK" = 0 ] || [ "$SATA_STANDBY_BLINK" = 1 ] || error '休眠闪烁开关无效'
    [ "$TEMP_OFF" -lt "$TEMP_LOW" ] && [ "$TEMP_LOW" -lt "$TEMP_FULL" ] && [ "$TEMP_FULL" -le "$TEMP_CRITICAL" ] || error '温度阈值必须依次升高'
    mkdir -p /etc/zero1-tool
    tmp="${CONFIG}.tmp.$$"
    umask 022
    {
      echo '# Managed by T-NAS Zero1tool'
      echo "MODE=$MODE"; echo "MANUAL_SPEED=$MANUAL_SPEED"; echo "TEMP_OFF=$TEMP_OFF"; echo "TEMP_LOW=$TEMP_LOW"; echo "TEMP_FULL=$TEMP_FULL"; echo "TEMP_CRITICAL=$TEMP_CRITICAL"; echo "FAN_DUTY_MIN=$FAN_DUTY_MIN"; echo "CHECK_INTERVAL=$CHECK_INTERVAL"
      echo "STARTUP_SPEED=$(get_value STARTUP_SPEED)"; echo "STARTUP_HOLD=$(get_value STARTUP_HOLD)"
    } > "$tmp"
    mv "$tmp" "$CONFIG"
    sata_tmp="${SATA_CONFIG}.tmp.$$"
    {
      echo '# Managed by T-NAS Zero1tool'
      echo "STANDBY_BLINK=$SATA_STANDBY_BLINK"
    } > "$sata_tmp"
    mv "$sata_tmp" "$SATA_CONFIG"
    systemctl kill -s HUP fan-control.service 2>/dev/null || systemctl restart fan-control.service 2>/dev/null || true
    systemctl kill -s HUP sata-led-manager.service 2>/dev/null || systemctl restart sata-led-manager.service 2>/dev/null || true
    header; printf '{"ok":true}\n'
    ;;
  *) error '接口不存在';;
esac
