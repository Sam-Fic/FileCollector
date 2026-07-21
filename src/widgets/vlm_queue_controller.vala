// VLM 预处理队列控制器
//
// 从 window.vala 中提取的 VLM (视觉语言模型) 预处理子系统封装:
//   - 持有 VLMQueueManager + VLMTaskRunner (任务调度与执行)
//   - 持有悬浮进度卡片的所有 widget ( Revealer / Label / Button / ProgressBar )
//   - 接收 VLMQueueManager 的信号 (progress_changed / state_changed / task_completed)
//     并更新 UI 或在 task_completed 时按 file_path 回写到 AppState.items 中的 ItemData
//   - 对外暴露 enqueue() / cancel_and_wait() / progress_revealer / refresh_list_requested
//
// 设计要点:
//   1. Controller 只持有自己构建的 widget (vlm_progress_revealer 及其子节点),
//      不接触 Window 私有的 snapshot_split / main_view —— overlay 的 reparenting
//      仍由 Window 在 setup() 后完成, 因为它涉及 Window 模板绑定的 [GtkChild] widget.
//   2. task_completed 回调中按 file_path 在 app_state.items 中查找 ItemData 并更新属性,
//      这属于数据层操作 (非 UI), 故封装在 Controller 内. UI 刷新通过 refresh_list_requested
//      信号委托给 Window (Window 才知道何时合并刷新).
//   3. vlm_runner 必须作为字段持有: VLMQueueManager.executor 是 unowned 委托,
//      不会对 runner 做 ref. 若 runner 仅是局部变量, setup() 返回后 runner 即被释放,
//      后续工作线程调用 executor() 会解引用悬空指针导致 SIGSEGV.

public class VlmQueueController : GLib.Object {

    // 任务完成后请求 Window 合并刷新编排列表 (Window 据此调用 schedule_refresh_list).
    public signal void refresh_list_requested ();

    // 悬浮进度卡片根节点: Window 取此 widget 挂到自己的 overlay 上.
    public Gtk.Revealer progress_revealer { get; private set; }

    private AppState app_state;
    private VLMQueueManager vlm_queue;
    private VLMTaskRunner vlm_runner;

    private Gtk.Label lbl_vlm_status;
    private Gtk.Button btn_vlm_pause;
    private Gtk.Button btn_vlm_cancel;
    private Gtk.ProgressBar progress_vlm;

    public VlmQueueController (AppState app_state) {
        this.app_state = app_state;

        vlm_queue = new VLMQueueManager ();
        vlm_runner = new VLMTaskRunner (
            app_state.work_dir,
            (file_path) => { return BinaryPreprocessor.get_default_prompt_for_path (file_path); }
        );
        // 绑定 work_dir: 用户切换工作目录时, vlm_runner.work_dir 自动同步,
        // 工作线程执行时即可读取到最新的 work_dir 用于缓存读写.
        app_state.bind_property (
            "work-dir", vlm_runner, "work-dir", GLib.BindingFlags.SYNC_CREATE
        );
        vlm_queue.executor = vlm_runner.execute;

        // 工作线程的结果回送: 在 items 中按 file_path 查找 ItemData,
        // 在主线程上更新其属性. 工作线程不直接接触 ItemData.
        vlm_queue.task_completed.connect (on_task_completed);

        build_progress_card ();

        // 信号连接
        vlm_queue.progress_changed.connect (on_vlm_progress_changed);
        vlm_queue.state_changed.connect (on_vlm_state_changed);

        btn_vlm_pause.clicked.connect (() => {
            if (vlm_queue.is_paused) {
                vlm_queue.resume ();
                btn_vlm_pause.icon_name = "media-playback-pause-symbolic";
                btn_vlm_pause.tooltip_text = _("Pause");
            } else {
                vlm_queue.pause ();
                btn_vlm_pause.icon_name = "media-playback-start-symbolic";
                btn_vlm_pause.tooltip_text = _("Continue Saving");
            }
        });

        btn_vlm_cancel.clicked.connect (() => {
            vlm_queue.cancel ();
        });
    }

    // 入队一个待预处理项. 保留原 enqueue 内部的状态守卫, 防止重复入队已经在
    // 处理中的项. 内部以 file_path (string) 入队, 不向 VLM 队列传递 ItemData GObject.
    public void enqueue (ItemData item) {
        if (item.file_path == null) return;
        if (item.preprocess_status == PreprocessStatus.PROCESSING ||
            item.preprocess_status == PreprocessStatus.CHECKING) return;
        // 每次入队前同步最新的并发数设置 (用户可能在设置里改过), 无需重启即可生效
        var mm = ConfigManager.load_multimodal_ai_settings ();
        vlm_queue.max_concurrency = mm.max_concurrency > 0 ? mm.max_concurrency : 3;
        vlm_queue.enqueue (item.file_path);
    }

    // 主程序退出前调用: 取消所有挂起任务并阻塞等待活动任务退出 (带超时),
    // 避免主程序退出后工作线程仍访问已释放的 BinaryConverter.temp_base_dir.
    public void cancel_and_wait () {
        if (vlm_queue == null) return;
        vlm_queue.cancel ();
        // 阻塞等待活动 VLM 任务退出 (带超时).
        vlm_queue.wait_for_completion ();
    }

    // ─── 内部 ──────────────────────────────────────────────────────────

    private void on_task_completed (string file_path, string? md, PreprocessStatus status, bool from_cache) {
        var items = app_state.items;
        for (int i = 0; i < items.size; i++) {
            var it = items.get (i);
            if (it.item_type == "file" && it.file_path == file_path) {
                if (md != null) it.preprocessed_content = md;
                it.preprocess_status = status;
                it.from_cache = from_cache;
                // 合并刷新: 批量预处理完成时每个文件完成都会触发, 直接 refresh_list
                // 会形成 N 次 O(n) 扫描 + 末尾预览级联. 委托给 Window 合并到 150ms 窗口
                // 只刷新一次.
                refresh_list_requested ();
                break;
            }
        }
    }

    private void on_vlm_progress_changed (int completed, int total, int active) {
        lbl_vlm_status.set_text (_("Preprocessing %d/%d files...").printf (completed, total));
        progress_vlm.set_fraction (total > 0 ? (double) completed / total : 0);
    }

    private void on_vlm_state_changed (bool has_tasks) {
        progress_revealer.set_reveal_child (has_tasks);
    }

    // 构建悬浮进度卡片 (programmatic, 避免 Blueprint 嵌套问题)
    private void build_progress_card () {
        lbl_vlm_status = new Gtk.Label (_("Preprocessing 0/0 files..."));
        lbl_vlm_status.hexpand = true;
        lbl_vlm_status.xalign = 0;
        lbl_vlm_status.ellipsize = Pango.EllipsizeMode.END;
        lbl_vlm_status.add_css_class ("heading");

        btn_vlm_pause = new Gtk.Button.from_icon_name ("media-playback-pause-symbolic");
        btn_vlm_pause.tooltip_text = _("Pause");
        btn_vlm_pause.add_css_class ("flat");
        btn_vlm_pause.add_css_class ("circular");

        btn_vlm_cancel = new Gtk.Button.from_icon_name ("media-record-symbolic");
        btn_vlm_cancel.tooltip_text = _("Cancel All");
        btn_vlm_cancel.add_css_class ("flat");
        btn_vlm_cancel.add_css_class ("circular");

        var header_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        header_box.append (lbl_vlm_status);
        header_box.append (btn_vlm_pause);
        header_box.append (btn_vlm_cancel);

        progress_vlm = new Gtk.ProgressBar ();
        progress_vlm.add_css_class ("osd");

        var card_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        card_box.margin_top = 12;
        card_box.margin_bottom = 12;
        card_box.margin_start = 12;
        card_box.margin_end = 12;
        card_box.set_size_request (280, -1);
        card_box.append (header_box);
        card_box.append (progress_vlm);

        var card_frame = new Gtk.Frame (null);
        card_frame.add_css_class ("card");
        card_frame.add_css_class ("vlm-progress-card");
        card_frame.set_child (card_box);

        progress_revealer = new Gtk.Revealer ();
        progress_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_UP;
        progress_revealer.reveal_child = false;
        progress_revealer.halign = Gtk.Align.END;
        progress_revealer.valign = Gtk.Align.END;
        progress_revealer.margin_end = 12;
        progress_revealer.margin_bottom = 12;
        progress_revealer.set_child (card_frame);
    }
}
