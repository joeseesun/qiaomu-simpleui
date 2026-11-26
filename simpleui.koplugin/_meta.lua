-- [INPUT]: SimpleUI 的本地化模块。
-- [OUTPUT]: 插件名称、版本和作者元数据。
-- [POS]: KOReader 插件加载器和安装包读取此文件。
-- [PROTOCOL]: Update this header on change, then check AGENTS.md
local _ = require("infra/sui_i18n").translate

return {
    name        = "simpleui",
    fullname    = _("Simple UI"),
    description = _("A simple UI for KOReader"),
    version     = "3.0.0-qiaomu.24",
    author      = "Doctor Hetfield",
}
