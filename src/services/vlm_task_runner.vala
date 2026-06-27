using GLib;
using Gee;

// ─── VLM 预处理任务执行器 ────────────────────────────────────────────
// 从 window.vala 中提取的 VLM 预处理核心逻辑, 通过委托回调与 UI 层解耦

public delegate string PromptProvider (ItemData item);
public delegate void RefreshCallback ();

public class VLMTaskRunner : GLib.Object {

    private File? work_dir;
    private PromptProvider prompt_provider;
    private RefreshCallback refresh_callback;

    public VLMTaskRunner (File? work_dir, owned PromptProvider prompt_provider, owned RefreshCallback refresh_callback) {
        this.work_dir = work_dir;
        this.prompt_provider = (owned) prompt_provider;
        this.refresh_callback = (owned) refresh_callback;
    }

    public void execute (ItemData item, VLMQueueManager manager) {
        File? local_work_dir = work_dir;

        // 1. 检查缓存
        string? cached_md = null;
        string hash = "";
        try {
            hash = PreprocessCache.compute_file_hash (item.file_path);
            if (local_work_dir != null) {
                var cache = new PreprocessCache (local_work_dir.get_path ());
                cached_md = cache.get_cached_markdown (item.file_path, hash);
            }
        } catch (Error e) {
            warning ("Cache check failed: %s", e.message);
        }

        if (manager.check_cancelled ()) {
            manager.notify_finished (item);
            return;
        }

        if (cached_md != null) {
            Idle.add (() => {
                item.preprocessed_content = cached_md;
                item.preprocess_status = PreprocessStatus.COMPLETED;
                item.from_cache = true;
                refresh_callback ();
                return Source.REMOVE;
            });
            manager.notify_finished (item);
            return;
        }

        // 2. 调用 VLM
        Idle.add (() => {
            item.preprocess_status = PreprocessStatus.PROCESSING;
            refresh_callback ();
            return Source.REMOVE;
        });

        var settings = ConfigManager.load_multimodal_ai_settings ();
        if (!settings.enabled || settings.api_key == "") {
            Idle.add (() => {
                item.preprocess_status = PreprocessStatus.FAILED;
                refresh_callback ();
                return Source.REMOVE;
            });
            manager.notify_finished (item);
            return;
        }

        try {
            string[] base64_images;
            string[] mime_types;

            if (item.is_image_target ()) {
                string? b64 = BinaryConverter.convert_image_to_base64 (item.file_path);
                if (b64 == null) throw new IOError.FAILED ("Image load failed");
                base64_images = { b64 };
                mime_types = { BinaryConverter.get_output_mime_for_image (item.file_path) };
            } else {
                string[]? images = BinaryConverter.convert_to_base64_images (item.file_path);
                if (images == null) throw new IOError.FAILED ("Document render failed");
                base64_images = images;
                mime_types = new string[images.length];
                for (int i = 0; i < images.length; i++) mime_types[i] = "image/png";
            }

            if (manager.check_cancelled ()) { manager.notify_finished (item); return; }

            string prompt = (settings.system_prompt_override != null && settings.system_prompt_override.length > 0)
                ? settings.system_prompt_override
                : prompt_provider (item);

            var client = new MultimodalAIClient (
                settings.base_url, settings.api_key, settings.model,
                prompt, settings.timeout
            );
            string md = client.process_images (base64_images, mime_types);

            if (manager.check_cancelled ()) { manager.notify_finished (item); return; }

            if (local_work_dir != null) {
                var cache = new PreprocessCache (local_work_dir.get_path ());
                cache.save_markdown (item.file_path, hash, md);
            }

            Idle.add (() => {
                item.preprocessed_content = md;
                item.preprocess_status = PreprocessStatus.COMPLETED;
                refresh_callback ();
                return Source.REMOVE;
            });
        } catch (Error e) {
            warning ("VLM Task failed: %s", e.message);
            Idle.add (() => {
                item.preprocess_status = PreprocessStatus.FAILED;
                refresh_callback ();
                return Source.REMOVE;
            });
        }

        manager.notify_finished (item);
    }
}
