project('filecollector', 'vala', 'c',
  version: '4.6.0',
  meson_version: '>= 0.62.0'
)

# 依赖导入
dependency('glib-2.0', version: '>= 2.76')
dependency('gtk4', version: '>= 4.14')
dependency('libadwaita-1', version: '>= 1.8')
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
  platform_link_args = ['-ladvapi32']
  libsecret_dep = dependency('libsecret-1', required: false)
elif host_machine.system() == 'darwin'
  platform_vala_args = ['-D', 'MACOS']
  platform_link_args = ['-framework', 'Security']
  libsecret_dep = dependency('libsecret-1', required: false)
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
src_locale = join_paths (meson.project_source_root (), 'locale')
if run_command('test', '-d', src_locale, check: false).returncode() == 0
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
  'src/models/directory_item.vala',
  'src/models/git_commit.vala',
  'src/models/prompt_template.vala',
  'src/models/search_result.vala',
  'src/controllers/project_controller.vala',
  'src/controllers/ai_controller.vala',
  'src/services/ai_client.vala',
  'src/services/ai_types.vala',
  'src/services/binary_converter.vala',
  'src/services/token_estimator.vala',
  'src/services/binary_preprocessor.vala',
  'src/services/config_manager.vala',
  'src/services/file_generator.vala',
  'src/services/multi_format_exporter.vala',
  'src/services/zip_exporter.vala',
  'src/services/git_service.vala',
  'src/services/multimodal_ai_client.vala',
  'src/services/preprocess_cache.vala',
  'src/services/project_manager.vala',
  'src/services/search_service.vala',
  'src/services/undo_manager.vala',
  'src/services/vlm_queue.vala',
  'src/services/vlm_task_runner.vala',
  'src/utils/encoding_helper.vala',
  'src/utils/glob_helper.vala',
  'src/utils/ui_helpers.vala',
  'src/widgets/ai_panel.vala',
  'src/widgets/ai_settings_dialog.vala',
  'src/widgets/context_menus.vala',
  'src/widgets/context_settings_dialog.vala',
  'src/widgets/preferences_dialog.vala',
  'src/widgets/global_search_dialog.vala',
  'src/widgets/markdown_view.vala',
  'src/widgets/phrases_picker.vala',
  'src/widgets/preview_syntax.vala',
  'src/widgets/settings_dialog.vala',
  'src/widgets/shortcuts_helper.vala',
  'src/widgets/phrases_picker.vala',
  'src/widgets/templates_manager.vala'
)

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