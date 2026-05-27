project('filecollector', 'vala', 'c',
  version: '2.0.4',
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