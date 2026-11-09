#!/usr/bin/env python3
"""校验 Windows 便携包（staging 目录或 ZIP）的运行时 DLL 完整性。

不依赖 MSYS2、ldd 或 PATH：直接解析每个 PE 文件的导入表，确认它引用的 DLL
要么在包内，要么是 Windows 系统自带。这样即使 DLL 收集脚本一个都没拷到，
打包阶段也会直接失败，不会再发布出「找不到 xxx.dll」的坏包。

用法: verify_windows_package.py <staging_dir_or_zip>
"""
import glob
import os
import struct
import sys
import zipfile

# 主程序至少需要的运行时 DLL；缺一个就说明收集环节出问题了。
REQUIRED_DLLS = (
    "libgtk-4-1.dll",
    "libglib-2.0-0.dll",
    "libgio-2.0-0.dll",
    "libgobject-2.0-0.dll",
    "libgdk_pixbuf-2.0-0.dll",
    "libadwaita-1-0.dll",
    "libgtksourceview-5-0.dll",
    "libsoup-3.0-0.dll",
)
# 一个正常 GTK4 便携包的 bin/ 至少会有几十个 DLL。低于这个值就是异常。
MIN_BIN_DLLS = 20
# 系统提供的 API 集/扩展 DLL 不在 System32 文件列表里也能安全忽略。
SYSTEM_PREFIXES = ("api-ms-", "ext-ms-")


def pe_imports(data):
    """返回 PE 文件导入表里的 DLL 名列表（大小写原样）。"""
    if len(data) < 0x40 or data[:2] != b"MZ":
        return []
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if data[e_lfanew:e_lfanew + 4] != b"PE\0\0":
        return []
    coff = e_lfanew + 4
    nsec = struct.unpack_from("<H", data, coff + 2)[0]
    optsz = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from("<H", data, opt)[0]
    if magic == 0x20B:       # PE32+
        dd = opt + 112
    elif magic == 0x10B:     # PE32
        dd = opt + 96
    else:
        return []
    imp_rva = struct.unpack_from("<II", data, dd + 8)[0]
    if not imp_rva:
        return []

    sections = []
    sec_off = opt + optsz
    for i in range(nsec):
        o = sec_off + i * 40
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", data, o + 8)
        sections.append((vaddr, max(vsize, rsize), raddr))

    def rva_to_offset(rva):
        for vaddr, size, raddr in sections:
            if vaddr <= rva < vaddr + size:
                return raddr + (rva - vaddr)
        return None

    def cstring(off):
        end = data.find(b"\0", off)
        return data[off:end].decode("ascii", "replace")

    off = rva_to_offset(imp_rva)
    if off is None:
        return []
    names = []
    for _ in range(512):
        try:
            _, _, _, name_rva, first_thunk = struct.unpack_from("<IIIII", data, off)
        except struct.error:
            break
        if name_rva == 0 and first_thunk == 0:
            break
        name_off = rva_to_offset(name_rva)
        if name_off is None:
            break
        names.append(cstring(name_off))
        off += 20
    return names


def iter_package(target):
    """产出 (相对路径, 内容 bytes)；支持目录与 ZIP。"""
    if os.path.isdir(target):
        for root, _, files in os.walk(target):
            for f in files:
                path = os.path.join(root, f)
                rel = os.path.relpath(path, target).replace("\\", "/")
                with open(path, "rb") as fh:
                    yield rel, fh.read()
    elif zipfile.is_zipfile(target):
        with zipfile.ZipFile(target) as z:
            for info in z.infolist():
                if info.is_dir():
                    continue
                rel = info.filename.replace("\\", "/").lstrip("./")
                yield rel, z.read(info)
    else:
        print("ERROR: %s is neither a directory nor a ZIP file." % target, file=sys.stderr)
        sys.exit(1)


def system_dlls():
    windir = os.environ.get("WINDIR") or os.environ.get("SystemRoot") or r"C:\Windows"
    result = set()
    for sub in ("System32", "SysWOW64"):
        d = os.path.join(windir, sub)
        if os.path.isdir(d):
            # 不局限于 .dll: WINSPOOL.DRV 之类系统组件也会被 GTK 导入。
            result.update(f.lower() for f in os.listdir(d))
    return result


def main():
    if len(sys.argv) != 2:
        print("usage: verify_windows_package.py <staging_dir_or_zip>", file=sys.stderr)
        sys.exit(1)
    target = sys.argv[1]

    entries = [(rel, data) for rel, data in iter_package(target)
               if rel.lower().endswith((".dll", ".exe"))]
    available = {os.path.basename(rel).lower() for rel, _ in entries
                 if rel.lower().endswith(".dll")}
    # 只有 bin/ 下的可执行文件与 lib/ 下动态加载的模块参与闭包检查。
    pe_files = [(rel, data) for rel, data in entries
                if rel.lower().startswith("bin/") or rel.lower().startswith("lib/")]

    errors = []
    bin_dlls = {os.path.basename(rel).lower() for rel, _ in entries
                if rel.lower().startswith("bin/") and rel.lower().endswith(".dll")}
    if len(bin_dlls) < MIN_BIN_DLLS:
        errors.append("bin/ contains only %d DLLs (expected >= %d)"
                      % (len(bin_dlls), MIN_BIN_DLLS))

    for dll in REQUIRED_DLLS:
        if dll.lower() not in bin_dlls:
            errors.append("missing runtime DLL in bin/: %s" % dll)

    sys_dlls = system_dlls()
    missing = {}
    for rel, data in pe_files:
        for name in pe_imports(data):
            low = name.lower()
            if low in available or low in sys_dlls or low.startswith(SYSTEM_PREFIXES):
                continue
            missing.setdefault(name, []).append(rel)
    for name, users in sorted(missing.items()):
        errors.append("unresolved import %s (required by %s%s)"
                      % (name, ", ".join(users[:3]), " ..." if len(users) > 3 else ""))

    print("checked %s" % target)
    print("  PE files: %d, bundled DLLs: %d, bin/ DLLs: %d"
          % (len(pe_files), len(available), len(bin_dlls)))
    if errors:
        print("FAIL: Windows portable package is NOT self-contained:", file=sys.stderr)
        for e in errors:
            print("  - %s" % e, file=sys.stderr)
        sys.exit(1)
    print("OK: all PE imports resolve inside the package or Windows system directories.")


if __name__ == "__main__":
    main()
