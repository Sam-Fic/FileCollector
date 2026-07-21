# 单元测试
#
# 设计原则:
#   - 每个 test_*.vala 是独立可执行文件, 拥有自己的 main(), 用 print 输出
#     PASS/FAIL 行, 退出码 0/1 反映结果. 这样既可被 meson `test()` 调度,
#     也能直接 ./run 手动调试.
#   - 每个 exe 只链接被测模块及其依赖, 不链接整个 filecollector (避免拉入
#     window.vala / GTK / libadwaita 等无关重量级依赖).
#   - stubs.vala 提供 ConfigManager.atomic_write_json / get_ignored_dirs 与
#     AI.SchemaHelper.obj_to_node 的最小桩实现, 仅在测试 PreprocessCache /
#     MultiFormatExporter / FileGenerator (它们依赖这些符号但不需要完整
#     ConfigManager/AIClient) 时链接, 避免把 config_manager.vala + secret_store
#     + libsecret + ai_client.vala + libsoup 全部拉进来.

# ─── 公共依赖 ────────────────────────────────────────────────────────
# gio-2.0 提供 File/FileInputStream/Cancellable/ListStore 等,
# 即使纯逻辑测试也常因间接引用 (如 ItemData.is_snippet 等) 需要.
glib_dep = dependency('glib-2.0')
gio_dep  = dependency('gio-2.0')
gee_dep  = dependency('gee-0.8')
json_dep = dependency('json-glib-1.0')
m_dep    = meson.get_compiler('c').find_library('m', required: false)

# 仅 multi_format_exporter / file_generator 的错误消息路径用到 UIHelpers.format_size,
# 它本身只是 GLib.format_size 的转发, 但 ui_helpers.vala 整体含 GTK 符号 → 必须 link gtk4.
gtk_dep = dependency('gtk4', required: false)
soup_dep = dependency('libsoup-3.0')

src_root = meson.project_source_root()
src_dir  = join_paths(src_root, 'src')
vapi_dir = join_paths(src_dir, 'vapi')

# ─── 被测源文件 (按需链接) ──────────────────────────────────────────
encoding_helper_src       = files(join_paths(src_dir, 'utils',   'encoding_helper.vala'))
token_estimator_src       = files(join_paths(src_dir, 'services', 'token_estimator.vala'))
item_data_src             = files(join_paths(src_dir, 'models',   'item_data.vala'))
app_state_src             = files(join_paths(src_dir, 'models',   'app_state.vala'))
directory_item_src        = files(join_paths(src_dir, 'models',   'directory_item.vala'))
workspace_snapshot_src    = files(join_paths(src_dir, 'models',   'workspace_snapshot.vala'))
preprocess_cache_src      = files(join_paths(src_dir, 'services', 'preprocess_cache.vala'))
vlm_queue_src             = files(join_paths(src_dir, 'services', 'vlm_queue.vala'))
zip_exporter_src          = files(join_paths(src_dir, 'services', 'zip_exporter.vala'))
ai_client_src             = files(join_paths(src_dir, 'services', 'ai_client.vala'))
multi_format_exporter_src = files(join_paths(src_dir, 'services', 'multi_format_exporter.vala'))
file_generator_src        = files(join_paths(src_dir, 'services', 'file_generator.vala'))
file_content_reader_src   = files(join_paths(src_dir, 'services', 'file_content_reader.vala'))
ui_helpers_src            = files(join_paths(src_dir, 'utils',   'ui_helpers.vala'))

stubs_src = files('stubs.vala')

# ─── 1. EncodingHelper (纯逻辑, 无项目依赖) ────────────────────────
test_encoding_helper_exe = executable('test_encoding_helper',
  'test_encoding_helper.vala',
  encoding_helper_src,
  dependencies: [glib_dep, gio_dep, gee_dep],
)
test('test_encoding_helper', test_encoding_helper_exe)

# ─── 2. TokenEstimator (纯逻辑, 但 estimate_file_tokens_fast 用 Gio.File) ─
test_token_estimator_exe = executable('test_token_estimator',
  'test_token_estimator.vala',
  token_estimator_src,
  dependencies: [glib_dep, gio_dep, gee_dep, m_dep],
)
test('test_token_estimator', test_token_estimator_exe)

# ─── 3. AppState (依赖 ItemData/TokenEstimator/WorkspaceSnapshot/DirectoryItem) ─
test_app_state_exe = executable('test_app_state',
  'test_app_state.vala',
  app_state_src,
  item_data_src,
  token_estimator_src,
  workspace_snapshot_src,
  directory_item_src,
  dependencies: [glib_dep, gio_dep, gee_dep, m_dep],
)
test('test_app_state', test_app_state_exe)

# ─── 4. PreprocessCache (依赖 ConfigManager.atomic_write_json + AI.SchemaHelper) ─
# 用 stubs.vala 避免拉入完整的 config_manager.vala + secret_store + ai_client.vala.
test_preprocess_cache_exe = executable('test_preprocess_cache',
  'test_preprocess_cache.vala',
  preprocess_cache_src,
  stubs_src,
  dependencies: [glib_dep, gio_dep, gee_dep, json_dep],
)
test('test_preprocess_cache', test_preprocess_cache_exe)

# ─── 5. VLMQueueManager (依赖 PreprocessStatus 枚举 → item_data.vala) ─
test_vlm_queue_exe = executable('test_vlm_queue',
  'test_vlm_queue.vala',
  vlm_queue_src,
  item_data_src,
  token_estimator_src,
  dependencies: [glib_dep, gio_dep, gee_dep, m_dep],
)
test('test_vlm_queue', test_vlm_queue_exe)

# ─── 6. ZipExporter (依赖 ItemData; 运行时需要 zip/unzip 命令) ─────
test_zip_exporter_exe = executable('test_zip_exporter',
  'test_zip_exporter.vala',
  zip_exporter_src,
  item_data_src,
  token_estimator_src,
  dependencies: [glib_dep, gio_dep, gee_dep, m_dep],
)
test('test_zip_exporter', test_zip_exporter_exe)

# ─── 7. AIClient.parse_response_bytes + build_full_tool_schema (纯 JSON) ─
test_ai_client_exe = executable('test_ai_client',
  'test_ai_client.vala',
  ai_client_src,
  encoding_helper_src,
  dependencies: [glib_dep, gio_dep, gee_dep, json_dep, soup_dep],
)
test('test_ai_client', test_ai_client_exe)

# ─── 8. MultiFormatExporter.resolve_single_item ───────────────────
# 依赖 UIHelpers.format_size (仅错误消息路径), 链接 gtk4 满足符号解析.
# ui_helpers.vala 引用 ConfigManager.get_ignored_dirs (仅 enumerate_dir_children 用到)
# 和 DirChildInfo, 故需 stubs_src + directory_item_src 满足链接.
# multi_format_exporter 现依赖 FileContentReader, 需一并链接.
test_multi_format_exporter_exe = executable('test_multi_format_exporter',
  'test_multi_format_exporter.vala',
  multi_format_exporter_src,
  file_content_reader_src,
  item_data_src,
  token_estimator_src,
  encoding_helper_src,
  ui_helpers_src,
  directory_item_src,
  stubs_src,
  dependencies: [glib_dep, gio_dep, gee_dep, json_dep, gtk_dep, m_dep],
)
test('test_multi_format_exporter', test_multi_format_exporter_exe)

# ─── 9. FileGenerator.write_items_to_stream (用内存流验证) ─────────
# stubs.vala 用 Json.Generator/Node → 需要 json_dep.
# file_generator 现依赖 FileContentReader, 需一并链接.
test_file_generator_exe = executable('test_file_generator',
  'test_file_generator.vala',
  file_generator_src,
  file_content_reader_src,
  item_data_src,
  token_estimator_src,
  encoding_helper_src,
  ui_helpers_src,
  directory_item_src,
  stubs_src,
  dependencies: [glib_dep, gio_dep, gee_dep, json_dep, gtk_dep, m_dep],
)
test('test_file_generator', test_file_generator_exe)

# ─── 10. FileContentReader.read_text_streaming (统一文件读取服务) ────
# 纯逻辑 + Gio.File, 无项目依赖.
test_file_content_reader_exe = executable('test_file_content_reader',
  'test_file_content_reader.vala',
  file_content_reader_src,
  encoding_helper_src,
  dependencies: [glib_dep, gio_dep, gee_dep],
)
test('test_file_content_reader', test_file_content_reader_exe)

# ─── 11. SearchQueryParser (布尔查询解析, 纯逻辑) ─────────────────
# 解析器只依赖 gee-0.8 + glib-2.0, 无 GTK / json-glib 依赖.
search_query_parser_src = files(join_paths(src_dir, 'services', 'search_query_parser.vala'))
test_search_query_parser_exe = executable('test_search_query_parser',
  'test_search_query_parser.vala',
  search_query_parser_src,
  dependencies: [glib_dep, gio_dep, gee_dep],
)
test('test_search_query_parser', test_search_query_parser_exe)
