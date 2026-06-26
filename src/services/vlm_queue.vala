using GLib;
using Gee;

public delegate void VLMTaskExecutor (ItemData item, VLMQueueManager manager);

public class VLMQueueManager : GLib.Object {
    public signal void progress_changed (int completed, int total, int active);
    public signal void state_changed (bool has_tasks);

    private Gee.LinkedList<ItemData> pending_queue;
    private Gee.HashSet<ItemData> pending_set;
    private Gee.HashSet<ItemData> active_set;

    private int completed_count;
    private int total_count;

    public int max_concurrency { get; set; default = 3; }
    public bool is_paused { get; private set; default = false; }
    private bool is_cancelled = false;

    public unowned VLMTaskExecutor? executor { get; set; }

    public VLMQueueManager () {
        pending_queue = new Gee.LinkedList<ItemData> ();
        pending_set = new Gee.HashSet<ItemData> ();
        active_set = new Gee.HashSet<ItemData> ();
    }

    public void enqueue (ItemData item) {
        if (active_set.contains (item) || pending_set.contains (item)) return;
        if (item.preprocess_status == PreprocessStatus.PROCESSING ||
            item.preprocess_status == PreprocessStatus.CHECKING) return;

        pending_queue.offer (item);
        pending_set.add (item);
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

    public void notify_finished (ItemData item) {
        Idle.add (() => {
            finish_task (item);
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
            var item = pending_queue.poll ();
            pending_set.remove (item);
            active_set.add (item);
            emit_signals ();

            execute_task_in_background (item);
        }
    }

    private void finish_task (ItemData item) {
        active_set.remove (item);
        completed_count++;
        emit_signals ();
        if (active_set.size == 0 && pending_queue.is_empty) {
            state_changed (false);
        } else {
            try_process_next ();
        }
    }

    private void execute_task_in_background (ItemData item) {
        if (executor == null) {
            finish_task (item);
            return;
        }
        try {
            new Thread<void*> ("vlm-queue-task", () => {
                executor (item, this);
                return null;
            });
        } catch (ThreadError e) {
            warning ("Failed to create VLM thread: %s", e.message);
            item.preprocess_status = PreprocessStatus.FAILED;
            Idle.add (() => {
                finish_task (item);
                return Source.REMOVE;
            });
        }
    }
}
