#!/usr/bin/env python3
"""将 macOS 可执行文件依赖的 dylib 改为 @executable_path 相对引用并收集到同目录。

用法: fix_rpaths.py <exe_path> <dest_dir>
基于 otool -L 找出非系统 dylib (/opt/homebrew/lib, /usr/local/lib), 拷贝到 dest_dir,
并用 install_name_tool 重写依赖与 id, 使 .app 可独立分发 (无需用户装 homebrew)。
"""
import os
import sys
import shutil
import subprocess

HOMEBREW_LIB_PREFIXES = ("/opt/homebrew/lib", "/usr/local/lib", "/opt/homebrew/opt", "/usr/local/opt")


def list_deps(target):
    out = subprocess.run(["otool", "-L", target], capture_output=True, text=True).stdout
    deps = []
    for line in out.splitlines()[1:]:  # 跳过第一行 (自身)
        dep = line.split("(")[0].strip()
        if dep.startswith(HOMEBREW_LIB_PREFIXES):
            deps.append(dep)
    return deps


def basename_of(path):
    return os.path.basename(path)


def main():
    if len(sys.argv) != 3:
        print("usage: fix_rpaths.py <exe> <dest>", file=sys.stderr)
        sys.exit(1)
    exe, dest = sys.argv[1], sys.argv[2]
    os.makedirs(dest, exist_ok=True)
    collected = {}

    def process(target):
        for dep in list_deps(target):
            if dep in collected:
                continue
            name = basename_of(dep)
            dst = os.path.join(dest, name)
            if not os.path.exists(dst):
                shutil.copy(dep, dst)
                process(dst)
            collected[dep] = name
            # 改写 target 对该 dep 的引用为 @executable_path/name
            subprocess.run(["install_name_tool", "-change", dep,
                            "@executable_path/" + name, target], check=False)

    process(exe)
    # 处理所有已收集 dylib 的内部依赖 (递归已覆盖, 这里再收敛一次)
    for dep, name in collected.items():
        dylib = os.path.join(dest, name)
        for sub in list_deps(dylib):
            if sub in collected:
                subprocess.run(["install_name_tool", "-change", sub,
                                "@executable_path/" + collected[sub], dylib], check=False)
    print(f"collected {len(collected)} dylibs into {dest}")


if __name__ == "__main__":
    main()
