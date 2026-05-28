project('filecollector', 'vala', 'c',
  version: '3.0.0',
  meson_version: '>= 0.62.0'
)

# 依赖导入
dependency('glib-2.0', version: '>= 2.76')
dependency('gtk4', version: '>= 4.10')
dependency('libadwaita-1', version: '>= 1.4')
dependency('json-glib-1.0')

gettext_package = meson.project_name ()
locale_dir = join_paths (get_option ('prefix'), get_option ('localedir'))

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
  'src/window.vala',
  'src/models/item_data.vala',
  'src/services/config_manager.vala',
  'src/services/file_generator.vala',
  'src/services/project_manager.vala',
  'src/utils/tree_helper.vala',
  'src/widgets/settings_dialog.vala',
  'src/widgets/phrases_picker.vala'
)

# 国际化
i18n = import ('i18n')
i18n.gettext (gettext_package,
  preset: 'glib',
  languages: ['en'],
  args: [
    '--from-code=UTF-8',
    '--add-comments=TRANSLATORS'
  ]
)

executable('filecollector',
  sources,
  config,
  resources,
  dependencies: [
    dependency('glib-2.0'),
    dependency('gtk4'),
    dependency('libadwaita-1'),
    dependency('json-glib-1.0')
  ],
  install: true
)

install_data('data/com.github.samfic.filecollector.desktop',
  install_dir: join_paths(get_option('datadir'), 'applications')
)

install_data('data/com.github.samfic.filecollector.metainfo.xml',
  install_dir: join_paths(get_option('datadir'), 'metainfo')
)

install_data('data/com.github.samfic.filecollector.svg',
  install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', 'scalable', 'apps')
)