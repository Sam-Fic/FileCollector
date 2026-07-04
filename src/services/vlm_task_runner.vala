using GLib;
using Gee;

// ─── VLM 预处理任务执行器 ────────────────────────────────────────────
// 从 window.vala 中提取的 VLM 预处理核心逻辑, 通过委托回调与 UI 层解耦.
//
// 重要: 工作线程不持有任何 ItemData GObject 引用, 只使用不可变的 file_path
// 字符串. 结果通过 VLMQueueManager.task_completed 信号 (在 Idle 回调中, 主线程
// 上发射) 回送到主线程, 由主线程查找 ItemData 并更新其属性.

public delegate string PromptProvider (string file_path);

public class VLMTaskRunner : GLib.Object {

    private File? work_dir;
    private PromptProvider prompt_provider;

    public VLMTaskRunner (File? work_dir, owned PromptProvider prompt_provider) {
        this.work_dir = work_dir;
        this.prompt_provider = (owned) prompt_provider;
    }

    public void execute (string file_path, VLMQueueManager manager) {
        File? local_work_dir = work_dir;

        // 1. 检查缓存
        string? cached_md = null;
        string hash = "";
        try {
            hash = PreprocessCache.compute_file_hash (file_path);
            if (local_work_dir != null) {
                var cache = new PreprocessCache (local_work_dir.get_path ());
                cached_md = cache.get_cached_markdown (file_path, hash);
            }
        } catch (Error e) {
            warning ("Cache check failed: %s", e.message);
        }

        if (manager.check_cancelled ()) {
            manager.notify_finished (file_path);
            return;
        }

        if (cached_md != null) {
            string md = cached_md;
            Idle.add (() => {
                manager.task_completed (file_path, md, PreprocessStatus.COMPLETED, true);
                return Source.REMOVE;
            });
            manager.notify_finished (file_path);
            return;
        }

        // 2. 标记为 PROCESSING (主线程接收信号后更新 UI)
        Idle.add (() => {
            manager.task_completed (file_path, null, PreprocessStatus.PROCESSING, false);
            return Source.REMOVE;
        });

        var settings = ConfigManager.load_multimodal_ai_settings ();
        if (!settings.enabled || settings.api_key == "") {
            Idle.add (() => {
                manager.task_completed (file_path, null, PreprocessStatus.FAILED, false);
                return Source.REMOVE;
            });
            manager.notify_finished (file_path);
            return;
        }

        try {
            string[] base64_images;
            string[] mime_types;

            if (ItemData.is_image_file (file_path)) {
                string? b64 = BinaryConverter.convert_image_to_base64 (file_path);
                if (b64 == null) throw new IOError.FAILED ("Image load failed");
                base64_images = { b64 };
                mime_types = { BinaryConverter.get_output_mime_for_image (file_path) };
            } else {
                string[]? images = BinaryConverter.convert_to_base64_images (file_path);
                if (images == null) throw new IOError.FAILED ("Document render failed");
                base64_images = images;
                mime_types = new string[images.length];
                for (int i = 0; i < images.length; i++) mime_types[i] = "image/png";
            }

            if (manager.check_cancelled ()) { manager.notify_finished (file_path); return; }

            string prompt = (settings.system_prompt_override != null && settings.system_prompt_override.length > 0)
                ? settings.system_prompt_override
                : prompt_provider (file_path);

            var client = new MultimodalAIClient (
                settings.base_url, settings.api_key, settings.model,
                prompt, settings.timeout
            );
            string md = client.process_images (base64_images, mime_types);

            if (manager.check_cancelled ()) { manager.notify_finished (file_path); return; }

            if (local_work_dir != null) {
                var cache = new PreprocessCache (local_work_dir.get_path ());
                cache.save_markdown (file_path, hash, md);
            }

            Idle.add (() => {
                manager.task_completed (file_path, md, PreprocessStatus.COMPLETED, false);
                return Source.REMOVE;
            });
        } catch (Error e) {
            warning ("VLM Task failed: %s", e.message);
            Idle.add (() => {
                manager.task_completed (file_path, null, PreprocessStatus.FAILED, false);
                return Source.REMOVE;
            });
        }

        manager.notify_finished (file_path);
    }
}
