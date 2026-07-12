# 国际化: 从 po/ 目录构建翻译
# 源语言为英文 (代码中 _() 的 msgid), zh_CN.po 提供中文翻译
i18n = import ('i18n')
i18n.gettext (gettext_package,
  preset: 'glib',
  languages: ['zh_CN'],
  args: [
    '--from-code=UTF-8',
    '--language=Vala',
    '--add-comments=TRANSLATORS'
  ]
)
