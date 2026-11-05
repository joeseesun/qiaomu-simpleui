# 更新记录 / Changelog

## 未发布 / Unreleased

- 主页新增「刚送达」：乔木 Kindle 助手经 Wi-Fi 送到 `我的文章` 的书按送达时间从新到旧排列，打开前封面带「新」标记；文件夹里没有书时不占位置。新装默认在「继续阅读」之后；已保存布局的老用户只在第一页「继续阅读」后插入一次，其余模块顺序不变，在「排列模块」里移除后不再加回。
- 停在主页时自动刷新：每 12 秒 stat 一次 `我的文章` 和书库根目录的 mtime，只有可见书名变化才重扫书库并重绘，十几秒内新书出现在「刚送达」「最近加入」「新书」里。菜单或对话框盖住主页、进入阅读、休眠时停止轮询，唤醒或回到主页时立即补查一次。
- 传输中的 `.receiving-*` 等隐藏临时文件不计入、不显示，书传完改名后才出现。
- 新增 `tests/test_arrivals_watch.py`（真实扫描器 + 计时器生命周期 + 布局迁移），CI 已纳入。尚待 PW3 实机验收。

English: a "Just arrived" Homescreen row for books delivered over Wi-Fi to `我的文章` (newest first, New badge until opened, hidden when empty), placed once after Currently Reading without reordering saved layouts. While the Homescreen is in front, a 12-second directory-mtime check refreshes it when a visible book appears; polling stops when covered, reading, or asleep and catches up on resume. Hidden `.receiving-*` temp files are ignored. PW3 hardware acceptance pending.

## v3.0.0-qiaomu.21 — 测试版 / Prerelease

- 为 Kindle 资讯 API 及图片下载随包提供经 SHA-256 校验的 Mozilla CA，保留 HTTPS 证书和主机名验证。
- 新增真实本地 HTTPS 正反例和安装包完整性检查。原 PW1 尚待实机验收。

English: ship verified Mozilla roots for Kindle news and images. Verify TLS and package integrity with local tests. Original PW1 acceptance is pending.

## v3.0.0-qiaomu.20 — 测试版 / Prerelease

- 修复 KPW1 旧版 curl 不支持 `--connect-to`，导致资讯请求及图片下载失败的问题；改用兼容 curl 7.33 的动态源站解析与 `--resolve`，保留 HTTPS 证书校验和资讯 API 的公网备用线路。
- 资讯失败提示区分 DNS、连接、TLS、超时等 curl 状态，保留两条线路的错误原因；新增旧参数回归、解析失败和备用线路边界测试。
- 本地回归与安装包检查通过；尚未在 KPW1 实机验收 HTTPS 或阅读画面，升级后需重启 KOReader 验证。

English: use dynamically resolved origin routing compatible with PW1 curl 7.33 for News and images, retaining TLS verification and the public API fallback. Report per-route curl failures and cover DNS/fallback boundaries. PW1 hardware HTTPS and screen acceptance remain unverified.

## v3.0.0-qiaomu.19 — 测试版 / Prerelease

- 修复手机扫码配置 AI 时，空自定义动作列表被 Lua JSON 编码为对象，导致页面报 `quick_prompts.map is not a function`、设置加载中断的问题。
- 兼容空对象、空数组、缺失字段和无效条目，保留有效自定义动作；设置加载完成前禁用测试与保存，防止提交不完整的表单。
- 新增执行实际页面 JavaScript 的回归，覆盖首次空配置、已有动作、测试请求及加载失败；API Key 不会回传给页面。

English: handle empty Lua objects and malformed custom-action lists on the phone setup page. Enable Test/Save only after settings load successfully. Execute the shipped JavaScript in regression tests for initial setup, custom actions and failed state requests.

## v3.0.0-qiaomu.18 — 测试版 / Prerelease

- 修复 RSS 中文解读里同段多个 Markdown 链接合并、地址中的括号及下划线破坏图片和链接的问题；保留链接文字、文字强调和代码示例。
- 图片下载与正文渲染共用解析结果，兼容带标题的图片及 HTML 延迟加载图片；已缓存的文章联网打开时有限重试缺失图片，图片补齐后自动重建 EPUB，保留阅读设置与批注。
- 使用 KOReader v2026.07.1 的真实 Markdown 解析器回归；在用户报告的最新文章中核对 49 个链接、9 张图片地址，与独立 CommonMark 结果一致。Paperwhite 5 SE 原生 LuaJIT 与 HTTPS 已实测下载一张图片并生成含图 EPUB；实际阅读画面仍待用户确认。

English: fix merged inline Markdown links and broken image URLs, share parsing between downloads and rendering, and retry missing images in cached articles once per session while online. Rebuild EPUBs when image availability changes without removing reading settings or annotations. Real KOReader parser regression passes; physical Kindle rendering and HTTPS remain pending.

## v3.0.0-qiaomu.17 — 测试版 / Prerelease

- 修复新安装时默认底栏加上微信读书后占满位置，导致「资讯」入口缺失的问题；默认布局的「关闭」移回菜单，底栏保留「资讯」和「微信读书」。
- 一次性修复 .15/.16 已错误标记完成的默认底栏；保留自定义满栏及修复后的手动选择，没有空位时不再误报添加成功。
- 回归覆盖首次启动、连续重启、旧配置迁移、自定义满栏及空位恢复；文件安装与真实设备画面验收分开记录。

English: replace Power in the stock navbar with News, retaining WeRead. Repair the failed .15/.16 stock migration once, preserve custom full bars and subsequent manual choices, and retry incomplete insertion when space becomes available.

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
