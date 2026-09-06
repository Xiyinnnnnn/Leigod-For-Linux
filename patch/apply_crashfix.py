#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Leigod-For-Linux crash-fix patcher

把雷神官方 acc-gw.router 二进制做 10 字节崩溃修复：
纯 HTTP + 非空 Host 头访问 5588 → websocketpp::exception "invalid state" → SIGABRT (100% 必崩)。
补丁让状态检查走安全返回路径，不进入崩溃分支；不影响正常 WS/TURN/绑定/加速。

原理(与官方版差异, 偏移 0x172937):
  官方: bf 09 00 00 00        mov edi, 9          ; 准备 exit code 进崩溃路径
  修复: 31 c0 31 d2 90*5      xor eax,eax; xor edx,edx; nop*6   ; 状态检查走安全返回
"""
import hashlib, os, sys

OFFSET      = 0x172937
OFFICIAL_HASH = "8e0adbd1b1ce0d37e6588ff222408fed66a3f8954fee27bc37a10e0bf6806d4d"  # d0b7c823
PATCHED_HASH  = "0dba34d7cc319e0ea2953de8a5ca9a13bd4822369af4ebd26b94b50af04d56bb"  # b1c3b473

OFFICIAL_BYTES = bytes.fromhex("bf09000000e84afdfeff")
PATCHED_BYTES  = bytes.fromhex("31c031d2909090909090")

def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def patch_file(src, dst):
    with open(src, "rb") as f:
        data = f.read()
    if data[OFFSET:OFFSET+len(PATCHED_BYTES)] == PATCHED_BYTES:
        return "already_patched"
    if data[OFFSET:OFFSET+len(OFFICIAL_BYTES)] != OFFICIAL_BYTES:
        raise SystemExit(
            "[!] 二进制与已知官方版特征不符。官方可能更新了版本。\n"
            f"    期望 @0x{OFFSET:x}: {OFFICIAL_BYTES.hex()}\n"
            f"    实际 @0x{OFFSET:x}: {data[OFFSET:OFFSET+16].hex()}\n"
            "    请到 GitHub issues 反馈新版本偏移。")
    patched = data[:OFFSET] + PATCHED_BYTES + data[OFFSET+len(PATCHED_BYTES):]
    with open(dst, "wb") as f:
        f.write(patched)
    os.chmod(dst, 0o755)
    return "patched"

if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit("usage: apply_crashfix.py <input_binary> <output_binary>")
    src, dst = sys.argv[1], sys.argv[2]
    if not os.path.exists(src):
        raise SystemExit(f"[!] 找不到输入文件: {src}")
    before = sha256(src)
    print(f"[*] input  sha256 = {before}")
    print(f"[*] official     = {OFFICIAL_HASH}")
    print(f"[*] patched      = {PATCHED_HASH}")
    if before == PATCHED_HASH:
        print("[*] 已是补丁版，无需处理")
        sys.exit(0)
    if before != OFFICIAL_HASH:
        print(f"[!] 警告: 输入 sha256 与官方基线不一致")
        if not os.environ.get("LEIGOD_PATCH_FORCE"):
            print("[!] 终止。如需强制打补丁，设 LEIGOD_PATCH_FORCE=1 后重试")
            sys.exit(2)
    res = patch_file(src, dst)
    after = sha256(dst) if os.path.exists(dst) else ""
    print(f"[*] result = {res}")
    print(f"[*] output sha256 = {after}")
    if res == "patched" and after != PATCHED_HASH:
        print("[!] 警告: 补丁后 sha256 与预期不符，请勿使用该二进制")
        sys.exit(3)
    print("[✓] 崩溃修复补丁应用成功")
