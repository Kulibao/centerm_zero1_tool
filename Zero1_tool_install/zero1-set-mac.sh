#!/usr/bin/env bash
set -euo pipefail

# 铁牛 Zero1 自定义 MAC 地址工具
# 用法：sudo bash zero1-set-mac.sh 02:aa:bb:cc:dd:ee
#
# Zero1 的 system_setmac.service 会根据 eMMC CID 设置硬件网卡地址，
# 因此修改 /etc/machine-id 不会改变 eth0 MAC。本脚本通过 NetworkManager
# 的 cloned-mac-address 持久化自定义地址，重启后由 NetworkManager 应用。

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "请使用 root 权限运行：sudo bash $0 02:aa:bb:cc:dd:ee" >&2
    exit 1
fi

MAC_RAW="${1:-}"
if [[ -z "$MAC_RAW" ]]; then
    echo "用法：sudo bash $0 XX:XX:XX:XX:XX:XX" >&2
    echo "示例：sudo bash $0 02:aa:bb:cc:dd:ee" >&2
    exit 2
fi

# 统一为小写并校验为标准 6 字节单播地址。
MAC="${MAC_RAW,,}"
if [[ ! "$MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
    echo "错误：MAC 地址格式不正确，应为 XX:XX:XX:XX:XX:XX" >&2
    exit 2
fi
FIRST_OCTET=$((16#${MAC:0:2}))
if (( (FIRST_OCTET & 1) != 0 )); then
    echo "错误：不能使用组播 MAC 地址（首字节最低位必须为 0）" >&2
    exit 2
fi
if [[ "$MAC" == "00:00:00:00:00:00" ]]; then
    echo "错误：不能使用全零 MAC 地址" >&2
    exit 2
fi
if (( (FIRST_OCTET & 2) == 0 )); then
    echo "提示：建议使用本地管理地址，首字节通常以 2、6、A 或 E 开头。"
fi

command -v nmcli >/dev/null 2>&1 || {
    echo "错误：未找到 NetworkManager/nmcli，无法持久化 MAC。" >&2
    exit 1
}

# 找到绑定 eth0 的连接；优先使用当前活动连接。
# 不要解析 `nmcli -t -f NAME,DEVICE` 的冒号分隔输出：连接名称本身
# 可能包含冒号，直接按冒号切分会把连接名错误变成“名称:eth0”。
CONNECTION="$(nmcli -g GENERAL.CONNECTION device show eth0 2>/dev/null | head -n 1)"
[[ "$CONNECTION" == "--" ]] && CONNECTION=""
if [[ -z "$CONNECTION" ]]; then
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        iface="$(nmcli -g connection.interface-name connection show "$candidate" 2>/dev/null | head -n 1)"
        if [[ "$iface" == "eth0" ]]; then
            CONNECTION="$candidate"
            break
        fi
    done < <(nmcli -g NAME connection show 2>/dev/null)
fi
if [[ -z "$CONNECTION" ]]; then
    echo "错误：没有找到绑定 eth0 的 NetworkManager 连接。" >&2
    nmcli -f NAME,DEVICE connection show >&2 || true
    exit 1
fi

echo "网卡：eth0"
echo "连接：$CONNECTION"
echo "目标 MAC：$MAC"

# 由 NetworkManager 持久化，避免 system_setmac.service 在重启时覆盖。
nmcli connection modify "$CONNECTION" 802-3-ethernet.cloned-mac-address "$MAC"

STATE_FILE=/etc/zero1-custom-mac.conf
umask 022
{
    echo "# Managed by zero1-set-mac.sh"
    echo "INTERFACE=eth0"
    echo "CONNECTION=$(printf '%q' "$CONNECTION")"
    echo "MAC_ADDRESS=$MAC"
    echo "UPDATED_AT=$(date '+%Y-%m-%d %H:%M:%S %z')"
} > "$STATE_FILE"

echo "已写入 NetworkManager 配置：$STATE_FILE"
echo "当前运行中的 MAC 不会在本次会话中强制切换，重启后生效。"
echo "设备将在 5 秒后重启，请先保存正在编辑的文件。"
sleep 5
/sbin/reboot
