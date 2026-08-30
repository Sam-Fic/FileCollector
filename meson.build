project('filecollector', 'vala', 'c',
  version: '4.8.0',
  meson_version: '>= 0.62.0'
)

# 依赖导入
dependency('glib-2.0', version: '>= 2.76')
# GTK >= 4.16: data/style.css 使用 :root + CSS 变量语法（var(--radius-lg) 等）,
# 该特性在 4.16 才支持, 低版本上圆角/描边规则会静默失效。
dependency('gtk4', version: '>= 4.16')
dependency('libadwaita-1', version: '>= 1.9')
dependency('json-glib-1.0')
dependency('libsoup-3.0')
dependency('gee-0.8')
dependency('gtksourceview-5')

# libsecret 仅 Linux 需要 (Win/macOS 由 SecretStore 用平台原生 API 替代)
if host_machine.system() == 'linux'
  dependency('libsecret-1')
endif

# cmark-gfm (GitHub Flavored Markdown) — 用于 AI 聊天气泡的 Markdown 渲染 (含表格)
# 不用 dependency() 避免 meson 自动注入错误的 --pkg 名
cc = meson.get_compiler('c')
cmark_dep = cc.find_library('cmark-gfm', required: true)
cmark_ext_dep = cc.find_library('cmark-gfm-extensions', required: true)
cmark_header = cc.has_header('cmark-gfm.h', required: true)
cmark_ext_header = cc.has_header('cmark-gfm-core-extensions.h', required: true)

# ─── 平台分支 ──────────────────────────────────────────────────────────
# 给 Vala 传递平台宏, 并决定额外链接库:
#   - Linux   : libsecret-1 (密钥环走 libsecret)
#   - Windows : advapi32    (DPAPI, CryptProtectData)
#   - macOS   : -framework Security (SecKeychain)
if host_machine.system() == 'windows'
  platform_vala_args = ['-D', 'WINDOWS']
  platform_link_args = ['-ladvapi32', '-lcrypt32']
  # 定义 Windows 目标版本, 并强制先包含 windows.h,
  # 否则 Vala 生成的 #include <dpapi.h> 早于 windows.h, 导致
  # WINAPI_FAMILY_PARTITION / _WIN32_WINNT_WIN10 等宏未定义而编译失败。
  add_project_arguments('-D_WIN32_WINNT=0x0A00', '-DWINVER=0x0A00',
    '-include', 'windows.h', '-include', 'dpapi.h', language: 'c')
  libsecret_dep = dependency('libsecret-1', required: false)
elif host_machine.system() == 'darwin'
  platform_vala_args = ['-D', 'MACOS']
  platform_link_args = ['-framework', 'Security', '-framework', 'CoreFoundation']
  libsecret_dep = dependency('libsecret-1', required: false)
  # GTK 的 Vala 绑定将泛型回调生成 void* 参数；生成 C 的 GObject* 参数在 ABI 上兼容，
  # 但新版 Apple Clang 将该类函数指针转换默认视为错误。保留诊断但不阻断构建。
  add_project_arguments('-Wno-error=incompatible-function-pointer-types', language: 'c')
else
  # Linux (及其他类 Unix)
  platform_vala_args = ['-D', 'LINUX', '--pkg', 'libsecret-1']
  platform_link_args = []
  libsecret_dep = dependency('libsecret-1')
endif
cmark_header = cc.has_header('cmark-gfm.h', required: true)
cmark_ext_header = cc.has_header('cmark-gfm-core-extensions.h', required: true)

gettext_package = meson.project_name ()
locale_dir = join_paths (get_option ('prefix'), get_option ('localedir'))

# 开发构建：优先使用源码树 locale/ 目录，避免 /usr/share/locale 找不到 .mo
# 用 Python 做跨平台目录存在性检查, 避免依赖 Unix 的 `test` 命令
# (在 PowerShell / cmd 下 `test` 不存在会导致 configure 失败)。
src_locale = join_paths (meson.project_source_root (), 'locale')
py = find_program ('python3', 'python', required: false)
if py.found () and run_command (
    py, '-c', 'import os, sys; sys.exit(0 if os.path.isdir(sys.argv[1]) else 1)',
    src_locale, check: false
).returncode () == 0
    locale_dir = src_locale
endif

# 添加 C 编译器定义
add_project_arguments('-DGETTEXT_PACKAGE="' + gettext_package + '"', language: 'c')

# 编译 Blueprint 为 UI 资源文件
gnome = import('gnome')
blueprint_compiler = find_program('blueprint-compiler', required: true)

window_ui = custom_target('window-blp',
  input: 'src/window.blp',
  output: 'window.ui',
  command: [
    blueprint_compiler, 'compile',
    '--output', '@OUTPUT@',
    '@INPUT@'
  ],
  build_by_default: true,
)

resources = gnome.compile_resources('filecollector-resources',
  'data/filecollector.gresource.xml',
  source_dir: [meson.current_build_dir(), 'data'],
  dependencies: window_ui,
)

# 生成配置（版本号、gettext 包名、locale 目录）
config = configure_file(
  input: 'src/config.vala.in',
  output: 'config.vala',
  configuration: {
    'VERSION': meson.project_version (),
    'GETTEXT_PACKAGE': gettext_package,
    'LOCALE_DIR': locale_dir
  }
)

sources = files(
  'src/main.vala',
  'src/cli.vala',
  'src/window.vala',
  'src/utils/platform.vala',
  'src/services/secret_store.vala',
  'src/models/item_data.vala',
  'src/models/app_state.vala',
  'src/models/workspace_snapshot.vala',
  'src/models/directory_item.vala',
  'src/models/git_commit.vala',
  'src/models/prompt_template.vala',
  'src/models/search_result.vala',
  'src/controllers/project_controller.vala',
  'src/controllers/ai_controller.vala',
  'src/services/ai_client.vala',
  'src/services/ai_prompt_builder.vala',
  'src/services/ai_types.vala',
  'src/services/binary_converter.vala',
  'src/services/token_estimator.vala',
  'src/services/binary_preprocessor.vala',
  'src/services/config_manager.vala',
  'src/services/file_content_reader.vala',
  'src/services/file_generator.vala',
  'src/services/multi_format_exporter.vala',
  'src/services/zip_exporter.vala',
  'src/services/git_service.vala',
  'src/services/multimodal_ai_client.vala',
  'src/services/paddleocr_client.vala',
  'src/services/preprocess_cache.vala',
  'src/services/project_manager.vala',
  'src/services/recovery_manager.vala',
  'src/services/search_service.vala',
  'src/services/search_query_parser.vala',
  'src/services/undo_manager.vala',
  'src/services/vlm_queue.vala',
  'src/services/vlm_task_runner.vala',
  'src/utils/encoding_helper.vala',
  'src/utils/glob_helper.vala',
  'src/utils/ui_helpers.vala',
  'src/widgets/ai_panel.vala',
  'src/widgets/git_history_panel.vala',
  'src/widgets/context_menus.vala',
  'src/widgets/preferences_dialog.vala',
  'src/widgets/global_search_dialog.vala',
  'src/widgets/markdown_view.vala',
  'src/widgets/phrases_picker.vala',
  'src/widgets/preview_syntax.vala',
  'src/widgets/shortcuts_helper.vala',
  'src/widgets/templates_manager.vala',
  'src/widgets/vlm_queue_controller.vala',
  'src/widgets/queue_list_factory.vala',
  'src/widgets/file_tree_factory.vala'
)

# win32_dpapi_shim.c 仅 Windows 构建需要 (DPAPI 封装), 其它平台不存在该文件。
if host_machine.system() == 'windows'
  sources += files('src/win32_dpapi_shim.c')
endif

# 国际化
# 源语言为英文 (代码中 _() 的 msgid), 翻译文件在 po/ 目录。
# 注意: 必须强制 xgettext 用 Vala 语言解析所有输入 (含 window.blp),
# 否则 xgettext 遇到不识别的 .blp 扩展名会漏提字符串。
subdir ('po')

executable('filecollector',
  sources,
  config,
  resources,
  dependencies: [
    dependency('glib-2.0'),
    dependency('gtk4'),
    dependency('libadwaita-1'),
    dependency('json-glib-1.0'),
    dependency('libsoup-3.0'),
    dependency('gee-0.8'),
    dependency('gtksourceview-5'),
    cmark_dep,
    cmark_ext_dep,
    libsecret_dep,
    meson.get_compiler('c').find_library('m', required: false)
  ],
  link_args: platform_link_args,
  vala_args: [
    '--header', 'filecollector_types.h',
    '--includedir', meson.current_build_dir (),
    '--vapidir', join_paths(meson.current_source_dir(), 'src', 'vapi'),
    '--pkg', 'cmark',
  ] + platform_vala_args,
  install: true
)

install_data('data/io.github.sam_fic.filecollector.desktop',
  install_dir: join_paths(get_option('datadir'), 'applications')
)

install_data('data/io.github.sam_fic.filecollector.metainfo.xml',
  install_dir: join_paths(get_option('datadir'), 'metainfo')
)

install_data('data/io.github.sam_fic.filecollector.svg',
  install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', 'scalable', 'apps')
)

# GtkSourceView 预览配色方案由运行时从 ${datadir}/filecollector/ 读取。
# Windows/macOS 便携包复制整个 data/ 目录；此规则保证 DEB 与 Flatpak 也分发同一资源。
install_subdir('data/gtksourceview-5',
  install_dir: join_paths(get_option('datadir'), 'filecollector')
)

# 仅包含项目实际使用的两个 XApp symbolic SVG，叠加到标准 hicolor 主题中。
install_subdir('data/icons/hicolor',
  install_dir: join_paths(get_option('datadir'), 'icons')
)

# 在每次 Meson 安装（含 DESTDIR 和 Flatpak 构建）后验证关键运行时资源。
meson.add_install_script('tools/verify_installed_resources.py', get_option('datadir'))

# 单元测试 (meson test)
subdir('tests')