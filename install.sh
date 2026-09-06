#!/bin/sh
# =============================================================================
#  leigod-for-bazzite — 一键安装脚本
#  对不可变 Linux（Bazzite/SteamOS/Fedora Atomic）友好的雷神加速器组件
#
#  用法:
#    sudo ./install.sh
#    sudo ./install.sh --dir /home/deck/leigod        # 自定义安装目录(默认 /opt/leigod)
#    sudo ./install.sh --mac e8:4e:ce:12:34:56        # 沿用旧设备的 wlan0 MAC(保留原绑定)
#    sudo ./install.sh --token-file ./token.txt       # 从文件导入 token(=行)
#    sudo ./install.sh --force                        # 强制覆盖 config(会丢绑定 token,慎用)
#
#  幂等:重复执行安全;已存在 accelerator.ini 时默认保留(绑定不丢)。
#  回滚:./uninstall.sh
# =============================================================================
set -u

# ---- 可覆盖默认值 ----------------------------------------------------------
INSTALL_DIR="/opt/leigod"        # Bazzite /opt 可写,SELinux usr_t 天然匹配
MAC=""
TOKEN_FILE=""
FORCE=0

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ---- 解析参数 ---------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)        INSTALL_DIR="$2"; shift 2;;
        --mac)        MAC="$2"; shift 2;;
        --token-file) TOKEN_FILE="$2"; shift 2;;
        --force)      FORCE=1; shift;;
        -h|--help)    usage 0;;
        *) echo "[!] 未知参数: $1"; usage 1;;
    esac
done

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DL_BASE="http://119.3.40.126"          # 雷神官方下载源
BIN_NAME="acc-gw.router.amd64"

# ---- 基础检查 ---------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "[!] 请用 sudo 运行: sudo $0"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[!] 缺少依赖: $1"; exit 1; }; }
for c in curl python3 systemctl ip sed grep uname cat md5sum awk; do need_cmd "$c"; done

ARCH=$(uname -m)
[ "$ARCH" = "x86_64" ] || { echo "[!] 暂仅支持 x86_64(amd64),当前: $ARCH"; exit 1; }

# 校验 MAC 格式
if [ -n "$MAC" ]; then
    echo "$MAC" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' \
        || { echo "[!] MAC 格式非法: $MAC (应为 xx:xx:xx:xx:xx:xx)"; exit 1; }
else
    # 每机唯一: 由 machine-id 派生 (monitor 兜底逻辑保持一致)
    MAC="02:$(cat /etc/machine-id 2>/dev/null | md5sum | head -c 10 | sed 's/\(..\)/\1:/g;s/:$//')"
fi

[ -f "$REPO_DIR/patch/apply_crashfix.py" ] || { echo "[!] 找不到补丁脚本: $REPO_DIR/patch/apply_crashfix.py"; exit 1; }

say()  { echo "==> $*"; }
ok()   { echo "    [✓] $*"; }
warn() { echo "    [⚠] $*"; }

# ---- 0. 停旧服务(幂等) ------------------------------------------------------
say "停止旧服务(如存在)"
systemctl stop leigod_plugin.service 2>/dev/null
systemctl stop leigod-spoof-dmi.service 2>/dev/null
systemctl stop leigod-wlan0.service 2>/dev/null
ok "已停止"

# ---- 1. 目录与运行资产 ------------------------------------------------------
say "创建安装目录 $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/config"
mkdir -p "$INSTALL_DIR/panel"

say "复制仓库内资产 (fake 伪装文件 / 守护脚本 / 面板)"
cp "$REPO_DIR/files/fake_product_name"  "$INSTALL_DIR/fake_product_name"
cp "$REPO_DIR/files/fake_os-release"    "$INSTALL_DIR/fake_os-release"
cp "$REPO_DIR/files/steamdeck_acc_monitor.sh" "$INSTALL_DIR/steamdeck_acc_monitor.sh"
cp "$REPO_DIR/panel/leigod_panel.py"    "$INSTALL_DIR/panel/leigod_panel.py"
chmod 755 "$INSTALL_DIR/steamdeck_acc_monitor.sh" "$INSTALL_DIR/panel/leigod_panel.py"
ok "资产就绪"

# ---- 2. 下载官方二进制 + 数据文件, 并本地打崩溃补丁 -------------------------
TMP_DL="/tmp/leigod-for-bazzite-dl.$$"
mkdir -p "$TMP_DL"

say "从官方源下载组件: $DL_BASE"
fetch() { # $1=远端文件名 $2=落盘路径
    curl -fsSL -o "$2" "$DL_BASE/$1" \
        || { echo "[!] 下载失败: $DL_BASE/$1"; exit 1; }
}
fetch "$BIN_NAME"                       "$TMP_DL/acc-gw.router.amd64"
fetch "ipdatacloud_country.xdb"         "$TMP_DL/ipdatacloud_country.xdb"
fetch "plugin_common.sh"                "$INSTALL_DIR/plugin_common.sh"
fetch "plugin_uninstall.sh"             "$INSTALL_DIR/leigod_uninstall.sh"
ok "下载完成"

say "本地应用崩溃修复补丁 (纯HTTP+Host头→SIGABRT 问题)"
python3 "$REPO_DIR/patch/apply_crashfix.py" \
    "$TMP_DL/acc-gw.router.amd64" "$INSTALL_DIR/$BIN_NAME"
cp "$INSTALL_DIR/$BIN_NAME" "$INSTALL_DIR/acc_upgrade_monitor"   # 官方同样结构: 同一二进制
chmod 755 "$INSTALL_DIR/$BIN_NAME" "$INSTALL_DIR/acc_upgrade_monitor"
chmod 644 "$INSTALL_DIR/leigod_uninstall.sh" 2>/dev/null || true
ok "补丁二进制就位: $INSTALL_DIR/$BIN_NAME"

# ---- 3. config (绑定保留策略) ----------------------------------------------
CONF_FILE="$INSTALL_DIR/config/accelerator.ini"
if [ -f "$CONF_FILE" ] && [ "$FORCE" -eq 0 ]; then
    say "检测到已有 accelerator.ini,保留现有绑定配置"
else
    say "生成 accelerator.ini (release 模板)"
    if [ "$FORCE" -eq 1 ] && [ -f "$CONF_FILE" ]; then
        warn "--force 覆盖旧 config,将丢失原绑定 token"
    fi
    cat "$REPO_DIR/files/config/accelerator.ini.template" > "$CONF_FILE"
    ok "模板已写"
fi

# 可选: 从 --token-file 导入 token (迁移用)
if [ -n "$TOKEN_FILE" ]; then
    [ -f "$TOKEN_FILE" ] || { echo "[!] token 文件不存在: $TOKEN_FILE"; exit 1; }
    TK=$(grep -E '^token=' "$TOKEN_FILE" | head -1 | cut -d= -f2- | tr -d ' \r')
    [ -n "$TK" ] || { echo "[!] token 文件里没有 token= 行"; exit 1; }
    # 更新/注入 accelerator.ini 的 token 行
    if grep -q '^token=' "$CONF_FILE"; then
        sed -i "s|^token=.*|token=\"$TK\"|" "$CONF_FILE"
    else
        sed -i "/^\[base\]/a token=\"$TK\"" "$CONF_FILE"
    fi
    ok "token 已导入 accelerator.ini"
fi

# 数据文件与版本文件
cp "$TMP_DL/ipdatacloud_country.xdb" "$INSTALL_DIR/config/ipdatacloud_country.xdb"
cp "$REPO_DIR/files/config/acc_version.ini"      "$INSTALL_DIR/config/acc_version.ini"
cp "$REPO_DIR/files/config/new_upgrade_conf.json" "$INSTALL_DIR/config/new_upgrade_conf.json"
ok "config 就绪"

# ---- 4. 安装 uci/ubus shim (动态 token, 不把 token 入库) --------------------
say "安装 uci/ubus 兼容垫片到 /usr/local/sbin"
install_shim() { # $1=仓库shim $2=目标
    local src="$1" dst="$2"
    if [ -e "$dst" ] && ! head -2 "$dst" | grep -q 'leigod-for-bazzite'; then
        cp -a "$dst" "$dst.bak-leigod" && warn "已有非本仓库 $dst,已备份为 $dst.bak-leigod"
    fi
    sed "s|@INSTALL_DIR@|$INSTALL_DIR|g" "$src" > "$dst"
    chmod 755 "$dst"
    chcon -t bin_t "$dst" 2>/dev/null || true
}
install_shim "$REPO_DIR/shims/uci"  /usr/local/sbin/uci
install_shim "$REPO_DIR/shims/ubus" /usr/local/sbin/ubus
ok "shim 就位 (uci 读 $INSTALL_DIR/config/accelerator.ini)"

# ---- 5. systemd 单元 (占位符替换) ------------------------------------------
say "生成 systemd 单元"
sed -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" \
    -e "s|@FAKE_DIR@|$INSTALL_DIR|g" \
    -e "s|@MAC@|$MAC|g" \
    "$REPO_DIR/systemd/leigod_plugin.service"      > /etc/systemd/system/leigod_plugin.service
sed -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" \
    -e "s|@FAKE_DIR@|$INSTALL_DIR|g" \
    "$REPO_DIR/systemd/leigod-spoof-dmi.service"   > /etc/systemd/system/leigod-spoof-dmi.service
sed -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" \
    -e "s|@MAC@|$MAC|g" \
    "$REPO_DIR/systemd/leigod-wlan0.service"       > /etc/systemd/system/leigod-wlan0.service
ok "单元写入 /etc/systemd/system"

# ---- 6. SELinux (Bazzite 必需) ----------------------------------------------
say "修正 SELinux 标签"
chcon -R -t usr_t "$INSTALL_DIR" 2>/dev/null \
    && ok "usr_t: $INSTALL_DIR" || warn "chcon 失败(可忽略,若系统无 SELinux)"
ok "SELinux 处理完成"

# ---- 7. 免密面板授权(sudoers.d, 限定单条命令) -------------------------------
say "写入 sudoers 免密(仅限 systemctl restart leigod_plugin.service)"
SUDOERS_FILE="/etc/sudoers.d/leigod-panel"
printf '%%wheel ALL=(root) NOPASSWD: /usr/bin/systemctl restart leigod_plugin.service\n' > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
ok "sudoers: $SUDOERS_FILE"

# ---- 8. 启停对称启动 ---------------------------------------------------------
say "daemon-reload + 启动三服务"
systemctl daemon-reload
systemctl enable leigod-wlan0.service leigod-spoof-dmi.service leigod_plugin.service >/dev/null 2>&1
systemctl start  leigod-wlan0.service leigod-spoof-dmi.service leigod_plugin.service
sleep 3
systemctl is-active leigod_plugin.service >/dev/null 2>&1 \
    && ok "leigod_plugin.service 运行中" || { echo "[!] 服务启动失败,查看: journalctl -u leigod_plugin -n 50"; exit 1; }

# ---- 9. 桌面向导(可选, 检测到 Desktop 才装) --------------------------------
PANEL_PY="$INSTALL_DIR/panel/leigod_panel.py"
if [ -n "${SUDO_USER:-}" ] && [ -d "/home/$SUDO_USER/Desktop" ] && command -v yad >/dev/null 2>&1; then
    sed "s|@PANEL@|$PANEL_PY|" "$REPO_DIR/panel/雷神加速器.desktop.template" \
        > "/home/$SUDO_USER/Desktop/雷神加速器.desktop"
    chown "$SUDO_USER:" "/home/$SUDO_USER/Desktop/雷神加速器.desktop"
    ok "桌面图标: /home/$SUDO_USER/Desktop/雷神加速器.desktop"
else
    warn "跳过桌面图标(需 Desktop 目录 + yad); 面板文件已装: $PANEL_PY"
fi

# ---- 10. 收尾 -----------------------------------------------------------------
rm -rf "$TMP_DL"
cat <<DONE

================================================================
 ✅ leigod-for-bazzite 安装完成

    安装目录 : $INSTALL_DIR
    设备 MAC : $MAC  (wlan0 dummy, 即设备 SN)
    DMI 伪装 : Jupiter (SteamDeck)  via leigod-spoof-dmi.service
    崩溃补丁 : 已应用 (SHA256 基线校验通过)
    守护进程 : leigod_plugin.service (monitor→daemon→web 自愈)
    手机绑定 : 打开雷神 App → 加速,首次会在本机写入 token

 查看状态: systemctl status leigod_plugin
 桌 面  : 双击「雷神加速器」图标查看/重启
 回 滚  : sudo $INSTALL_DIR/leigod_uninstall.sh 或仓库内 ./uninstall.sh
================================================================
DONE
exit 0
