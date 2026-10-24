-- module_currently.lua — Simple UI
-- Currently Reading module: cover beside the title, author, series, description,
-- progress bar and a statistics line.

-- External dependencies
local Device  = require("device")
local Screen  = Device.screen
local _ = require("infra/sui_i18n").translate
local logger  = require("logger")

local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Size            = require("ui/size")

-- Internal dependencies
local Config       = require("infra/sui_config")
local SectionLabel = require("engines/sui_section_label")
local UI           = require("infra/sui_core")
local SUISettings  = require("infra/sui_store")
local SUIStyle     = require("features/sui_style")
local BookStats    = require("infra/sui_book_stats")
local Text         = require("infra/sui_text")
local Chrome       = require("features/sui_module_chrome")
local PAD          = UI.PAD
local LABEL_H      = UI.LABEL_H

-- Lazy-loaded shared book helpers (cover, progress bar, book data).
local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("simpleui: module_currently: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

-- Colours

-- Vertical gaps between elements (base values at 100% scale; scaled in build()).
local _BASE_COVER_GAP  = Screen:scaleBySize(16)  -- between cover and text column
local _BASE_TITLE_GAP  = Screen:scaleBySize(4)   -- before title
local _BASE_AUTHOR_GAP = Screen:scaleBySize(6)   -- before author
local _BASE_SERIES_GAP = Screen:scaleBySize(4)   -- before series (smaller — visually grouped with author)
local _BASE_DESC_GAP   = Screen:scaleBySize(6)   -- before description
-- Vertical gaps around the progress bar.
-- The bar (LineWidget) has no internal padding — it starts and ends at exact pixels.
-- TextWidget includes ascender/descender space inside its reported height, which
-- the eye reads as part of the gap. To look balanced:
--   before the bar: slightly smaller because the author text's descender space
--                   adds ~2px of visual gap "for free" from inside the widget.
--   after the bar:  larger to compensate for the ascender space of the next text
--                   being consumed from the gap, making it look narrower.
local _BASE_BAR_GAP_BEFORE = Screen:scaleBySize(6)   -- gap above the progress bar
local _BASE_BAR_GAP_AFTER  = Screen:scaleBySize(10)  -- gap below the progress bar
local _BASE_PCT_GAP    = Screen:scaleBySize(3)   -- before percent / stats rows

-- Progress bar dimensions
local _BASE_BAR_H       = SUIStyle.PROGRESS_BAR_H
local _BASE_BAR_PCT_GAP = Screen:scaleBySize(6)   -- horizontal gap between bar and inline pct label
local _BASE_STATS_SEP_W = Screen:scaleBySize(8)   -- horizontal gap between inline stats items
local _BASE_PCT_W       = Screen:scaleBySize(32)  -- width reserved for inline pct label (e.g. "100%")

-- Font sizes — derived from the central SUIStyle typographic scale.
-- Modules that have their own user-controlled scale multiply it on top.
local _BASE_TITLE_FS     = SUIStyle.FS_TITLE     -- 22: title text
local _BASE_AUTHOR_FS    = SUIStyle.FS_SUBTITLE   -- 20: author text
local _BASE_STATS_FS     = SUIStyle.FS_DETAIL     -- 15: stats text
local _BASE_INLINEPCT_FS = SUIStyle.FS_DETAIL     -- 15: pct label inside the bar
local _BASE_DESC_FS      = SUIStyle.FS_DETAIL     -- 15: description text
local _BASE_SERIES_FS    = SUIStyle.FS_CAPTION    -- 12: series text (smaller than author)

-- Description is clamped to a fixed number of lines rather than a dynamic
-- "remaining space" layout, because every other element in this module
-- reserves a fixed height; keeping description fixed-height too lets height
-- calculations stay a simple sum. The card itself grows to fit its
-- elements, so a taller fixed value costs no layout risk — just card height.
local DESC_MAX_LINES = 8

-- Layout plans: the cover size, text width and description clamp resolved by
-- the measuring passes of M.build(). A plan is reused while every input of
-- those passes is unchanged, so repeat builds (page turns, refreshes, progress
-- updates) render the text column once. Weak-keyed by the settings bundle:
-- replacing the bundle drops its plans. Keys carry the book texts, so the
-- per-bundle count is capped.
local _layout_plans     = setmetatable({}, { __mode = "k" })
local MAX_PLANS_PER_CFG = 8

-- Key of a layout plan: the geometry inputs in `parts` plus the book texts
-- whose wrapping sets the text column's height (title, description). The
-- progress and statistics values never change it.
local function _layoutPlanKey(parts, book_data)
    parts[#parts + 1] = tostring(book_data.title)
    parts[#parts + 1] = tostring(book_data.description)
    return table.concat(parts, "\31")
end

local function _findLayoutPlan(cfg, key)
    local entry = _layout_plans[cfg]
    return entry and entry.plans[key]
end

local function _storeLayoutPlan(cfg, key, plan)
    local entry = _layout_plans[cfg]
    if not entry or entry.count >= MAX_PLANS_PER_CFG then
        entry = { count = 0, plans = {} }
        _layout_plans[cfg] = entry
    end
    entry.plans[key] = plan
    entry.count = entry.count + 1
end

-- Description text alignment. "justify" stretches word spacing to fill each
-- line and keeps the last line of every paragraph left-aligned.
local DESC_ALIGN_KEY     = "currently_description_align"
local DESC_ALIGN_VALUES  = { "left", "right", "justify" }
local DESC_ALIGN_DEFAULT = "justify"

local function resolveDescAlign(stored)
    return Config.resolveChoice(stored, DESC_ALIGN_VALUES, DESC_ALIGN_DEFAULT)
end

-- Setting key for progress bar style: "with_pct" (default) or "simple"
local BAR_STYLE_KEY    = "currently_bar_style"
local BAR_STYLE_VALUES = { "simple", "with_pct" }

local function getBarStyle(pfx)
    return Config.readChoice(pfx .. BAR_STYLE_KEY, BAR_STYLE_VALUES, "with_pct")
end

-- Progress badge (pentagon overlay on the cover) — same drawing primitive
-- and settings shape as the Coverdeck / book-grid progress badge.
-- Opt-in (unset == off). Color override nil means "Follow Style".
local SETTING_SHOW_PROGRESS_BADGE  = "currently_show_progress_badge"
local SETTING_PROGRESS_BADGE_COLOR = "currently_progress_badge_color"

local function showProgressBadge(pfx)
    return SUISettings:readSetting(pfx .. SETTING_SHOW_PROGRESS_BADGE) == true
end

local function getProgressBadgeColorOverride(pfx)
    return SUIStyle.badgeChoice(SUISettings:readSetting(pfx .. SETTING_PROGRESS_BADGE_COLOR))
end

local function setProgressBadgeColor(pfx, v)
    SUISettings:saveSetting(pfx .. SETTING_PROGRESS_BADGE_COLOR, v)
end

-- Draws the progress pentagon over a cover through the shared helper, using
-- the module's own color and size settings.
local function applyProgressBadge(cover, bd, cw, ch, pfx)
    local SH = getSH()
    if not SH or not SH.applyProgressBadge then return cover end
    return SH.applyProgressBadge(cover, bd, cw, ch, {
        color     = getProgressBadgeColorOverride(pfx),
        scale_pct = Config.getBadgeScalePct("currently", pfx),
    })
end

local COVER_GAP_KEY = "currently_cover_gap"

local function getCoverGapPct(pfx)
    local v = SUISettings:readSetting(pfx .. COVER_GAP_KEY)
    local n = tonumber(v)
    return n and math.max(0, math.min(300, math.floor(n))) or 100
end

-- Setting key for the module's overall layout mode. Both modes share the
-- exact same single-column architecture (one centered VerticalGroup, built
-- by buildMetaColumn — see below); they only differ in how the cover is
-- sized:
--   "default" — cover sized as a percentage of the module's own width
--               (see _COVER_W_PCT); if the text column would end up
--               shorter than the cover, non-elastic content keeps its
--               natural size and the description (the only elastic
--               element) shrinks or is omitted to fit
--   "dynamic" — same as "default", but the cover additionally grows or
--               shrinks to match the text column's height
-- Any other stored value (including legacy/removed modes) falls back to
-- "default", which is also the default for a module never configured.
local LAYOUT_KEY = "currently_layout"

local function getLayout(pfx)
    return SUISettings:readSetting(pfx .. LAYOUT_KEY) == "dynamic" and "dynamic" or "default"
end

-- Builds a progress bar with an inline percentage label: [▓▓▓░░░░] XX%
-- Spacing below the bar is handled by gap_before() on the next element,
-- consistent with how every other element in the layout works.
local function buildProgressBarWithPct(w, pct, bar_h, scale, text_scale, face_inline, bold_inline, ink)
    local PCT_W   = math.max(16, math.floor(_BASE_PCT_W       * scale * text_scale))
    local GAP     = math.max(2,  math.floor(_BASE_BAR_PCT_GAP * scale))
    local bar_w   = math.max(10, w - GAP - PCT_W)
    local pct_str = string.format("%.0f%%", (pct or 0) * 100)
    -- face_inline and bold_inline are pre-resolved by build(); fallback for
    -- direct calls is the default font in bold.
    local _face, _bold = face_inline, bold_inline
    if not _face then
        _face, _bold = SUIStyle.getStyledFace(nil, math.max(7, math.floor(_BASE_INLINEPCT_FS * scale * text_scale)), "bold")
    end
    local bar = UI.progressBar(bar_w, pct, bar_h, ink.bar_fg, ink.bar_bg)

    return HorizontalGroup:new{
        align = "center",
        bar,
        HorizontalSpan:new{ width = GAP },
        UI.makeColoredText{
            text    = pct_str,
            face    = _face,
            bold    = _bold,
            fgcolor = ink.blk,
            width   = PCT_W,
        },
    }
end


local fetchBookStats = BookStats.fetch

-- Puts `bar` in the single-child `container`, freeing the bar it replaces.
local function _swapBar(container, bar)
    local old = container[1]
    container[1] = bar
    if old and old.free then old:free() end
end


-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------
-- The text column is a list of items the user can hide and reorder; the
-- "stats" item is one line made of the visible statistics, in their own order.
-- Both orders go through Config.makeOrderedItems in the settings menu.

local ITEM_IDS  = { "title", "author", "series", "description", "progress", "stats" }
local STAT_IDS  = { "percent", "book_days", "book_time", "book_remaining" }
local MAIN_ORDER_KEY  = "currently_main_order"   -- pfx .. this
local STATS_ORDER_KEY = "currently_stats_order"  -- pfx .. this
local STATS_STYLE_KEY = "currently_stats_style"  -- pfx .. this; "compact" | "default"
local STATS_ICON_KEY  = "currently_stats_icon"   -- pfx .. this; clock icon before the compact line

-- Clock glyph of the symbols font, drawn before the compact stats line.
local STATS_ICON_GLYPH = "\u{E84F}"

-- The icon is on until the user turns it off (shipped default: sui_config.lua).
local function getStatsIcon(pfx)
    return SUISettings:nilOrTrue(pfx .. STATS_ICON_KEY)
end

-- "compact" joins the statistics into one line; "default" gives each its own.
local function getStatsStyle(pfx)
    return SUISettings:readSetting(pfx .. STATS_STYLE_KEY) == "default" and "default" or "compact"
end

local function itemLabel(id)
    if id == "title"       then return _("Title") end
    if id == "author"      then return _("Author") end
    if id == "series"      then return _("Series") end
    if id == "description" then return _("Description") end
    if id == "progress"    then return _("Progress bar") end
    return _("Statistics")
end

-- Visibility of an item or statistic. The shipped default of every key is
-- written by sui_config.lua's applyFirstRunDefaults().
local function _showElem(pfx, key)
    return SUISettings:nilOrTrue(pfx .. "currently_show_" .. key)
end

local function _setElemVisible(pfx, key, visible)
    SUISettings:saveSetting(pfx .. "currently_show_" .. key, visible)
end

-- Visibility of every item and statistic.
local function _readShow(pfx)
    local show = {}
    for _i, ids in ipairs({ ITEM_IDS, STAT_IDS }) do
        for _j, id in ipairs(ids) do show[id] = _showElem(pfx, id) end
    end
    return show
end

-- The percentage is already part of the progress bar when it shows it inline.
local function _statAvailable(id, bar_style)
    return id ~= "percent" or bar_style ~= "with_pct"
end

-- Number of statistics the stats item shows.
local function _visibleStatCount(show, bar_style)
    local n = 0
    if show.stats then
        for _i, id in ipairs(STAT_IDS) do
            if show[id] and _statAvailable(id, bar_style) then n = n + 1 end
        end
    end
    return n
end

-- Saved orders (raw values, from the settings bundle or a direct read) merged
-- with the defaults.
local function _getItemOrder(saved)
    return Config.mergeOrder(saved, ITEM_IDS)
end

local function _getStatsOrder(saved)
    return Config.mergeOrder(saved, STAT_IDS)
end

-- Module API
local M = {}

M.id          = "currently"
M.name        = _("Currently Reading")
M.label       = _("Currently Reading")
M.enabled_key = "currently_enabled"
M.default_on  = true

-- Text elements with a user-selectable font family, size and variant.
M.text_elems = { "title", "author", "series", "description", "stats" }

-- The title is bold until the user picks another variant. The percentage
-- shown with the progress bar is always emphasised on top of the "stats"
-- variant.
Config.declareTextVariants(M.id, { title = "bold" })

M.has_covers  = true   -- activates e-ink dithering and cover poll
M.fills_row_height = true  -- rebuilt with ctx.grow_h when its row is taller (see moduleregistry)
M.is_book_mod = true   -- suppresses empty-state when active


-- ---------------------------------------------------------------------------
-- _scaledLayoutDims — single source of truth for the gap/font-size formulas
-- shared by build() and getHeight(). Both functions need the exact same
-- scaled values (build() to lay out the real widgets, getHeight() to
-- estimate the reserved height before those widgets exist), so computing
-- them in one place means a future change to a base constant or a
-- clamp/floor value can't silently drift between the two call sites.
-- `styles` holds the user's per-element text style (see Config.readTextStyles);
-- Per-element text style scale multiplies the element's font size on top of
-- the module layout scale.
-- ---------------------------------------------------------------------------
local function _scaledLayoutDims(scale, styles)
    local function fs(base, min_fs, style)
        return math.max(min_fs, math.floor(base * scale * (style and style.scale or 1)))
    end
    return {
        title_fs  = fs(_BASE_TITLE_FS,  8, styles.title),
        author_fs = fs(_BASE_AUTHOR_FS, 8, styles.author),
        series_fs = fs(_BASE_SERIES_FS, 7, styles.series),
        desc_fs   = fs(_BASE_DESC_FS,   8, styles.description),
        stats_fs  = fs(_BASE_STATS_FS,  7, styles.stats),

        bar_h          = math.max(1, math.floor(_BASE_BAR_H          * scale)),
        title_gap      = math.max(1, math.floor(_BASE_TITLE_GAP      * scale)),
        author_gap     = math.max(1, math.floor(_BASE_AUTHOR_GAP     * scale)),
        series_gap     = math.max(1, math.floor(_BASE_SERIES_GAP     * scale)),
        desc_gap       = math.max(1, math.floor(_BASE_DESC_GAP       * scale)),
        bar_gap_before = math.max(1, math.floor(_BASE_BAR_GAP_BEFORE * scale)),
        bar_gap_after  = math.max(1, math.floor(_BASE_BAR_GAP_AFTER  * scale)),
        pct_gap        = math.max(1, math.floor(_BASE_PCT_GAP        * scale)),
    }
end

-- _resolveFaces — the font face of every text element, shared by build() and
-- getHeight() for the same reason as _scaledLayoutDims. Each face follows the
-- element's chosen family and variant. Returns the faces and, under the same
-- keys, whether the text widget must still embolden the face.
local function _resolveFaces(LD, styles)
    local faces, embolden = {}, {}
    local function resolve(key, elem, size)
        faces[key], embolden[key] = SUIStyle.getTextFace(styles[elem], size)
    end
    resolve("title",  "title",       LD.title_fs)
    resolve("author", "author",      LD.author_fs)
    resolve("series", "series",      LD.series_fs)
    resolve("desc",   "description", LD.desc_fs)
    resolve("stats",  "stats",       LD.stats_fs)
    return faces, embolden
end

-- Cover width as a fraction of the module's own content width — the single
-- source of truth for base cover sizing, used by every layout in both
-- build() and getHeight(). Keeps the cover proportionate to whatever
-- column width this module ends up in (grid vs single column, portrait
-- vs landscape) instead of a device-pixel constant that ignores it.
local _COVER_W_PCT = 0.30
-- Widest the cover grows when the module is stretched to the height of its
-- row, as a fraction of the module width.
local _COVER_GROW_MAX_W_PCT = 0.42

-- _computeCoverDims(w, thumb_scale, ratio) — base cover pixel size for a
-- module of width `w`. `thumb_scale` is the user's "Cover size" multiplier;
-- callers must pass the RAW value (without landscape_factor folded in),
-- since `w` itself is already the module's landscape-reduced column width
-- whenever lf < 1 — applying lf a second time here would compound it.
-- `ratio` is the cover's height/width aspect ratio, taken from SH.getDims
-- so it stays in sync with the rest of SUI's cover artwork without
-- hard-coding a second aspect constant here.
local function _computeCoverDims(w, thumb_scale, ratio)
    local cover_w = math.max(1, math.floor(w * _COVER_W_PCT * thumb_scale))
    local cover_h = math.max(1, math.floor(cover_w * ratio))
    return cover_w, cover_h
end

-- Clears the entire stats cache. Called from main.lua:onCloseDocument as a
-- fallback when the closed book's md5 could not be resolved; safe since
-- fetchBookStats() re-populates entries on demand.
function M.invalidateCache()
    BookStats.invalidate()
end

-- Removes only the cache entry for the given md5, leaving stats cached for
-- every other book intact. Mirrors module_coverdeck.invalidateCacheForMd5;
-- called from main.lua:onCloseDocument so the closed book's stats are fresh
-- on the next render without discarding the rest of the cache.
function M.invalidateCacheForMd5(md5)
    if md5 then BookStats.invalidate(md5) end
end

-- True when the visible statistics need the stats database. The percentage
-- comes from the book's own data and never does.
function M.needsDbStats(show)
    return show.stats and (show.book_days or show.book_time or show.book_remaining) or false
end

-- Exposed for pre-computation in _buildCtx (sui_homescreen.lua).
-- Mirrors module_coverdeck.fetchBookStatsForCtx.
-- Returns the stats table or nil; does NOT set ctx.db_conn_fatal (no ctx here).
function M.fetchBookStatsForCtx(md5, db_conn, force)
    return fetchBookStats(md5, db_conn, nil, force)
end


-- Empty placeholder when history has no existing books (same pattern as
-- Quick Actions / Featured Collection / Collections).
-- Uses a wrapping text box rather than the single-line TextWidget behind
-- makeColoredText, since this message is long enough to need multiple lines
-- at the module's own width.
local function _emptyPlaceholder(w, h, text_alpha, ink)
    local face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
    local line_h = math.floor(1.3 * face.size + 0.5)
    local args = {
        text      = _("No books to show yet — open a book to see it here."),
        face      = face,
        width     = w - PAD * 2,
        height    = math.max(line_h, h - PAD * 2),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
        fgcolor   = (ink or Chrome.PLAIN_INK).sub,
    }

    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        UI.makeTextBox(args, text_alpha),
    }
end

-- Builds the module widget: cover on the left, text column on the right.
-- Elements in the text column are rendered in user-configured order.
function M.build(w, ctx)
    -- Drops the stop of a previous build; the book's own is registered below.
    if ctx.kbStops then ctx.kbStops(M.id, {}) end
    if not ctx.current_fp then
        return _emptyPlaceholder(w, M.getHeight(ctx), ctx.text_alpha, ctx.ink)
    end

    local SH = getSH()
    if not SH then
        return _emptyPlaceholder(w, M.getHeight(ctx), ctx.text_alpha, ctx.ink)
    end

    -- Use pre-read settings bundle from ctx when available (normal HS path).
    -- Falls back to direct reads only when called outside the homescreen.
    -- c.scale/c.thumb_scale (from ctx.cfg) are RAW; apply
    -- ctx.landscape_factor here, on both the cached and fallback path.
    -- thumb_scale is the exception: `w` below is already the module's
    -- landscape-reduced column width (col_w, set by the screen engine), so
    -- the cover-size percentage-of-w calculation must use the RAW value —
    -- multiplying by lf again would apply the landscape reduction twice.
    local c = ctx.cfg and ctx.cfg.currently
    local pfx         = ctx.pfx
    local lf          = ctx.landscape_factor or 1
    local raw_scale   = c and c.scale       or Config.getModuleScale("currently", pfx)
    local scale       = raw_scale * lf
    local raw_thumb_scale = c and c.thumb_scale or Config.getThumbScale("currently", pfx)
    local bar_style   = c and c.bar_style   or getBarStyle(pfx)
    local layout = (c and c.layout) or getLayout(pfx)
    local stats_style = c and c.stats_style or getStatsStyle(pfx)
    local stats_icon  = getStatsIcon(pfx)
    if c and c.stats_icon ~= nil then stats_icon = c.stats_icon end
    local show        = c and c.show or _readShow(pfx)
    local item_order  = _getItemOrder(c and c.main_order or SUISettings:readSetting(pfx .. MAIN_ORDER_KEY))
    local stats_order = _getStatsOrder(c and c.stats_order or SUISettings:readSetting(pfx .. STATS_ORDER_KEY))
    local desc_align  = resolveDescAlign(c and c.desc_align or SUISettings:readSetting(pfx .. DESC_ALIGN_KEY))

    -- Base cover size, as a percentage of the module's own width `w` — see
    -- _computeCoverDims. Used as-is by "default"; "dynamic" grows/shrinks
    -- it further below to match the text column's height.
    -- `ratio` (H/W) is taken from the shared book-cover helpers so this
    -- module's covers keep the same proportions as module_recent/book grid.
    local _cover_ratio = SH.getDims(1.0, 1.0).COVER_H / SH.getDims(1.0, 1.0).COVER_W
    local D = {}
    D.COVER_W, D.COVER_H = _computeCoverDims(w, raw_thumb_scale * raw_scale, _cover_ratio)

    -- Scale gaps and font sizes (layout scale × text scale where applicable).
    -- See _scaledLayoutDims for the shared formulas (also used by getHeight()).
    local styles = Config.resolveTextStyles(ctx, M.id, M.text_elems)
    local LD = _scaledLayoutDims(scale, styles)
    local title_gap, author_gap, series_gap, desc_gap =
        LD.title_gap, LD.author_gap, LD.series_gap, LD.desc_gap
    local bar_gap_before, bar_gap_after, pct_gap, bar_h =
        LD.bar_gap_before, LD.bar_gap_after, LD.pct_gap, LD.bar_h

    -- cover_gap has no getHeight() counterpart (getHeight doesn't need the
    -- cover/text spacing), so it stays computed directly here.
    local cover_gap = math.max(0, math.floor(_BASE_COVER_GAP * scale * (getCoverGapPct(pfx) / 100)))

    -- Resolve font faces once so they are not re-created per element.
    local FC, FB = _resolveFaces(LD, styles)
    local face_title, face_author, face_series, face_desc, face_s =
        FC.title, FC.author, FC.series, FC.desc, FC.stats

    -- Use prefetched book data. After onCloseDocument, _cached_books_state is
    -- cleared and prefetchBooks() re-reads the sidecar, so this is always fresh.
    -- NOTE: the actual cover image widget (SH.getBookCover) is fetched further
    -- below, once cover_w/cover_h are resolved to their final (possibly
    -- dynamically-grown) size — fetching it here at D.COVER_W/H would waste a
    -- render at the wrong size whenever dynamic cover sizing changes it.
    local prefetched_entry = ctx.prefetched and ctx.prefetched[ctx.current_fp]
    local bd    = SH.getBookData(ctx.current_fp, prefetched_entry)

    -- Series text — SH.getBookSeries is the single shared source (also used
    -- by the book-grid corner badge), memoized per filepath. Only fetched
    -- when the element is visible, to avoid the BookInfoManager lookup on
    -- every render for users who don't use this element.
    local series_text = ""
    if show.series then
        local sd = SH.getBookSeries(ctx.current_fp)
        if sd and sd.series then
            local idx = tonumber(sd.series_index)
            if idx then
                -- Whole numbers print as "#1"; fractional as "#1.5" (split/
                -- omnibus volumes).
                local idx_text = (idx == math.floor(idx))
                    and tostring(math.floor(idx)) or string.format("%.10g", idx)
                series_text = sd.series .. " #" .. idx_text
            else
                series_text = sd.series
            end
        end
    end

    -- Text column width: full width minus the box's insets (padding plus
    -- any active border), cover, and cover gap. This is the BASE width,
    -- computed from the base cover size (D.COVER_W). When dynamic cover
    -- sizing is enabled, the final width used for the text column may
    -- differ — see the two-pass layout below.
    local tw0 = w - D.COVER_W - cover_gap

    -- Fetch stats once if any statistic that comes from the stats database is active.
    local bstats
    if M.needsDbStats(show) then
        local book_md5 = prefetched_entry and prefetched_entry.partial_md5_checksum
        if not book_md5 then
            logger.dbg("simpleui: module_currently: no md5 for "
                       .. tostring(ctx.current_fp)
                       .. " — stats will not be fetched this render")
        end
        -- Fast path: use stats pre-computed by _buildCtx() (zero extra DB query).
        -- Falls back to a live query when _buildCtx didn't pre-compute them
        -- (e.g. direct call outside the homescreen, or ctx.currently_book_stats absent).
        local pre = ctx.currently_book_stats
        if pre and pre.fp == ctx.current_fp then
            bstats = pre.stats
        else
            bstats = fetchBookStats(book_md5, ctx.db_conn, ctx)
        end
    end

    -- Content colours over the module fill; `dim` is the placeholder stats text.
    local ink              = ctx.ink or Chrome.PLAIN_INK
    local _CLR_DARK_EFF    = ink.blk
    local CLR_TEXT_SUB_EFF = ink.sub
    local CLR_PH_EFF       = ink.sub

    -- Inline pct on the progress bar uses the same Progress Text style as
    -- standalone percent / stats lines.
    local face_inlinepct, bold_inlinepct = SUIStyle.getTextFace(
        styles.stats,
        math.max(7, math.floor(_BASE_INLINEPCT_FS * scale * (styles.stats.scale or 1))),
        true)

    -- Builds the text column (title/author/series/description/progress bar/
    -- stats) at the given width `tw`. Every element inside is either
    -- line-clamped (title, description — fixed height regardless of width)
    -- or single-line/truncated (author, series, stats, progress bar — width
    -- only affects wrapping/truncation, never height). This means the
    -- resulting VerticalGroup's height is independent of `tw`, which is what
    -- makes the two-pass dynamic-cover layout below safe: calling this twice
    -- with different widths always yields the same height, so there is no
    -- risk of an oscillating/convergence loop — at most one extra pass.
    --
    -- `opts` (optional) lets the caller shrink or hide the description —
    -- the only element treated as elastic — to keep the text column from
    -- growing past the cover in the "default" layout (see the anchoring
    -- logic below, right after the first buildMetaColumn call):
    --   opts.desc_max_lines     — overrides DESC_MAX_LINES (0 hides it)
    --   opts.suppress_description — omit the description entirely, used to
    --                                measure every OTHER element's height
    --                                (i.e. the fixed budget the description
    --                                must fit whatever is left over from)
    local function buildMetaColumn(tw, opts)
        local desc_max_lines    = (opts and opts.desc_max_lines) or DESC_MAX_LINES
        local suppress_desc     = opts and opts.suppress_description
        local meta = VerticalGroup:new{ align = "left" }
        -- Refresh closures fn(stats, data) run by updateStats; `stats` is nil
        -- when the book has no recorded reading history.
        local _cr_update_funcs  = {}
        local function _updateColoredText(wgt, txt, fg)
            if wgt._inner and wgt._inner.setText then
                wgt._inner:setText(txt)
                wgt._fg = fg
                wgt.dimen = wgt._inner:getSize()
            elseif wgt.setText then
                wgt:setText(txt)
                wgt.fgcolor = fg
            end
        end

        -- Adds a vertical gap before the next element, but not before the first one.
        -- _next_gap overrides the default size for exactly one call (used after the
        -- progress bar, where bar_gap_after compensates for font metric asymmetry).
        local meta_has_content = false
        local _next_gap        = nil
        local function gap_before(size)
            if meta_has_content then
                meta[#meta+1] = VerticalSpan:new{ width = _next_gap or size }
            end
            _next_gap = nil
        end

        -- Append each visible element to meta in user-configured order.
        for _i, elem in ipairs(item_order) do
        if elem == "title" and show.title then
            gap_before(title_gap)

            local tbw_line_h = math.floor(1.3 * face_title.size + 0.5)
            local title_args = {
                text      = bd.title or "?",
                face      = face_title,
                bold      = FB.title,
                width     = tw,
                height    = tbw_line_h * 2,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
                max_lines = 2,
                fgcolor   = _CLR_DARK_EFF,
            }

            meta[#meta+1] = UI.makeTextBox(title_args, ctx.text_alpha)
            meta_has_content = true

        elseif elem == "author" and show.author then
            local author_text = Text.formatAuthors(bd.authors)
            if author_text then
                gap_before(author_gap)
                meta[#meta+1] = UI.makeColoredText{
                    text            = author_text,
                    face            = face_author,
                    bold            = FB.author,
                    fgcolor         = CLR_TEXT_SUB_EFF,
                    width           = tw,
                    max_width       = tw,
                    truncation_char = "…",
                }
                meta_has_content = true
            end

        elseif elem == "series" and show.series and series_text ~= "" then
            gap_before(series_gap)
            meta[#meta+1] = UI.makeColoredText{
                text            = series_text,
                face            = face_series,
                bold            = FB.series,
                fgcolor         = CLR_TEXT_SUB_EFF,
                width           = tw,
                max_width       = tw,
                truncation_char = "…",  -- ellipsis
            }
            meta_has_content = true

        elseif elem == "description" and show.description and bd.description and bd.description ~= ""
               and not suppress_desc and desc_max_lines > 0 then
            gap_before(desc_gap)
            -- TextBoxWidget has no "max_lines" property — it only clamps
            -- via an explicit pixel `height` (see title element above for
            -- the same pattern). height_overflow_show_ellipsis only takes
            -- effect when `height` is set; leaving height nil would make
            -- the widget grow to fit the full text instead of clamping.
            local desc_tbw_line_h = math.floor(1.3 * face_desc.size + 0.5)
            local desc_args = {
                text      = bd.description,
                face      = face_desc,
                bold      = FB.desc,
                width     = tw,
                alignment = desc_align == "right" and "right" or "left",
                justified = desc_align == "justify",
                height    = desc_tbw_line_h * desc_max_lines,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
                fgcolor   = CLR_TEXT_SUB_EFF,
            }

            meta[#meta+1] = UI.makeTextBox(desc_args, ctx.text_alpha)
            meta_has_content = true

        elseif elem == "progress" and show.progress then
            gap_before(bar_gap_before)
            -- The bar is wrapped in a container whose single child is
            -- replaced by _update_bar, so a stats refresh only patches the
            -- bar's pixels without touching the surrounding layout or
            -- allocating new VerticalGroup nodes.
            local function makeBar(pct)
                if bar_style == "with_pct" then
                    return buildProgressBarWithPct(
                        tw, pct, bar_h, scale, styles.stats.scale or 1, face_inlinepct, bold_inlinepct, ink)
                end
                return UI.progressBar(tw, pct, bar_h, ink.bar_fg, ink.bar_bg)
            end
            local init_bar = makeBar(bd.percent)
            local bar_container = OverlapGroup:new{
                dimen = init_bar:getSize(),
                init_bar,
            }
            table.insert(_cr_update_funcs, function(_nb, nd)
                _swapBar(bar_container, makeBar(nd and nd.percent or 0))
            end)
            meta[#meta+1] = bar_container
            meta_has_content = true
            _next_gap = bar_gap_after  -- next element uses the larger post-bar gap

        elseif elem == "stats" and _visibleStatCount(show, bar_style) > 0 then
            -- Each row is capped to `tw` and truncated with an ellipsis. Rows
            -- are shown even without data so their height stays reserved.
            local function isShown(id) return show[id] and _statAvailable(id, bar_style) end
            local rows = { stats_order }
            if stats_style == "default" then
                rows = {}
                for _j, id in ipairs(stats_order) do
                    if isShown(id) then rows[#rows+1] = { id } end
                end
            end
            for _j, row_ids in ipairs(rows) do
                local function rowContent(nb, nd)
                    local line = BookStats.line(row_ids, isShown,
                        function(id) return BookStats.textFor(id, nb, nd) end)
                    if line == "" then return "—", CLR_PH_EFF end
                    return line, CLR_TEXT_SUB_EFF
                end
                local text0, fg0 = rowContent(bstats, bd)

                -- A clock before the single compact line (not before the
                -- one-statistic-per-row layout). It is centred on the text
                -- line's own height, so it never makes the row taller than
                -- the height getHeight() reserves for it.
                local icon_w, icon_gap, icon_widget = 0, 0, nil
                if stats_icon and stats_style == "compact" then
                    local icon_face = SUIStyle.pxFace(SUIStyle.FACE_ICONS, face_s.size * 1.1)
                    icon_widget = UI.makeColoredText{
                        text = STATS_ICON_GLYPH, face = icon_face, fgcolor = fg0, padding = 0,
                    }
                    icon_w   = icon_widget:getSize().w
                    icon_gap = math.floor(face_s.size * 0.5)
                    -- Symbol glyphs sit off-centre in their line box: nudge the
                    -- drawn clock to the middle of the line.
                    local nudge = SUIStyle.inkCentreShift(icon_face, STATS_ICON_GLYPH, false)
                    if nudge ~= 0 then
                        icon_widget = FrameContainer:new{
                            bordersize = 0, padding = 0,
                            padding_top    = math.max(0,  nudge),
                            padding_bottom = math.max(0, -nudge),
                            icon_widget,
                        }
                        icon_widget._clock = icon_widget[1]
                    end
                end

                local row_text = UI.makeColoredText{
                    text                   = text0,
                    face                   = face_s,
                    bold                   = FB.stats,
                    fgcolor                = fg0,
                    max_width              = math.max(1, tw - icon_w - icon_gap),
                    truncate_with_ellipsis = true,
                }
                local row_w = row_text
                if icon_widget then
                    local line_h = row_text:getSize().h
                    row_w = HorizontalGroup:new{
                        align = "center",
                        CenterContainer:new{
                            dimen = Geom:new{ w = icon_w, h = line_h },
                            icon_widget,
                        },
                        HorizontalSpan:new{ width = icon_gap },
                        row_text,
                    }
                end
                table.insert(_cr_update_funcs, function(nb, nd)
                    local text, fg = rowContent(nb, nd)
                    _updateColoredText(row_text, text, fg)
                    -- The icon follows the text colour (dimmed placeholder).
                    if icon_widget then
                        UI.updateColoredText(icon_widget._clock or icon_widget, STATS_ICON_GLYPH, fg)
                    end
                end)
                gap_before(pct_gap)
                meta[#meta+1] = row_w
                meta_has_content = true
            end
        end
        end -- for _i, elem in ipairs(item_order)

        return meta, _cr_update_funcs
    end


    -- Both layouts share the exact same single-column build path (see
    -- buildMetaColumn above); the only difference is whether the cover
    -- additionally grows to match the text column, below.
    local dynamic_cover = (layout == "dynamic")

    -- Resolves the final cover size and text column. Pass 1 builds at the base
    -- width to measure the text column's natural height. Measuring by asking
    -- the VerticalGroup itself (rather than summing known element heights) is
    -- the only reliable way, since TextWidget line heights depend on font
    -- metrics, not just the font size number.
    -- Returns the plan (see _layout_plans) followed by the built column.
    local function resolveLayout()
        local cover_w, cover_h = D.COVER_W, D.COVER_H
        local tw               = tw0
        local meta_opts
        local meta, update_funcs = buildMetaColumn(tw0)
        local meta_h = meta:getSize().h

        if dynamic_cover and meta_h > 0 then
            -- Grow (or shrink) the cover so its height matches the text
            -- column's height, preserving the cover's aspect ratio, then apply
            -- the "Cover size" (raw_thumb_scale) setting as a multiplier ON TOP of
            -- that dynamic height. This makes the Cover size stepper still do
            -- something useful while Dynamic Cover Size is on: instead of being
            -- ignored (thumb_scale used to only affect D.COVER_W/H, which this
            -- branch overwrote entirely), each step grows/shrinks the cover
            -- relative to whatever size the dynamic layout would otherwise pick
            -- at that moment. cover_gap is untouched — only the cover's own box
            -- changes size.
            --
            -- IMPORTANT (landscape): meta_h is the measured height of the text
            -- column, which was already built using `scale`, which
            -- has `lf` (landscape_factor) folded in. Multiplying
            -- meta_h by the lf-inclusive `thumb_scale` would apply lf a SECOND
            -- time (effectively lf² instead of lf), collapsing the dynamic
            -- cover far more than intended in landscape. Use the RAW thumb
            -- scale (the user's Cover size % on its own) instead — same "RAW
            -- getters, value already narrowed upstream" pattern documented in
            -- sui_book_grid.lua's build() for the same reason.
            --
            -- A floor is applied so the cover can never shrink below its base
            -- 100%-cover-size (the size used when Dynamic Cover Size is off and
            -- Cover size = 100%), no matter how little vertical space the text
            -- column ends up needing. min_cover_h uses the same percentage-of-`w`
            -- formula as the base size, with thumb_scale pinned to 1.0 (100%).
            local ratio        = D.COVER_W / D.COVER_H  -- scale-invariant aspect ratio
            local _, min_cover_h = _computeCoverDims(w, 1.0, _cover_ratio)
            local new_cover_h  = math.max(min_cover_h, math.floor(meta_h * raw_thumb_scale))
            local new_cover_w  = math.max(1, math.floor(new_cover_h * ratio))
            if new_cover_w ~= cover_w or new_cover_h ~= cover_h then
                cover_w, cover_h = new_cover_w, new_cover_h
                tw = math.max(1, w - cover_w - cover_gap)
                meta:free()
                -- Pass 2: rebuild the text column at the corrected width now
                -- that the cover (and thus the space left for text) changed
                -- size. Height cannot change between passes (see comment on
                -- buildMetaColumn above), so meta_h from pass 1 stays valid —
                -- no further passes or re-measuring needed.
                meta, update_funcs = buildMetaColumn(tw)
            end

        elseif not dynamic_cover and meta_h > cover_h then
            -- Anchor the text column to the cover's height in "default": the
            -- cover's own size is authoritative and the text column must
            -- never grow taller than it. The description is the sole elastic
            -- element (title/author/series/progress/stats keep their natural
            -- size); it shrinks to whatever room is left, or is omitted
            -- entirely if there isn't enough room for even one line.
            if show.description and bd.description and bd.description ~= "" then
                -- Measure every OTHER element's height first (description
                -- suppressed), so we know exactly how much room is left for it.
                local probe   = buildMetaColumn(tw0, { suppress_description = true })
                local other_h = probe:getSize().h
                probe:free()
                local breath  = math.max(1, desc_gap)
                local available = cover_h - other_h - breath
                local desc_line_h = math.floor(1.3 * face_desc.size + 0.5)
                local new_desc_lines = (available >= face_desc.size)
                    and math.max(1, math.floor(available / desc_line_h)) or 0
                meta_opts = { desc_max_lines = new_desc_lines }
                meta:free()
                meta, update_funcs = buildMetaColumn(tw0, meta_opts)
                meta_h = meta:getSize().h
            end
            -- If there's no description to shrink (or it's disabled/empty),
            -- meta_h simply stays as measured — the module falls back to
            -- growing past the cover rather than clipping fixed-size content.
        end

        return { cover_w = cover_w, cover_h = cover_h, tw = tw, meta_h = meta_h, meta_opts = meta_opts },
               meta, update_funcs
    end

    -- A plan is only valid for identical inputs: the settings bundle (its
    -- identity), the geometry below and the book texts. A plan found in the
    -- cache comes without a column; the caller builds it.
    local function resolvePlan()
        local plan_key = c and _layoutPlanKey({
            w, lf, raw_scale, raw_thumb_scale, layout, cover_gap,
            _cover_ratio, ctx.has_wallpaper and 1 or 0, series_text, D.COVER_W,
        }, bd)
        local found = plan_key and _findLayoutPlan(c, plan_key)
        if found then return found end
        local resolved, meta_col, funcs = resolveLayout()
        if plan_key then _storeLayoutPlan(c, plan_key, resolved) end
        return resolved, meta_col, funcs
    end
    local plan, meta, _cr_update_funcs = resolvePlan()

    -- The row is taller than the module (see `fills_row_height`): the cover
    -- takes the extra height, as far as the width left for the text allows. A
    -- dynamic cover already follows the text column.
    local grow = tonumber(ctx.grow_h) or 0
    if grow > 0 and not dynamic_cover then
        local ratio = D.COVER_H / D.COVER_W
        local target_h = math.max(plan.cover_h, plan.meta_h) + grow
        local grown_w = math.min(math.floor(w * _COVER_GROW_MAX_W_PCT), math.floor(target_h / ratio))
        if grown_w > D.COVER_W then
            D.COVER_W, D.COVER_H = grown_w, math.floor(grown_w * ratio)
            tw0 = w - D.COVER_W - cover_gap
            if meta then meta:free() end
            plan, meta, _cr_update_funcs = resolvePlan()
        end
    end
    if not meta then meta, _cr_update_funcs = buildMetaColumn(plan.tw, plan.meta_opts) end
    local cover_w, cover_h, tw, meta_h = plan.cover_w, plan.cover_h, plan.tw, plan.meta_h

    local content_h = math.max(cover_h, meta_h)

    -- Fetch the actual cover image at its final (possibly dynamically-grown
    -- or -shrunk) size. SH.getBookCover's underlying cache keeps the
    -- largest size requested this session per book and resizes to fit at
    -- paint time, so requesting a larger size here than a previous render
    -- simply grows the cached bitmap — no special-casing needed.
    local cover = SH.getBookCover(ctx.current_fp, cover_w, cover_h)
                  or SH.coverPlaceholder(bd.title, bd.authors, cover_w, cover_h)

    -- Optional progress pentagon on the cover (same primitive as Coverdeck
    -- and the book-grid modules). Applied after the cover is resolved so
    -- late loads in updateCovers can re-apply it the same way.
    if showProgressBadge(pfx) then
        cover = applyProgressBadge(cover, bd, cover_w, cover_h, pfx)
    end

    -- Layout: cover on left, text column on right.
    -- The cover is wrapped in a CenterContainer sized to content_h so it
    -- stays vertically centred when the text column is taller than the cover.
    local cover_frame = FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_right = cover_gap,
            cover,
        }
    local cover_centered = CenterContainer:new{
        dimen = Geom:new{ w = cover_w + cover_gap, h = content_h },
        cover_frame,
    }

    local meta_centered = CenterContainer:new{
        dimen = Geom:new{ w = tw, h = content_h },
        meta,
    }

    local row = HorizontalGroup:new{
        align = "top",
        cover_centered,
        meta_centered,
    }
    local tappable = InputContainer:new{
        dimen    = Geom:new{ w = w, h = content_h },
        _fp      = ctx.current_fp,
        _open_fn = ctx.open_fn,
        [1] = row,
    }
    tappable.ges_events = {
        TapBook = {
            GestureRange:new{
                ges   = "tap",
                range = function() return tappable.dimen end,
            },
        },
    }
    -- align/stretch dropped: SH.getBookCover is stretch-only now.
    tappable._cover_slots = {
        { container = cover_frame, idx = 1, fp = ctx.current_fp,
          w = cover_w, h = cover_h },
    }
    function tappable:onTapBook()
        if self._open_fn then self._open_fn(self._fp) end
        return true
    end

    -- Two long-press zones, mirroring module_coverdeck.lua's onHoldDeck
    -- centre-cover-vs-side-cover split (cover-region vs text-region here,
    -- since there's a single cover rather than a carousel to split
    -- against): holding the COVER respects "Long press on cover" →
    -- Config.getCoverHoldMode as before; holding the title/author/stats
    -- text column always falls through to the module wrapper's
    -- HoldMod/HoldModRelease (settings screen), same as holding a side
    -- cover in coverdeck does today. Registered any time book_dialog mode
    -- is on for this module — previously onHoldBook consumed the ENTIRE
    -- tappable unconditionally, so a hold on the text column also opened
    -- the book dialog instead of settings.
    if Config.getCoverHoldMode("currently", ctx.pfx) == "book_dialog" then
        tappable.ges_events.HoldBook = {
            GestureRange:new{ ges = "hold", range = function() return tappable.dimen end },
        }
        tappable.ges_events.HoldBookRelease = {
            GestureRange:new{ ges = "hold_release", range = function() return tappable.dimen end },
        }
        function tappable:onHoldBook(_, ges)
            local x = ges.pos.x - self.dimen.x
            self._hold_on_cover = (x >= 0 and x < cover_w)
            -- Only swallow the gesture (and thus block the settings-menu
            -- fallback) when it actually lands on the cover.
            return self._hold_on_cover or nil
        end
        function tappable:onHoldBookRelease()
            if self._hold_on_cover and self._fp and ctx.hold_fn then
                ctx.hold_fn(self._fp, "currently")
            end
            return self._hold_on_cover or nil
        end
    end

    tappable._cr_update_funcs = _cr_update_funcs

    if ctx.kbStops then
        UI.makeFocusable(tappable, tappable.onTapBook)
        ctx.kbStops(M.id, { { id = "book", widget = tappable } })
    end

    return tappable
end

-- updateCovers(widget, ctx) — called by the homescreen cover poll instead of
-- a full build(). Swaps only the cover image(s) inside the existing widget
-- tree, leaving all text, layout, and gesture handlers untouched.
-- Returns true if all covers are now resolved, false if some are still missing.
function M.updateCovers(widget, _ctx)
    if not widget or not widget._cover_slots then return true end

    local SH = getSH()
    if not SH then return true end

    local pfx = (_ctx and _ctx.pfx) or ""
    local show_badge = showProgressBadge(pfx)
    local all_done = true
    for _, slot in ipairs(widget._cover_slots) do
        local new_cover = SH.getBookCover(slot.fp, slot.w, slot.h)
        if new_cover then
            if show_badge then
                local bd = SH.getBookData(slot.fp, _ctx and _ctx.prefetched and _ctx.prefetched[slot.fp])
                new_cover = applyProgressBadge(new_cover, bd, slot.w, slot.h, pfx)
            end
            slot.container[slot.idx] = new_cover
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end

-- Returns the total pixel height of the module including the section label.
-- Measures real font line heights via Font:getFace() so the estimate matches
-- what build() actually renders.  This prevents the homescreen from
-- under-allocating space and causing overlap with the module below.
function M.getHeight(_ctx)
    local SH = getSH()
    if not SH then return SectionLabel.height(M.id, _ctx and _ctx.landscape_factor) end
    local pfx = _ctx and _ctx.pfx
    -- Use pre-read settings bundle from ctx when available (normal HS path).
    -- c.scale/c.thumb_scale (from ctx.cfg) are RAW; apply
    -- ctx.landscape_factor here, on both the cached and fallback path.
    -- thumb_scale is the exception: w_estimate below (ctx.col_w) is already
    -- the module's landscape-reduced column width, so the cover-size
    -- percentage-of-w calculation must use the RAW value — multiplying by
    -- lf again would apply the landscape reduction twice.
    local c           = _ctx and _ctx.cfg and _ctx.cfg.currently
    local lf          = (_ctx and _ctx.landscape_factor) or (UI.isLandscape() and UI.getLandscapeFactor() or 1)
    local raw_scale   = c and c.scale       or Config.getModuleScale("currently", pfx)
    local scale       = raw_scale * lf
    local raw_thumb_scale = c and c.thumb_scale or Config.getThumbScale("currently", pfx)

    local layout = (c and c.layout) or getLayout(pfx)

    -- Base cover size, mirroring build()'s _computeCoverDims call exactly.
    -- getHeight() has no module width of its own (see moduleregistry's
    -- contract, M.getHeight(ctx)), so it estimates it the same way
    -- module_clock/module_coverdeck/module_quick_actions already do.
    local w_estimate = (_ctx and (_ctx.col_w or _ctx.inner_w))
                        or UI.getInnerW()
    local _cover_ratio = SH.getDims(1.0, 1.0).COVER_H / SH.getDims(1.0, 1.0).COVER_W
    local cover_w, cover_h = _computeCoverDims(w_estimate, raw_thumb_scale * raw_scale, _cover_ratio)
    local D = { COVER_W = cover_w, COVER_H = cover_h }

    local bar_style    = c and c.bar_style   or getBarStyle(pfx)
    local stats_style  = c and c.stats_style or getStatsStyle(pfx)
    local show = c and c.show or _readShow(pfx)

    -- Measure real line heights using the same font faces as build().
    -- See _scaledLayoutDims for the shared formulas (also used by build()).
    local styles = Config.resolveTextStyles(_ctx, M.id, M.text_elems)
    local LD = _scaledLayoutDims(scale, styles)
    local FC = _resolveFaces(LD, styles)
    local bar_h, bar_gap_b, bar_gap_a, title_gap, author_gap, series_gap, desc_gap, pct_gap =
        LD.bar_h, LD.bar_gap_before, LD.bar_gap_after, LD.title_gap, LD.author_gap, LD.series_gap, LD.desc_gap, LD.pct_gap

    local title_lh  = SUIStyle.faceHeight(FC.title)
    local author_lh = SUIStyle.faceHeight(FC.author)
    local series_lh = SUIStyle.faceHeight(FC.series)
    local desc_lh   = SUIStyle.faceHeight(FC.desc)
    local stats_lh  = SUIStyle.faceHeight(FC.stats)

    -- Build the element list using real (measured) line heights, mirroring
    -- build()'s own gap_before ordering. is_desc tags the description entry
    -- so its contribution can be excluded below for non-dynamic layouts
    -- (where build() treats description as elastic, never as something
    -- that grows the module past the cover — see the anchoring branch in
    -- build()).
    local elems = {}
    if show.title then
        elems[#elems+1] = { title_gap, title_lh * 2 }
    end
    if show.author then
        elems[#elems+1] = { author_gap, author_lh }
    end
    if show.series then
        -- Conservative: reserve one line regardless of whether the current
        -- book actually belongs to a series (same policy as author above).
        elems[#elems+1] = { series_gap, series_lh }
    end
    if show.description then
        -- Conservative: reserve full DESC_MAX_LINES height regardless of
        -- whether the current book actually has a description, same policy
        -- as the other elements in this function (avoids under-allocating
        -- and overlapping the module below). Only actually counted toward
        -- content_h for "dynamic" — see is_desc below.
        elems[#elems+1] = { desc_gap, desc_lh * DESC_MAX_LINES, is_desc = true }
    end
    if show.progress then
        elems[#elems+1] = { bar_gap_b, bar_h + bar_gap_a }
    end
    -- The stats rows always reserve their height: they are rendered even for
    -- a book without recorded history.
    local n_stats = _visibleStatCount(show, bar_style)
    for _ = 1, stats_style == "default" and n_stats or math.min(n_stats, 1) do
        elems[#elems+1] = { pct_gap, stats_lh }
    end

    -- Sums the element list; skip_desc=true excludes the description entry
    -- (and its leading gap), giving the height of every OTHER element only.
    local function sumH(skip_desc)
        local h, first = 0, true
        for _, e in ipairs(elems) do
            if not (skip_desc and e.is_desc) then
                if not first then h = h + e[1] end
                h = h + e[2]
                first = false
            end
        end
        return h
    end
    local text_h         = sumH(false)
    local text_h_no_desc = sumH(true)

    local dynamic_cover = (layout == "dynamic")

    -- When dynamic cover sizing is on, build() grows the cover to match the
    -- text column, then applies the Cover size (raw thumb_scale, WITHOUT lf
    -- — see build()'s comment on why lf must not be applied twice) multiplier
    -- on top and floors the result at the base 100%-cover-size. Mirror that
    -- same computation here so the reserved height never falls short of what
    -- build() will actually render (which would overlap the next module).
    -- text_h is already a conservative UPPER BOUND on the real meta_h (see
    -- comments above — it reserves full stats rows etc. regardless of
    -- whether this particular book has data), so this stays a safe
    -- over-estimate, never an under-estimate.
    --
    -- The "default" layout instead ANCHORS the text column to the
    -- cover's height: build() shrinks or hides the
    -- description to fit, so the module's real height is never taller than
    -- max(cover_h, everything-except-description). Using text_h (which
    -- still includes the description's full reserved height) here would
    -- over-allocate space that build() will never actually use — text_h_no_desc
    -- mirrors what build() actually anchors against.
    local content_h
    if dynamic_cover then
        local _, min_cover_h = _computeCoverDims(w_estimate, 1.0, _cover_ratio)
        local dyn_cover_h = math.max(min_cover_h, math.floor(text_h * raw_thumb_scale))
        content_h = math.max(text_h, dyn_cover_h)
    else
        content_h = math.max(D.COVER_H, text_h_no_desc)
    end
    -- The module chrome adds its padding and border around the content.
    content_h = content_h + Chrome.boxInset(Chrome.resolve(pfx, M.id))
    return SectionLabel.height(M.id, lf) + content_h
end


-- Settings menu helpers (scale, text size, cover size).
local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("currently", pfx) end,
        set          = function(v) Config.setModuleScale(v, "currently", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

local function _makeThumbScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Cover Size") end,
        title     = _lc("Cover Size"),
        info      = _lc("Scale for the cover thumbnail only.\n100% is the default size.\nWhen Dynamic Cover Size is on, this scales the cover relative to its current dynamic size instead, and the cover never shrinks below its 100% size."),
        get       = function() return Config.getThumbScalePct("currently", pfx) end,
        set       = function(v) Config.setThumbScale(v, "currently", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end



local function _makeCoverGapItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Cover Spacing") end,
        title     = _lc("Cover Spacing"),
        info      = _lc("Horizontal space between the cover and the text.\n100% is the default spacing."),
        get       = function() return getCoverGapPct(pfx) end,
        set       = function(v) SUISettings:saveSetting(pfx .. COVER_GAP_KEY, v) end,
        refresh   = ctx_menu.refresh,
        value_min = 0,
        value_max = 300,
        value_step = 10,
        default_value = 100,
    })
end

-- "Default" sizes the cover as a percentage of the module's width (see
-- _COVER_W_PCT) and anchors the text column to the cover's height,
-- shrinking the description if needed. "Dynamic" additionally grows or
-- shrinks the cover to match the text column's height.
local function _makeLayoutItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeRadioSubmenuItem{
        text      = _lc("Layout"),
        separator = true,
        options   = {
            { value = "default", label = _lc("Default") },
            {
                value     = "dynamic",
                label     = _lc("Dynamic"),
                help_text = _lc("Grows or shrinks the cover so its height always matches the text column, keeping the cover's proportions.\nThe spacing between cover and text stays as set above.\nThe Cover size setting still applies on top of this, and the cover never shrinks below its 100% size."),
            },
        },
        get       = function() return getLayout(pfx) end,
        set       = function(v) SUISettings:saveSetting(pfx .. LAYOUT_KEY, v) end,
        refresh   = ctx_menu.refresh,
    }
end

-- Returns the settings menu items for this module.
function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._

    local thumb = _makeThumbScaleItem(ctx_menu)

    local gap_item = _makeCoverGapItem(ctx_menu)

    -- Items and statistics share one visibility and order model. Changes also
    -- drop the settings snapshot the screens build from.
    local function itemList(opts)
        opts.ctx         = ctx_menu
        opts.refresh     = refresh
        opts.is_visible  = function(key) return _showElem(pfx, key) end
        opts.set_visible = function(key, visible) _setElemVisible(pfx, key, visible) end
        return Config.makeOrderedItems(opts)
    end
    local stats_list = itemList{
        ids          = STAT_IDS,
        order_key    = pfx .. STATS_ORDER_KEY,
        label        = BookStats.statLabel,
        is_available = function(id) return _statAvailable(id, getBarStyle(pfx)) end,
        title        = _lc("Statistics"),
        text         = _lc("Arrange Statistics"),
        empty_text   = _lc("No statistics selected."),
    }
    local main_list = itemList{
        ids       = ITEM_IDS,
        order_key = pfx .. MAIN_ORDER_KEY,
        label     = itemLabel,
        title     = _lc("Items"),
        text      = _lc("Arrange Items"),
        nested    = { stats = stats_list },
    }

    -- The SUI menu reaches the statistics from the Items screen; the classic
    -- menu lists them in a submenu of their own.
    local rows = main_list.rows()
    local items_entry = rows[1]
    if not ctx_menu.is_sui then
        rows[1].separator = true
        rows[#rows + 1] = { text = _lc("Statistics"), sub_item_table = stats_list.rows() }
        items_entry = { text = _lc("Items"), sub_item_table = rows }
    end

    local size_items = {
        _makeScaleItem(ctx_menu),
        thumb,
        gap_item,
    }

    local text_opts = {
        mod_id  = M.id,
        elems   = M.text_elems,
        labels  = {
            title       = _lc("Title"),
            author      = _lc("Author"),
            series      = _lc("Series"),
            description = _lc("Description"),
            stats       = _lc("Progress Text"),
        },
        info    = _lc("Size of this text.\n100% is the default size."),
        pfx     = pfx,
        refresh = refresh,
        _lc     = _lc,
    }

    local progress_badge_group = {
        Config.makeBadgeSizeItem{
            info         = _lc("Scale for the progress badge."),
            enabled_func = function() return showProgressBadge(pfx) end,
            get          = function() return Config.getBadgeScalePct("currently", pfx) end,
            set          = function(v) Config.setBadgeScale(v, "currently", pfx) end,
            refresh      = refresh,
            _lc          = _lc,
            separator    = true,
        },
        {
            text           = _lc("Progress Badge"),
            checked_func   = function() return showProgressBadge(pfx) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. SETTING_SHOW_PROGRESS_BADGE, not showProgressBadge(pfx))
                refresh()
            end,
        },
        Config.makeRadioSubmenuItem{
            text         = _lc("Progress Badge Color"),
            enabled_func = function() return showProgressBadge(pfx) end,
            options      = SUIStyle.badgeColorOptions(_lc, _lc("Follow Style")),
            get          = function() return SUIStyle.badgeChoiceShown(getProgressBadgeColorOverride(pfx)) end,
            set          = function(v) setProgressBadgeColor(pfx, v) end,
            refresh      = refresh,
        },
    }

    local progress_stats_entry = {
            text_func      = function() return _lc("Progress and Stats") end,
            sub_item_table = {
                Config.makeRadioSubmenuItem{
                    text    = _lc("Progress bar style"),
                    options = {
                        { value = "simple",   label = _lc("Simple") },
                        { value = "with_pct", label = _lc("With percentage") },
                    },
                    get     = function() return getBarStyle(pfx) end,
                    set     = function(v) SUISettings:saveSetting(pfx .. BAR_STYLE_KEY, v) end,
                    refresh = refresh,
                },
                Config.makeRadioSubmenuItem{
                    text    = _lc("Stats layout"),
                    options = {
                        { value = "default",  label = _lc("Detailed") },
                        { value = "compact",  label = _lc("Compact") },
                    },
                    get     = function() return getStatsStyle(pfx) end,
                    set     = function(v) SUISettings:saveSetting(pfx .. STATS_STYLE_KEY, v) end,
                    refresh = refresh,
                },
                {
                    -- Only the compact (single-line) layout carries the clock.
                    text           = _lc("Clock icon"),
                    enabled_func   = function() return getStatsStyle(pfx) == "compact" end,
                    checked_func   = function() return getStatsIcon(pfx) end,
                    keep_menu_open = true,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. STATS_ICON_KEY, not getStatsIcon(pfx))
                        refresh()
                    end,
                },
                {
                    text_func  = function() return _lc("Progress Badge") end,
                    value_func = function()
                        return showProgressBadge(pfx) and _lc("On") or _lc("Off")
                    end,
                    sub_item_table = progress_badge_group,
                },
            },
    }

    local cover_hold_entry = Config.makeCoverHoldModeItem{
            mod_id  = "currently",
            pfx     = pfx,
            refresh = refresh,
            _lc     = _lc,
    }

    local update_stats_entry = {
            text           = _lc("Update Stats Now"),
            separator      = true,
            keep_menu_open = true,
            callback       = function()
                local SP = package.loaded["modules/module_stats_provider"]
                if SP and SP.rescanBooks then SP.rescanBooks() end
                local SH = package.loaded["modules/module_books_shared"]
                if SH and SH.invalidateSidecarCache then SH.invalidateSidecarCache() end
                local MC = package.loaded["modules/module_currently"]
                if MC and MC.invalidateCache then MC.invalidateCache() end
                local MCD = package.loaded["modules/module_coverdeck"]
                if MCD and MCD.invalidateCache then MCD.invalidateCache() end

                local ScreenEngine = package.loaded["engines/sui_screen_engine"]
                if ScreenEngine and ScreenEngine.invalidateAllCfgAndRefresh then
                    ScreenEngine.invalidateAllCfgAndRefresh(true)
                end
                if ctx_menu and type(ctx_menu.refresh) == "function" then ctx_menu.refresh() elseif refresh then refresh() end
                UI.Notify.toast(_lc("Stats updated successfully."), 2)
            end,
    }

    local appearance_extra = {
        Config.makeAlignmentItem{
            key          = pfx .. DESC_ALIGN_KEY,
            values       = DESC_ALIGN_VALUES,
            default      = DESC_ALIGN_DEFAULT,
            text         = _lc("Description Alignment"),
            enabled_func = function() return _showElem(pfx, "description") end,
            refresh      = refresh,
            _lc          = _lc,
        },
        Config.makeLabelToggleItem("currently", refresh, _lc),
        Config.makeLabelPlacementItem("currently", refresh, _lc),
    }

    return Config.buildModuleMenu({
        items   = { items_entry },
        content = { _makeLayoutItem(ctx_menu) },
        appearance = {
            size  = size_items,
            text  = text_opts,
            extra = appearance_extra,
        },
        badges    = { progress_stats_entry },
        behaviour = { cover_hold_entry, update_stats_entry },
    }, ctx_menu)
end

function M.updateStats(widget, ctx)
    if not widget or not widget._cr_update_funcs then return false end

    local fp = widget._fp
    if not fp then return false end

    -- The widget only carries data for the book it was built with (_fp).
    -- If ctx.current_fp now points to a DIFFERENT book — e.g. the user
    -- closed a book that wasn't already showing in "Currently Reading" —
    -- patching stats in-place would silently refresh the WRONG book's
    -- numbers while leaving the old book's cover/title on screen. Force a
    -- full rebuild (return false) so module_currently.build() runs again
    -- with the new ctx.current_fp and replaces the widget entirely,
    -- mirroring the identity check module_recent.updateStats() already
    -- does for its own fp list.
    if ctx.current_fp ~= fp then return false end

    -- Progress badge is composited into the cover widget tree at build time.
    -- Percent/status changes on the badge require a full rebuild.
    local pfx = (ctx and ctx.pfx) or ""
    if showProgressBadge(pfx) then return false end

    local c = ctx.cfg and ctx.cfg.currently
    local show = c and c.show or _readShow(pfx)

    local bstats
    local pre = ctx.currently_book_stats
    if pre and pre.fp == fp then
        bstats = pre.stats
    end

    local prefetched_entry = ctx.prefetched and ctx.prefetched[fp]
    if not bstats and M.needsDbStats(show) then
        local md5 = prefetched_entry and prefetched_entry.partial_md5_checksum
        if not md5 then
            local DS = require("docsettings")
            local ok_ds, ds = pcall(DS.open, DS, fp)
            if ok_ds and ds then
                md5 = ds:readSetting("partial_md5_checksum")
                pcall(function() ds:close() end)
            end
        end
        if md5 then
            bstats = fetchBookStats(md5, ctx.db_conn, ctx, true)
        end
    end

    local SH = getSH()
    if SH then
        local bd = SH.getBookData(fp, prefetched_entry)
        for _, fn in ipairs(widget._cr_update_funcs) do
            fn(bstats, bd)
        end
    end
    return true
end

return M