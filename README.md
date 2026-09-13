# 铁牛 Zero1 Tool

这是铁牛 Zero1（RK3568）安装飞牛 OS 后使用的驱动修复组件。

修改于铁牛官方提供的驱动文件。

当前版本号：`2609131530`

最新版本：[GitHub 项目仓库](https://github.com/Kulibao/centerm_zero1_tool)

仓库根目录只保留本说明文件和完整工具目录 `Zero1_tool_install/`。使用时请将该目录复制到 NAS 的 `/home/anna/Zero1_tool_install`。

## 目录结构

以下内容位于 `Zero1_tool_install/` 内：

- `install_all.sh`：统一安装脚本。
- `uninstall_zero1_tool.sh`：卸载增强功能并恢复完整原版文件。
- `fan_temp_control.sh`：风扇温控脚本，支持 PWM 调速和 GPIO 回退。
- `fan-control.service`：风扇控制服务。
- `web/`：铁牛Zero1tool 网页后台，使用 BusyBox httpd 和 Shell CGI。
- `zero1-buzzer-test.sh`：网页蜂鸣器“一声测试”入口，不执行关机。
- `fnos_kernel_fix.sh`：飞牛内核更新后的 DTB、initramfs 和 RK3568 GPU 驱动修复脚本。
- `fnos_npu_fix.sh`：RK3568 NPU 修复脚本，修复完成后自动重启设备。
- `zero1-lvm-activate.sh`：开机时在 `trim_init.service` 前主动激活 LVM 卷组，减少数据卷未及时出现导致的启动等待。
- `zero1-lvm-activate.service`：LVM 预激活脚本的 systemd 服务。
- `trim-init-lvm-activate.conf`：确保 `trim_init.service` 明确等待 LVM 预激活完成。
- `zero1-tool-httpd.service`：网页后台服务，默认端口 9511。
- `zero1-set-mac.sh`：校验并持久化 eth0 自定义 MAC 地址，配置后自动重启设备。
- `fan-control.conf`：风扇温控配置模板。
- `LOG_RETENTION_DAYS`：风扇日志按天归档后的保留天数，默认 3 天，可在网页“日志设置”中调整为 1-30 天。
- `LOG_ENABLED`：风扇日志开关，默认开启；关闭后不再写入新的风扇日志。
- `sata-led.conf`：SATA 指示灯配置模板，可控制硬盘休眠时是否慢闪。
- `buzzer.conf`：开机蜂鸣开关的配置模板。
- `original_files/`：为铁牛官方驱动文件，不能删除。

## 安装

必须把整个目录复制到飞牛 NAS 的固定路径：

```text
/home/anna/Zero1_tool_install
```

然后通过 SSH 执行：

```sh
sudo bash /home/anna/Zero1_tool_install/install_all.sh
```

安装脚本会安装设备树、蜂鸣器、电源键、电源灯、SATA 灯和风扇控制，并启用网页后台。

## 网页后台

安装完成后打开：

```text
http://NAS_IP:9511/
```

页面名称为“铁牛Zero1tool”，可以查看 CPU 温度、风扇档位、PWM 占空比和日志，并切换：

- 点击顶部监控按钮可进入副屏监控模式，仅显示 CPU 温度、两个硬盘状态、当前转速档位、PWM 占空比和控制后端六项实时数据；右上角“退出监控”可返回完整页面。

- 自动温控
- 手动转速
- 全速散热
- 关闭风扇

自动温控可选“风扇始终运行”。开启后，CPU 温度低于低温阈值时，风扇保持 `0 / 15` 档显示，并按可设置的 `10%-40%` PWM 占空比持续运行；默认已开启，默认低温运行功率为 `30%`，不影响手动转速、全速散热和关闭风扇模式。

网页包含“eMMC”区域。寿命估算 A、寿命估算 B 和预 EOL 状态会优先显示，其余设备信息默认收在“其他数据”折叠区。只有点击“读取 eMMC 信息”时才会读取一次 eMMC；读取结果和时间保存在 NAS 的 `/etc/zero1-tool/emmc-health.json`，因此不同电脑或手机打开网页时都能看到同一份上次读取结果。硬件或内核没有提供的数据会显示“设备未提供”。

网页的“自定义 MAC 地址”区域将地址拆分为六组输入框，并在前端和后端同时检查格式、全零地址、广播地址和组播地址。保存后会写入 NetworkManager 的 eth0 连接配置，设备约 5 秒后自动重启；重启期间网页和 SSH 会暂时断开。

温控参数保存后会在一个检测周期内生效。网页使用未保存编辑保护，定时刷新状态时不会覆盖正在填写的参数。

网页顶部会显示两个 SATA 盘位的实时硬盘温度。硬盘休眠时显示“休眠”，空盘位显示“无硬盘”；状态检测不会唤醒已经休眠的硬盘，活动硬盘的温度最多每 30 秒刷新一次。

风扇日志会按天保存为 `/var/log/fan_control.log.YYYY-MM-DD`，当前日志仍写入 `/var/log/fan_control.log`。超过网页设置保留天数的归档会自动删除，默认保留 3 天。

网页“日志设置”可以关闭日志，或在确认后删除当前日志及全部按天归档；删除操作不可恢复。

在“SATA 指示灯”区域可以选择硬盘休眠时绿色灯是否一亮一灭。关闭后休眠盘显示绿色常亮，其他 SATA 灯状态不变。

在“蜂鸣器”区域可以开启或关闭开机蜂鸣，可以使用“响一声测试”检查蜂鸣器。

内核更新后可执行：

```sh
sudo bash /home/anna/Zero1_tool_install/fnos_kernel_fix.sh
```

内核修复脚本会恢复 Zero1 的 DTB，刷新新内核的模块依赖，登记 `rkgpu_bifrost_jm` GPU 驱动，并将其加入 initramfs 和开机自动加载配置。

NPU 修复前请先在飞牛应用商店安装“AI 引擎 (RK356X)”，然后执行：

```sh
sudo bash /home/anna/Zero1_tool_install/fnos_npu_fix.sh
```

NPU 修复会启用设备树节点并配置 `rknpu` 驱动开机自动加载；完成后会自动重启设备，请提前保存文件。

## 默认温控逻辑

```text
低于 50°C：开启“风扇始终运行”时按设定低温功率运行；关闭该选项时关闭风扇
达到 50°C：开始低速运行
达到 55°C：进入中速逐步调速
达到 70°C：全速运行
达到 90°C：过热保护，强制全速
```

开启“风扇始终运行”后，第一行会改为：低于 50°C 时保持 `0 / 15` 档，并按设定的低温运行功率持续运行。默认最低启动占空比为 `50%`，用于保证风扇可靠启动。

风扇服务启动阶段会先使用最高速；温度读取失败时也保持最高速，读取恢复后再按照当前模式调速。

## 卸载与恢复

执行：

```sh
sudo bash /home/anna/Zero1_tool_install/uninstall_zero1_tool.sh
```

卸载脚本会停止并删除网页后台、配置和运行目录，然后从 `original_files/` 恢复所有原版脚本、service 和 DTB。

## 常用检查

```sh
systemctl status fan-control.service --no-pager
systemctl status zero1-tool-httpd.service --no-pager
ss -ltnp | grep 9511
tail -n 80 /var/log/fan_control.log
```

网页服务文件位于 `/usr/local/lib/zero1-tool/www/`，风扇配置位于 `/etc/zero1-tool/fan.conf`。
SATA 指示灯配置位于 `/etc/zero1-tool/sata-led.conf`。
