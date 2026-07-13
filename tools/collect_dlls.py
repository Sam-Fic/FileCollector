#!/usr/bin/env python3
"""递归收集 Windows 可执行文件依赖的 mingw64 DLL 到目标目录。

用法: collect_dlls.py <exe_path> <dest_dir>
仅拷贝位于 mingw64/bin 下的 DLL (避免误收系统 DLL), 保证便携包自包含。
"""
import os
import sys
import shutil
import subprocess

# gcc 的位置可能因运行环境不同而返回 Windows 路径 (C:\msys64\mingw64\bin)
# 或 MSYS POSIX 路径 (/mingw64/bin)。统一规范化为 /mingw64/bin 形式，
# 以便与 ldd 输出的路径 (通常为 /mingw64/bin/...) 正确比较。
def normalize_mingw_bin(p):
    if not p:
        return None
    p = p.replace("\\", "/")
    idx = p.find("/mingw64/bin")
    if idx != -1:
        return p[idx:]  # -> /mingw64/bin
    return p


MINGW_BIN = normalize_mingw_bin(os.path.dirname(shutil.which("gcc") or "")) or None


def to_win(p):
    """将 MSYS POSIX 路径转换为 Windows 路径，原生 Windows Python 才能访问。
    ldd 输出的是 /mingw64/bin/... 形式，需要用 cygpath 转换。"""
    try:
        r = subprocess.run(["cygpath", "-w", p], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except Exception:
        pass
    return p


def find_dlls(target):
    """返回 target 直接依赖的、位于 mingw64/bin 的 DLL 绝对路径列表。"""
    out = subprocess.run(["ldd", target], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        # 形如:  libgtk-4-1.dll => /mingw64/bin/libgtk-4-1.dll (0x...)
        if "=>" not in line:
            continue
        rhs = line.split("=>", 1)[1]
        path = rhs.split("(")[0].strip()
        if not path or path == "not found":
            continue
        # 只收集 mingw64 提供的 DLL（规范化为 /mingw64/bin 后比较）
        path_norm = normalize_mingw_bin(path) or path.replace("\\", "/")
        if MINGW_BIN and path_norm.startswith(MINGW_BIN):
            found.append(to_win(path))
    return found


def main():
    if len(sys.argv) != 3:
        print("usage: collect_dlls.py <exe> <dest>", file=sys.stderr)
        sys.exit(1)
    exe, dest = sys.argv[1], sys.argv[2]
    os.makedirs(dest, exist_ok=True)
    collected = set()
    queue = [exe]
    while queue:
        cur = queue.pop(0)
        for dll in find_dlls(cur):
            name = os.path.basename(dll)
            if name in collected:
                continue
            collected.add(name)
            dst = os.path.join(dest, name)
            if not os.path.exists(dst):
                shutil.copy(dll, dst)
            queue.append(dll)
    print(f"collected {len(collected)} DLLs into {dest}")


if __name__ == "__main__":
    main()
