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

    // 作为 GObject 属性, 可通过 bind_property 与 AppState.work_dir 同步,
    // 确保工作线程执行时拿到的是最新的 work_dir 而非构造时的快照.
    public File? work_dir { get; set; }
    private PromptProvider prompt_provider;

    // ─── VLM 客户端池 ──────────────────────────────────────────────────
    // 复用 MultimodalAIClient 以避免每个任务都重建 Soup.Session. 并发上限通常很小
    // (默认 3), 故池容量固定一个较小的上限即可. 复用前必须校验连接参数 (base_url/
    // api_key/model/timeout) 与当前设置完全一致 —— 否则复用旧凭据/旧模型会发出错误
    // 请求. 参数变化时清空整个池, 防止任何陈旧客户端被复用.
    private static Mutex pool_mutex = Mutex ();
    private static Gee.LinkedList<MultimodalAIClient> client_pool = new Gee.LinkedList<MultimodalAIClient> ();
    private static string? pool_settings_sig = null;
    private const int POOL_CAP = 8;

    private static string settings_signature (ConfigManager.MultimodalAISettings s) {
        // 客户端池复用判据: provider + base_url + model + timeout + 密钥指纹.
        //
        // 密钥不直接拼入, 改为 SHA-256 指纹. 原因:
        //   1. 未来加 debug 日志时不会把 api_key / paddleocr_token 拼进日志;
        //   2. 不同密钥产生不同指纹 -> 复用判断依然准确;
        //   3. 即使被异常堆栈 / coredump 抓取, 也只能拿到 64 hex 字符, 无法逆推.
        // provider 已参与, 顺带把 base_url/model/timeout 拼入即可.
        string token = (s.provider == ConfigManager.PROVIDER_PADDLEOCR) ? s.paddleocr_token : s.api_key;
        string token_fpr = compute_token_fingerprint (token);

        return "%s|%s|%s|%s|%g".printf (
            s.provider, token_fpr, s.base_url, s.model, s.timeout);
    }

    // 对密钥字节流做 SHA-256 摘要. 空字符串返回固定 "<empty>" 以便日志中识别.
    // 使用 GLib.Checksum (无第三方依赖, GLib 自带).
    private static string compute_token_fingerprint (string? token) {
        if (token == null || token.length == 0) return "<empty>";
        var cs = new GLib.Checksum (GLib.ChecksumType.SHA256);
        cs.update ((uint8[]) token.data, token.length);
        return cs.get_string ();
    }

    // 取一个与当前设置匹配的客户端; 池空或参数不匹配则新建. 调用方需在 finally 中
    // release_client 归还, 以便后续任务复用.
    private static MultimodalAIClient acquire_client (ConfigManager.MultimodalAISettings settings, string prompt) {
        string sig = settings_signature (settings);
        pool_mutex.lock ();
        if (pool_settings_sig != null && pool_settings_sig != sig) {
            // 设置已变化: 丢弃整个池, 避免复用陈旧客户端
            while (!client_pool.is_empty) { var old = client_pool.poll (); }
            pool_settings_sig = null;
        }
        if (pool_settings_sig == null) pool_settings_sig = sig;

        MultimodalAIClient? client = null;
        if (!client_pool.is_empty) {
            client = client_pool.poll ();
        }
        pool_mutex.unlock ();

        if (client != null) {
            // prompt 是每任务可变的, 直接更新 (public 属性, 构造后亦可赋值)
            client.prompt = prompt;
            return client;
        }
        var fresh = new MultimodalAIClient (
            settings.base_url, settings.api_key, settings.model,
            prompt, settings.timeout
        );
        return fresh;
    }

    private static void release_client (MultimodalAIClient client) {
        pool_mutex.lock ();
        if (pool_settings_sig != null && client_pool.size < POOL_CAP) {
            client_pool.offer (client);
        }
        pool_mutex.unlock ();
    }

    public VLMTaskRunner (File? work_dir, owned PromptProvider prompt_provider) {
        this.work_dir = work_dir;
        this.prompt_provider = (owned) prompt_provider;
    }

    public void execute (string file_path, VLMQueueManager manager) {
        // 工作线程持有 manager 的强引用, 防止主线程在窗口关闭且
        // wait_for_completion 超时后释放 manager, 导致工作线程访问
        // 已释放的对象 (UAF)。所有 return 路径通过 finally 保证 unref。
        manager.@ref ();
        try {
        // 读取属性: Vala 为局部 owned 变量添加 ref, 即使主线程在此期间
        // 更新了 vlm_runner.work_dir, local_work_dir 持有的 GFile 也不会被释放.
        File? local_work_dir = work_dir;

        // 1. 检查缓存
        string? cached_md = null;
        string hash = "";
        bool hash_valid = false;
        try {
            // 先走轻量指纹 (size:mtime) 快速命中, 跳过对大文件计算 SHA256
            string quick = PreprocessCache.compute_file_hash_fast (file_path);
            if (local_work_dir != null) {
                var cache = new PreprocessCache (local_work_dir.get_path ());
                cached_md = cache.get_cached_markdown_quick (file_path, quick);
                if (cached_md == null) {
                    hash = PreprocessCache.compute_file_hash (file_path);
                    hash_valid = true;
                    cached_md = cache.get_cached_markdown (file_path, hash);
                }
            } else {
                hash = PreprocessCache.compute_file_hash (file_path);
                hash_valid = true;
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

        // 校验启用状态与对应服务商所需凭据
        bool has_credential = (settings.provider == ConfigManager.PROVIDER_PADDLEOCR)
            ? settings.paddleocr_token.length > 0
            : settings.api_key.length > 0;
        if (!settings.enabled || !has_credential) {
            Idle.add (() => {
                manager.task_completed (file_path, null, PreprocessStatus.FAILED, false);
                return Source.REMOVE;
            });
            manager.notify_finished (file_path);
            return;
        }

        try {
            string md = "";

            if (settings.provider == ConfigManager.PROVIDER_PADDLEOCR) {
                // ── PaddleOCR 云端路径 ──
                // 上传原文件 (PDF/图片直传, Office 先转 PDF), 轮询并合并 Markdown.
                bool is_temp;
                string? upload_source = BinaryConverter.resolve_upload_source (file_path, out is_temp);
                if (upload_source == null) {
                    throw new IOError.FAILED (_("Failed to prepare upload source for %s").printf (file_path));
                }
                try {
                    // 仅在哈希有效且有工作目录时构造缓存实例, 供配图落盘与 md 保存复用
                    PreprocessCache? pd_cache = (local_work_dir != null && hash_valid)
                        ? new PreprocessCache (local_work_dir.get_path ()) : null;
                    var client = new PaddleOCRClient (settings.paddleocr_token, settings.timeout);
                    md = client.process_file (
                        upload_source, hash_valid ? hash : "", pd_cache, (CancelCheck) manager.check_cancelled);

                    if (manager.check_cancelled ()) { manager.notify_finished (file_path); return; }

                    if (pd_cache != null) {
                        pd_cache.save_markdown (file_path, hash, md);
                    }
                } finally {
                    if (is_temp) BinaryConverter.cleanup_dir (Path.get_dirname (upload_source));
                }
            } else {
                // ── OpenAI 兼容路径 (现有行为, 渲染为 base64 图片序列) ──
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

                var client = acquire_client (settings, prompt);
                try {
                    md = client.process_images (base64_images, mime_types);

                    if (manager.check_cancelled ()) { manager.notify_finished (file_path); return; }

                    if (local_work_dir != null && hash_valid) {
                        var cache = new PreprocessCache (local_work_dir.get_path ());
                        cache.save_markdown (file_path, hash, md);
                    }
                } finally {
                    release_client (client);
                }
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
        } finally {
            manager.unref ();
        }
    }
}
