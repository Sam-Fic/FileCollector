using GLib;

/**
 * 跨平台运行环境 helper。
 *
 * 收敛原本散落在各处的 Linux/Flatpak 专属假设：
 *   - /proc/self/exe            (locale / 重启)
 *   - /usr/share/filecollector  (gtksourceview 主题)
 *   - /run/host/usr/bin/git     (Flatpak 内 git)
 *
 * 各方法在非 Linux 平台有合理回退, 保证三平台都能编译运行。
 */

namespace Platform {

    /**
     * 当前可执行文件的绝对路径。
     * Linux 读 /proc/self/exe; Win 用 GetModuleFileNameW; macOS 用 _NSGetExecutablePath。
     * 任何平台失败都回退到 argv[0] 或 "."。
     */
    public static string get_executable_path () {
#if WINDOWS
        // 最多 32768 宽字符 (Win32 路径上限)
        uint16[] buf = new uint16[32768];
        uint32 n = GetModuleFileNameW (null, buf, (uint32) buf.length);
        if (n > 0) {
            // UTF-16LE -> UTF-8 (BMP 安全; 可执行路径通常不含代理对)
            var sb = new StringBuilder ();
            for (uint32 i = 0; i < n; i++) {
                unichar c = buf[i];
                if (c < 0x80) {
                    sb.append_c ((char) c);
                } else {
                    sb.append (c.to_string ());
                }
            }
            return sb.str;
        }
        return ".";
#elif MACOS
        uint8[] buf = new uint8[4096];
        uint32 size = (uint32) buf.length;
        if (_NSGetExecutablePath (buf, ref size) == 0) {
            // _NSGetExecutablePath 写入的 buf 不保证末尾有 \0,
            // 用 EncodingHelper.bytes_to_string_safe 显式补 \0
            return EncodingHelper.bytes_to_string_safe (buf, buf.length);
        }
        return ".";
#else
        try {
            return FileUtils.read_link ("/proc/self/exe");
        } catch (Error e) {
            return ".";
        }
#endif
    }

#if WINDOWS
    [CCode (cheader_filename = "windows.h", cname = "GetModuleFileNameW")]
    private extern static uint32 GetModuleFileNameW (void* hModule, [CCode (array_length = false)] uint16[] lpFilename, uint32 nSize);
#endif

#if MACOS
    [CCode (cheader_filename = "mach-o/dyld.h", cname = "_NSGetExecutablePath")]
    private extern static int _NSGetExecutablePath ([CCode (array_length = false)] uint8[] buf, ref uint32 bufsize);
#endif

    /**
     * 应用数据目录 (gtksourceview 主题等)。
     * 解析优先级:
     *   1. 系统安装路径 /usr/share/filecollector
     *   2. 从可执行文件所在目录向上查找含 data/gtksourceview-5/styles 的目录
     *      (开发期可执行文件在 build/, 其父即源码树根, 这样无论从 build/ 还是
     *       源码根启动都能定位到 data/, 不再依赖启动时的当前工作目录)
     *   3. 回退到当前工作目录下的 data/
     */
    public static string get_data_dir () {
#if LINUX
        string app_data_dir = "/usr/share/filecollector";
        if (FileUtils.test (app_data_dir, FileTest.EXISTS)) {
            return app_data_dir;
        }
        // 从 exe 目录向上至多 4 层查找 data/gtksourceview-5/styles
        string? dir = Path.get_dirname (get_executable_path ());
        for (int i = 0; i < 4 && dir != null && dir != "/"; i++) {
            string candidate = Path.build_filename (dir, "data", "gtksourceview-5", "styles");
            if (FileUtils.test (candidate, FileTest.EXISTS)) {
                return Path.build_filename (dir, "data");
            }
            dir = Path.get_dirname (dir);
        }
        return Path.build_filename (Environment.get_current_dir (), "data");
#elif WINDOWS
        string exe_dir = Path.get_dirname (get_executable_path ());
        string portable_data = Path.build_filename (exe_dir, "..", "share", "data");
        if (FileUtils.test (portable_data, FileTest.EXISTS)) {
            return portable_data;
        }
        return Path.build_filename (Environment.get_current_dir (), "data");
#elif MACOS
        string exe_dir = Path.get_dirname (get_executable_path ());
        string bundle_data = Path.build_filename (exe_dir, "..", "Resources", "data");
        if (FileUtils.test (bundle_data, FileTest.EXISTS)) {
            return bundle_data;
        }
        return Path.build_filename (Environment.get_current_dir (), "data");
#else
        return Path.build_filename (Environment.get_current_dir (), "data");
#endif
    }

    /**
     * 解析 git 可执行文件路径。
     * Flatpak 运行时用 /run/host/usr/bin/git; 其他环境走 PATH 上的 "git"。
     */
    private static string? _git_executable = null;
    public static string get_git_executable () {
        if (_git_executable != null) return _git_executable;
#if LINUX
        if (FileUtils.test ("/.flatpak-info", FileTest.EXISTS) &&
            FileUtils.test ("/run/host/usr/bin/git", FileTest.EXISTS)) {
            _git_executable = "/run/host/usr/bin/git";
            return _git_executable;
        }
#endif
        _git_executable = "git";
        return _git_executable;
    }

    /**
     * 重启当前应用 (用于"应用设置需重启生效"场景)。
     */
    public static void restart_app () {
        string exec_path = get_executable_path ();
        try {
            Process.spawn_async (null, { exec_path }, null, 0, null, null);
            // 由调用方负责 quit, 这里只负责拉起新进程
        } catch (Error e) {
            warning ("Platform: failed to restart: %s", e.message);
        }
    }

    /**
     * locale 目录查找 (供 main.vala 的 setup_i18n 使用)。
     * 返回绿色版场景下的 locale 目录候选, 找不到返回 null。
     */
    public static string? get_portable_locale_dir () {
#if LINUX
        // 1. AppImage
        var appdir = Environment.get_variable ("APPDIR");
        if (appdir != null && appdir.length > 0) {
            var candidate = Path.build_filename (appdir, "usr", "share", "locale");
            if (FileUtils.test (Path.build_filename (candidate, "zh_CN", "LC_MESSAGES",
                    "filecollector.mo"), FileTest.EXISTS))
                return candidate;
        }
        // 2. 绿色版: 相对 exe
        try {
            string exe_link = FileUtils.read_link ("/proc/self/exe");
            var candidate = Path.build_filename (Path.get_dirname (exe_link), "locale");
            if (FileUtils.test (Path.build_filename (candidate, "zh_CN", "LC_MESSAGES",
                    "filecollector.mo"), FileTest.EXISTS))
                return candidate;
        } catch (Error e) { }
        return null;
#elif WINDOWS
        // Windows 便携包: <root>/bin/filecollector.exe 与 <root>/locale/ 并列。
        string exe = get_executable_path ();
        if (exe == "." || exe.length == 0) return null;
        var candidate = Path.build_filename (Path.get_dirname (exe), "..", "locale");
        if (FileUtils.test (Path.build_filename (candidate, "zh_CN", "LC_MESSAGES",
                "filecollector.mo"), FileTest.EXISTS))
            return candidate;
        return null;
#elif MACOS
        // .app: <App>.app/Contents/MacOS/FileCollector，locale 位于 Resources。
        string exe = get_executable_path ();
        if (exe == "." || exe.length == 0) return null;
        var candidate = Path.build_filename (Path.get_dirname (exe), "..", "Resources", "locale");
        if (FileUtils.test (Path.build_filename (candidate, "zh_CN", "LC_MESSAGES",
                "filecollector.mo"), FileTest.EXISTS))
            return candidate;
        return null;
#else
        return null;
#endif
    }
}
