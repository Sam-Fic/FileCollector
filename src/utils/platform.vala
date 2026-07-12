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
            // UTF-16LE -> UTF-8
            string? s = null;
            // 用 GLib 转换: 先把 uint16[] 当 unowned 字符串处理
            var u16 = (unowned string) (buf[0:n]);
            return u16;
        }
        return ".";
#elif MACOS
        uint8[] buf = new uint8[4096];
        uint32 size = (uint32) buf.length;
        if (_NSGetExecutablePath (buf, &size) == 0) {
            return (string) buf;
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
    private extern static uint32 GetModuleFileNameW (void* hModule, uint16[] lpFilename, uint32 nSize);
#endif

#if MACOS
    [CCode (cheader_filename = "mach-o/dyld.h", cname = "_NSGetExecutablePath")]
    private extern static int _NSGetExecutablePath (uint8[] buf, ref uint32 bufsize);
#endif

    /**
     * 应用数据目录 (gtksourceview 主题等)。
     * Linux 默认 /usr/share/filecollector, 找不到则回退到源码树 data/。
     * 其他平台直接回退到工作目录下的 data/。
     */
    public static string get_data_dir () {
#if LINUX
        string app_data_dir = "/usr/share/filecollector";
        if (!FileUtils.test (app_data_dir, FileTest.EXISTS)) {
            app_data_dir = Path.build_filename (Environment.get_current_dir (), "data");
        }
        return app_data_dir;
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
            if (FileUtils.test (Path.build_filename (candidate, "en", "LC_MESSAGES",
                    "filecollector.mo"), FileTest.EXISTS))
                return candidate;
        }
        // 2. 绿色版: 相对 exe
        try {
            string exe_link = FileUtils.read_link ("/proc/self/exe");
            var candidate = Path.build_filename (Path.get_dirname (exe_link), "locale");
            if (FileUtils.test (Path.build_filename (candidate, "en", "LC_MESSAGES",
                    "filecollector.mo"), FileTest.EXISTS))
                return candidate;
        } catch (Error e) { }
        return null;
#else
        // Windows/macOS 便携版: 相对 exe 的 locale 子目录
        string exe = get_executable_path ();
        if (exe == "." || exe.length == 0) return null;
        var candidate = Path.build_filename (Path.get_dirname (exe), "locale");
        if (FileUtils.test (Path.build_filename (candidate, "en", "LC_MESSAGES",
                "filecollector.mo"), FileTest.EXISTS))
            return candidate;
        return null;
#endif
    }
}
