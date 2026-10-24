# 更新记录 / Changelog

## v3.0.0-qiaomu.3 — 测试版 / Prerelease

- 微信读书动作在底栏清理前注册，避免重启后入口被误删。
- 升级时一次性修复 .1/.2 已丢失的入口；后续保留手动底栏选择。
- 插件禁用/缺失时暂存入口状态，重新可用后恢复；底栏满时保留原有选择。
- 新增按实际启动代码顺序执行的回归测试，覆盖连续两次冷启动、旧状态修复、手动移除和底栏满。
- 2026-10-24：用户已在一台运行 KOReader v2026.07.1 的 Kindle 上确认隐藏/恢复画面修复，以及本版微信读书入口修复正常。其他机型与未测试交互不在验收范围。

English: register WeRead before startup sanitization, repair previously pruned tabs once, and preserve manual choices. Cold-start regression tests pass; a user confirmed the shortcut fix on one Kindle running KOReader v2026.07.1 on 2026-10-24.

## v3.0.0-qiaomu.2 — 测试版 / Prerelease

- 修复隐藏后的重复重绘路径：先失效缓存，再由当前界面关闭弹层并重绘一次。
- 主页可见时不刷新底层文件管理器；恢复时仅重绘当前界面。
- 去掉隐藏后的多余提示弹层，保留已隐藏记录。
- 新增刷新顺序、唯一绘制者和异常后恢复标志的回归测试。后续 Kindle 用户已确认隐藏/恢复画面修复正常。

English: fix the duplicate/background redraw path after hiding; preserve visibility records. Rendering lifecycle regression tests pass; hide/restore rendering was subsequently user-confirmed on one Kindle.

## v3.0.0-qiaomu.1 — 测试版 / Prerelease

- 初次启用时隐藏顶部下拉提示箭头。
- 为已安装且启用的微信读书插件添加快捷入口。
- 主页和书库长按隐藏书籍/文档，设置中逐项恢复。
- 以路径记录可见性，保留原文件、批注和阅读历史。
- 自动测试已覆盖持久化、恢复、路径隔离和入口分发；真机交互待验收。

English: cleaner header, conditional WeRead shortcut, reversible book visibility. Automated regression checks pass; physical-device interaction acceptance is pending.
