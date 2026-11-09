#!/usr/bin/env python3
"""递归收集 MSYS2 运行时 DLL 到 Windows 便携包的 bin 目录。

用法: collect_dlls.py [--min N] <exe_or_dll_path> <dest_dir>

只拷贝当前 MSYS2 子系统 bin 目录（UCRT64 / MINGW64 / CLANG64 ...）里的 DLL，
避免把 Windows 系统 DLL 混进便携包。子系统前缀由 MSYSTEM_PREFIX 或 gcc 路径推断，
绝不能写死 /mingw64：CI 已从 MINGW64 迁到 UCRT64，写死会静默收集到 0 个 DLL，
产出一个用户启动时满屏「找不到 xxx.dll」的坏包。

--min N 用于让调用方设置下限；收集数量不足时以非零状态退出，阻止坏包继续发布。
"""
import os
import re
import shutil
import subprocess
import sys

SUBSYSTEMS = "ucrt64|mingw64|clang64|mingw32|clang32|clangarm64"
BIN_RE = re.compile(r"/(%s)/bin" % SUBSYSTEMS, re.IGNORECASE)


def normalize(p):
    """把 C:/msys64/ucrt64/bin/x.dll 与 /ucrt64/bin/x.dll 都归一成 /ucrt64/bin/x.dll。"""
    p = (p or "").replace("\\", "/")
    m = BIN_RE.search(p)
    return p[m.start():] if m else p


def msys_bin():
    """返回当前 MSYS2 子系统的 bin 目录（POSIX 形式，如 /ucrt64/bin）。"""
    env = os.environ.get("MSYSTEM_PREFIX")
    if env:
        norm = normalize(env + "/bin")
        if BIN_RE.match(norm):
            return norm
    gcc = shutil.which("gcc") or shutil.which("cc")
    if gcc:
        norm = normalize(os.path.dirname(gcc))
        if BIN_RE.match(norm):
            return norm
    return None


def to_win(p):
    """ldd 输出的是 MSYS POSIX 路径；原生 Windows Python 需要转换后才能访问。"""
    try:
        r = subprocess.run(["cygpath", "-w", p], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except OSError:
        pass
    return p


def find_dlls(target, runtime_bin):
    """返回 target 直接依赖的、位于当前 MSYS2 子系统 bin 下的 DLL。"""
    r = subprocess.run(["ldd", target], capture_output=True, text=True)
    if r.returncode != 0:
        print("ldd failed for %s:\n%s" % (target, r.stderr or r.stdout), file=sys.stderr)
        sys.exit(1)
    found = []
    for line in r.stdout.splitlines():
        # 形如: libgtk-4-1.dll => /ucrt64/bin/libgtk-4-1.dll (0x...)
        if "=>" not in line:
            continue
        path = line.split("=>", 1)[1].split("(")[0].strip()
        if not path:
            continue
        if path == "not found":
            print("WARNING: unresolved dependency: %s" % line.strip(), file=sys.stderr)
            continue
        norm = normalize(path)
        if norm.startswith(runtime_bin + "/"):
            found.append(to_win(norm))
    return found


def main():
    args = sys.argv[1:]
    min_dlls = 1
    if args[:1] == ["--min"]:
        min_dlls = int(args[1])
        args = args[2:]
    if len(args) < 2:
        print("usage: collect_dlls.py [--min N] <exe_or_dll> [more ...] <dest>", file=sys.stderr)
        sys.exit(1)
    targets, dest = args[:-1], args[-1]

    runtime_bin = msys_bin()
    if not runtime_bin:
        print(
            "ERROR: cannot determine the MSYS2 subsystem bin directory. "
            "Set MSYSTEM_PREFIX (e.g. /ucrt64) and make sure gcc is on PATH.",
            file=sys.stderr,
        )
        sys.exit(1)
    print("MSYS2 runtime dir: %s" % runtime_bin)

    os.makedirs(dest, exist_ok=True)
    collected = set()
    queue = list(targets)
    while queue:
        cur = queue.pop(0)
        for dll in find_dlls(cur, runtime_bin):
            name = os.path.basename(dll).lower()
            if name in collected:
                continue
            collected.add(name)
            dst = os.path.join(dest, os.path.basename(dll))
            if not os.path.exists(dst):
                shutil.copy(dll, dst)
            queue.append(dll)

    print("collected %d DLLs into %s" % (len(collected), dest))
    if len(collected) < min_dlls:
        print(
            "ERROR: collected only %d DLLs, expected at least %d. "
            "The portable package would be broken; aborting. "
            "Check MSYSTEM_PREFIX and the ldd output."
            % (len(collected), min_dlls),
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
