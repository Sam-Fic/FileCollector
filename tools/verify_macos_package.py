#!/usr/bin/env python3
"""校验 macOS .app bundle 的运行时依赖闭包与关键资源 (支持目录或 ZIP)。

不依赖 macOS 工具链: 直接解析 Mach-O 64 位的加载命令。CI 在签名前对 bundle
执行本脚本, 防止再次发布出 @rpath 悬空、缺 GIO TLS 模块或缺 pixbuf loader
这类只能在真实机器上暴露的坏包 (v4.9.1 及之前的 macOS 包在无 Homebrew 的
机器上 dyld 报 "Library not loaded" 无法启动, AI 功能因缺 TLS 后端全部失效)。

用法: verify_macos_package.py <bundle_dir_or_zip>

检查项:
  - 所有 Mach-O (主程序 / MacOS 下 dylib / GIO 模块 / pixbuf loaders):
      * LC_LOAD_DYLIB / LC_REEXPORT_DYLIB: @executable_path/<n> 必须存在于
        MacOS/; /usr/lib、/System/Library 系统库放行; 其余一律失败
        (含 @rpath、@loader_path、Homebrew 绝对路径);
      * LC_LOAD_WEAK_DYLIB / LC_LAZY_LOAD_DYLIB: 允许目标缺失 (按需加载);
      * 不允许出现任何 LC_RPATH (收集后应全部删除, 防止指向构建机);
  - Info.plist: NSHighResolutionCapable, LSMinimumSystemVersion >= 15.0
    (macOS 26 Homebrew bottle 的部署目标), 可执行文件与 CFBundleIconFile
    一致性;
  - 关键资源: GIO TLS 模块 (libgiognutls.so)、pixbuf loaders 与指向 bundle
    内部的 loaders.cache、fontconfig 配置 (含 Apple 字体目录)、zh_CN locale、
    Adwaita/hicolor 图标主题、必备 dylib 清单与数量下限。
"""
import os
import plistlib
import struct
import sys
import zipfile

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0x0C
LC_ID_DYLIB = 0x0D
LC_REEXPORT_DYLIB = 0x0F
LC_LOAD_WEAK_DYLIB = 0x18
LC_RPATH = 0x1C
LC_LAZY_LOAD_DYLIB = 0x20
LOAD_KINDS = {
    LC_LOAD_DYLIB: "load",
    LC_REEXPORT_DYLIB: "reexport",
    LC_LOAD_WEAK_DYLIB: "weak",
    LC_LAZY_LOAD_DYLIB: "lazy",
}
# 允许目标缺失的按需加载类型 (弱符号 / 首次使用时加载)
OPTIONAL_KINDS = ("weak", "lazy")

SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
FORBIDDEN_PREFIXES = ("/opt/homebrew", "/usr/local")

MACOS_DIR_REL = "Contents/MacOS"
SCAN_DIRS_REL = (
    MACOS_DIR_REL,
    "Contents/Resources/lib/gio/modules",
    "Contents/Resources/lib/gdk-pixbuf-2.0/2.10.0/loaders",
)
INFO_PLIST_REL = "Contents/Info.plist"
LOADERS_CACHE_REL = "Contents/Resources/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
FONTS_CONF_REL = "Contents/Resources/etc/fonts/fonts.conf"
LOCALE_MO_REL = "Contents/Resources/locale/zh_CN/LC_MESSAGES/filecollector.mo"
ICON_THEME_RELS = (
    "Contents/Resources/share/icons/Adwaita/index.theme",
    "Contents/Resources/share/icons/hicolor/index.theme",
)

# 主程序运行必备的 dylib (闭包断裂时最先缺失的就是这些)
REQUIRED_DYLIBS = (
    "libgtk-4.1.dylib",
    "libadwaita-1.0.dylib",
    "libglib-2.0.0.dylib",
    "libgio-2.0.0.dylib",
    "libgobject-2.0.0.dylib",
    "libgdk_pixbuf-2.0.0.dylib",
    "libgtksourceview-5.0.dylib",
    "libsoup-3.0.0.dylib",
)
# 一个正常 GTK4 bundle 的 MacOS/ 至少有几十个 dylib, 低于此值即收集环节异常
MIN_MACOS_DYLIBS = 40


def macho_load_commands(data):
    """解析 Mach-O64: 返回 (deps, rpaths); 非 Mach-O64 返回 None。
    deps 为 (kind, name) 列表。"""
    if len(data) < 64 or data[:4] != struct.pack("<I", MH_MAGIC_64):
        return None
    ncmds, = struct.unpack_from("<I", data, 16)
    off = 32
    deps = []
    rpaths = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd in LOAD_KINDS or cmd == LC_RPATH:
            stroff, = struct.unpack_from("<I", data, off + 8)
            end = data.index(b"\x00", off + stroff)
            name = data[off + stroff:end].decode("utf-8", "replace")
            if cmd == LC_RPATH:
                rpaths.append(name)
            else:
                deps.append((LOAD_KINDS[cmd], name))
        off += cmdsize
    return deps, rpaths


class BundleView:
    """统一读取目录形态与 ZIP 形态的 bundle。rel 路径以 bundle 根为基准。"""

    def __init__(self, target):
        self._zip = None
        self._zip_root = None
        self._root = None
        if os.path.isdir(target):
            self._root = target
        elif zipfile.is_zipfile(target):
            self._zip = zipfile.ZipFile(target)
            names = [i.filename.replace("\\", "/") for i in self._zip.infolist()]
            app_dirs = {n.split("/")[0] for n in names if "/" in n}
            if len(app_dirs) != 1:
                raise SystemExit("ERROR: ZIP must contain exactly one app bundle root, got %s"
                                 % sorted(app_dirs))
            self._zip_root = app_dirs.pop() + "/"
        else:
            raise SystemExit("ERROR: %s is neither a directory nor a ZIP file." % target)

    def _zip_rel(self, rel):
        return self._zip_root + rel

    def exists(self, rel):
        if self._root is not None:
            return os.path.isfile(os.path.join(self._root, rel))
        try:
            self._zip.getinfo(self._zip_rel(rel))
            return True
        except KeyError:
            return False

    def read(self, rel):
        if self._root is not None:
            with open(os.path.join(self._root, rel), "rb") as fh:
                return fh.read()
        return self._zip.read(self._zip_rel(rel))

    def list_files(self, dir_rel):
        """列出 dir_rel 下的直接文件名 (不含子目录)。"""
        if self._root is not None:
            d = os.path.join(self._root, dir_rel)
            if not os.path.isdir(d):
                return []
            return [n for n in os.listdir(d)
                    if os.path.isfile(os.path.join(d, n))]
        prefix = self._zip_rel(dir_rel).rstrip("/") + "/"
        out = []
        for info in self._zip.infolist():
            rel = info.filename.replace("\\", "/")
            if info.is_dir():
                continue
            if rel.startswith(prefix) and "/" not in rel[len(prefix):]:
                out.append(rel[len(prefix):])
        return out


def check_macho_closure(view, errors):
    macos_files = set(view.list_files(MACOS_DIR_REL))
    scanned = 0
    for dir_rel in SCAN_DIRS_REL:
        for name in view.list_files(dir_rel):
            rel = dir_rel + "/" + name
            data = view.read(rel)
            parsed = macho_load_commands(data)
            if parsed is None:
                # MacOS/ 下所有文件都应是 Mach-O; 模块目录只扫 Mach-O (容忍杂项)
                if dir_rel == MACOS_DIR_REL:
                    errors.append("%s is not a Mach-O64 binary" % rel)
                continue
            scanned += 1
            deps, rpaths = parsed
            for rpath in rpaths:
                errors.append("%s still has LC_RPATH %s (all rpaths must be removed)"
                              % (rel, rpath))
            for kind, dep in deps:
                if dep.startswith(SYSTEM_PREFIXES):
                    continue
                if any(dep.startswith(p) for p in FORBIDDEN_PREFIXES):
                    errors.append("%s depends on build-machine path %s" % (rel, dep))
                elif dep.startswith("@rpath/") or dep.startswith("@loader_path/"):
                    errors.append("%s has unresolved %s dependency %s"
                                  % (rel, kind, dep))
                elif dep.startswith("@executable_path/"):
                    target = dep[len("@executable_path/"):]
                    if target not in macos_files and kind not in OPTIONAL_KINDS:
                        errors.append("%s depends on missing %s @executable_path/%s"
                                      % (rel, kind, target))
                else:
                    errors.append("%s has unrecognized dependency %s" % (rel, dep))
    return scanned, macos_files


def main():
    if len(sys.argv) != 2:
        print("usage: verify_macos_package.py <bundle_dir_or_zip>", file=sys.stderr)
        sys.exit(1)
    view = BundleView(sys.argv[1])
    errors = []

    # ── Mach-O 依赖闭包 ──────────────────────────────────────────────
    scanned, macos_files = check_macho_closure(view, errors)

    dylibs = {n for n in macos_files if n.endswith(".dylib")}
    if len(dylibs) < MIN_MACOS_DYLIBS:
        errors.append("MacOS/ contains only %d dylibs (expected >= %d)"
                      % (len(dylibs), MIN_MACOS_DYLIBS))
    for name in REQUIRED_DYLIBS:
        if name not in macos_files:
            errors.append("missing runtime dylib in MacOS/: %s" % name)
    if "FileCollector" not in macos_files:
        errors.append("missing main executable MacOS/FileCollector")

    # ── Info.plist ───────────────────────────────────────────────────
    if not view.exists(INFO_PLIST_REL):
        errors.append("missing %s" % INFO_PLIST_REL)
    else:
        try:
            plist = plistlib.loads(view.read(INFO_PLIST_REL))
        except Exception as exc:
            plist = None
            errors.append("Info.plist not parseable: %s" % exc)
        if plist is not None:
            if plist.get("CFBundleExecutable") != "FileCollector":
                errors.append("Info.plist CFBundleExecutable is %r (expected FileCollector)"
                              % plist.get("CFBundleExecutable"))
            if not plist.get("NSHighResolutionCapable"):
                errors.append("Info.plist NSHighResolutionCapable is not enabled (Retina blur)")
            min_version = str(plist.get("LSMinimumSystemVersion", ""))
            try:
                major = int(min_version.split(".")[0])
            except ValueError:
                major = 0
            if major < 15:
                errors.append("Info.plist LSMinimumSystemVersion is %r (macOS 26 Homebrew "
                              "bottles require >= 15.0)" % min_version)
            icns_rel = "Contents/Resources/FileCollector.icns"
            icon_file = plist.get("CFBundleIconFile")
            if icon_file and not view.exists(icns_rel):
                errors.append("CFBundleIconFile=%r but %s is missing" % (icon_file, icns_rel))
            if view.exists(icns_rel) and not icon_file:
                errors.append("%s exists but CFBundleIconFile is not set" % icns_rel)

    # ── 运行时插件与关键资源 ──────────────────────────────────────────
    gio_modules = view.list_files(SCAN_DIRS_REL[1])
    if not gio_modules:
        errors.append("no GIO modules bundled under %s (HTTPS/TLS would fail "
                      "on machines without Homebrew)" % SCAN_DIRS_REL[1])
    elif "libgiognutls.so" not in gio_modules:
        errors.append("GIO TLS backend libgiognutls.so missing from %s" % SCAN_DIRS_REL[1])

    loaders = view.list_files(SCAN_DIRS_REL[2])
    pixbuf_loaders = [n for n in loaders if n.startswith("libpixbufloader-")]
    if not pixbuf_loaders:
        errors.append("no gdk-pixbuf loader modules bundled under %s (image loading "
                      "and SVG icons would fail)" % SCAN_DIRS_REL[2])

    if not view.exists(LOADERS_CACHE_REL):
        errors.append("missing %s" % LOADERS_CACHE_REL)
    else:
        cache = view.read(LOADERS_CACHE_REL).decode("utf-8", "replace")
        if "@executable_path/../Resources/lib/gdk-pixbuf-2.0/2.10.0/loaders" not in cache:
            errors.append("loaders.cache does not reference loaders via "
                          "@executable_path (entries would resolve against the build machine)")

    if not view.exists(FONTS_CONF_REL):
        errors.append("missing %s (fontconfig would find no fonts on clean machines)"
                      % FONTS_CONF_REL)
    else:
        fonts_conf = view.read(FONTS_CONF_REL).decode("utf-8", "replace")
        if "/System/Library/Fonts" not in fonts_conf:
            errors.append("fonts.conf does not scan /System/Library/Fonts")
        if "/opt/homebrew" in fonts_conf or "/usr/local" in fonts_conf:
            errors.append("fonts.conf still references build-machine Homebrew paths")

    for rel in (LOCALE_MO_REL,) + ICON_THEME_RELS:
        if not view.exists(rel):
            errors.append("missing %s" % rel)

    print("checked %s" % sys.argv[1])
    print("  Mach-O files scanned: %d, MacOS/ dylibs: %d, GIO modules: %d, "
          "pixbuf loaders: %d" % (scanned, len(dylibs), len(gio_modules),
                                  len(pixbuf_loaders)))
    if errors:
        print("FAIL: macOS app bundle is NOT self-contained:", file=sys.stderr)
        for e in errors:
            print("  - %s" % e, file=sys.stderr)
        sys.exit(1)
    print("OK: all Mach-O dependencies resolve inside the bundle or macOS system "
          "directories; runtime components are bundled.")


if __name__ == "__main__":
    main()
