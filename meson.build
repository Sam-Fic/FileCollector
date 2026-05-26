project('filecollector', 'vala', 'c',
  version: '2.0.1',
  meson_version: '>= 0.62.0'
)

# 依赖导入
dependency('glib-2.0', version: '>= 2.76')
dependency('gtk4', version: '>= 4.10')
dependency('libadwaita-1', version: '>= 1.4')
dependency('json-glib-1.0')

# 添加 C 编译器定义
add_project_arguments('-DGETTEXT_PACKAGE="' + meson.project_name() + '"', language: 'c')

# 编译 Blueprint 为 UI 资源文件
gnome = import('gnome')

# 编译 Blueprint 到建输出目录
window_ui = custom_target('window-blp',
  output: 'window.ui',
  input: 'src/window.blp',
  command: ['sh', '-c', 'blueprint-compiler compile --typelib-path /usr/lib/x86_64-linux-gnu/girepository-1.0 @INPUT@ --output @OUT@'],
  build_by_default: true
)

# 使用 gnome.compile_resources 来生成资源文件（兼容 Vala GtkTemplate）
resources = gnome.compile_resources('filecollector-resources',
  'data/filecollector.gresource.xml',
  source_dir: ['data', meson.current_build_dir()],
  dependencies: window_ui
)

sources = files(
  'src/main.vala',
  'src/window.vala'
)

executable('filecollector',
  sources,
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