# Kindle news reading

Use the existing monochrome KOReader design. This is a polish of the working native reader, not a new visual direction.

- Reference: Qiaomu AI RSS `src/view.ts` / `styles.css`: source/date metadata, two-line article title, unread weight, right-aligned square thumbnail. Adapt the desktop 15/12 type hierarchy to native logical 18/12 points; never scale a font size twice. Apple reference contributes restrained 400/600 weights and a 44-point touch target, not web effects.
- Seven fixed-height rows; source/date in a separate small line, title at most two lines, 64-point thumbnail when available. No fake image placeholder and no repeated read/offline words. Preserve native menu pagination, focus, tap/hold feedback and back navigation.
- Article controls occupy one row: previous, next, bookmark and return icons, with native glyph assets, 44-point touch areas and hold labels. Keep native swipe paging, font controls and position restoration.
- Content wins: text appears first; images download in a cancellable native task attached to the open view. Closing the owner cancels work; no late callback can reopen it or steal position. Cached local images work offline.
- News cache is limited to 512 MiB, with a 256 MiB disk reserve. Evict older image copies/unstarred bodies, pin saved article text, never traverse book directories. Show usage and offer explicit cleanup.
- Validate on the actual 1072×1448 Kindle: list density/long titles, images/no images, toolbar height, bookmark feedback, return position, offline image reopen, cancelled download and WeRead tab restoration.
