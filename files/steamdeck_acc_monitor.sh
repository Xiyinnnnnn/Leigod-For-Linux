#!/bin/sh
# Leigod-For-Linux: 进程守护（daemon + web 自愈）
# 从本脚本所在目录推导安装路径，支持 /opt/leigod、/home/<u>/leigod 任意位置

run_env=$1
LOG_DIR="/tmp/acc/log/"
LOG_FILE="$LOG_DIR/steamdeck_acc_monitor.log"
UPGRADE_FLAG="/tmp/acc/upgrade_flag"
mkdir -p "$LOG_DIR"

log_message() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

echo "=========================================" >> "$LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting process monitor daemon (env=${run_env:-release})" >> "$LOG_FILE"
echo "=========================================" >> "$LOG_FILE"

# --- 架构 ---
arch=$(uname -m)
case "$arch" in
  x86_64)  arch="amd64";;
  aarch64) arch="arm64";;
  mips)    arch="mipsel";;
  armv7l)  arch="arm";;
  *) log_message "unsupported arch: ${arch}"; exit 1;;
esac

# --- 安装目录：取本脚本所在真实目录 ---
BASE_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
log_message "install directory is $BASE_PATH"

# --- 幂等补齐 wlan0（加速需 SN；MAC 迁移说明见 README）---
if ! ip link show wlan0 >/dev/null 2>&1; then
    WLAN0_MAC=""
    for iface in wlp0s20f3 wlan0 eno2 eno1 ens32 ens33 ens34 ens35 ens36; do
        if [ -f "/sys/class/net/${iface}/address" ]; then
            WLAN0_MAC=$(cat "/sys/class/net/${iface}/address" 2>/dev/null)
            [ -n "$WLAN0_MAC" ] && break
        fi
    done
    # 由 machine-id 派生稳定 MAC（保留 SN 迁移见 install.sh --mac）
    if [ -z "$WLAN0_MAC" ]; then
        WLAN0_MAC="02:$(cat /etc/machine-id 2>/dev/null | md5sum | head -c 10 | sed 's/\(..\)/\1:/g;s/:$//')"
    fi
    ip link add wlan0 type dummy
    ip link set wlan0 address "$WLAN0_MAC"
    ip link set wlan0 up
    log_message "Created dummy wlan0 with MAC: $WLAN0_MAC"
fi

LOCK_FILE="/var/run/acc_daemon.lock"
if [ "${run_env}" = "test" ]; then
    PROCESS_DATA="
acc-gw.router.${arch}:-d debug -r daemon:${BASE_PATH}/acc-gw.router.${arch} -d debug -r daemon -m tun -p 5588
acc_upgrade_monitor:-d debug -r upgrade:${BASE_PATH}/acc_upgrade_monitor -d debug -r upgrade
"
else
    PROCESS_DATA="
acc-gw.router.${arch}:-r daemon:${BASE_PATH}/acc-gw.router.${arch} -r daemon -m tun -p 5588
acc_upgrade_monitor:-r upgrade:${BASE_PATH}/acc_upgrade_monitor -r upgrade
"
fi

# 单例
if [ -f "$LOCK_FILE" ]; then
    if kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
        log_message "[Monitor] already running (PID: $(cat "$LOCK_FILE")). Exiting."
        exit 1
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"

# /proc 扫描（替代 pidof：pidof 在 D 进程/卡死 /proc 时会被拖死）
is_process_running() {
    local pattern="$2"
    for proc_dir in /proc/[0-9]*; do
        [ -r "$proc_dir/cmdline" ] || continue
        cmdline=$(tr '\0' ' ' < "$proc_dir/cmdline" 2>/dev/null)
        case "$cmdline" in
            *"$pattern"*) return 0;;
        esac
    done
    return 1
}

log_message "Monitor daemon started (PID: $$)"

while true; do
    if [ -f "$UPGRADE_FLAG" ]; then
        log_message "upgrade in progress, skip cycle"
        sleep 5; continue
    fi
    echo "$PROCESS_DATA" | while IFS=":" read -r process_name pattern start_cmd; do
        [ -z "$(echo "$process_name" | tr -d ' ')" ] && continue
        process_name=$(echo "$process_name" | xargs)
        pattern=$(echo "$pattern" | xargs)
        start_cmd=$(echo "$start_cmd" | xargs)
        if ! is_process_running "$process_name" "$pattern"; then
            log_message "Process not running: $process_name, starting..."
            log_message "Start command: $start_cmd"
            eval "$start_cmd >/dev/null 2>&1 </dev/null &"
            sleep 1
            if is_process_running "$process_name" "$pattern"; then
                log_message "Successfully started: $process_name"
            else
                log_message "Failed to start: $process_name"
            fi
        fi
    done
    sleep 5
done
