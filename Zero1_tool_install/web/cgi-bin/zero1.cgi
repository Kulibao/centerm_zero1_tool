#!/bin/sh
set -eu

CONFIG=/etc/zero1-tool/fan.conf
STATUS=/run/zero1-tool/fan-status.json
LOG=/var/log/fan_control.log

header() { printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nStatus: %s\r\n\r\n' "${1:-200 OK}"; }
error() { header "400 Bad Request"; printf '{"error":"%s"}\n' "$1"; exit 0; }
json_escape() { sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r//g;s/\n/\\n/g'; }
get_value() { sed -n "s/^$1=//p" "$CONFIG" 2>/dev/null | tail -n 1; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
in_range() { is_uint "$1" && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
urldecode() { printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g;s/%/\\x/g')"; }

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
    printf '{"MODE":"%s","MANUAL_SPEED":"%s","TEMP_OFF":"%s","TEMP_LOW":"%s","TEMP_FULL":"%s","TEMP_CRITICAL":"%s","FAN_DUTY_MIN":"%s","CHECK_INTERVAL":"%s"}\n' \
      "$(get_value MODE)" "$(get_value MANUAL_SPEED)" "$(get_value TEMP_OFF)" "$(get_value TEMP_LOW)" "$(get_value TEMP_FULL)" "$(get_value TEMP_CRITICAL)" "$(get_value FAN_DUTY_MIN)" "$(get_value CHECK_INTERVAL)"
    ;;
  logs)
    header
    if [ -r "$LOG" ]; then text=$(tail -n 80 "$LOG" | json_escape); else text=''; fi
    printf '{"text":"%s"}\n' "$text"
    ;;
  save)
    [ "${REQUEST_METHOD:-}" = POST ] || error '只允许POST请求'
    length=${CONTENT_LENGTH:-0}; in_range "$length" 1 8192 || error '请求大小无效'
    body=$(dd bs=1 count="$length" 2>/dev/null)
    MODE=''; MANUAL_SPEED=''; TEMP_OFF=''; TEMP_LOW=''; TEMP_FULL=''; TEMP_CRITICAL=''; FAN_DUTY_MIN=''; CHECK_INTERVAL=''
    oldifs=$IFS; IFS='&'
    for item in $body; do
      key=${item%%=*}; value=${item#*=}; value=$(urldecode "$value")
      case "$key" in
        MODE) MODE="$value";; MANUAL_SPEED) MANUAL_SPEED="$value";; TEMP_OFF) TEMP_OFF="$value";; TEMP_LOW) TEMP_LOW="$value";; TEMP_FULL) TEMP_FULL="$value";; TEMP_CRITICAL) TEMP_CRITICAL="$value";; FAN_DUTY_MIN) FAN_DUTY_MIN="$value";; CHECK_INTERVAL) CHECK_INTERVAL="$value";;
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
    systemctl kill -s HUP fan-control.service 2>/dev/null || systemctl restart fan-control.service 2>/dev/null || true
    header; printf '{"ok":true}\n'
    ;;
  *) error '接口不存在';;
esac
