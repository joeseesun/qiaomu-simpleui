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
- Kindle uses its built-in curl with system CA verification, gzip, bounded response size, timeout and at most two current DNS addresses. HTTP responses are distinguished from transport failures; a partial body is not accepted merely because headers contained HTTP 200. Other platforms retain the native LuaSocket path.
- Packaging now excludes Finder metadata and hidden files. The current plugin payload has 305 files; private installation receipts and screenshots are excluded.

## Device evidence and outstanding work

- Read-only SSH confirmed the installed .3 customizations and existing hidden preferences. A 1072×1448 framebuffer capture confirmed that the bottom navbar obscures the second cover row in the old home layout.
- A native Kindle request returned and decoded a two-entry public API response. Repeated network tests also hit TLS timeouts and a truncated source-catalog response; this is not full acceptance of direct news refresh.
- A temporary network probe was bounded to the API endpoint and had an exit cleanup trap. Confirm its removal in the next successful SSH session.
- The candidate has **not yet been installed**: the first attempt could not use the old CLI endpoint; an existing native-app interface confirmed the pairing, but the subsequent SSH handshake timed out before any SFTP mutation. User wake/connection feedback is pending.
- Frozen plugin/test source: `b74589166032f9e274081256a819b3f8f65cfe97`; [CI succeeded](https://github.com/joeseesun/qiaomu-simpleui/actions/runs/40152133365). [PR #5](https://github.com/joeseesun/qiaomu-simpleui/pull/5) remains a draft.
- The `.4` prerelease draft contains only the installation ZIP and SHA256SUMS. It is not publicly published. Uploaded ZIP digest: `5b894f126d2878738e290770d4826051c425949c6047c394c394c42063373f50` (2,626,433 bytes); the artifact is frozen to the source above.
- Next: reconnect, back up the full installed plugin and SimpleUI settings, verify the known baseline, upload/hash-check the candidate, ask for a KOReader restart, inspect the actual new home/menu/news rendering, and test a complete article/offline reopen. Keep the release draft until the outstanding device checks are resolved.
