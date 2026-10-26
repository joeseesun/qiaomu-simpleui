# 更新记录 / Changelog

## v3.0.0-qiaomu.16 — 测试版 / Prerelease

- 修复乔木精选富文本文章正文过小、Aa 字号调节无效：清理原文固定字号、字体和行高覆盖，保留显式加粗、斜体、对齐、隐藏及图片样式。
- 旧文章 EPUB 在下次打开时自动重建；正文等长更新、标题和样式变更也会刷新缓存，保留原路径及阅读设置、位置和批注文件。
- 新增富文本与旧缓存自动回归、设备原生排版测试脚本。在 Kindle Paperwhite 4 / KOReader v2026.07.1 上复现旧问题并验证修复，用户重启后确认旧文章 Aa 字号变化正常；其他机型、真实批注对齐及整套导航交互未在本轮单独实机验收。
- 感谢 MoreCrazy 在 PR #7 提供的初始修复，PR #8 补全样式与缓存处理并保留原提交署名。

English: fix rich-text news articles ignoring Aa font sizes while preserving explicit emphasis, alignment, hidden content and image styles. Rebuild stale EPUBs without deleting reading settings, progress or annotation sidecars. Automated regression and native Kindle rendering pass; the user confirmed Aa sizing after restarting KOReader on a Paperwhite 4 running v2026.07.1. Other devices, real annotation alignment and full navigation were not separately device-tested in this release. Includes MoreCrazy's original contribution from #7, completed in #8.

## v3.0.0-qiaomu.15 — 测试版 / Prerelease

- 首页：最近加入的书优先、书架「⋯」菜单、超高首页纵向滑动；底栏「资讯」替换低频的「我的收藏」。
- 乔木精选：频道结构与 Qiaomu AI RSS Obsidian 插件一致（全部精选、四个乔木分组、读者社区），按频道记住筛选和页码；列表上下滑翻页；缩略图不再撑爆 KOReader 共享图片缓存（修复点文章退出 KOReader）。
- 文章改用 KOReader 正式阅读器（EPUB）打开：不进阅读历史、阅读统计和「继续阅读」，异常退出后自动清理；乔木阅读条提供上一篇 / 下一篇 / 列表 / Aa 排版 / AI / 收藏，正文末尾可直接打开下一篇，排版沿用到下一篇。
- 乔木 AI：手机扫码配置 DeepSeek 等 OpenAI 兼容服务（Key 仅存设备本地）；划线 AI 翻译、查词卡片（可加入生词本）、词典弹窗「AI 释义」；选中文字 / 整篇文章 / 当前页一键问答与追问，答案可存为批注或 Markdown 笔记。
- README 新增给 AI Agent 的 KOReader 微信读书插件安装指引。

English: newest-first home shelf and shelf menu; Qiaomu picks with Obsidian-matching channels; articles read in KOReader's reader without polluting book history or statistics; a reading bar with article navigation and a typography card; optional AI translation, word lookup and one-tap Q&A configured from a phone; agent-oriented install guide for the WeRead plugin. Pre-release: device acceptance covers one Kindle Paperwhite 4 on KOReader v2026.07.1 and is still incomplete for some AI actions.

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
