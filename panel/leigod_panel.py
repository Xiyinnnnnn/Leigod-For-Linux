#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""雷神加速器状态面板 (leigod-for-bazzite): 双击查看状态 / 一键免密重启。
   由 install.sh 部署到 INSTALL_DIR/panel/leigod_panel.py, 桌面图标 Exec 指向它。
   依赖: yad (yad 缺失时 install.sh 跳过桌面图标, 仍可用命令行查看)。"""

SERVICE = "leigod_plugin"
PROCS   = ["steamdeck_acc_monitor.sh", "acc-gw.router.amd64", "acc_upgrade_monitor"]
LOG     = "/tmp/acc/log/steamdeck_acc_monitor.log"
YAD     = "/usr/bin/yad"

def sh(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (r.returncode, r.stdout.strip(), r.stderr.strip())
    except Exception as e:
        return (1, "", str(e))

def collect():
    info = {}
    _, out, _ = sh(["systemctl", "is-active", SERVICE])
    info["service_active"] = out == "active"
    rc, out, _ = sh(["systemctl", "is-enabled", SERVICE])
    info["service_enabled"] = rc == 0
    info["procs"] = {}
    for p in PROCS:
        _, out, _ = sh(["pgrep", "-f", p])
        info["procs"][p] = bool(out.strip())
    info["wlan0"] = os.path.exists("/sys/class/net/wlan0")
    _, out, _ = sh(["systemctl", "show", SERVICE, "-p", "ActiveEnterTimestamp", "--value"])
    info["uptime"] = out or "未知"
    info["log"] = ""
    if os.path.exists(LOG):
        with open(LOG, "r", errors="replace") as f:
            info["log"] = "".join(f.readlines()[-6:])
    # 手机连接状态（雷神 App 走 5588 web 服务）
    info["phone"] = {}
    import socket
    try:
        _s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        _s.settimeout(2)
        _s.connect(("127.0.0.1", 5588))
        _s.close()
        info["phone"]["online"] = True
    except Exception:
        info["phone"]["online"] = False
    rc, out, _ = sh(["ss", "-tn"])
    est = [l for l in out.splitlines() if ":5588" in l and "ESTAB" in l]
    info["phone"]["count"] = len(est)
    rc, out, _ = sh(["ip", "-4", "addr", "show"])
    ip = ""
    for line in out.splitlines():
        if "inet " in line and "127.0.0.1" not in line:
            ip = line.split()[1].split("/")[0]
            break
    info["phone"]["ip"] = ip
    return info

def render(info):
    lines = []
    ok = True
    if info["service_active"]:
        lines.append("✅ 服务状态：运行中" + ("（开机自启）" if info["service_enabled"] else "（未开机自启）"))
    else:
        lines.append("❌ 服务状态：已停止")
        ok = False
    for name, alive in info["procs"].items():
        short = name.replace(".amd64", "").replace(".sh", "")
        lines.append(("✅" if alive else "❌") + " 进程 " + short)
        if not alive:
            ok = False
    lines.append(("✅" if info["wlan0"] else "⚠️") + " 虚拟网卡 wlan0" + ("（存在）" if info["wlan0"] else "（缺失，加速可能不可用）"))
    if not info["wlan0"]:
        ok = False
    ph = info.get("phone", {})
    if ph.get("online"):
        lines.append(("📱 手机连接：在线 · " + str(ph.get("count", 0)) + " 台设备连接中" if ph.get("count") else "📱 手机连接：在线 · 等待手机 App 连接") + ("（" + ph.get("ip", "") + ":5588）" if ph.get("ip") else ""))
    else:
        lines.append("❌ 手机连接：web 服务(5588)离线")
        ok = False
    lines.append("⏱ 本次运行：" + info["uptime"])
    head = "✅ 雷神加速器运行正常" if ok else "⚠️ 雷神加速器状态异常"
    return head, lines, ok

def dialog(head, body, warn=False):
    import html
    fg = "#f87171" if warn else "#4ade80"
    # head 可控无需转义；body 可能含日志(有 <>&)需转义防 markup 破坏
    text = "<span foreground='%s' size='x-large'><b>%s</b></span>\n\n%s" % (fg, head, html.escape(body))
    return subprocess.run([
        YAD, "--title=雷神加速器",
        "--text=" + text,
        "--markup",
        "--button=🔄 刷新:3", "--button=🔧 强制重启:1", "--button=关闭:0",
        "--buttons-layout=center",
        "--center", "--width=480", "--height=420", "--scroll",
    ]).returncode

def restart_service():
    # 免密 sudo（sudoers.d 已配置 NOPASSWD）
    subprocess.run(["sudo", "-n", "systemctl", "restart", SERVICE])

def main():
    info = collect()
    head, lines, ok = render(info)
    while True:
        body = "\n".join(lines)
        if not ok and info["log"]:
            body += "\n\n──── 最近日志 ────\n" + info["log"]
        ret = dialog(head, body, warn=not ok)
        if ret in (0, 252):
            break
        if ret == 3:
            info = collect()
            head, lines, ok = render(info)
            continue
        if ret == 1:
            c = subprocess.run([
                YAD, "--title=雷神加速器", "--text-align=center",
                "--text=<b>⚠️ 确定要强制重启雷神加速器吗？</b>\n\n将终止全部 leigod 进程并重新拉起。",
                "--button=取消:1", "--button=确认重启:0",
                "--buttons-layout=center", "--center",
            ]).returncode
            if c == 0:
                restart_service()
                time.sleep(3)
            info = collect()
            head, lines, ok = render(info)
            continue

if __name__ == "__main__":
    main()
