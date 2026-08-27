Unified install package for this RK3568 machine
=============================================

Included components
-------------------
- Device tree:
  - rk3568-nanopi-r5s-new.dtb
- Buzzer:
  - beep-short.sh
  - beep-boot.service
  - power-key.sh
  - triggerhappy-power-key.conf
  - buzzer-test.sh
- Power LED:
  - power-led-solid.sh
  - power-led-solid.service
- SATA LEDs:
  - sata-led-enable.sh
  - sata-led-enable.service
  - sata-led-manager.sh
  - sata-led-manager.service
  - SMART health checks use standby-safe mode and are limited to once every 5 minutes; standby indication uses the non-waking "/sbin/hdparm -C" power-state query.
  - LED policy: normal idle is solid green; disk standby is slow green blink; disk activity is fast green blink; SMART failure is solid red; empty slot is slow red blink.
- Fan:
  - fan_temp_control.sh
  - fan-control.service
  - Temperature policy: below 50C off, 50-55C low speed, 55-70C medium speed, 70C and above full speed.

Install on target machine
-------------------------
1) Copy this whole folder to the target machine as exactly:
   /home/anna/Zero1_tool_install
2) Run:
   sudo bash /home/anna/Zero1_tool_install/install_all.sh
3) Reboot:
   sudo reboot

Web management
--------------
- Open http://NAS_IP:9511/ after installation.
- Page title: T-NAS Zero1tool (Chinese UI: 铁牛Zero1tool).
- Supports automatic, manual, full-speed and off modes.
- Temperature thresholds and manual speed are saved to /etc/zero1-tool/fan.conf
  and applied to fan-control.service within one control interval.
- Fan control uses the original multi-user startup timing. It uses full speed
  whenever the temperature reading is unavailable, then changes to the selected
  mode after a valid reading is obtained.
- Runtime status: /run/zero1-tool/fan-status.json
- Web service: zero1-tool-httpd.service
- The web backend uses BusyBox httpd and shell CGI; Python is not required.
- The old Python prototype files are not included.
- If port 9511 cannot be opened, check:
  systemctl status zero1-tool-httpd.service --no-pager
  journalctl -u zero1-tool-httpd.service -n 50 --no-pager
  ss -ltnp | grep 9511
  command -v busybox; command -v httpd

Notes
-----
- install_all.sh backs up existing DTB as:
  /boot/dtb/rockchip/rk3568-nanopi-r5s.dtb.bak_YYYYmmdd_HHMMSS
- SATA LED manager replaces HDled_monit_v0.service.
- The installer refuses to run unless its directory is /home/anna/Zero1_tool_install.
- original_files/ is a complete copy of the original install package. To remove this
  version and restore every original script/service, run:
  sudo bash /home/anna/Zero1_tool_install/uninstall_zero1_tool.sh
