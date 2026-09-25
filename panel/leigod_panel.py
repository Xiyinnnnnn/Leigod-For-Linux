#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""雷神加速器状态面板：傻瓜式双击 → 看状态 → 一键强制重启（免密）
2026-09-25 改版：
  - web 探测：TCP 连接/HTTP → 进程存活 + 端口 LISTEN（零流量，不打扰 web）
  - 手机连接：ESTAB 计数 → nftables UDP 计数器（TURN 隧道下发流量 dport 5588）
  - 每 5s 自动刷新
"""
import os, re, time, subprocess

SERVICE = "leigod_plugin"
PROCS = {
    "steamdeck_acc_monitor.sh": "监控脚本",
    "acc-gw.router.amd64 -r daemon": "daemon",
    "acc-gw.router.amd64 -r web": "web",
    "acc_upgrade_monitor -r upgrade": "升级监控",
}
LOG = "/tmp/acc/log/steamdeck_acc_monitor.log"
YAD = "/usr/bin/yad"
NFT_TABLE = "leigod_panel"
REFRESH_SECS = 5

def sh(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (r.returncode, r.stdout.strip(), r.stderr.strip())
    except Exception as e:
        return (1, "", str(e))

def ensure_nft():
    """确保 nftables 计数表存在（policy accept，只计数不改流量）"""
    rc, out, _ = sh(["sudo", "-n", "nft", "list", "table", "inet", NFT_TABLE])
    if rc == 0 and out.count("counter") >= 2:
        return
    sh(["sudo", "-n", "nft", "delete", "table", "inet", NFT_TABLE])
    sh(["sudo", "-n", "nft", "add", "table", "inet", NFT_TABLE])
    sh(["sudo", "-n", "nft", "add", "chain", "inet", NFT_TABLE, "out",
        "{ type filter hook output priority 0; policy accept; }"])
    sh(["sudo", "-n", "nft", "add", "rule", "inet", NFT_TABLE, "out", "udp dport 5588 counter"])
    sh(["sudo", "-n", "nft", "add", "chain", "inet", NFT_TABLE, "in",
        "{ type filter hook input priority 0; policy accept; }"])
    sh(["sudo", "-n", "nft", "add", "rule", "inet", NFT_TABLE, "in", "udp sport 5588 counter"])

def read_udp_counter():
    rc, out, _ = sh(["sudo", "-n", "nft", "list", "table", "inet", NFT_TABLE])
    if rc != 0:
        return None
    total = 0
    for line in out.splitlines():
        m = re.search(r"packets (\d+)", line)
        if m:
            total += int(m.group(1))
    return total

def collect(state):
    info = {}
    _, out, _ = sh(["systemctl", "is-active", SERVICE])
    info["service_active"] = out == "active"
    _, out, _ = sh(["systemctl", "is-enabled", SERVICE])
    info["service_enabled"] = out == "enabled"
    info["procs"] = {}
    for pat, label in PROCS.items():
        _, out, _ = sh(["pgrep", "-f", pat])
        info["procs"][label] = bool(out.strip())
    info["wlan0"] = os.path.exists("/sys/class/net/wlan0")
    _, out, _ = sh(["systemctl", "show", SERVICE, "-p", "ActiveEnterTimestamp", "--value"])
    info["uptime"] = out or "未知"
    info["log"] = ""
    if os.path.exists(LOG):
        with open(LOG, "r", errors="replace") as f:
            info["log"] = "".join(f.readlines()[-6:])
    # web 在线 = web 进程存活 + 5588 端口 LISTEN（零流量探测，不发包不打扰 web）
    _, out, _ = sh(["ss", "-tln"])
    info["web_port"] = any(
        l.split()[3].endswith(":5588")
        for l in out.splitlines()
        if l.startswith("LISTEN") and len(l.split()) >= 4
    )
    info["web_online"] = info["procs"]["web"] and info["web_port"]
    # 手机连接 = TURN 隧道 UDP 流量（下发 dport 5588 + 上行 sport 5588 之和）
    total = read_udp_counter()
    if total is None:
        info["phone_udp"] = None
    else:
        last = state.get("last_udp")
        info["phone_udp"] = max(0, total - last) if last is not None else None
        state["last_udp"] = total
    _, out, _ = sh(["ip", "-4", "addr", "show"])
    ip = ""
    for line in out.splitlines():
        if "inet " in line and "127.0.0.1" not in line:
            ip = line.split()[1].split("/")[0]
            break
    info["phone_ip"] = ip
    return info

def render(info):
    lines = []
    ok = True
    if info["service_active"]:
        lines.append("✅ 服务状态：运行中" + ("（开机自启）" if info["service_enabled"] else "（未开机自启）"))
    else:
        lines.append("❌ 服务状态：已停止")
        ok = False
    for label, alive in info["procs"].items():
        lines.append(("✅" if alive else "❌") + " 进程 " + label)
        if not alive:
            ok = False
    lines.append(("✅" if info["wlan0"] else "⚠️") + " 虚拟网卡 wlan0" + ("（存在）" if info["wlan0"] else "（缺失，加速可能不可用）"))
    if not info["wlan0"]:
        ok = False
    if not info["web_online"]:
        lines.append("❌ web 服务(5588)：离线")
        ok = False
    else:
        udp = info["phone_udp"]
        if udp is None:
            lines.append("📱 手机：UDP 计数器不可用")
        elif udp > 0:
            lines.append("📱 手机：在线（近 %ds UDP 隧道流量 %d 包）" % (REFRESH_SECS, udp))
        else:
            lines.append("📱 手机：无 UDP 流量（未连接或空闲）")
        lines.append("📍 本机 IP：" + info["phone_ip"])
    lines.append("⏱ 本次运行：" + info["uptime"])
    head = "✅ 雷神加速器运行正常" if ok else "⚠️ 雷神加速器状态异常"
    return head, lines, ok

def dialog(head, body, warn=False):
    import html
    fg = "#f87171" if warn else "#4ade80"
    text = "<span foreground='%s' size='x-large'><b>%s</b></span>\n\n%s" % (fg, head, html.escape(body))
    return subprocess.run([
        YAD, "--title=雷神加速器",
        "--text=" + text,
        "--markup",
        "--button=🔧 强制重启:1", "--button=关闭:0",
        "--buttons-layout=center",
        "--center", "--width=480", "--height=420", "--scroll",
    ]).returncode

def restart_service():
    # 免密 sudo（sudoers.d 已配置 NOPASSWD）
    subprocess.run(["sudo", "-n", "systemctl", "restart", SERVICE])

def main():
    ensure_nft()
    state = {"last_udp": read_udp_counter()}
    time.sleep(3)  # 首个测量窗口
    while True:
        info = collect(state)
        head, lines, ok = render(info)
        body = "\n".join(lines)
        if not ok and info["log"]:
            body += "\n\n──── 最近日志 ────\n" + info["log"]
        ret = dialog(head, body, warn=not ok)
        if ret in (0, 252):
            break
        if ret == 1:
            c = subprocess.run([
                YAD, "--title=雷神加速器", "--text-align=center",
                "--text=<b>⚠️ 确定要强制重启雷神加速器吗？</b>\n\n将终止全部 leigod 进程并重新拉起。",
                "--button=取消:1", "--button=确认重启:0",
                "--buttons-layout=center",
                "--center",
            ]).returncode
            if c == 0:
                restart_service()
                time.sleep(3)
            continue
        time.sleep(REFRESH_SECS)

if __name__ == "__main__":
    main()
