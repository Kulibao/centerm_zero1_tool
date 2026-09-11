#!/bin/sh
set -eu

CONFIG=/etc/zero1-tool/fan.conf
SATA_CONFIG=/etc/zero1-tool/sata-led.conf
BUZZER_CONFIG=/etc/zero1-tool/buzzer.conf
EMMC_HEALTH=/etc/zero1-tool/emmc-health.json
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
SLOT1_PATH='/sys/devices/platform/fc400000.sata/ata*/host*/target*:*:*/*:*:*:*/block'
SLOT2_PATH='/sys/devices/platform/fc800000.sata/ata*/host*/target*:*:*/*:*:*:*/block'
DISK_TEMP_CACHE_SECONDS=30

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
slot_dev() {
  # The argument contains the board-specific sysfs glob and must expand here.
  ls $1 2>/dev/null | head -n 1 || true
}
disk_status_json() {
  slot="$1"; path="$2"; dev="$(slot_dev "$path")"
  if [ -z "$dev" ] || [ ! -e "/sys/block/$dev/stat" ]; then
    rm -f "/run/zero1-tool/disk${slot}-temp" 2>/dev/null || true
    printf '{"device":"","state":"missing","temperature":null}'
    return
  fi

  power='unknown'
  if [ -x /sbin/hdparm ]; then
    power_output=$(/sbin/hdparm -C "/dev/$dev" 2>&1 || true)
    if printf '%s\n' "$power_output" | grep -Eiq 'standby|sleeping'; then
      power='standby'
    elif printf '%s\n' "$power_output" | grep -Eiq 'active/idle'; then
      power='active'
    fi
  fi
  if [ "$power" = standby ]; then
    printf '{"device":"%s","state":"standby","temperature":null}' "$dev"
    return
  fi

  cache="/run/zero1-tool/disk${slot}-temp"
  now=$(date +%s)
  if [ "$power" = active ] && [ -r "$cache" ]; then
    cache_time=$(stat -c %Y "$cache" 2>/dev/null || printf '0')
    cache_dev=$(sed -n '1p' "$cache" 2>/dev/null || true)
    cache_temp=$(sed -n '2p' "$cache" 2>/dev/null || true)
    if [ "$cache_dev" = "$dev" ] && in_range "$cache_temp" 1 125 && [ $((now - cache_time)) -lt "$DISK_TEMP_CACHE_SECONDS" ]; then
      printf '{"device":"%s","state":"active","temperature":%s}' "$dev" "$cache_temp"
      return
    fi
  fi

  smart_output=$(smartctl -n standby -A "/dev/$dev" 2>&1 || true)
  if printf '%s\n' "$smart_output" | grep -Eiq 'device is in standby|device is in sleep'; then
    printf '{"device":"%s","state":"standby","temperature":null}' "$dev"
    return
  fi
  temp=$(printf '%s\n' "$smart_output" | awk '
    $1 == "194" && $10 ~ /^[0-9]+$/ { print $10; exit }
    $1 == "190" && $10 ~ /^[0-9]+$/ { fallback = $10 }
    /Current Drive Temperature:/ { for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) { print $i; exit } }
    END { if (fallback != "") print fallback }
  ' | head -n 1)
  if in_range "$temp" 1 125; then
    mkdir -p /run/zero1-tool
    cache_tmp="${cache}.tmp.$$"
    printf '%s\n%s\n' "$dev" "$temp" > "$cache_tmp" && mv "$cache_tmp" "$cache"
    printf '{"device":"%s","state":"active","temperature":%s}' "$dev" "$temp"
  else
    printf '{"device":"%s","state":"unavailable","temperature":null}' "$dev"
  fi
}

json_quote() { printf '"%s"' "$(printf '%s' "$1" | json_escape)"; }
json_num() { case "$1" in ''|*[!0-9]*) printf 'null';; *) printf '%s' "$1";; esac; }

life_time_label() {
  case "$1" in
    0x01) printf '0%% - 10%%';; 0x02) printf '10%% - 20%%';; 0x03) printf '20%% - 30%%';;
    0x04) printf '30%% - 40%%';; 0x05) printf '40%% - 50%%';; 0x06) printf '50%% - 60%%';;
    0x07) printf '60%% - 70%%';; 0x08) printf '70%% - 80%%';; 0x09) printf '80%% - 90%%';;
    0x0A|0x0a) printf '90%% - 100%%';; 0x0B|0x0b) printf '超过寿命范围';; *) printf '未提供';;
  esac
}

pre_eol_label() {
  case "$1" in
    0x01) printf '正常';; 0x02) printf '警告：接近寿命终点';;
    0x03) printf '严重：已达到寿命终点';; *) printf '未提供';;
  esac
}

find_emmc_block() {
  for p in /sys/block/mmcblk*; do
    [ -d "$p" ] || continue
    type=$(cat "$p/device/type" 2>/dev/null || true)
    removable=$(cat "$p/removable" 2>/dev/null || true)
    if [ "$type" = MMC ] || { [ "$removable" = 0 ] && [ -e "$p/device" ]; }; then
      basename "$p"
      return 0
    fi
  done
  return 1
}

emmc_attr() { [ -r "$1" ] && cat "$1" 2>/dev/null || true; }
emmc_ios_attr() {
  [ -r "$1" ] || return 0
  awk -F: -v key="$2" '$1 == key { sub(/^[[:space:]]*/, "", $2); print $2; exit }' "$1" 2>/dev/null || true
}

emmc_health_read_json() {
  emmc_read_at=$(date '+%Y-%m-%d %H:%M:%S')
  emmc_block=$(find_emmc_block || true)
  if [ -z "$emmc_block" ]; then
    printf '{"available":false,"read_at":%s,"message":"未检测到 eMMC 设备"}\n' "$(json_quote "$emmc_read_at")"
    return 0
  fi

  emmc_device="/sys/block/${emmc_block}/device"
  emmc_card=$(readlink -f "$emmc_device" 2>/dev/null || true)
  [ -n "$emmc_card" ] || emmc_card="$emmc_device"
  emmc_card_name=$(basename "$emmc_card")
  emmc_host_name=$(basename "$(dirname "$emmc_card")")
  emmc_ext_csd="/sys/kernel/debug/${emmc_host_name}/${emmc_card_name}/ext_csd"
  [ -r "$emmc_ext_csd" ] || emmc_ext_csd=''
  emmc_ios="/sys/kernel/debug/${emmc_host_name}/ios"
  [ -r "$emmc_ios" ] || emmc_ios=''

  emmc_name=$(emmc_attr "$emmc_card/name")
  emmc_serial=$(emmc_attr "$emmc_card/serial")
  emmc_date=$(emmc_attr "$emmc_card/date")
  emmc_manfid=$(emmc_attr "$emmc_card/manfid")
  emmc_oemid=$(emmc_attr "$emmc_card/oemid")
  emmc_fwrev=$(emmc_attr "$emmc_card/fwrev")
  emmc_hwrev=$(emmc_attr "$emmc_card/hwrev")
  emmc_revision=$(emmc_attr "$emmc_card/rev")
  emmc_product_revision=$(emmc_attr "$emmc_card/prv")
  emmc_type=$(emmc_attr "$emmc_card/type")
  emmc_cid=$(emmc_attr "$emmc_card/cid")
  emmc_csd=$(emmc_attr "$emmc_card/csd")
  emmc_ocr=$(emmc_attr "$emmc_card/ocr")
  emmc_rca=$(emmc_attr "$emmc_card/rca")
  emmc_dsr=$(emmc_attr "$emmc_card/dsr")
  emmc_life=$(emmc_attr "$emmc_card/life_time")
  emmc_life_a=$(printf '%s\n' "$emmc_life" | awk '{print $1}')
  emmc_life_b=$(printf '%s\n' "$emmc_life" | awk '{print $2}')
  emmc_pre_eol=$(emmc_attr "$emmc_card/pre_eol_info")
  emmc_preferred_erase=$(emmc_attr "$emmc_card/preferred_erase_size")
  emmc_erase_size=$(emmc_attr "$emmc_card/erase_size")
  emmc_wp_group_size=$(emmc_attr "$emmc_card/wp_grp_size")
  emmc_reliable_sectors=$(emmc_attr "$emmc_card/rel_sectors")
  emmc_enhanced_area_offset=$(emmc_attr "$emmc_card/enhanced_area_offset")
  emmc_enhanced_area_size=$(emmc_attr "$emmc_card/enhanced_area_size")
  emmc_raw_rpmb_size_mult=$(emmc_attr "$emmc_card/raw_rpmb_size_mult")
  emmc_enhanced_rpmb_supported=$(emmc_attr "$emmc_card/enhanced_rpmb_supported")
  emmc_ffu_capable=$(emmc_attr "$emmc_card/ffu_capable")
  emmc_cmdq_enabled=$(emmc_attr "$emmc_card/cmdq_en")
  emmc_size_sectors=$(emmc_attr "/sys/block/${emmc_block}/size")
  emmc_size_bytes=$(case "$emmc_size_sectors" in ''|*[!0-9]*) printf ''; ;; *) printf '%s' $((emmc_size_sectors * 512));; esac)
  emmc_size_human=$(lsblk -dnro SIZE "/dev/${emmc_block}" 2>/dev/null || true)
  emmc_logical=$(emmc_attr "/sys/block/${emmc_block}/queue/logical_block_size")
  emmc_physical=$(emmc_attr "/sys/block/${emmc_block}/queue/physical_block_size")
  emmc_ro=$(emmc_attr "/sys/block/${emmc_block}/ro")
  emmc_removable=$(emmc_attr "/sys/block/${emmc_block}/removable")
  emmc_ios_clock=$(emmc_ios_attr "$emmc_ios" clock)
  emmc_ios_actual_clock=$(emmc_ios_attr "$emmc_ios" 'actual clock')
  emmc_ios_vdd=$(emmc_ios_attr "$emmc_ios" vdd)
  emmc_ios_bus_mode=$(emmc_ios_attr "$emmc_ios" 'bus mode')
  emmc_ios_chip_select=$(emmc_ios_attr "$emmc_ios" 'chip select')
  emmc_ios_mode=$(emmc_ios_attr "$emmc_ios" 'timing spec')
  emmc_ios_voltage=$(emmc_ios_attr "$emmc_ios" 'signal voltage')
  emmc_ios_width=$(emmc_ios_attr "$emmc_ios" 'bus width')
  emmc_ios_power=$(emmc_ios_attr "$emmc_ios" 'power mode')
  emmc_ios_driver=$(emmc_ios_attr "$emmc_ios" 'driver type')
  emmc_partitions=$(lsblk -nrpo NAME,SIZE,FSTYPE,MOUNTPOINTS "/dev/${emmc_block}" 2>/dev/null | tr '\t' ' ' || true)
  emmc_stat=$(cat "/sys/block/${emmc_block}/stat" 2>/dev/null || true)
  emmc_reads=$(printf '%s\n' "$emmc_stat" | awk '{print $1}')
  emmc_sectors_read=$(printf '%s\n' "$emmc_stat" | awk '{print $3}')
  emmc_writes=$(printf '%s\n' "$emmc_stat" | awk '{print $5}')
  emmc_sectors_written=$(printf '%s\n' "$emmc_stat" | awk '{print $7}')
  emmc_ext_raw=''
  [ -r "$emmc_ext_csd" ] && emmc_ext_raw=$(head -c 4096 "$emmc_ext_csd" 2>/dev/null || true)
  emmc_temperature=''
  emmc_temp_file=$(find "$emmc_card" -maxdepth 1 -type f -iname '*temp*' -print -quit 2>/dev/null || true)
  [ -n "$emmc_temp_file" ] && emmc_temperature=$(emmc_attr "$emmc_temp_file")

  printf '{"available":true,"read_at":%s,"device":%s,"card_path":%s,"model":%s,"serial":%s,"manufacture_date":%s,"manufacturer_id":%s,"oem_id":%s,"firmware_revision":%s,"hardware_revision":%s,"revision":%s,"product_revision":%s,"type":%s,"cid":%s,"csd":%s,"ocr":%s,"rca":%s,"dsr":%s,"life_time_raw":%s,"life_time_a_raw":%s,"life_time_b_raw":%s,"life_time_a":%s,"life_time_b":%s,"pre_eol_raw":%s,"pre_eol":%s,"preferred_erase_size":%s,"erase_size":%s,"write_protect_group_size":%s,"reliable_sectors":%s,"enhanced_area_offset":%s,"enhanced_area_size":%s,"raw_rpmb_size_multiplier":%s,"enhanced_rpmb_supported":%s,"ffu_capable":%s,"cmdq_enabled":%s,"size_human":%s,"size_sectors":%s,"size_bytes":%s,"logical_block_size":%s,"physical_block_size":%s,"read_only":%s,"removable":%s,"bus_clock":%s,"actual_bus_clock":%s,"bus_vdd":%s,"bus_mode":%s,"chip_select":%s,"bus_timing":%s,"signal_voltage":%s,"bus_width":%s,"power_mode":%s,"driver_type":%s,"temperature":%s,"partitions":%s,"reads_completed_since_boot":%s,"sectors_read_since_boot":%s,"writes_completed_since_boot":%s,"sectors_written_since_boot":%s,"stat_raw":%s,"ext_csd_raw":%s,"message":"读取结果已保存到 /etc/zero1-tool/emmc-health.json"}\n' \
    "$(json_quote "$emmc_read_at")" "$(json_quote "/dev/${emmc_block}")" "$(json_quote "$emmc_card")" "$(json_quote "$emmc_name")" "$(json_quote "$emmc_serial")" "$(json_quote "$emmc_date")" "$(json_quote "$emmc_manfid")" "$(json_quote "$emmc_oemid")" "$(json_quote "$emmc_fwrev")" "$(json_quote "$emmc_hwrev")" "$(json_quote "$emmc_revision")" "$(json_quote "$emmc_product_revision")" "$(json_quote "$emmc_type")" "$(json_quote "$emmc_cid")" "$(json_quote "$emmc_csd")" "$(json_quote "$emmc_ocr")" "$(json_quote "$emmc_rca")" "$(json_quote "$emmc_dsr")" "$(json_quote "$emmc_life")" "$(json_quote "$emmc_life_a")" "$(json_quote "$emmc_life_b")" "$(json_quote "$(life_time_label "$emmc_life_a")")" "$(json_quote "$(life_time_label "$emmc_life_b")")" "$(json_quote "$emmc_pre_eol")" "$(json_quote "$(pre_eol_label "$emmc_pre_eol")")" "$(json_quote "$emmc_preferred_erase")" "$(json_quote "$emmc_erase_size")" "$(json_quote "$emmc_wp_group_size")" "$(json_quote "$emmc_reliable_sectors")" "$(json_quote "$emmc_enhanced_area_offset")" "$(json_quote "$emmc_enhanced_area_size")" "$(json_quote "$emmc_raw_rpmb_size_mult")" "$(json_quote "$emmc_enhanced_rpmb_supported")" "$(json_quote "$emmc_ffu_capable")" "$(json_quote "$emmc_cmdq_enabled")" "$(json_quote "$emmc_size_human")" "$(json_num "$emmc_size_sectors")" "$(json_num "$emmc_size_bytes")" "$(json_num "$emmc_logical")" "$(json_num "$emmc_physical")" "$(json_num "$emmc_ro")" "$(json_num "$emmc_removable")" "$(json_quote "$emmc_ios_clock")" "$(json_quote "$emmc_ios_actual_clock")" "$(json_quote "$emmc_ios_vdd")" "$(json_quote "$emmc_ios_bus_mode")" "$(json_quote "$emmc_ios_chip_select")" "$(json_quote "$emmc_ios_mode")" "$(json_quote "$emmc_ios_voltage")" "$(json_quote "$emmc_ios_width")" "$(json_quote "$emmc_ios_power")" "$(json_quote "$emmc_ios_driver")" "$(json_quote "$emmc_temperature")" "$(json_quote "$emmc_partitions")" "$(json_num "$emmc_reads")" "$(json_num "$emmc_sectors_read")" "$(json_num "$emmc_writes")" "$(json_num "$emmc_sectors_written")" "$(json_quote "$emmc_stat")" "$(json_quote "$emmc_ext_raw")"
}

emmc_health_json() {
  if [ -r "$EMMC_HEALTH" ]; then
    cat "$EMMC_HEALTH"
  else
    printf '{"available":false,"read_at":null,"message":"尚未读取 eMMC 信息，请点击读取按钮"}\n'
  fi
}
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
    disk1=$(disk_status_json 1 "$SLOT1_PATH")
    disk2=$(disk_status_json 2 "$SLOT2_PATH")
    printf '%s' "$body" | sed 's/}[[:space:]]*$//' | awk -v s="$service" -v d1="$disk1" -v d2="$disk2" '{ printf "%s,\"service\":\"%s\",\"disk1\":%s,\"disk2\":%s}\n", $0, s, d1, d2 }'
    printf '\n'
    ;;
  config)
    header
    retention="$(get_value LOG_RETENTION_DAYS)"
    in_range "$retention" 1 30 || retention=3
    enabled="$(get_value LOG_ENABLED)"
    [ "$enabled" = 0 ] || enabled=1
    always_on="$(get_value ALWAYS_ON)"
    [ "$always_on" = 1 ] || always_on=0
    idle_duty="$(get_value IDLE_DUTY_PERCENT)"
    in_range "$idle_duty" 10 40 || idle_duty=20
    printf '{"MODE":"%s","MANUAL_SPEED":"%s","TEMP_OFF":"%s","TEMP_LOW":"%s","TEMP_FULL":"%s","TEMP_CRITICAL":"%s","FAN_DUTY_MIN":"%s","ALWAYS_ON":"%s","IDLE_DUTY_PERCENT":"%s","CHECK_INTERVAL":"%s","LOG_RETENTION_DAYS":"%s","LOG_ENABLED":"%s","STANDBY_BLINK":"%s","BOOT_BEEP":"%s"}\n' \
      "$(get_value MODE)" "$(get_value MANUAL_SPEED)" "$(get_value TEMP_OFF)" "$(get_value TEMP_LOW)" "$(get_value TEMP_FULL)" "$(get_value TEMP_CRITICAL)" "$(get_value FAN_DUTY_MIN)" "$always_on" "$idle_duty" "$(get_value CHECK_INTERVAL)" "$retention" "$enabled" "$(get_sata_value STANDBY_BLINK)" "$(get_buzzer_value BOOT_BEEP)"
    ;;
  emmc_health)
    header
    emmc_health_json
    ;;
  emmc_health_read)
    [ "${REQUEST_METHOD:-}" = POST ] || error '只允许POST请求'
    mkdir -p /etc/zero1-tool
    emmc_tmp="${EMMC_HEALTH}.tmp.$$"
    emmc_body=$(emmc_health_read_json)
    printf '%s\n' "$emmc_body" > "$emmc_tmp" || error '无法保存 eMMC 读取结果'
    chmod 0644 "$emmc_tmp" 2>/dev/null || true
    mv -f "$emmc_tmp" "$EMMC_HEALTH" || error '无法保存 eMMC 读取结果'
    header
    printf '%s\n' "$emmc_body"
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
  save_log)
    [ "${REQUEST_METHOD:-}" = POST ] || error '只允许POST请求'
    length=${CONTENT_LENGTH:-0}; in_range "$length" 1 1024 || error '请求大小无效'
    body=$(dd bs=1 count="$length" 2>/dev/null)
    LOG_RETENTION_DAYS=''
    LOG_ENABLED=''
    oldifs=$IFS; IFS='&'
    for item in $body; do
      key=${item%%=*}; value=${item#*=}; value=$(urldecode "$value")
      case "$key" in
        LOG_RETENTION_DAYS) LOG_RETENTION_DAYS="$value";;
        LOG_ENABLED) LOG_ENABLED="$value";;
      esac
    done
    IFS=$oldifs
    in_range "$LOG_RETENTION_DAYS" 1 30 || error '日志保留天数必须是1到30天'
    [ "$LOG_ENABLED" = 0 ] || [ "$LOG_ENABLED" = 1 ] || error '日志开关参数无效'
    mkdir -p /etc/zero1-tool
    log_tmp="${CONFIG}.tmp.$$"
    if [ -r "$CONFIG" ]; then
      awk -v value="$LOG_RETENTION_DAYS" -v enabled="$LOG_ENABLED" '
        BEGIN { found = 0 }
        /^LOG_RETENTION_DAYS=/ { if (!found) print "LOG_RETENTION_DAYS=" value; found = 1; next }
        /^LOG_ENABLED=/ { if (!enabled_found) print "LOG_ENABLED=" enabled; enabled_found = 1; next }
        { print }
        END { if (!found) print "LOG_RETENTION_DAYS=" value; if (!enabled_found) print "LOG_ENABLED=" enabled }
      ' "$CONFIG" > "$log_tmp"
    else
      printf '# Managed by T-NAS Zero1tool\nLOG_RETENTION_DAYS=%s\nLOG_ENABLED=%s\n' "$LOG_RETENTION_DAYS" "$LOG_ENABLED" > "$log_tmp"
    fi
    mv "$log_tmp" "$CONFIG"
    systemctl kill -s HUP fan-control.service 2>/dev/null || systemctl restart fan-control.service 2>/dev/null || true
    header; printf '{"ok":true}\n'
    ;;
  delete_logs)
    [ "${REQUEST_METHOD:-}" = POST ] || error '只允许POST请求'
    # Remove the active file and any archive/temp using the fixed fan-log prefix only.
    rm -f -- "$LOG" "$LOG".* 2>/dev/null || true
    header; printf '{"ok":true}\n'
    ;;
  save)
    [ "${REQUEST_METHOD:-}" = POST ] || error '只允许POST请求'
    length=${CONTENT_LENGTH:-0}; in_range "$length" 1 8192 || error '请求大小无效'
    body=$(dd bs=1 count="$length" 2>/dev/null)
    MODE=''; MANUAL_SPEED=''; TEMP_OFF=''; TEMP_LOW=''; TEMP_FULL=''; TEMP_CRITICAL=''; FAN_DUTY_MIN=''; CHECK_INTERVAL=''; SATA_STANDBY_BLINK="$(get_sata_value STANDBY_BLINK)"
    ALWAYS_ON="$(get_value ALWAYS_ON)"
    [ "$ALWAYS_ON" = 1 ] || ALWAYS_ON=0
    IDLE_DUTY_PERCENT="$(get_value IDLE_DUTY_PERCENT)"
    in_range "$IDLE_DUTY_PERCENT" 10 40 || IDLE_DUTY_PERCENT=20
    LOG_RETENTION_DAYS="$(get_value LOG_RETENTION_DAYS)"
    in_range "$LOG_RETENTION_DAYS" 1 30 || LOG_RETENTION_DAYS=3
    LOG_ENABLED="$(get_value LOG_ENABLED)"
    [ "$LOG_ENABLED" = 0 ] || [ "$LOG_ENABLED" = 1 ] || LOG_ENABLED=1
    [ "$SATA_STANDBY_BLINK" = 0 ] || SATA_STANDBY_BLINK=1
    oldifs=$IFS; IFS='&'
    for item in $body; do
      key=${item%%=*}; value=${item#*=}; value=$(urldecode "$value")
      case "$key" in
        MODE) MODE="$value";; MANUAL_SPEED) MANUAL_SPEED="$value";; TEMP_OFF) TEMP_OFF="$value";; TEMP_LOW) TEMP_LOW="$value";; TEMP_FULL) TEMP_FULL="$value";; TEMP_CRITICAL) TEMP_CRITICAL="$value";; FAN_DUTY_MIN) FAN_DUTY_MIN="$value";; ALWAYS_ON) ALWAYS_ON="$value";; IDLE_DUTY_PERCENT) IDLE_DUTY_PERCENT="$value";; CHECK_INTERVAL) CHECK_INTERVAL="$value";; SATA_STANDBY_BLINK) SATA_STANDBY_BLINK="$value";;
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
    [ "$ALWAYS_ON" = 0 ] || [ "$ALWAYS_ON" = 1 ] || error '风扇始终运行开关无效'
    in_range "$IDLE_DUTY_PERCENT" 10 40 || error '低温运行功率必须是10到40'
    in_range "$CHECK_INTERVAL" 1 30 || error '检测间隔必须是1到30秒'
    [ "$SATA_STANDBY_BLINK" = 0 ] || [ "$SATA_STANDBY_BLINK" = 1 ] || error '休眠闪烁开关无效'
    [ "$TEMP_OFF" -lt "$TEMP_LOW" ] && [ "$TEMP_LOW" -lt "$TEMP_FULL" ] && [ "$TEMP_FULL" -le "$TEMP_CRITICAL" ] || error '温度阈值必须依次升高'
    mkdir -p /etc/zero1-tool
    tmp="${CONFIG}.tmp.$$"
    umask 022
    {
      echo '# Managed by T-NAS Zero1tool'
      echo "MODE=$MODE"; echo "MANUAL_SPEED=$MANUAL_SPEED"; echo "TEMP_OFF=$TEMP_OFF"; echo "TEMP_LOW=$TEMP_LOW"; echo "TEMP_FULL=$TEMP_FULL"; echo "TEMP_CRITICAL=$TEMP_CRITICAL"; echo "FAN_DUTY_MIN=$FAN_DUTY_MIN"; echo "ALWAYS_ON=$ALWAYS_ON"; echo "IDLE_DUTY_PERCENT=$IDLE_DUTY_PERCENT"; echo "CHECK_INTERVAL=$CHECK_INTERVAL"; echo "LOG_RETENTION_DAYS=$LOG_RETENTION_DAYS"; echo "LOG_ENABLED=$LOG_ENABLED"
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
