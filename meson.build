project('singularity-printers', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-printers"', language: 'c')
subdir('po')

gtk_dep = dependency('gtk4')
gee_dep = dependency('gee-0.8')
gio_dep = dependency('gio-2.0')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

executable('singularity-printers',
  files('src/app.vala', 'src/queue_window.vala'),
  dependencies: [gtk_dep, gee_dep, gio_dep, libsingularity_dep],
  install: true
)

data_conf = configuration_data()
data_conf.set('bindir', get_option('prefix') / get_option('bindir'))

configure_file(
  input: 'data/dev.sinty.Printers.service.in',
  output: 'dev.sinty.Printers.service',
  configuration: data_conf,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

install_data('data/dev.sinty.Printers.desktop',
  install_dir: get_option('datadir') / 'applications'
)

configure_file(
  input: 'data/dev.sinty.Printers.Monitor.desktop.in',
  output: 'dev.sinty.Printers.Monitor.desktop',
  configuration: data_conf,
  install_dir: get_option('sysconfdir') / 'xdg' / 'autostart'
)
