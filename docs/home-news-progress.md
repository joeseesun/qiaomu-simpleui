# Home shelf and independent news candidate

Updated 2026-10-25. Base: `f8a91a3`; branch: `codex/home-arrivals-news`.

## Accepted interaction

- Keep Continue Reading and the flat shelf. Default the shelf to newest file date first, retain explicit user sorts, and reset its page when new arrivals change the visible ordering/count.
- Use KOReader's native vertical scroll container when home modules exceed the available screen area. Keep the navbar fixed and horizontal grid pagination working.
- Put a visible `⋯` beside the shelf title for sorting, book favorites, hidden-book restoration and shelf settings. Book favorites also remain in Library settings.
- Replace the default Favorites navbar slot with News once; do not override later manual navigation changes. Keep WeRead and its restart repair.
- News is an independent Qiaomu picks list with source/date/unread/offline labels, saved articles and reading position. Opening an article marks it read; long-press can restore unread. No ReaderUI or book-history writes.

## Implementation and validation

- Six automated Lua behavior suites pass: existing visibility/refresh/WeRead checks plus actual filesystem arrivals, home controls and news persistence/UI callbacks. All 152 Lua files parse; Chinese locale compilation and duplicate checks pass.
- The home-controls regression fails against the previous release at the missing scrollbar-width reservation. It passes with the candidate.
- News uses the same anonymous API paths and compact-list header as the current Obsidian RSS client. Existing published rewrites are preferred; original full content is the fallback. No AI generation is requested.
- Public source-name metadata ships with the plugin (113 enabled sources as of 2026-10-25). Refreshing the large catalog is a separate user action, so catalog failure cannot prevent loading the latest article list.
- The rolling index keeps 200 entries plus older saved articles. Opened bodies are cached separately under the user's settings directory. Article IDs cannot overwrite the index file.
- Kindle uses its built-in curl with system CA verification, gzip, bounded response size, timeout and at most two connection routes. HTTP responses are distinguished from transport failures; a partial body is not accepted merely because headers contained HTTP 200. Other platforms retain the native LuaSocket path.
- Packaging now excludes Finder metadata and hidden files. The current plugin payload has 305 files; private installation receipts and screenshots are excluded.

## Device evidence and outstanding work

- Read-only SSH confirmed the installed .3 customizations and existing hidden preferences. A 1072×1448 framebuffer capture confirmed that the bottom navbar obscures the second cover row in the old home layout.
- Direct device validation on the installed `.4` module fetched all 60 list entries, loaded 113 bundled source names, fetched a complete 4,145-byte original HTML article, wrote it to an isolated test cache and reopened it with persisted offline/read/page flags. This exercised the real Kindle network/cache code without modifying production news settings. Earlier requests encountered TLS timeouts and truncation; one successful run does not establish long-term reliability or article-UI acceptance.
- Reconnected on 2026-10-25 at 13:50 Asia/Shanghai; confirmed the temporary `qiaomu-rss-mtu-probe` rule is absent.
- Installed `.4` on 2026-10-25 at 13:51 Asia/Shanghai using paired Wi-Fi SSH/SFTP. Backed up the full SimpleUI settings tree and existing plugin, checked the installed `.3` source against the known baseline, and verified all 305 uploaded files. Settings bytes are unchanged; the original remote plugin remains available for rollback. The private installation receipt records runtime acceptance as false. User restart/home feedback is pending.
- Frozen plugin/test source: `b74589166032f9e274081256a819b3f8f65cfe97`; [CI succeeded](https://github.com/joeseesun/qiaomu-simpleui/actions/runs/40152133365). [PR #5](https://github.com/joeseesun/qiaomu-simpleui/pull/5) remains a draft.
- The `.4` prerelease draft contains only the installation ZIP and SHA256SUMS. It is not publicly published. Uploaded ZIP digest: `5b894f126d2878738e290770d4826051c425949c6047c394c394c42063373f50` (2,626,433 bytes); the artifact is frozen to the source above.
- Next: after the requested KOReader restart, inspect the actual new home/menu/news rendering and test a complete article/offline reopen. Keep the release draft until the outstanding device checks are resolved.

## `.5` follow-up after restart

- The user restarted KOReader; the device framebuffer showed the new Qiaomu news menu, and the one-time news-tab migration persisted. The actual Update action failed with transport exit 28. A standalone successful smoke test was insufficient to establish reliable UI refresh.
- Verbose device traces reproduced TLS handshake stalls against both current CDN IPv4 answers. Keeping the API URL, SNI, Host and certificate validation unchanged while connecting through the existing DNS-only origin name `vps2.qiaomu.ai` returned all 60 entries twice in 3.20 and 2.49 seconds. No infrastructure or DNS configuration was modified.
- `.5` prioritizes that origin connection using curl `--connect-to` and allows one public-CDN fallback. Deployment IPs are not pinned; native curl bounds DNS/connect/transfer time.
- The reported warning triangle was caused by supplying an absolute SVG path as IconButton's symbolic icon name. The title-row builder now uses SimpleUI's existing `restoreDefaultIcon` helper to load the SVG as a file.
- Both added regressions failed on the previous code and pass after these changes. The six behavior suites, 152 Lua parses and both Chinese locale compilation checks pass.
- `.5` package: 305 files, 2,626,478 bytes; SHA-256 `de7c58df9223fa4132e2fd970cc23b9e535cafcde8412c156b7649b27a8dac57`. Wireless installation completed on 2026-10-25 at 14:00 Asia/Shanghai: all 305 files verified against the package, `.4` backed up, settings bytes unchanged. The installed `.5` module then fetched 60 entries and a 4,044-byte published Markdown rewrite and passed isolated cache/state reload checks. [CI on source 7605947 passed](https://github.com/joeseesun/qiaomu-simpleui/actions/runs/40167540558). Actual post-restart home/article interactions remain pending; the user has been asked to restart once more.

## `.6` native IPC and automatic refresh

- User confirmed the `.5` home can scroll to reveal the second cover row and the shelf `⋯` menu works. The framebuffer also showed the correct dots icon, latest-first shelf/new badges, scrollbar and News tab.
- The `.5` UI refresh still failed, now without a transport error. Native logs contained `cannot serialize function`. KOReader's LuaJSON maps JSON null to a function marker, which native Trapper's LuaJIT object serialization cannot carry.
- The news job now passes a JSON string envelope through Trapper's documented simple-string mode, retaining result/error and cancellation semantics. This was verified on the real Kindle using the actual native Trapper, fork/pipe code and LuaJSON, with only display widgets stubbed and a separate temporary cache: installed `.5` reproduced the IPC failure; the new reader delivered 60 entries and a 4,044-byte Markdown article, then cached it successfully. Production news settings were untouched by this harness.
- Every online entry to News now refreshes after showing cached rows. An offline visit with cached rows keeps reading available without enabling Wi-Fi. Manual Update is a retry action.
- A stricter startup fixture also reproduced WeRead being pruned when News migration called the tab loader before WeRead registration, with the older repair flag already set. Registration now completes for both external actions before the migration reads tabs. Deliberate manual removals remain respected. The device's missing WeRead tab is being clarified with the user.
- Six suites, 152 Lua parses and both Chinese locales pass, including null-marker IPC, online re-entry refresh, offline cache, error propagation and cancellation checks. Package: 305 files, 2,626,809 bytes; SHA-256 `70546e6656f9ca818d95415ffcf14f4b8ac0b5457539dbb3f600722c68bcbb62`. `.6` was installed over paired Wi-Fi SSH/SFTP on 2026-10-25 at 14:07 Asia/Shanghai, all 305 files verified, `.5` backed up, settings bytes unchanged. [CI on source c77a122 passed](https://github.com/joeseesun/qiaomu-simpleui/actions/runs/40167926085). The `.6` release draft is frozen to that source and package. Awaiting the requested restart and actual automatic-refresh/article feedback; do not publish the failed `.4`/`.5` drafts.

## `.7` compact news and bounded image cache

- User accepted `.6` automatic list loading and full-article reading on the Kindle. The existing home scroll and shelf overflow menu also passed user feedback. The requested WeRead restoration is authorized; the earlier startup registration-order fix prevents future accidental pruning but does not re-add a tab previously removed by that bug.
- Actual pre-change framebuffer showed oversized list typography, a two-row text toolbar and missing article images. Compared the actual Qiaomu RSS Obsidian `src/view.ts`, `styles.css`, `src/lazy-thumbnails.ts` and `src/images.ts`: preserve source/date hierarchy, two-line title, unread weight and a right thumbnail. Native MenuItem flattens embedded newlines; `.7` replaces only its content widget, retaining native focus/gestures/page behavior. Logical font size is no longer scaled twice.
- Seven native rows, separately aligned source/date, optional 64-point image; four native article buttons in one 44-point touch row, with hold labels and immediate bookmark feedback. Native page/scroll boundaries, font controls and position restoration remain in use.
- Article HTML retains image URLs and localizes downloaded images into the native HTML resource directory. HTTPS raster downloads have byte/pixel/time budgets, SHA-256 deduplication and atomic writes. Text displays first; owner-bound native tasks run without a blocking overlay, release reserved cache budgets on completion/cancel and suppress late redraw after close. Old original-text caches can restore previously stripped image tags in the background. Only the visible list page downloads thumbnails.
- The user chose 512 MiB. Cache enforcement includes concurrent reservations and a 256 MiB disk reserve, evicting old images before unstarred bodies; saved article text remains pinned. Low disk space can trigger eviction even before the cache reaches its quota. Cleanup scans only managed news names, excludes symlinks and does not traverse book folders. Usage and explicit unstarred cleanup are available in the news menu.
- Last verified device disk measurement: 5,533,032 KiB free (about 5.28 GiB), 15% used, news cache about 64 KiB. This is the previous live measurement, not a guarantee of current space.
- Wireless installation is currently blocked: the previously paired Obsidian session exited; the remaining runtime has pairing metadata but no matching SecretStorage key. No key was exported and no host verification was relaxed. A request to restore the original paired session is pending. `.7` has not replaced the installed `.6`; no new list/image rendering, offline image reopen or missing WeRead-tab restoration is claimed as device-verified.
- Next: restore the paired client, run native image fetch in an isolated cache, back up and install the `.7` package with file hash checks, restore the explicitly requested WeRead tab before settings load, restart KOReader once, then inspect real list/article rendering and offline image reopening.

### `.7` local verification and handoff (2026-10-25 14:33 Asia/Shanghai)

- All seven automated suites passed on the final candidate, including actual filesystem cache/image pipeline, quota/reservations, low-space eviction, saved text retention, safe bounded downloads, local-only HTML, background owner cancellation/late callback suppression and bookmark button-width preservation. All 155 plugin Lua files parse; zh_CN/zh_TW (1,374 strings each) compile with duplicate checks. New cache/image suite is included in CI.
- Installable ZIP contains 309 plugin files and all new modules/icon; payload files were compared byte-for-byte with source. Final package: 2,635,034 bytes; SHA-256 `a33de39ac1f267af24ad39306300a8433a2f1ea9efadc1ee8ea9c8b8acc85eee`. No settings, credentials, news cache, device screenshots or private receipts are included.
- Fresh read-only check of the current rockfish runtime: Qiaomu Reader 4.9.0, paired flag and pinned fingerprint present, referenced SecretStorage key absent. Pairing metadata alone cannot establish an SSH connection. The previously installed `.6` is therefore retained.
- Device-only one-time WeRead repair is prepared locally and tested against isolated settings: insert before Settings, preserve all other values/hidden records, keep a backup, and self-delete after verification. It remains uninstalled; actual native LuaSettings and the restarted device must still be checked. No permanent migration overrides users who deliberately removed the shortcut.
- Keep PR #5 and the `.7` release in draft until native image fetch and actual Kindle render/navigation acceptance are completed. The code and checked package can be reviewed on GitHub while the device connection is unavailable.
