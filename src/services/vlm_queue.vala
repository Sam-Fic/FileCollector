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
    // bg_threads 跨线程访问 (worker 启动 / 退出都 touch), 必须加锁保护
    private Gee.ArrayList<Thread<void*>> bg_threads;
    private Mutex bg_threads_lock;

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
        // 注: 活动任务通过 check_cancelled () 主动检查并自行退出,
        // 这里不阻塞等待, 避免在 UI 线程上卡死。
        // 主程序退出前应调用 wait_for_completion 等待活动任务退出。
    }

    /**
     * 阻塞等待所有活动任务退出 (带超时)。
     * 主程序退出前必须调用, 否则工作线程可能在 BinaryConverter.cleanup_temp_dir
     * 之后仍访问已释放的 temp_base_dir, 导致 use-after-free。
     *
     * 实现注意: 必须在循环中调用 MainContext.iteration(false) 处理挂起的 Idle
     * 回调. 否则 finish_task (通过 notify_finished → Idle.add 调度) 永远不会
     * 执行, active_set 永远不会清空, 函数必然超时. 这在主线程上调用时尤其严重
     * (on_close_request 场景), 旧实现用纯 Thread.usleep 阻塞 5 秒后超时退出,
     * 既浪费用户时间又无法真正等待工作线程退出.
     */
    public void wait_for_completion (uint timeout_ms = 5000) {
        uint elapsed = 0;
        const uint STEP_MS = 10;
        var ctx = MainContext.default ();
        while (active_set.size > 0 && elapsed < timeout_ms) {
            // 非阻塞地处理挂起的主循环事件, 让 finish_task 的 Idle 回调能执行
            ctx.iteration (false);
            Thread.usleep (STEP_MS * 1000);
            elapsed += STEP_MS;
        }
        if (active_set.size > 0) {
            warning ("VLM queue wait_for_completion timed out: %d tasks still active",
                     active_set.size);
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
                // 用 Thread.self 获取当前线程引用, 避免闭包捕获 thread 变量的竞态:
                // new Thread 内部会立即启动工作线程, 而主线程的赋值
                // `thread = new Thread...` 可能尚未完成, 此时闭包看到的 thread 仍是 null,
                // 会导致 bg_threads 中的引用无法被清除 (内存泄漏 + 无法 join)。
                Thread<void*>? self = Thread.self<void*> ();
                Idle.add (() => {
                    bg_threads_lock.lock ();
                    try {
                        bg_threads.remove (self);
                    } finally {
                        bg_threads_lock.unlock ();
                    }
                    return Source.REMOVE;
                });
                return null;
            });
            // bg_threads 同时被主线程 (add) 和 worker 通过 Idle 回调 (remove) 访问,
            // 虽然 Idle 在主线程上执行, 但加锁可明确同步语义, 防止未来重构引入竞态。
            bg_threads_lock.lock ();
            try {
                bg_threads.add (thread);
            } finally {
                bg_threads_lock.unlock ();
            }
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
