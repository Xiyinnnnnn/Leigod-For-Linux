#!/bin/sh
# =============================================================================
#  leigod-for-bazzite — 卸载/回滚脚本
#  用法: sudo ./uninstall.sh [--dir /opt/leigod] [--purge]
#    --purge  连安装目录一并删除(默认保留 /opt/leigod 便于回退,只停服务拆单元)
# =============================================================================
set -u

INSTALL_DIR="/opt/leigod"
PURGE=0
[ $# -ge 1 ] && [ "$1" = "--dir" ] && { INSTALL_DIR="$2"; shift 2; }
[ $# -ge 1 ] && [ "$1" = "--purge" ] && PURGE=1

[ "$(id -u)" -eq 0 ] || { echo "[!] 请用 sudo 运行"; exit 1; }

say()  { echo "==> $*"; }
ok()   { echo "    [✓] $*"; }

say "停止并禁用服务"
for svc in leigod_plugin.service leigod-spoof-dmi.service leigod-wlan0.service; do
    systemctl stop "$svc" 2>/dev/null
    systemctl disable "$svc" 2>/dev/null
done

say "删除 systemd 单元"
rm -f /etc/systemd/system/leigod_plugin.service
rm -f /etc/systemd/system/leigod-spoof-dmi.service
rm -f /etc/systemd/system/leigod-wlan0.service
systemctl daemon-reload
ok "单元已移除"

# 若 install.sh 前系统本来就装有官方 service, 尝试用备份还原(install_shim 同理备份了 shim)
if [ -f /etc/systemd/system/leigod_plugin.service.bak-leigod ]; then
    mv /etc/systemd/system/leigod_plugin.service.bak-leigod /etc/systemd/system/leigod_plugin.service
    systemctl daemon-reload
    warn "已还原安装前 leigod_plugin.service (未启动, 自行 systemctl enable --now)"
fi

say "删除 uci/ubus shim(还原备份)"
for dst in /usr/local/sbin/uci /usr/local/sbin/ubus; do
    if [ -f "$dst.bak-leigod" ]; then
        mv "$dst.bak-leigod" "$dst" && ok "还原 $dst"
    elif head -2 "$dst" 2>/dev/null | grep -q 'leigod-for-bazzite'; then
        rm -f "$dst" && ok "删除本仓库 shim $dst"
    fi
done

say "删除 sudoers 免密规则"
rm -f /etc/sudoers.d/leigod-panel
ok "sudoers 已清理"

# 卸载残留进程(确保 dummy wlan0 可清)
pkill -f "acc-gw.router.amd64" 2>/dev/null
pkill -f "steamdeck_acc_monitor" 2>/dev/null
pkill -f "acc_upgrade_monitor" 2>/dev/null
sleep 1

say "清理 dummy wlan0"
ip link show wlan0 >/dev/null 2>&1 && ip link del wlan0
rmmod dummy 2>/dev/null || true
ok "wlan0 已删除"

# 还原 DMI 伪装(bind mount 卸载)
umount /sys/devices/virtual/dmi/id/product_name 2>/dev/null || true
ok "DMI bind mount 已卸载"

say "移除桌面图标"
if [ -n "${SUDO_USER:-}" ]; then
    rm -f "/home/$SUDO_USER/Desktop/雷神加速器.desktop"
fi
ok "桌面图标已移除"

if [ "$PURGE" -eq 1 ]; then
    say "删除安装目录 $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
    ok "已删除"
fi

cat <<DONE

================================================================
 ✅ 已卸载 leigod-for-bazzite
   (安装目录 $INSTALL_DIR 保留, 可用 sudo $INSTALL_DIR/leigod_uninstall.sh 或重装恢复)
   如需连目录删除: sudo ./uninstall.sh --purge
================================================================
DONE
exit 0
