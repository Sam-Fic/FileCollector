using GLib;
using Gee;

public class GitService : GLib.Object {

    public static bool is_git_repo (string work_dir) {
        try {
            string[] argv = { "git", "rev-parse", "--is-inside-work-tree" };
            int status;
            string stdout;
            Process.spawn_sync (work_dir, argv, null,
                SpawnFlags.SEARCH_PATH | SpawnFlags.STDERR_TO_DEV_NULL,
                null, out stdout, null, out status);
            return status == 0 && stdout.strip () == "true";
        } catch (SpawnError e) {
            return false;
        }
    }

    public static string run_git (string work_dir, string[] args) throws GLib.Error {
        string[] argv = { "git" };
        foreach (var a in args) argv += a;

        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE
        );
        launcher.set_cwd (work_dir);
        launcher.setenv ("GIT_PAGER", "cat", true);
        launcher.setenv ("GIT_TERMINAL_PROMPT", "0", true);

        var proc = launcher.spawnv (argv);
        string stdout, stderr;
        proc.communicate_utf8 (null, null, out stdout, out stderr);

        if (!proc.get_successful ()) {
            if (stderr.contains ("not a git repository")) {
                throw new IOError.NOT_SUPPORTED ("Not a git repository: " + work_dir);
            }
            throw new IOError.FAILED ("Git error: " + stderr.strip ());
        }
        return stdout;
    }

    public static ArrayList<GitCommit> get_log (string work_dir, int max_count = 50) throws GLib.Error {
        return get_log_with_skip (work_dir, max_count, 0);
    }

    public static ArrayList<GitCommit> get_log_with_skip (string work_dir, int max_count, int skip) throws GLib.Error {
        string[] cmd = { "log", "-n", max_count.to_string () };
        if (skip > 0) {
            cmd += "--skip=" + skip.to_string ();
        }
        cmd += "--pretty=format:%H%x1f%an%x1f%ad%x1f%s";
        cmd += "--date=short";

        string output = run_git (work_dir, cmd);

        var commits = new ArrayList<GitCommit> ();
        foreach (var line in output.split ("\n")) {
            string trimmed = line.strip ();
            if (trimmed.length == 0) continue;
            string[] parts = trimmed.split ("\x1f", 4);
            if (parts.length < 4) continue;
            commits.add (new GitCommit (parts[0], parts[1], parts[2], parts[3]));
        }
        return commits;
    }

    public static string get_working_tree_diff (string work_dir) throws GLib.Error {
        return run_git (work_dir, { "diff" });
    }

    public static string get_staged_diff (string work_dir) throws GLib.Error {
        return run_git (work_dir, { "diff", "--cached" });
    }

    public static string get_commit_diff (string work_dir, string hash) throws GLib.Error {
        return run_git (work_dir, { "show", "--format=", "--patch-with-stat", hash });
    }

    public static string get_status (string work_dir) throws GLib.Error {
        return run_git (work_dir, { "status", "--porcelain=v1", "-uall" });
    }

    public static string get_diff_for_range (string work_dir, string from_hash, string to_hash) throws GLib.Error {
        return run_git (work_dir, { "diff", from_hash + ".." + to_hash });
    }
}
