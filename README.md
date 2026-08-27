# 铁牛 Zero1 Tool

这是铁牛 Zero1（RK3568）安装飞牛 OS 后使用的驱动修复组件。

修改于铁牛官方提供的驱动文件。

仓库根目录只保留本说明文件和完整工具目录 `Zero1_tool_install/`。使用时请将该目录复制到 NAS 的 `/home/anna/Zero1_tool_install`。

网页中的风扇设置和 SATA 指示灯设置分别保存，互不影响；宽屏时两栏并排，小屏时上下排列。

## 目录结构

以下内容位于 `Zero1_tool_install/` 内：

- `install_all.sh`：统一安装脚本。
- `uninstall_zero1_tool.sh`：卸载增强功能并恢复完整原版文件。
- `fan_temp_control.sh`：风扇温控脚本，支持 PWM 调速和 GPIO 回退。
- `fan-control.service`：风扇控制服务。
- `web/`：铁牛Zero1tool 网页后台，使用 BusyBox httpd 和 Shell CGI。
- `zero1-tool-httpd.service`：网页后台服务，默认端口 9511。
- `fan-control.conf`：风扇温控配置模板。
- `sata-led.conf`：SATA 指示灯配置模板，可控制硬盘休眠时是否慢闪。
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

- 自动温控
- 手动转速
- 全速散热
- 关闭风扇

温控参数保存后会在一个检测周期内生效。网页使用未保存编辑保护，定时刷新状态时不会覆盖正在填写的参数。

在“SATA 指示灯”区域可以选择硬盘休眠时绿色灯是否一亮一灭。关闭后休眠盘显示绿色常亮，其他 SATA 灯状态不变。

## 默认温控逻辑

```text
低于 50°C：关闭风扇
达到 50°C：开始低速运行
达到 55°C：进入中速逐步调速
达到 70°C：全速运行
达到 90°C：过热保护，强制全速
```

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
