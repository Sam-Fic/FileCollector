using GLib;
using Gee;

// 工作线程执行器签名: 只接收不可变的 file_path 字符串, 不共享 ItemData GObject.
// 结果通过 VLMQueueManager.task_completed 信号 (在 Idle 回调中, 主线程上发射)
// 回送到主线程.
public delegate void VLMTaskExecutor (string file_path, VLMQueueManager manager);

public class VLMQueueManager : GLib.Object {
    public signal void progress_changed (int completed, int total, int active);
    public signal void state_changed (bool has_tasks);
    // 工作线程的结果回送信号. 主线程接收后, 在 items 中按 file_path 查找 ItemData
    // 并更新其属性. md 为 null 表示无内容更新 (PROCESSING/FAILED 阶段).
    public signal void task_completed (
        string file_path,
        string? preprocessed_content,
        PreprocessStatus status,
        bool from_cache
    );

    private Gee.LinkedList<string> pending_queue;
    private Gee.HashSet<string> pending_set;
    private Gee.HashSet<string> active_set;
    private Gee.ArrayList<Thread<void*>> bg_threads;

    private int completed_count;
    private int total_count;

    public int max_concurrency { get; set; default = 3; }
    public bool is_paused { get; private set; default = false; }
    private bool is_cancelled = false;

    public unowned VLMTaskExecutor? executor { get; set; }

    public VLMQueueManager () {
        pending_queue = new Gee.LinkedList<string> ();
        pending_set = new Gee.HashSet<string> ();
        active_set = new Gee.HashSet<string> ();
        bg_threads = new Gee.ArrayList<Thread<void*>> ();
    }

    public void enqueue (string file_path) {
        if (active_set.contains (file_path) || pending_set.contains (file_path)) return;

        pending_queue.offer (file_path);
        pending_set.add (file_path);
        total_count++;
        is_cancelled = false;
        emit_signals ();
        try_process_next ();
    }

    public void pause () {
        is_paused = true;
    }

    public void resume () {
        if (is_paused) {
            is_paused = false;
            try_process_next ();
        }
    }

    public void cancel () {
        is_cancelled = true;
        pending_queue.clear ();
        pending_set.clear ();
        total_count = completed_count;
        emit_signals ();
        if (active_set.size == 0) {
            state_changed (false);
        }
    }

    public bool check_cancelled () {
        return is_cancelled;
    }

    public void notify_finished (string file_path) {
        Idle.add (() => {
            finish_task (file_path);
            return Source.REMOVE;
        });
    }

    public bool has_tasks () {
        return total_count > completed_count || !pending_queue.is_empty || active_set.size > 0;
    }

    private void emit_signals () {
        progress_changed (completed_count, total_count, active_set.size);
        state_changed (has_tasks ());
    }

    private void try_process_next () {
        if (is_paused || is_cancelled) return;

        while (active_set.size < max_concurrency && !pending_queue.is_empty) {
            var path = pending_queue.poll ();
            pending_set.remove (path);
            active_set.add (path);
            emit_signals ();
            execute_task_in_background (path);
        }
    }

    private void finish_task (string file_path) {
        active_set.remove (file_path);
        completed_count++;
        emit_signals ();
        if (active_set.size == 0 && pending_queue.is_empty) {
            state_changed (false);
        } else {
            try_process_next ();
        }
    }

    private void execute_task_in_background (string file_path) {
        if (executor == null) {
            finish_task (file_path);
            return;
        }
        try {
            Thread<void*>? thread = null;
            thread = new Thread<void*> ("vlm-queue-task", () => {
                executor (file_path, this);
                if (thread != null) {
                    Idle.add (() => {
                        bg_threads.remove (thread);
                        return Source.REMOVE;
                    });
                }
                return null;
            });
            bg_threads.add (thread);
        } catch (ThreadError e) {
            warning ("Failed to create VLM thread: %s", e.message);
            Idle.add (() => {
                task_completed (file_path, null, PreprocessStatus.FAILED, false);
                finish_task (file_path);
                return Source.REMOVE;
            });
        }
    }
}
