#!/bin/sh
set -eu

# 网页“响一声”测试：绕过开机蜂鸣开关，但不执行关机动作。
exec /usr/local/sbin/beep-short.sh --force
