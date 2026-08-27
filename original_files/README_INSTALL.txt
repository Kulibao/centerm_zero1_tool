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
- Fan:
  - fan_temp_control.sh
  - fan-control.service

Install on target machine
-------------------------
1) Copy this whole /home/anna/install directory to target machine.
2) Run:
   sudo bash /home/anna/install/install_all.sh
3) Reboot:
   sudo reboot

Notes
-----
- install_all.sh backs up existing DTB as:
  /boot/dtb/rockchip/rk3568-nanopi-r5s.dtb.bak_YYYYmmdd_HHMMSS
- SATA LED manager replaces HDled_monit_v0.service.
