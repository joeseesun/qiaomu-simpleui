# 乔木 SimpleUI

**中文** | [English](#english)

> 给 Kindle / KOReader 一个像手机一样好用的读书首页：最近加入的书优先展示，「乔木精选」按频道读 AI 资讯，划线就能 AI 翻译、查词、问答，底栏直达微信读书。
>
> A phone-like home for Kindle/KOReader: newest books first, Qiaomu's curated AI news by channel, one-tap AI translation, lookup and Q&A on any selection, and a WeRead shortcut.

[下载测试版](https://github.com/joeseesun/qiaomu-simpleui/releases) · [给 AI Agent 的安装指引](#给-ai-agent-的安装指引) · [原版 SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) · [GPL-3.0](LICENSE) · [CI](https://github.com/joeseesun/qiaomu-simpleui/actions)

基于 Doctor Hetfield 的 **SimpleUI 3.0.0** 定制，保留上游作者和 GPL-3.0 许可证，不代表上游官方发布。当前版本：**v3.0.0-qiaomu.16（测试版）**，开发与实机记录见 [docs/home-news-progress.md](docs/home-news-progress.md)，设计说明见 [DESIGN.md](DESIGN.md)。

## 能做什么

| 能力 | 你得到什么 |
|---|---|
| 最近加入的书架 | 首页平铺书架默认按文件日期从新到旧，新书出现回到第一页；书架「⋯」切换排序、打开收藏、恢复隐藏 |
| 隐藏书籍与文档 | 长按文件「从主页和书库隐藏」；设置 → 书库 → 已隐藏的书籍与文档里随时恢复，原文件和批注不动 |
| 乔木精选（资讯） | 底栏「资讯」读取乔木 AI RSS 公开服务，频道结构与 Obsidian 插件一致：全部精选、微信公众号、播客、Newsletter、博客与资讯、读者社区；每个频道记住自己的筛选和页码 |
| 用 KOReader 阅读器读文章 | 文章打包成 EPUB 交给 KOReader 正式阅读器：原生字体、目录、词典、划线；不进阅读历史、不进阅读统计、不影响「继续阅读」 |
| 乔木阅读条 | 读文章时点屏幕底部：上一篇 · 列表 · Aa · AI · 收藏 · 下一篇；Aa 一屏调字体（朱雀仿宋、霞鹜文楷、思源宋体、思源黑体）、字号、行距、页边距，下一篇自动沿用；正文末尾直接点「下一篇」 |
| AI 划线翻译与查词 | 划线后「AI 翻译」：选中一个词出查词卡片（音标、本句含义、义项、例句，可加入生词本），选中一段出译文卡片（可存为批注）；词典弹窗多一个「AI 释义」 |
| AI 一键问答 | 选中文字点「问 AI」，或在文章 / 当前页点「AI」：解释、总结要点、举个例子、补充背景、换个角度看、出题考考我、总结全文……点一下就有答案，再点「说得更简单 / 举个例子 / 继续深入」追问，答案可保存 |
| 手机扫码配置 AI | Kindle 显示二维码，手机扫码填 DeepSeek 等服务的 API Key 和模型，不用在 Kindle 上打字；Key 只存在设备本地 |
| 微信读书入口 | 装好 [微信读书插件](https://github.com/finlater/weread.koplugin) 后自动注册快捷动作，底栏有空位时自动加入口 |

## 快速开始

需要：**已安装 KOReader v2026.03 或更新版本**（当前在 v2026.07.1 上开发和实机验证），并启用 KOReader 自带的 CoverBrowser 插件。

1. 退出 KOReader，备份设备上的 `koreader/plugins/simpleui.koplugin` 和 `koreader/settings/simpleui`（如果有）。
2. 从 [Releases](https://github.com/joeseesun/qiaomu-simpleui/releases) 下载 **simpleui.koplugin.zip**（不要用 GitHub 自动生成的 Source code ZIP），可以用同一页面的 `SHA256SUMS` 校验。
3. 解压得到 `simpleui.koplugin` 文件夹，放进 KOReader 的插件目录，替换原插件：

   | 设备 | 插件目录 |
   |---|---|
   | Kindle | `koreader/plugins/`（设备内路径 `/mnt/us/koreader/plugins/`） |
   | Kobo | `.adds/koreader/plugins/` |
   | Android | `koreader/plugins/`（KOReader 数据目录下） |

4. 安全弹出设备，启动 KOReader。在「设置 → 主页 → 行为」里开启以主页启动；首页添加「平铺书库」模块即可跨子文件夹浏览封面。

### 微信读书（可选）

微信读书功能来自第三方开源插件 [finlater/weread.koplugin](https://github.com/finlater/weread.koplugin)（AGPL-3.0），本项目**不捆绑、不代登录、不同步账号数据**，只在它已安装并启用时提供入口。

1. 从 [weread.koplugin Releases](https://github.com/finlater/weread.koplugin/releases) 下载最新的 `weread.koplugin-vX.Y.Z.zip`（附带 `.sha256` 校验文件）。
2. 解压得到 `weread.koplugin` 文件夹，放进同一个 KOReader 插件目录，例如 Kindle 的 `koreader/plugins/weread.koplugin/`。
3. 重启 KOReader，菜单里会出现「工具 → 微信读书」。
4. 登录（必须本人在手机上操作）：手机微信读书 App → 我 → 设置 → **微信读书 Skill** → 获取 API Key；然后在 KOReader 打开「工具 → 微信读书 → 微信扫码登录」，用微信扫码确认，手机显示四位验证码时在 KOReader 中输入。
5. 再次重启后，乔木 SimpleUI 会自动注册「微信读书」快捷动作；底栏已满时，在 SimpleUI 的快捷动作 / 导航栏设置里手动选择「微信读书」。

### 乔木 AI（可选）

1. KOReader 顶部菜单 → 工具 → **乔木 AI** → **用手机配置**。
2. 手机连同一个 Wi-Fi 扫码，选服务（默认 DeepSeek），粘贴 API Key，点「测试连接」后「保存到 Kindle」。
3. 读书或读文章时划线即可使用「AI 翻译」「问 AI」；文章阅读条和「乔木 AI → 问 AI：这一页」可以对整篇或当前页提问。

预设服务：DeepSeek、Kimi、通义千问、智谱 GLM、硅基流动、豆包（火山方舟）、MiniMax、OpenRouter，以及任意 OpenAI 兼容接口（可以接局域网里的 Ollama、LM Studio）。在参考 Kindle 上实测，国内这几家 0.3–0.7 秒内响应；OpenAI、Anthropic、Google 翻译从这台设备连不上。

## 给 AI Agent 的安装指引

> 本节写给帮用户安装的 AI Agent（Claude Code、Codex 等）。用户可以直接把这一节发给 Agent。请严格按步骤执行，每步都要验证；遇到需要用户本人操作的步骤，停下来请用户完成。

**边界（必须遵守）**

- 不要替用户越狱 Kindle、刷固件或安装 KOReader 本体。如果设备上没有 KOReader，请用户按 [KOReader 官方安装说明](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices) 自行完成，再继续。
- 不要替用户登录微信读书，不要读取、导出或打印任何账号、Cookie、API Key、SSH 私钥。微信扫码登录必须用户本人完成。
- 不要修改 KOReader 运行时正在使用的设置文件；替换插件前先请用户退出 KOReader（USB 方式），或在 KOReader 运行时只替换插件目录、不碰 `settings/`。
- 只从下面两个官方 GitHub 仓库下载：`joeseesun/qiaomu-simpleui`、`finlater/weread.koplugin`。下载后必须校验 SHA-256。

**步骤**

1. **确认环境**：找到设备上的 KOReader 根目录（Kindle USB 挂载时通常是 `<挂载点>/koreader/`，设备内为 `/mnt/us/koreader/`；Kobo 为 `.adds/koreader/`）。读取 `koreader/git-rev` 或请用户在 KOReader「帮助 → 关于」查看版本，确认 **≥ v2026.03**，否则请用户先升级 KOReader。
2. **下载并校验**（在电脑上执行）：

   ```bash
   # 本项目目前发布的是测试版（pre-release），不带版本号的下载只认稳定版，所以先取最新的版本号
   TAG=$(gh release list --repo joeseesun/qiaomu-simpleui --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName')
   gh release download "$TAG" --repo joeseesun/qiaomu-simpleui --pattern 'simpleui.koplugin.zip' --pattern 'SHA256SUMS' --dir ./qiaomu
   (cd qiaomu && shasum -a 256 -c SHA256SUMS)
   gh release download --repo finlater/weread.koplugin --pattern 'weread.koplugin-v*.zip*' --dir ./weread
   (cd weread && shasum -a 256 -c weread.koplugin-v*.zip.sha256)
   ```

   如果 `.sha256` 文件只有哈希值没有文件名，就用 `shasum -a 256 weread.koplugin-v*.zip` 手动比对。任何一项校验失败都要停止。
3. **备份**：把设备上已有的 `koreader/plugins/simpleui.koplugin`、`koreader/plugins/weread.koplugin`（如果存在）和 `koreader/settings/simpleui` 复制到电脑上带时间戳的目录。
4. **安装**：解压两个 ZIP，确认得到的文件夹名**严格**是 `simpleui.koplugin` 和 `weread.koplugin`（不能多一层目录，不能带版本号），整体替换到 `koreader/plugins/` 下。
5. **核对**：逐个比对设备上插件目录里的文件与解压结果（数量和 SHA-256 一致）；确认 `koreader/plugins/simpleui.koplugin/_meta.lua` 里的版本号与下载的 Release 一致。
6. **交给用户**：请用户安全弹出设备并重启 KOReader，然后确认三件事：
   - 首页是否显示乔木 SimpleUI 的书架和底栏「资讯」；
   - 「工具 → 微信读书」是否出现；
   - 按上面「微信读书」第 4 步完成扫码登录（用户本人操作），重启后底栏是否出现「微信读书」入口。
7. **出问题时**：读取 `koreader/crash.log` 末尾，按时间找最近的报错；回滚就是把第 3 步的备份原样放回去。不要删除用户的书、笔记或设置。

## 隐私、限制与边界

- **AI 是可选功能，默认关闭**。只有你主动点按钮时，才把选中的文字（或整篇文章 / 当前页，超过约 2 万字按段均匀精简）、书名和问题发给你自己选择的服务。API Key 存在 Kindle 的 `/var/local/qiaomu/ai.json`（仅 root 可读，USB 看不到），请求时不出现在命令行和日志里。
- **手机配置页**只在 Kindle 显示二维码时开启：一次性口令、5 分钟无操作或保存后自动关闭并恢复防火墙。局域网内是普通 HTTP，Key 会以明文经过你的 Wi-Fi，请只在信任的网络使用。
- **乔木精选**读取 `https://rss.qiaomu.ai` 的公开接口，不会生成新的 AI 内容；离线时可以读已缓存的文章。缓存上限 512 MiB，并保留 256 MiB 剩余空间。
- **文章不污染书库**：资讯 EPUB 存在 KOReader 设置目录下的隐藏缓存，关闭时从阅读历史和阅读统计中移除；异常退出后，下次启动自动清理。
- **隐藏书籍不是加密**：只改变首页和书库的显示，其他应用或文件选择器仍能打开原文件。记录按完整路径保存，文件在外部改名或移动后不会自动跟随。
- **微信读书**完全依赖第三方插件及其账号权限，使用前请阅读该插件的免责声明。
- 这是测试版：实机验证集中在一台 Kindle Paperwhite 4（KOReader v2026.07.1），其他 Kindle、Kobo、Android 机型没有逐项验收。

## 实测验证

自动化测试（CI 中运行）：

```bash
python3 -m pip install -r requirements-dev.txt
for t in tests/test_*.py; do python3 "$t"; done
python3 scripts/package.py   # 生成 dist/simpleui.koplugin.zip 与 dist/SHA256SUMS
```

在参考 Kindle 上已确认：首页纵向滑动与书架菜单；资讯自动刷新；文章用 KOReader 阅读器打开约 2 秒、关闭后阅读历史与统计无残留；手机扫码配置 DeepSeek 并测试连接成功，配置文件权限 0600、日志中没有 Key；划线译文卡片完整显示；一次 AI 问答 3 秒返回。待实机确认：查词卡片与生词本、存为批注、AI 笔记文件、追问、频道切换的完整验收。详细记录见 [docs/home-news-progress.md](docs/home-news-progress.md)。

## 恢复原版

退出 KOReader，把备份的原版 `simpleui.koplugin` 和 `settings/simpleui` 放回原处即可；书、批注和阅读记录不需要动。要清除 AI 配置：「工具 → 乔木 AI → 清除 AI 设置」。

## 来源与维护

- 原版：[doctorhetfield-cmd/simpleui.koplugin](https://github.com/doctorhetfield-cmd/simpleui.koplugin)，Doctor Hetfield，GPL-3.0。
- 阅读引擎：[KOReader](https://github.com/koreader/koreader)。
- 微信读书插件：[finlater/weread.koplugin](https://github.com/finlater/weread.koplugin)，AGPL-3.0，独立安装，未被本项目捆绑。
- AI 提示词、查词与频道规则移植自乔木的 Qiaomu Reader 与 Qiaomu AI RSS（Obsidian 插件）。
- 欢迎提交能复现的 issue / PR，请注明 KOReader 版本、设备型号和重启后的表现；不要上传账号、Cookie、API Key 或完整个人配置。

## 关于向阳乔木

[qiaomu.ai](https://qiaomu.ai) · [博客](https://blog.qiaomu.ai) · [乔木推荐](https://tuijian.qiaomu.ai/) · [X @vista8](https://x.com/vista8) · [GitHub @joeseesun](https://github.com/joeseesun/) · 微信公众号「向阳乔木推荐看」

---

<a id="english"></a>
# English

Qiaomu SimpleUI is a customization of **Doctor Hetfield's SimpleUI 3.0.0** for KOReader (GPL-3.0). It is not an official upstream release. Current version: **v3.0.0-qiaomu.16 (pre-release)**.

**What you get**

- A home shelf sorted by newest files, a shelf menu, and reversible hiding of books/documents (files and annotations untouched).
- **Qiaomu picks**: Qiaomu AI RSS's public feed with the same channel structure as the Obsidian plugin (all picks, WeChat, podcasts, newsletters, blogs and news, reader community); each channel remembers its filter and page.
- Articles open in KOReader's real reader as EPUB (fonts, TOC, dictionary, highlights) without touching reading history, statistics or "continue reading". A reading bar offers previous/next article, list, a typography card (four bundled open-source CJK fonts, size, line spacing, margins carried to the next article), AI and save.
- **AI** (optional): AI translate and word lookup on any selection (lookup card with vocabulary-builder export; translations can be saved as notes), an "AI meaning" button in the dictionary popup, and one-tap Q&A actions (explain, key points, example, background, another angle, quiz me, summarize the article) with one-tap follow-ups. Configure DeepSeek or another OpenAI-compatible service by scanning a QR code with your phone; the key stays on the device.
- A shortcut to the separately installed [WeRead plugin](https://github.com/finlater/weread.koplugin).

**Install**: requires KOReader v2026.03+ with CoverBrowser enabled. Back up `koreader/plugins/simpleui.koplugin` and `koreader/settings/simpleui`, download **simpleui.koplugin.zip** from Releases (verify with `SHA256SUMS`), extract it into KOReader's `plugins/` directory (Kindle `koreader/plugins/`, Kobo `.adds/koreader/plugins/`) and restart. For WeRead, install `weread.koplugin` from its own releases into the same folder, restart, then sign in yourself via **Tools → WeRead → WeChat QR login** after enabling "WeRead Skill" (API key) in the WeRead phone app.

**For AI agents** installing on a user's behalf: follow the Chinese section [给 AI Agent 的安装指引](#给-ai-agent-的安装指引). In short: never jailbreak, flash firmware or install KOReader itself; never sign in, read or print account data, cookies, API keys or SSH keys; download only from `joeseesun/qiaomu-simpleui` (releases are pre-releases, so resolve the newest tag with `gh release list` before `gh release download`) and `finlater/weread.koplugin`, and verify SHA-256; back up existing plugin folders and `settings/simpleui`; install folders named exactly `simpleui.koplugin` and `weread.koplugin`; verify file counts/hashes and the version in `_meta.lua`; let the user restart KOReader and complete the WeChat QR login; on failure read the end of `koreader/crash.log` and roll back from the backup.

**Privacy and limits**: AI is off until configured and only sends what you explicitly ask about (selection, article or page, clipped to ~20k characters) plus the title and question to the service you chose. The key is stored at `/var/local/qiaomu/ai.json` (root-only, not visible over USB) and kept out of command lines and logs. The phone setup page runs only while the QR code is shown (one-time token, auto-stops after saving or 5 idle minutes) and uses plain HTTP on your LAN, so use trusted Wi-Fi only. Hiding is not encryption. Device acceptance so far covers one Kindle Paperwhite 4 on KOReader v2026.07.1; see [docs/home-news-progress.md](docs/home-news-progress.md) for what is and is not verified yet.

**Verify / build**: `pip install -r requirements-dev.txt`, run every `tests/test_*.py`, then `python3 scripts/package.py`.

Maintainer: 向阳乔木 · [qiaomu.ai](https://qiaomu.ai) · [X @vista8](https://x.com/vista8) · [GitHub @joeseesun](https://github.com/joeseesun/).
