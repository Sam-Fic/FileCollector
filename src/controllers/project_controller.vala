using Gee;

// 负责 .fcol 项目文件的序列化与反序列化，操作目标是 AppState。
public class ProjectController : GLib.Object {
    public AppState app_state { get; construct; }

    public ProjectController (AppState state) {
        Object (app_state: state);
    }

    // 从 .fcol 文件加载状态，完全替换当前 AppState
    public void load (string file_path) throws Error {
        File? work_dir;
        string? project_file;
        bool use_absolute;
        bool show_header;

        var items = new Gee.ArrayList<ItemData> ();
        var checked_paths = new Gee.HashSet<string> ();
        var checked_dirs = new Gee.HashSet<string> ();
        var common_phrases = new Gee.ArrayList<string> ();
        var snapshots = new Gee.ArrayList<WorkspaceSnapshot> ();

        ProjectManager.load_project_file (
            file_path,
            items, checked_paths, checked_dirs, common_phrases, snapshots,
            out work_dir, out project_file, out use_absolute, out show_header
        );

        app_state.replace_from (work_dir, use_absolute, show_header, items, checked_paths, checked_dirs, common_phrases, snapshots);
        app_state.project_file = project_file;
    }

    // 保存当前 AppState 到 .fcol 文件
    public void save (string file_path) throws Error {
        ProjectManager.write_project_file (
            file_path,
            app_state.work_dir,
            app_state.use_absolute,
            app_state.show_header,
            app_state.items,
            app_state.check_model.checked_files,
            app_state.check_model.checked_dirs,
            app_state.common_phrases,
            app_state.snapshots
        );
        app_state.project_file = file_path;
    }

    // 保存到当前 project_file（如果存在）
    public bool save_current () throws Error {
        if (app_state.project_file == null) return false;
        save (app_state.project_file);
        return true;
    }
}
