铁牛 Zero1 Tool 安装说明
========================

本目录是铁牛 Zero1（RK3568）安装飞牛 OS 后使用的驱动修复组件（修改自铁牛官方驱动文件）。

一、固定安装目录
----------------
必须将整个目录复制到飞牛 NAS：

  /home/anna/Zero1_tool_install

安装脚本会检查固定路径，路径不正确时不会继续执行。

二、安装
--------
通过 SSH 执行：

  sudo bash /home/anna/Zero1_tool_install/install_all.sh

脚本会安装设备树、蜂鸣器、电源键、电源灯、SATA 灯和风扇控制，并启用网页后台。

三、网页后台
------------
安装后访问：

  http://NAS_IP:9511/

网页名称：铁牛Zero1tool
网页后台使用 BusyBox httpd 和 Shell CGI，不需要 Python。
可查看温度、风扇档位、PWM 占空比和日志，并调整自动温控、手动转速、全速散热和关闭风扇模式。
网页中的“SATA 指示灯”区域可以选择硬盘休眠时绿色灯是否一亮一灭；关闭后休眠盘显示绿色常亮。
风扇设置和 SATA 设置有各自独立的保存按钮。

四、默认温控逻辑
----------------
  低于 50°C：关闭风扇
  达到 50°C：开始低速运行
  达到 55°C：进入中速逐步调速
  达到 70°C：全速运行
  达到 90°C：过热保护，强制全速

风扇启动阶段先使用最高速；温度读取失败时保持最高速，读取到有效温度后再自动调速。

五、卸载与恢复原版
------------------
执行：

  sudo bash /home/anna/Zero1_tool_install/uninstall_zero1_tool.sh

卸载脚本会删除网页后台、配置和运行目录，并从 original_files/ 恢复全部原版脚本、service 和 DTB。
original_files/ 是完整原版快照，请勿删除或修改。
恢复完成后会询问是否立即重启，输入 Y 才会重启。

六、常用检查
------------
  systemctl status fan-control.service --no-pager
  systemctl status zero1-tool-httpd.service --no-pager
  ss -ltnp | grep 9511
  tail -n 80 /var/log/fan_control.log

主要运行路径：
  网页文件：/usr/local/lib/zero1-tool/www/
  风扇配置：/etc/zero1-tool/fan.conf
  SATA 灯配置：/etc/zero1-tool/sata-led.conf
  风扇日志：/var/log/fan_control.log
