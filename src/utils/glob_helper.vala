using Gee;

public class GlobHelper : GLib.Object {

    public static bool match_glob (string pattern, string text) {
        if (!pattern.contains ("**")) {
            var spec = new PatternSpec (pattern.down ());
            return spec.match_string (text.down ());
        }
        return match_glob_recursive (pattern.down (), text.down ());
    }

    private static bool match_glob_recursive (string pattern, string text) {
        int p_idx = 0;
        int t_idx = 0;
        int star_idx = -1;
        int match_idx = 0;

        while (t_idx < text.length) {
            if (p_idx < pattern.length &&
                (pattern[p_idx] == text[t_idx] || pattern[p_idx] == '?')) {
                p_idx++;
                t_idx++;
            } else if (p_idx < pattern.length && pattern[p_idx] == '*') {
                if (p_idx + 1 < pattern.length && pattern[p_idx + 1] == '*') {
                    star_idx = p_idx;
                    match_idx = t_idx;
                    p_idx += 2;
                    while (p_idx < pattern.length && pattern[p_idx] == '/') {
                        p_idx++;
                    }
                } else {
                    star_idx = p_idx;
                    match_idx = t_idx;
                    p_idx++;
                }
            } else if (star_idx != -1) {
                p_idx = star_idx + 1;
                match_idx++;
                t_idx = match_idx;
            } else {
                return false;
            }
        }

        while (p_idx < pattern.length && pattern[p_idx] == '*') {
            p_idx++;
        }

        return p_idx == pattern.length;
    }

    public static Gee.ArrayList<string> expand_glob (
        string base_dir,
        string pattern,
        int max_depth = 8,
        int max_results = 200
    ) {
        var results = new Gee.ArrayList<string> ();
        expand_glob_recursive (base_dir, base_dir, pattern, 0, max_depth, max_results, results);
        return results;
    }

    private static void expand_glob_recursive (
        string base_dir,
        string current_dir,
        string pattern,
        int depth,
        int max_depth,
        int max_results,
        Gee.ArrayList<string> results
    ) {
        if (results.size >= max_results || depth > max_depth) return;

        try {
            var dir = File.new_for_path (current_dir);
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NONE
            );

            FileInfo info;
            while ((info = enumerator.next_file ()) != null && results.size < max_results) {
                var child_path = Path.build_filename (current_dir, info.get_name ());
                string rel = child_path.substring (base_dir.length);
                if (rel.has_prefix ("/")) rel = rel.substring (1);

                if (match_glob (pattern, rel)) {
                    results.add (child_path);
                }

                if (info.get_file_type () == FileType.DIRECTORY && depth < max_depth) {
                    expand_glob_recursive (base_dir, child_path, pattern, depth + 1, max_depth, max_results, results);
                }
            }
        } catch (Error e) {
        }
    }
}
