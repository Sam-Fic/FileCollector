using Gee;

// FileWatcherService — 监听已加入编排队列的文件的外部修改
//
// 包装 GLib.FileMonitor (基于 Linux inotify / macOS FSEvents / Windows ReadDirectoryChangesW),
// 跟踪 app_state.items 中所有文件类 item 的 file_path. 当文件被外部进程修改
// (例如用户切回 IDE 保存代码) 时, 发出 file_changed 信号让 Window 标记对应
// ItemData.is_externally_modified = true, 进而触发"⚠ 已修改"徽标显示.
//
// 设计要点:
//   - sync(paths) 做 diff 增删: 新路径建 monitor, 不在 paths 中的旧 monitor 取消,
//     避免 items 变化时整体重建造成抖动.
//   - FileMonitor 的 changed 信号在保存时会连发 CHANGED -> CHANGES_DONE_HINT,
//     只对 CHANGES_DONE_HINT / CREATED / DELETED / RENAMED 反应, 跳过中间的
//     CHANGED 抖动事件.
//   - rate_limit = 800ms 让 GLib 内部去抖, 防止编辑器频繁保存时反复触发.
//   - FileMonitor 持有路径对应的 File 引用, 文件被删除后 monitor 会自动失效,
//     但仍需显式 cancel 释放资源, 析构 / unwatch_all / sync 移除时统一处理.

public class FileWatcherService : GLib.Object {

    public signal void file_changed (string path, GLib.FileMonitorEvent event);

    private Gee.HashMap<string, GLib.FileMonitor> monitors
        = new Gee.HashMap<string, GLib.FileMonitor> ();

    // 同步监听集合: 给定当前 items 中的全部文件路径, diff 出新增 / 移除,
    // 只对差异部分操作, 避免每次 items_changed 都整体重建.
    public void sync (Gee.Collection<string> paths) {
        // 新增: 在 paths 中但不在 monitors 中的
        var to_add = new Gee.ArrayList<string> ();
        foreach (var p in paths) {
            if (!monitors.has_key (p)) to_add.add (p);
        }
        // 移除: 在 monitors 中但不在 paths 中的
        var to_remove = new Gee.ArrayList<string> ();
        foreach (var key in monitors.keys) {
            if (!paths.contains (key)) to_remove.add (key);
        }
        foreach (var p in to_add) watch (p);
        foreach (var p in to_remove) unwatch (p);
    }

    // 幂等监听: 已 watch 则直接返回. 失败(权限不足 / 文件不存在 / monitor 限额)
    // 静默吞掉错误并 warning, 不影响其它路径的监听.
    public void watch (string path) {
        if (monitors.has_key (path)) return;
        var file = File.new_for_path (path);
        GLib.FileMonitor monitor;
        try {
            monitor = file.monitor_file (FileMonitorFlags.NONE);
        } catch (Error e) {
            warning ("[FileWatcher] cannot monitor %s: %s", path, e.message);
            return;
        }
        // rate_limit 是 GLib 内置去抖: 800ms 内对同一文件的多次事件合并为一次回调,
        // 避免编辑器(尤其是带原子保存 / 多次 fsync 的)反复触发刷新按钮亮起.
        monitor.rate_limit = 800;
        monitor.changed.connect (on_monitor_changed);
        monitors[path] = monitor;
    }

    public void unwatch (string path) {
        GLib.FileMonitor? m;
        if (!monitors.unset (path, out m)) return;
        if (m != null) {
            m.changed.disconnect (on_monitor_changed);
            m.cancel ();
        }
    }

    public void unwatch_all () {
        foreach (var entry in monitors.entries) {
            entry.value.changed.disconnect (on_monitor_changed);
            entry.value.cancel ();
        }
        monitors.clear ();
    }

    // FileMonitor.changed 信号回调. event 类型参考 GLib.FileMonitorEvent:
    //   CHANGED            - 文件正在被写入 (中间事件, 跳过避免抖动)
    //   CHANGES_DONE_HINT  - 一系列写入完成, 是稳定态信号, 用此触发刷新
    //   DELETED            - 文件被删除
    //   CREATED            - 文件被创建 (原子保存场景下旧文件被替换为新文件)
    //   RENAMED            - 文件被重命名
    //   ATTRIBUTE_CHANGED  - 仅属性变化, 内容未变, 跳过
    private void on_monitor_changed (GLib.FileMonitor monitor,
                                      GLib.File? file, GLib.File? other_file,
                                      GLib.FileMonitorEvent event) {
        if (file == null) return;
        string? path = file.get_path ();
        if (path == null) return;

        switch (event) {
            case GLib.FileMonitorEvent.CHANGES_DONE_HINT:
            case GLib.FileMonitorEvent.CREATED:
            case GLib.FileMonitorEvent.DELETED:
            case GLib.FileMonitorEvent.RENAMED:
                file_changed (path, event);
                break;
            default:
                // CHANGED / PRE_UNMOUNT / UNMOUNTED / MOVED_IN / MOVED_OUT /
                // ATTRIBUTE_CHANGED 均不触发外部修改标记
                break;
        }
    }
}
