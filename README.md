# 乔木 SimpleUI

**中文** | [English](#english)

给 KOReader 一个清爽的阅读首页：新传入的书优先展示，内容超出屏幕时可以上下滑动；书架「⋯」集中管理排序和收藏，底栏「资讯」独立阅读乔木精选。

A customized SimpleUI for KOReader with a cleaner header, a WeRead shortcut, and reversible book visibility.

[下载测试版](https://github.com/joeseesun/qiaomu-simpleui/releases/tag/v3.0.0-qiaomu.4) · [原版 SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) · [GPL-3.0](LICENSE)

基于 Doctor Hetfield 的 **SimpleUI 3.0.0**，保留上游作者和许可证。本仓库提供定制版本，不代表上游官方发布。

## 改了什么

| 功能 | 使用方式 |
|---|---|
| 清爽顶部 | 首次启用定制版时关闭下拉提示箭头；顶部菜单和下拉手势仍可使用 |
| 微信读书入口 | 检测到已安装且启用的 `weread` 插件时，注册快捷动作；底栏有空位时自动加入口 |
| 隐藏书籍与文档 | 在主页或文件夹书库长按文件，选择「从主页和书库隐藏」 |
| 随时恢复 | 设置 → 书库 → 已隐藏的书籍与文档 → 选择条目 → 恢复显示 |
| 保留文件夹能力 | 原有文件夹浏览仍然可用，书架与文件夹共享隐藏记录 |
| 最近加入 | 首页平铺书架默认按文件日期从新到旧，保留用户已明确选择的其他排序；按日期排序时，新书出现会回到书架第一页 |
| 完整浏览封面 | 超高首页可上下滑动，底栏固定；书架左右滑动和页码箭头仍用于翻页 |
| 书架菜单 | 「最近加入」旁的「⋯」可切换排序、打开我的收藏、恢复隐藏文件和调整书架设置 |
| 独立资讯 | 底栏「资讯」替换低频的「我的收藏」；收藏也可从「设置 → 书库 → 我的收藏」访问 |

## 乔木精选与 RSS

「资讯」直接读取 Qiaomu AI RSS Obsidian 插件同一套公开服务：`https://rss.qiaomu.ai/api/`，来源、文章列表和已发布的解读均复用该服务。无需在电脑运行 Obsidian，也不会调用模型生成新的文章。

- 初次进入会请求联网更新，之后优先显示本地列表；菜单可手动更新、筛选未读/全部/收藏及选择来源。一次更新读取最近 60 篇，滚动保留 200 篇和额外收藏的旧文章。
- 列表显示标题、来源、发布日期、未读及已离线状态。打开文章标为已读，长按可改回未读或收藏。
- 正文优先使用已有且未过期的乔木解读，否则读取服务提供的原文；打开成功即保存离线正文，退出时保存阅读位置。标题、正文、页码和收藏属于独立资讯数据，不写入书籍阅读历史或「继续阅读」。
- 「已离线」只表示该篇正文已经保存，不表示列表中所有文章都已下载。当前为文字阅读，外部图片、嵌入音视频不下载；单篇正文上限 400 KB。
- Kindle 优先使用系统内置 curl 的 HTTPS 和 CA 证书，并在 DNS 提供的地址之间进行有限故障切换；不会安装程序或修改全局 DNS、防火墙。其他平台使用 KOReader 的 LuaSocket 请求实现。

KOReader 另外自带 [News downloader (RSS/Atom)](https://github.com/koreader/koreader/blob/master/plugins/newsdownloader.koplugin/main.lua)，可以添加其他 RSS/Atom 订阅并下载为 EPUB。当前独立资讯列表接入乔木精选，尚未将任意 RSS 订阅合并到这份列表。

隐藏仅改变展示可见性：原文件、批注和阅读历史保留。它不是加密或隐私保护；其他应用或普通文件选择器仍可能打开原文件。隐藏记录按完整路径保存，同名不同路径的文件相互独立；文件在外部改名或移动后，旧隐藏记录不自动跟随。

微信读书插件需另行安装。此版本只调用插件已有的 `openBookshelf` / `launch` 入口，不捆绑该插件，也不替用户登录或同步。

## 安装

需要 **KOReader v2026.03+**、已启用的内置 CoverBrowser。当前代码基线和设备安装检查使用 KOReader **v2026.07.1**。

1. 先退出 KOReader，备份原来的 `plugins/simpleui.koplugin` 及 `settings/simpleui`。
2. 从 Releases 下载 **simpleui.koplugin.zip**，解压后将 `simpleui.koplugin` 放进 KOReader 的 `plugins` 目录，替换原插件目录。不要使用 GitHub 的 Source code ZIP 当安装包。
3. 安全弹出设备，重新启动 KOReader。启用「设置 → 主页 → 行为 → 以主页启动」即可默认打开首页；具体译文随上游语言包变化。
4. 首页添加 **Flat Library（平铺书库）** 模块，即可跨子文件夹浏览封面；书库目录使用你自己的 KOReader 主目录。

Kindle 插件目录：`koreader/plugins/`；Kobo：`.adds/koreader/plugins/`。隐藏记录和其他 SimpleUI 设置保存在设备的 `settings/simpleui/sui_settings.lua`，安装 ZIP 不包含个人配置。

微信读书入口需要插件实际启用，并提供兼容启动方法。底栏已满时，请在 SimpleUI 的快捷动作/导航栏设置中手动选择「微信读书」。自动添加只进行一次，之后保留用户自己的导航栏选择。

## 恢复原版

退出 KOReader，恢复备份的原版插件目录；如需彻底撤回定制设置，再恢复对应的 `settings/simpleui` 备份。原书和阅读记录不需要搬动。定制版内置更新地址指向本仓库，避免被原版覆盖；应用内检查稳定版更新，测试版请在 Releases 页面手动下载。

## 验证与范围

本版是测试发布。已自动验证：隐藏与恢复、重载后持久化、同名路径隔离、文件保留、原生文件浏览过滤、主页网格过滤、微信读书检测/启动分发/入口去重，以及 Lua 语法。

2026-10-24，用户已在一台运行 KOReader v2026.07.1 的 Kindle 上确认：隐藏与恢复后的画面问题已修复，v3.0.0-qiaomu.3 的微信读书入口修复正常。301 个插件文件通过 Wi-Fi SSH/SFTP 安装并逐项校验，保留设备设置和隐藏记录。此结果不代表所有交互或 Kindle/Kobo/Android 机型均已验收。

```bash
python3 -m pip install -r requirements-dev.txt
python3 tests/test_customizations.py
python3 tests/test_refresh_lifecycle.py
python3 tests/test_weread_lifecycle.py
python3 tests/test_arrivals.py
python3 tests/test_home_controls.py
python3 tests/test_news.py
python3 scripts/package.py
```

生成 `dist/simpleui.koplugin.zip` 与 `dist/SHA256SUMS`。安装包只包含 `simpleui.koplugin/` 下的源码和资源，不包含设备配置、账号、阅读历史或隐藏清单。

## 来源与维护

- 原版：[doctorhetfield-cmd/simpleui.koplugin](https://github.com/doctorhetfield-cmd/simpleui.koplugin)，Doctor Hetfield，GPL-3.0；原版功能说明见上游仓库。
- 阅读引擎：[KOReader](https://github.com/koreader/koreader)。
- 定制改动：向阳乔木；[GitHub](https://github.com/joeseesun/) · [X](https://x.com/vista8) · [qiaomu.ai](https://qiaomu.ai)。
- 本仓库是小范围定制维护。欢迎提交复现清楚的 issue/PR，请注明 KOReader 版本、设备型号、重启后表现；不要上传账号、Cookie、密钥或个人完整配置。

<a id="english"></a>
## English

Qiaomu SimpleUI is a customization based on **Doctor Hetfield's SimpleUI 3.0.0**, distributed under GPL-3.0. It is not an official upstream release.

It hides the top swipe indicator on first activation, adds a shortcut for an installed and enabled WeRead plugin, and lets you hide individual books/documents from the home screen and library through the shared long-press menu. Restore items from **Settings → Library → Hidden books and documents**.

Files, annotations and reading history are preserved. Visibility is not encryption: other applications and ordinary file pickers can still access the files. Records use full paths; external renames/moves do not migrate records automatically. The optional WeRead plugin is not bundled; a compatible `openBookshelf` or `launch` method is required.

The .4 candidate defaults the flat shelf to newest file date first, adds a shelf overflow menu, and uses KOReader's native vertical scrolling for oversized home layouts while retaining horizontal book pagination. Explicit sort/badge preferences remain respected. A one-time migration replaces the Favorites navigation tab with News; book favorites stay in the shelf menu and Library settings. News reads Qiaomu's existing public API, keeps unread/saved/offline/progress data outside book history, and caches an article after opening it. Arbitrary RSS/Atom feeds remain available through KOReader's built-in News Downloader; they are not yet part of the separate Qiaomu news list.

Requires KOReader v2026.03+ and its enabled CoverBrowser plugin. Back up your existing plugin folder and `settings/simpleui`, then extract the release's **simpleui.koplugin.zip** into KOReader's `plugins/` directory and restart. Keep the folder name exactly `simpleui.koplugin`. Add the Flat Library module to browse books across subfolders. To roll back, restore your previous plugin and settings backup.

This is a test release: automated visibility, dispatch and syntax tests pass; on 2026-10-24, a user confirmed the hide/restore rendering fix and the .3 WeRead shortcut fix on one Kindle running KOReader v2026.07.1. All 301 plugin files were installed and hash-verified via paired Wi-Fi SSH/SFTP, preserving settings and hidden records. This does not establish acceptance of every interaction or other devices. Run the commands above to test and build the distributable ZIP. No account, device settings, history or hidden-book list is included.
