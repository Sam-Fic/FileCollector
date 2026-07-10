using GLib;
using Json;

public class PreprocessCache : GLib.Object {
    private static Mutex cache_mutex = Mutex ();
    private string work_dir_path;
    private string cache_dir;
    private string manifest_path;
    private string md_dir;
    private Json.Object manifest;

    public PreprocessCache (string work_dir) {
        work_dir_path = work_dir;
        cache_dir = GLib.Path.build_filename (work_dir, ".filecollector_cache");
        manifest_path = GLib.Path.build_filename (cache_dir, "manifest.json");
        md_dir = GLib.Path.build_filename (cache_dir, "markdown");

        DirUtils.create_with_parents (md_dir, 0755);
        manifest = load_manifest_unlocked ();
    }

    public static string compute_file_hash (string path) throws Error {
        var file = File.new_for_path (path);
        var stream = file.read ();
        var checksum = new Checksum (ChecksumType.SHA256);
        uint8[] buffer = new uint8[8192];
        ssize_t read_bytes;
        while ((read_bytes = stream.read (buffer)) > 0) {
            checksum.update (buffer, read_bytes);
        }
        return checksum.get_string ();
    }

    public string? get_cached_markdown (string abs_path, string current_hash) {
        cache_mutex.lock ();
        string? result = null;
        string rel_path = get_rel_path (abs_path);

        if (manifest.has_member (rel_path)) {
            var entry = manifest.get_object_member (rel_path);
            string cached_hash = entry.get_string_member_with_default ("hash", "");
            if (cached_hash == current_hash) {
                string md_filename = entry.get_string_member_with_default ("md_file", "");
                string md_path = GLib.Path.build_filename (md_dir, md_filename);
                if (FileUtils.test (md_path, FileTest.EXISTS)) {
                    try {
                        FileUtils.get_contents (md_path, out result);
                        result = result.strip ();
                    } catch (Error e) {
                        warning ("Read cache failed: %s", e.message);
                    }
                }
            }
        }
        cache_mutex.unlock ();
        return result;
    }

    public void save_markdown (string abs_path, string current_hash, string markdown_content) {
        string rel_path = get_rel_path (abs_path);
        string md_filename = current_hash + ".md";
        string md_path = GLib.Path.build_filename (md_dir, md_filename);

        cache_mutex.lock ();
        try {
            FileUtils.set_contents (md_path, markdown_content);
            var entry = new Json.Object ();
            entry.set_string_member ("hash", current_hash);
            entry.set_string_member ("md_file", md_filename);
            entry.set_int_member ("timestamp", new DateTime.now_utc ().to_unix ());
            manifest.set_member (rel_path, AI.SchemaHelper.obj_to_node (entry));
            save_manifest_unlocked ();
        } catch (Error e) {
            warning ("Save cache failed: %s", e.message);
        }
        cache_mutex.unlock ();
    }

    public void invalidate_cache (string abs_path) {
        cache_mutex.lock ();
        string rel_path = get_rel_path (abs_path);

        if (manifest.has_member (rel_path)) {
            var entry = manifest.get_object_member (rel_path);
            string md_filename = entry.get_string_member_with_default ("md_file", "");
            string md_path = GLib.Path.build_filename (md_dir, md_filename);

            if (FileUtils.test (md_path, FileTest.EXISTS)) {
                FileUtils.unlink (md_path);
            }

            manifest.remove_member (rel_path);
            save_manifest_unlocked ();
        }
        cache_mutex.unlock ();
    }

    private string get_rel_path (string abs_path) {
        if (abs_path.has_prefix (work_dir_path)) {
            string rel = abs_path.substring (work_dir_path.length);
            if (rel.has_prefix ("/") || rel.has_prefix ("\\")) rel = rel.substring (1);
            return rel;
        }
        return abs_path;
    }

    private Json.Object load_manifest_unlocked () {
        if (FileUtils.test (manifest_path, FileTest.EXISTS)) {
            try {
                string content;
                FileUtils.get_contents (manifest_path, out content);
                var parser = new Json.Parser ();
                parser.load_from_data (content);
                if (parser.get_root () != null && parser.get_root ().get_node_type () == Json.NodeType.OBJECT) {
                    return parser.get_root ().get_object ();
                }
            } catch (Error e) {
                warning ("Load manifest failed: %s", e.message);
            }
        }
        return new Json.Object ();
    }

    public void clear_all () {
        cache_mutex.lock ();
        try {
            var dir = File.new_for_path (cache_dir);
            if (dir.query_exists ()) {
                delete_recursive (dir);
                DirUtils.create_with_parents (md_dir, 0755);
            }
            manifest = new Json.Object ();
            save_manifest_unlocked ();
        } catch (Error e) {
            warning ("Clear cache failed: %s", e.message);
        }
        cache_mutex.unlock ();
    }

    private void delete_recursive (File dir) throws Error {
        var enumerator = dir.enumerate_children (
            FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS
        );
        FileInfo info;
        while ((info = enumerator.next_file ()) != null) {
            var child = dir.get_child (info.get_name ());
            if (info.get_file_type () == FileType.DIRECTORY) {
                delete_recursive (child);
            }
            child.delete ();
        }
    }

    private void save_manifest_unlocked () {
        var gen = new Json.Generator ();
        var node = new Json.Node (Json.NodeType.OBJECT);
        node.set_object (manifest);
        gen.set_root (node);
        gen.pretty = true;
        ConfigManager.atomic_write_json (gen, manifest_path);
    }
}
