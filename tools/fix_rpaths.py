#!/usr/bin/env python3
"""将 macOS Mach-O 的非系统 dylib 依赖统一改写为 @executable_path 相对引用并收集到同一目录。

用法: fix_rpaths.py <dest_dir> <macho_file> [<macho_file> ...]

所有输入 (主程序 + 动态加载的 GIO 模块 / pixbuf loaders) 共享同一个收集表,
保证依赖只收集一份、引用一致。处理规则:

- /opt/homebrew、/usr/local 前缀的绝对依赖: 拷贝 dylib 并改写引用;
- @rpath/<name> 依赖: 按加载者的 LC_RPATH 语义定位, 再回退到 Homebrew 目录树
  搜索, 拷贝后改写为 @executable_path/<name>。Homebrew bottle 产物广泛使用
  @rpath (如 brotli/libbrotlicommon、libwebp/libsharpyuv、cmark-gfm), 而
  otool -L 的旧方案看不到 LC_RPATH, 曾导致发布包在无 Homebrew 的机器上
  dyld 报 "Library not loaded" 无法启动;
- @loader_path/<name>、已指向 @executable_path 但目标缺失的依赖: 同样收集;
- 所有收集到的文件删除 LC_RPATH, 避免残留指向构建机的绝对路径;
- 未识别的依赖路径一律报错退出, 由打包流程在签名前兜底失败。
"""
import os
import shutil
import subprocess
import sys

# 非系统 dylib 可能出现的绝对前缀 (Apple Silicon 与 Intel Homebrew)
HOMEBREW_ROOTS = ("/opt/homebrew", "/usr/local")
# 系统自带库与框架, 无需收集也无需改写
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")


def run_checked(args, what):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError("%s failed (rc=%d): %s"
                           % (what, result.returncode, result.stderr.strip()))
    return result.stdout


def list_loads(target):
    """otool -L 的依赖路径列表 (跳过首行自身)。"""
    deps = []
    for line in run_checked(["otool", "-L", target], "otool -L " + target).splitlines()[1:]:
        dep = line.split("(")[0].strip()
        if dep:
            deps.append(dep)
    return deps


def list_rpaths(target):
    """otool -l 提取 LC_RPATH 路径列表。"""
    paths = []
    pending = False
    for line in run_checked(["otool", "-l", target], "otool -l " + target).splitlines():
        stripped = line.strip()
        if stripped.startswith("cmd "):
            pending = stripped == "cmd LC_RPATH"
        elif pending and stripped.startswith("path "):
            # "path /opt/homebrew/opt/x/lib (offset 12)" -> "/opt/homebrew/opt/x/lib"
            paths.append(stripped[len("path "):].rsplit(" (offset", 1)[0].strip())
    return paths


def find_dylib_in_homebrew(name):
    """在 Homebrew 树中按文件名搜索 dylib (opt/<formula>/lib 优先于全树 find)。"""
    for root in HOMEBREW_ROOTS:
        hit = subprocess.run(
            ["find", os.path.join(root, "opt"), "-name", name, "-print", "-quit"],
            capture_output=True, text=True)
        if hit.returncode == 0 and hit.stdout.strip():
            return hit.stdout.strip().splitlines()[0]
    for root in HOMEBREW_ROOTS:
        candidate = os.path.join(root, "lib", name)
        if os.path.isfile(candidate):
            return candidate
    return None


def find_dylib(name, search_dirs):
    """按 dyld 的搜索顺序定位同名 dylib: 显式搜索目录 (LC_RPATH / @loader_path
    所在目录 / bundle 目标目录) 优先, 回退到 Homebrew 目录树。"""
    for d in search_dirs:
        candidate = os.path.join(d, name)
        if os.path.isfile(candidate):
            return candidate
    return find_dylib_in_homebrew(name)


class Collector:
    def __init__(self, dest):
        self.dest = dest
        os.makedirs(dest, exist_ok=True)
        # basename -> bundle 内路径; 已收集的依赖不再重复拷贝
        self.collected = {}

    def ensure_collected(self, name, source):
        """把 source 收集为 dest/<name>, 并递归处理它自身的依赖。"""
        if name in self.collected:
            return
        dst = os.path.join(self.dest, name)
        if not os.path.exists(dst):
            shutil.copy(source, dst)
        self.collected[name] = dst
        self.process(dst)

    def resolve_source(self, dep, target, target_rpaths):
        """按依赖路径原文定位收集来源; 返回 (basename, source) 或 (None, None)。"""
        name = None
        search_dirs = []
        if dep.startswith("@rpath/"):
            name = dep[len("@rpath/"):]
            search_dirs = list(target_rpaths)
        elif dep.startswith("@loader_path/"):
            name = dep[len("@loader_path/"):]
            search_dirs = [os.path.dirname(os.path.abspath(target))]
        elif dep.startswith("@executable_path/"):
            name = dep[len("@executable_path/"):]
            search_dirs = [self.dest]
        elif any(dep.startswith(p) for p in HOMEBREW_ROOTS):
            return os.path.basename(dep), dep

        if name is None:
            return None, None
        if name in self.collected:
            return name, None
        source = find_dylib(name, search_dirs)
        if source is None:
            return None, None
        return name, source

    def process(self, target):
        # LC_RPATH 参与本次 @rpath 解析, 必须在删除前读取
        target_rpaths = list_rpaths(target)
        for dep in list_loads(target):
            if dep.startswith(SYSTEM_PREFIXES):
                continue
            name, source = self.resolve_source(dep, target, target_rpaths)
            if name is None:
                raise RuntimeError(
                    "unresolved dependency %s (required by %s); "
                    "not found via LC_RPATH %s nor under %s"
                    % (dep, target, target_rpaths or "[]", ", ".join(HOMEBREW_ROOTS)))
            if source is not None:
                self.ensure_collected(name, source)
            if not dep.startswith("@executable_path/"):
                run_checked(
                    ["install_name_tool", "-change", dep,
                     "@executable_path/" + name, target],
                    "install_name_tool -change %s" % dep)
        # 清理指向构建机的 LC_RPATH (含 meson 注入的构建期 rpath)
        for rpath in target_rpaths:
            run_checked(
                ["install_name_tool", "-delete_rpath", rpath, target],
                "install_name_tool -delete_rpath %s" % rpath)


def main():
    if len(sys.argv) < 3:
        print("usage: fix_rpaths.py <dest_dir> <macho_file> [<macho_file> ...]",
              file=sys.stderr)
        sys.exit(1)
    dest = sys.argv[1]
    collector = Collector(dest)
    for target in sys.argv[2:]:
        collector.process(target)
    print("collected %d dylibs into %s" % (len(collector.collected), dest))


if __name__ == "__main__":
    main()
