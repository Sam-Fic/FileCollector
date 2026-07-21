// 测试用 stub: 提供 PreprocessCache/UIHelpers 依赖的 ConfigManager 和 AI.SchemaHelper
using GLib;
using Json;

namespace AI.SchemaHelper {
    public static Json.Node obj_to_node (Json.Object o) {
        if (o == null) return new Json.Node (Json.NodeType.NULL);
        var n = new Json.Node (Json.NodeType.OBJECT);
        n.set_object (o);
        return n;
    }
}

public class ConfigManager : GLib.Object {
    public static void atomic_write_json (Json.Generator generator, string target_path) throws Error {
        var target = File.new_for_path (target_path);
        var dir = target.get_parent ();
        var tmp = File.new_for_path (
            GLib.Path.build_filename (dir != null ? dir.get_path () : ".", "." + target.get_basename () + ".tmp")
        );
        var stream = tmp.replace (null, false, FileCreateFlags.NONE);
        generator.to_stream (stream, null);
        stream.close ();
        tmp.move (target, FileCopyFlags.OVERWRITE);
    }

    // UIHelpers.enumerate_dir_children 引用此符号, 测试中不实际调用, 仅满足链接.
    public static string[] get_ignored_dirs () {
        return { ".git", "node_modules", "__pycache__", "build", ".venv", "venv",
                 "dist", "target", ".idea", ".vscode", "coverage" };
    }
}
