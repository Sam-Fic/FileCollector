using GLib;

// 同步二进制文件预处理工具:
// 1. 优先从 PreprocessCache 读取已转换的 Markdown
// 2. 缓存未命中时, 调用 VLM (MultimodalAIClient) 转换并写入缓存
// 供 CLI 模式 (无 GUI 异步线程) 直接同步调用.
public class BinaryPreprocessor : GLib.Object {
    // 同步预处理一个二进制文件
    // - item: 需要预处理的 ItemData (item_type == "file" 且 file_path 非空)
    // - work_dir_path: 工作目录绝对路径, 用于定位缓存目录
    // - from_cache (out): 缓存是否命中
    // 返回: 转换后的 Markdown 字符串; 失败时抛出 IOError
    public static string preprocess_sync (
        ItemData item, string work_dir_path, out bool from_cache
    ) throws Error {
        from_cache = false;

        // 1. 先走轻量指纹 (size:mtime) 快速命中缓存, 避免对大文件 (PDF/图片) 计算 SHA256.
        //    命中即返回, 未命中 (含旧版无 quick 字段的缓存) 再回退到完整 SHA256 路径.
        string quick = PreprocessCache.compute_file_hash_fast (item.file_path);
        var cache = new PreprocessCache (work_dir_path);
        string? cached = cache.get_cached_markdown_quick (item.file_path, quick);
        if (cached != null) {
            from_cache = true;
            return cached;
        }

        // 2. 完整哈希路径 (兼容既有磁盘缓存)
        //    哈希计算失败时 hash_valid 留 false, 后续跳过 save_markdown 避免污染缓存
        string hash = "";
        bool hash_valid = false;
        try {
            hash = PreprocessCache.compute_file_hash (item.file_path);
            hash_valid = true;
        } catch (Error e) {
            warning ("Hash computation failed for %s: %s", item.file_path, e.message);
        }
        if (hash_valid) {
            cached = cache.get_cached_markdown (item.file_path, hash);
            if (cached != null) {
                from_cache = true;
                return cached;
            }
        }

        // 3. Load VLM settings
        var settings = ConfigManager.load_multimodal_ai_settings ();
        if (!settings.enabled || settings.api_key == "") {
            throw new IOError.FAILED (
                "多模态 AI 未启用或 API Key 为空, 无法转换二进制文件"
            );
        }

        // 4. Convert binary to base64
        string[] base64_images;
        string[] mime_types;
        if (item.is_image_target ()) {
            string? b64 = BinaryConverter.convert_image_to_base64 (item.file_path);
            if (b64 == null) {
                throw new IOError.FAILED ("图片转换失败: " + item.file_path);
            }
            base64_images = { b64 };
            mime_types = { BinaryConverter.get_output_mime_for_image (item.file_path) };
        } else {
            string[]? images = BinaryConverter.convert_to_base64_images (item.file_path);
            if (images == null) {
                throw new IOError.FAILED ("文档渲染失败: " + item.file_path);
            }
            base64_images = images;
            mime_types = new string[images.length];
            for (int i = 0; i < images.length; i++) mime_types[i] = "image/png";
        }

        // 5. Get prompt
        string prompt = (
            settings.system_prompt_override != null &&
            settings.system_prompt_override.length > 0
        )
            ? settings.system_prompt_override
            : get_default_prompt (item);

        // 6. Call VLM
        var client = new MultimodalAIClient (
            settings.base_url, settings.api_key, settings.model,
            prompt, settings.timeout
        );
        string md = client.process_images (base64_images, mime_types);

        // 7. Save to cache (仅在 hash 有效时保存, 避免空 hash 污染 manifest)
        if (hash_valid) {
            cache.save_markdown (item.file_path, hash, md);
        }

        return md;
    }

    // 仅尝试从缓存读取, 不调用 VLM. 用于加载项目文件时复用已缓存的转换结果.
    // work_dir_path 接受 null: 当 GFile 失效 (G_IS_FILE 断言失败) 时 get_path() 返回 null,
    // 此时直接返回 null 而不是构造 PreprocessCache 触发连锁临界警告.
    public static string? try_cache_only (
        ItemData item, string? work_dir_path
    ) throws Error {
        if (work_dir_path == null) return null;
        // 先轻量指纹命中, 未命中回退 SHA256 路径 (兼容旧缓存)
        string quick = PreprocessCache.compute_file_hash_fast (item.file_path);
        var cache = new PreprocessCache (work_dir_path);
        string? cached = cache.get_cached_markdown_quick (item.file_path, quick);
        if (cached != null) return cached;
        string hash = PreprocessCache.compute_file_hash (item.file_path);
        return cache.get_cached_markdown (item.file_path, hash);
    }

    // 默认提示词 (基于 file_path 字符串, 不依赖 ItemData GObject)
    // 队列工作线程使用此方法, 避免跨线程共享 ItemData.
    public static string get_default_prompt_for_path (string file_path) {
        if (ItemData.is_image_file (file_path)) {
            string lower = file_path.down ();
            if (lower.contains ("screenshot") || lower.contains ("error") || lower.contains ("bug")) {
                return "这是一张系统截图。请提取图中所有可见文本内容（包括错误信息、堆栈跟踪、UI 元素）。" +
                       "保留原始格式，使用代码块包裹命令行输出或报错信息。";
            }
            if (lower.contains ("diagram") || lower.contains ("flow") || lower.contains ("arch")) {
                return "这是一张技术图表。请描述图表的结构和逻辑关系。" +
                       "如果可能，使用 Mermaid 语法重构此图表。";
            }
            return "请提取图片中的所有文本内容，并将其转换为结构清晰的 Markdown。" +
                   "保留标题层级、列表结构和表格。";
        }
        if (ItemData.is_document_file (file_path)) {
            string lower = file_path.down ();
            if (lower.has_suffix (".xlsx") || lower.has_suffix (".xls") || lower.has_suffix (".ods")) {
                return "请将图片中的电子表格数据转换为标准 Markdown 表格。" +
                       "保留表头结构、合并单元格的语义以及数值精度。";
            }
            if (lower.has_suffix (".pptx") || lower.has_suffix (".ppt") || lower.has_suffix (".odp")) {
                return "这是演示文稿的页面截图。请将每页内容提取为 Markdown，" +
                       "使用二级标题 (##) 分隔每页幻灯片，保留要点列表。";
            }
        }
        return "请将图片中的内容转换为结构清晰的 Markdown 格式。保留标题、列表和表格。";
    }

    // 兼容: 通过 ItemData 转发到基于 file_path 的实现
    public static string get_default_prompt (ItemData item) {
        return get_default_prompt_for_path (item.file_path);
    }
}
