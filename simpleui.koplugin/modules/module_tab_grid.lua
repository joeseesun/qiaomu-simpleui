-- module_tab_grid.lua — Simple UI
-- Module: Tabbed Grid (dynamic instances).
--
-- A book grid with a tab bar in the place of the section label. Each tab binds
-- the grid to a book source (engines/sui_book_sources.lua): reading history,
-- new books, the To Be Read list, any chosen collection, or the authors,
-- series and tags of the library. The grid, its scale, progress and badge
-- settings come from GridRenderer.makeModule.
--
-- A tab offers the settings of its source (engines/sui_book_sources.lua):
-- the options it declares and, for a collection, sort and arrange. They are
-- listed under the tab in Arrange Tabs.
--
-- A tab of a group source (authors, series, tags) lists groups of books
-- instead of books. Its cells are the group cells of engines/sui_group_cell.lua
-- (cover, count and name); tapping one opens the group in the library.
--
-- Layout, top to bottom:
--   tab bar   strip showing VISIBLE_TABS tabs, with chevrons to slide the
--             window when there are more; round pill, square pill or plain
--             tabs (see STYLES)
--   grid      rows x columns of covers; swipe turns the page, and tapping the
--             active tab returns to the first page
--   pager     page indicator, empty while the active tab fits one page. Its
--             style is one of PAGER_STYLES:
--               numbers  "page/pages" with chevrons, left, centre or right aligned
--               bar      progress bar, centred
--               off      none; swipe still turns the page
--             and its position one of PAGER_POSITIONS:
--               top      between the tab bar and the grid box, centred in the
--                        space between them
--               bottom   inside the grid box, under the covers. It follows
--                        the grid of the active tab: close to the covers, and
--                        further down under a line of text (see hasTextBelow)
--
-- The module draws its own chrome (owns_chrome): the tab bar and the grid are
-- two separate boxes, each with its own frame and background. The tab bar's
-- settings live under the id `<inst_id>_tabbar`, the grid's under `inst_id`
-- like any module.
--
-- The module height is the same for every tab and page: the tab bar and the
-- pager row are always reserved and the grid area is as tall as the tallest
-- kind of cell among the tabs, so switching tabs never moves the modules
-- below it. The grid box wraps the content of the active tab; the room a
-- shorter tab leaves stays empty under the box.
--
-- Persistence (per instance, under pfx .. inst_id):
--   _tabs        { { id, source, params }, ... }   ids and params only, never
--                translated text; `id` is unique within the instance and a
--                content (source and params) is added at most once
--   _active_tab  id of the selected tab
--   _tab_options { [tab id] = { key = value } }   options of each tab's
--                source (the values of its declared options and its sort
--                state); cleared together with the tab
--   _tab_style   one of STYLES
--   _pager_*     style (one of PAGER_STYLES), position (one of
--                PAGER_POSITIONS) and alignment of the numbers
--   _tabbar_*    tone, frame and opacity of the tab bar (see ModuleChrome)
--   _group_*     cover style, book stack, count badge and name label of the
--                group cells, shared by every group tab
--
-- Exposes M.instanciable = true and M.makeInstance(id) for the registry.
-- Instances persist in "simpleui_tab_grid_instances" (M.instances_key).

local _ = require("infra/sui_i18n").translate

local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local OverlapGroup    = require("ui/widget/overlapgroup")
local FrameContainer  = require("ui/widget/container/framecontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = require("device").screen
local Size            = require("ui/size")

local Arrange      = require("features/sui_arrange")
local Config       = require("infra/sui_config")
local ModuleChrome = require("features/sui_module_chrome")
local GridRenderer = require("engines/sui_book_grid")
local GroupCell    = require("engines/sui_group_cell")
local PageNav      = require("engines/sui_page_nav")
local SectionLabel = require("engines/sui_section_label")
local SourceMenu   = require("features/sui_source_menu")
local Sources      = require("engines/sui_book_sources")
local Backdrop     = require("infra/sui_backdrop")
local SUISettings  = require("infra/sui_store")
local SUIStyle     = require("features/sui_style")
local TabStrip     = require("engines/sui_tab_strip")
local TabWindow    = require("engines/sui_tab_window")
local UI           = require("infra/sui_core")

local PAD       = UI.PAD
local PAD2      = UI.PAD2
local PageState = SectionLabel.PageState

-- Tabs visible at once; more tabs slide through the window.
local VISIBLE_TABS = 4

local GRID_ROWS = 1
local GRID_COLS = 5

-- Book cells show no progress by default.
local PROGRESS_STYLE = { default = "none" }

-- Tab bar styles: pill with fully round corners, pill with the module frame's
-- corner radius, and plain tabs with an underline.
local STYLE_ROUND, STYLE_SQUARE, STYLE_TABS = "round", "square", "tabs"
local STYLES = { STYLE_ROUND, STYLE_SQUARE, STYLE_TABS }

-- TabStrip style of each tab bar style.
local STRIP_STYLE = {
    [STYLE_ROUND]  = "pill",
    [STYLE_SQUARE] = "pill",
    [STYLE_TABS]   = "underline",
}

-- Page indicator styles: page numbers with chevrons, a progress bar, or none.
local PAGER_NUMBERS, PAGER_BAR, PAGER_OFF = "numbers", "bar", "off"
local PAGER_STYLES = { PAGER_NUMBERS, PAGER_BAR, PAGER_OFF }

-- Page indicator positions: above the grid box or inside it, under the covers.
local POSITION_TOP, POSITION_BOTTOM = "top", "bottom"
local PAGER_POSITIONS = { POSITION_TOP, POSITION_BOTTOM }

-- Position of each style while none is chosen.
local DEFAULT_POSITION = {
    [PAGER_NUMBERS] = POSITION_BOTTOM,
    [PAGER_BAR]     = POSITION_TOP,
    [PAGER_OFF]     = POSITION_BOTTOM,
}

-- Alignments of the page numbers.
local PAGER_ALIGNS = { "left", "center", "right" }
local DEFAULT_ALIGN = "right"

-- Container that aligns an indicator in its row.
local ALIGN_CONTAINER = {
    left   = LeftContainer,
    center = CenterContainer,
    right  = RightContainer,
}

-- Surface kind of the tab bar: it starts framed and, over a wallpaper, solid.
local BAR_KIND = "tab_bar"

-- Tabs of an instance that has none stored yet.
local DEFAULT_TABS = {
    { id = 1, source = "recent",    params = {} },
    { id = 2, source = "new_books", params = {} },
}

-- ---------------------------------------------------------------------------
-- Tab store
-- ---------------------------------------------------------------------------

-- Identity of the content of a tab: its source and params.
local function contentKey(source, params)
    local keys = {}
    for key in pairs(params or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = { source }
    for _i, key in ipairs(keys) do
        parts[#parts + 1] = key .. "=" .. tostring(params[key])
    end
    return table.concat(parts, "|")
end

-- Persistence of the tabs and the selected tab of one instance.
local function newTabStore(inst_id)
    local tabs_key    = inst_id .. "_tabs"
    local active_key  = inst_id .. "_active_tab"
    local options_key = inst_id .. "_tab_options"
    local store = {}

    -- Options of every tab, { [tab id] = { key = value } }. The stored tables
    -- are shared with the settings, so a change writes copies.
    local function storedOptions(pfx)
        local stored = SUISettings:readSetting(pfx .. options_key)
        return type(stored) == "table" and stored or {}
    end

    -- Stored tabs whose source is still registered. The tab tables are shared
    -- with the settings and must not be modified.
    local function stored(pfx)
        local tabs = {}
        for _i, tab in ipairs(SUISettings:readSetting(pfx .. tabs_key) or DEFAULT_TABS) do
            if Sources.has(tab.source) then tabs[#tabs + 1] = tab end
        end
        return tabs
    end

    -- The tabs shown: stored tabs whose source is available. A tab of an
    -- unavailable source stays stored and comes back with its source.
    function store.read(pfx)
        local tabs = {}
        for _i, tab in ipairs(stored(pfx)) do
            if Sources.isAvailable(tab.source) then tabs[#tabs + 1] = tab end
        end
        return tabs
    end

    function store.write(pfx, tabs)
        SUISettings:saveSetting(pfx .. tabs_key, tabs)
    end

    -- The selected tab of `tabs` and its index; the first tab while the stored
    -- selection is gone, nothing while there are no tabs.
    function store.activeTab(pfx, tabs)
        local id = SUISettings:readSetting(pfx .. active_key)
        for i, tab in ipairs(tabs) do
            if tab.id == id then return tab, i end
        end
        if tabs[1] then return tabs[1], 1 end
    end

    -- Selection changes on every tab tap: kept in memory, flushed with the
    -- rest of the settings on suspend.
    function store.setActive(pfx, id)
        SUISettings:setNoFlush(pfx .. active_key, id)
    end

    -- Content keys of the stored tabs.
    function store.contentKeys(pfx)
        local keys = {}
        for _i, tab in ipairs(stored(pfx)) do
            keys[contentKey(tab.source, tab.params)] = true
        end
        return keys
    end

    -- Appends a tab; false when the instance already has that content.
    function store.add(pfx, source, params)
        local tabs, next_id = stored(pfx), 1
        local key = contentKey(source, params)
        for _i, tab in ipairs(tabs) do
            if contentKey(tab.source, tab.params) == key then return false end
            next_id = math.max(next_id, tab.id + 1)
        end
        tabs[#tabs + 1] = { id = next_id, source = source, params = params }
        store.write(pfx, tabs)
        return true
    end

    function store.option(pfx, id, key)
        local own = storedOptions(pfx)[id]
        return own and own[key]
    end

    -- Stores the options of one tab (nil forgets them).
    local function writeOptions(pfx, id, own)
        local all = {}
        for tab_id, options in pairs(storedOptions(pfx)) do all[tab_id] = options end
        all[id] = own
        SUISettings:saveSetting(pfx .. options_key, all)
    end

    function store.setOption(pfx, id, key, value)
        local own = {}
        for option_key, option_value in pairs(storedOptions(pfx)[id] or {}) do
            own[option_key] = option_value
        end
        own[key] = value
        writeOptions(pfx, id, own)
    end

    function store.remove(pfx, id)
        local kept = {}
        for _i, tab in ipairs(stored(pfx)) do
            if tab.id ~= id then kept[#kept + 1] = tab end
        end
        store.write(pfx, kept)
        if storedOptions(pfx)[id] ~= nil then writeOptions(pfx, id, nil) end
        -- A later tab may reuse the id: it must not inherit the selection.
        if SUISettings:readSetting(pfx .. active_key) == id then
            SUISettings:delNoFlush(pfx .. active_key)
        end
    end

    -- Orders the tabs as `ids`; the tabs not listed (those of unavailable
    -- sources) follow in their stored order.
    function store.reorder(pfx, ids)
        local all = stored(pfx)
        local by_id = {}
        for _i, tab in ipairs(all) do by_id[tab.id] = tab end
        local ordered = {}
        for _i, id in ipairs(ids) do
            if by_id[id] then
                ordered[#ordered + 1] = by_id[id]
                by_id[id] = nil
            end
        end
        for _i, tab in ipairs(all) do
            if by_id[tab.id] then ordered[#ordered + 1] = tab end
        end
        store.write(pfx, ordered)
    end

    return store
end

-- The store of an instance, created once and shared by the module and the
-- layout editor summary.
local stores = {}
local function tabStore(inst_id)
    local store = stores[inst_id]
    if not store then
        store = newTabStore(inst_id)
        stores[inst_id] = store
    end
    return store
end

-- Display name of a tab.
local function tabLabel(tab)
    return Sources.tabLabel(tab.source, tab.params)
end

-- Identity of what a tab shows: changes whenever the grid content does.
local function tabSignature(tab)
    return tab.id .. "|" .. contentKey(tab.source, tab.params)
end

-- Number of recent books the tabs need prefetched into ctx.recent_fps.
local function recentDemand(tabs)
    local demand = 0
    for _i, tab in ipairs(tabs) do
        local needs = Sources.get(tab.source).needs
        if needs and needs.recent then demand = math.max(demand, needs.recent) end
    end
    return demand
end

-- Settings prefix of a ctx; empty while the ctx carries none.
local function pfxOf(ctx)
    return ctx and ctx.pfx or ""
end

-- ---------------------------------------------------------------------------
-- Metrics
-- ---------------------------------------------------------------------------

-- Space between the tab bar and the grid.
local TAB_BAR_GAP = PAD

-- Text element id for the tab labels (Config text styles: font, size, variant).
local TAB_TEXT_ELEM = "tabs"

-- Text elements of the module: the grid item labels, covering the group names
-- too, and the tab labels, which have their own menu in Tab Bar.
local TEXT_ELEMS = { "label", TAB_TEXT_ELEM }

-- Tab labels match the homescreen section labels at 100% size: regular face at
-- body size, scaled by the label density, landscape factor and the per-instance
-- text style size. The pager uses the lighter detail size of the section
-- label's right text.
local function tabFace(ctx, inst_id)
    local scale = Config.getLabelScale() * GridRenderer.landscapeFactor(ctx)
    local style = Config.resolveTextStyles(ctx, inst_id, TEXT_ELEMS)[TAB_TEXT_ELEM]
    local size  = math.max(8, math.floor(SUIStyle.FS_BODY * scale * (style.scale or 1)))
    return (SUIStyle.getTextFace(style, size))
end

local function pagerFace(ctx)
    return PageNav.indicatorFace(Config.getLabelScale() * GridRenderer.landscapeFactor(ctx))
end

-- Id the tab bar's frame and background settings are stored under.
local function barId(inst_id)
    return inst_id .. "_tabbar"
end

local function styleKey(pfx, inst_id)
    return pfx .. inst_id .. "_tab_style"
end

local function tabStyle(pfx, inst_id)
    return Config.readChoice(styleKey(pfx, inst_id), STYLES, STYLE_ROUND)
end

-- Colour of the active tab, as a background tone. Unset, it is the accent, or
-- the text colour over a tinted bar, where the accent would blend into it.
local ACTIVE_TONES = {
    Backdrop.TONE.WHITE, Backdrop.TONE.GRAY, Backdrop.TONE.ACCENT, Backdrop.TONE.SECONDARY,
}

local function activeKey(pfx, inst_id)
    return pfx .. inst_id .. "_tab_active"
end

-- Stored tone of the active tab, nil when unset or when it is a palette colour
-- that is not on screen.
local function activeTone(pfx, inst_id)
    local tone = Config.readChoice(activeKey(pfx, inst_id), ACTIVE_TONES, nil)
    if SUIStyle.isPaletteChoice(tone) and not SUIStyle.paletteChoiceAvailable(tone) then return nil end
    return tone
end

-- Active tab indicator { color, fg } for the TabStrip, or nil for the accent.
local function activeIndicator(pfx, inst_id, surface)
    local tone = activeTone(pfx, inst_id)
    if tone then
        local plain = tone == Backdrop.TONE.WHITE or tone == Backdrop.TONE.GRAY
        local color = plain and Backdrop.toneColor(tone) or SUIStyle.resolveColor(tone)
        return { color = color, fg = SUIStyle.resolveForeground(tone) or SUIStyle.COLOR.text_primary }
    end
    if surface.foreground then return { color = surface.foreground, fg = surface.color } end
end

-- Look of the tab bar: its style and the TabStrip options that follow from it.
-- The tabs style draws neither frame nor background.
local function barLook(pfx, inst_id)
    local shape   = tabStyle(pfx, inst_id)
    local surface = shape == STYLE_TABS and ModuleChrome.NO_CHROME
        or ModuleChrome.resolve(pfx, barId(inst_id), BAR_KIND)
    return {
        shape     = shape,
        style     = STRIP_STYLE[shape],
        surface   = surface,
        indicator = activeIndicator(pfx, inst_id, surface),
    }
end

-- Width of what sits directly in the label column: the tab bar.
local function columnWidth(col_w)
    return ModuleChrome.contentWidth(col_w, ModuleChrome.NO_CHROME)
end

-- Progress bar of the bar pager (base pixels, scaled at use time).
local PROGRESS_BAR_W = 100
local PROGRESS_BAR_H = 6

-- Height of the row of the page indicator `pager`.
local function pagerRowHeight(ctx, pager)
    if pager.style == PAGER_BAR then return Screen:scaleBySize(PROGRESS_BAR_H) end
    return PageNav.rowHeight(pagerFace(ctx))
end

-- Space between the cells and a bottom pager row, under covers alone and under
-- a line of text. The bar has no row padding of its own, so it gets more.
local PAGER_GAPS = {
    [PAGER_NUMBERS] = { covers = math.floor(PAD2 / 2), text = PAD2 },
    [PAGER_BAR]     = { covers = PAD2,                 text = PAD2 + math.floor(PAD2 / 2) },
}

local function pagerGap(pager, has_text)
    return PAGER_GAPS[pager.style][has_text and "text" or "covers"]
end

-- Space a top indicator takes below the tab bar's own gap: its row and the
-- same gap under it, so it is centred between the tab bar and the grid box.
local function topPagerHeight(ctx, pager)
    if pager.position ~= POSITION_TOP then return 0 end
    return pagerRowHeight(ctx, pager) + TAB_BAR_GAP
end

local function pagerKey(pfx, inst_id, field)
    return pfx .. inst_id .. "_pager_" .. field
end

local function pagerStyle(pfx, inst_id)
    return Config.readChoice(pagerKey(pfx, inst_id, "style"), PAGER_STYLES, PAGER_NUMBERS)
end

local function pagerPosition(pfx, inst_id)
    return Config.readChoice(pagerKey(pfx, inst_id, "position"), PAGER_POSITIONS,
        DEFAULT_POSITION[pagerStyle(pfx, inst_id)])
end

-- Look of the page indicator: its style, and the position and alignment that
-- follow from it. The bar is always centred; `off` has neither.
local function pagerLook(pfx, inst_id)
    local style = pagerStyle(pfx, inst_id)
    if style == PAGER_OFF then return { style = style } end
    return {
        style    = style,
        position = pagerPosition(pfx, inst_id),
        align    = style == PAGER_BAR and "center"
                   or Config.getAlignment(pagerKey(pfx, inst_id, "align"), PAGER_ALIGNS, DEFAULT_ALIGN),
    }
end

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------

-- Centred text filling a w x h area.
local function buildNotice(w, h, text)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        UI.makeColoredText{
            text  = text,
            face  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY),
            width = w - PAD * 2,
        },
    }
end

-- Notice shown in place of the grid of `tab` while it has nothing to list.
local function emptyTabNotice(w, h, tab)
    return buildNotice(w, h, Sources.isGroupSource(tab.source)
        and _("No groups in this tab") or _("No books in this tab"))
end

-- Page indicator `pager` aligned in a `w` wide row (the chevron icon, not its
-- padding, meets the right edge); an empty row of the same height while there
-- is a single page. The page chevrons are D-pad focus stops.
-- `ink` is set only over a tinted fill (see ModuleChrome.ink).
local function buildPager(w, ctx, inst_id, pager, ink)
    local page, npages = PageState.get(ctx, inst_id)
    local row_h = pagerRowHeight(ctx, pager)
    local stops = {}
    local indicator
    if npages > 1 and pager.style == PAGER_BAR then
        indicator = PageNav.buildProgressBar(page, npages, Screen:scaleBySize(PROGRESS_BAR_W), row_h, ink)
    elseif npages > 1 then
        indicator, stops = PageNav.buildPager(page, npages, row_h,
            UI.makeColoredText{
                text = string.format("%d/%d", page, npages),
                face = pagerFace(ctx),
                bold = false,
                fgcolor = ink and ink.blk,
            },
            PAD2,
            function(delta) GridRenderer.requestPageTurn(ctx, inst_id, delta) end,
            ctx.kbStops ~= nil, ink)
    end
    if ctx.kbStops then ctx.kbStops(inst_id .. ":pager", stops) end
    if not indicator then return VerticalSpan:new{ width = row_h } end
    local overhang = pager.align == "right" and Size.padding.button or 0
    return ALIGN_CONTAINER[pager.align]:new{
        dimen = Geom:new{ w = w + overhang, h = row_h },
        indicator,
    }
end

-- Page indicator between the tab bar and the grid box, lined up with the grid
-- content and followed by the gap that separates it from the box.
local function buildTopPager(col_w, grid_w, ctx, inst_id, pager)
    return VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = math.floor((col_w - grid_w) / 2) },
            buildPager(grid_w, ctx, inst_id, pager),
        },
        VerticalSpan:new{ width = TAB_BAR_GAP },
    }
end

-- Module surface: the bare wallpaper restored under `content`, so content of
-- a previous tab or page never shows through a partial repaint. Each box
-- paints its own backdrop on top.
local function compose(w, h, ctx, inst_id, content)
    return OverlapGroup:new{
        allow_mirroring = false,
        dimen           = Geom:new{ w = w, h = h },
        GridRenderer.makeEraser(w, h, ModuleChrome.NO_CHROME),
        content,
    }
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

-- Pagination submenu: style, position and, for the page numbers,
-- alignment. Position and alignment apply only where they have an effect.
local function pagerMenuItem(inst_id, ctx_menu)
    local _lc     = ctx_menu._
    local refresh = ctx_menu.refresh
    local pfx     = ctx_menu.pfx
    local function setter(field)
        return function(v) SUISettings:saveSetting(pagerKey(pfx, inst_id, field), v) end
    end
    return {
        text      = _lc("Pagination"),
        sub_item_table = {
            Config.makeRadioSubmenuItem{
                text    = _lc("Style"),
                options = {
                    { value = PAGER_NUMBERS, label = _lc("Numbers") },
                    { value = PAGER_BAR,     label = _lc("Swipe Bar") },
                    { value = PAGER_OFF,     label = _lc("Hidden") },
                },
                get     = function() return pagerStyle(pfx, inst_id) end,
                set     = setter("style"),
                refresh = refresh,
            },
            Config.makeRadioSubmenuItem{
                text         = _lc("Position"),
                options      = {
                    { value = POSITION_TOP,    label = _lc("Top") },
                    { value = POSITION_BOTTOM, label = _lc("Bottom") },
                },
                get          = function() return pagerPosition(pfx, inst_id) end,
                set          = setter("position"),
                enabled_func = function() return pagerStyle(pfx, inst_id) ~= PAGER_OFF end,
                refresh      = refresh,
            },
            Config.makeAlignmentItem{
                key          = pagerKey(pfx, inst_id, "align"),
                values       = PAGER_ALIGNS,
                default      = DEFAULT_ALIGN,
                enabled_func = function() return pagerStyle(pfx, inst_id) == PAGER_NUMBERS end,
                refresh      = refresh,
                _lc          = _lc,
            },
        },
    }
end

-- Tab Bar submenu: style, text and background. The tabs style has neither
-- frame nor background, so that entry is disabled while it is selected.
local function tabBarMenuItem(inst_id, ctx_menu)
    local _lc     = ctx_menu._
    local refresh = ctx_menu.refresh
    local pfx     = ctx_menu.pfx

    local background = ModuleChrome.makeBackgroundItem(pfx, barId(inst_id), refresh, _lc, BAR_KIND)
    background.enabled_func = function() return tabStyle(pfx, inst_id) ~= STYLE_TABS end

    return {
        text      = _lc("Tab Bar"),
        sub_item_table = {
            Config.makeRadioSubmenuItem{
                text    = _lc("Style"),
                options = {
                    { value = STYLE_ROUND,  label = _lc("Round Pill") },
                    { value = STYLE_SQUARE, label = _lc("Square Pill") },
                    { value = STYLE_TABS,   label = _lc("Tabs") },
                },
                get     = function() return tabStyle(pfx, inst_id) end,
                set     = function(v) SUISettings:saveSetting(styleKey(pfx, inst_id), v) end,
                refresh = refresh,
            },
            Config.makeRadioSubmenuItem{
                text    = _lc("Active Tab Color"),
                options = function()
                    local options = {
                        { value = nil,                  label = _lc("Default") },
                        { value = Backdrop.TONE.WHITE,  label = _lc("White") },
                        { value = Backdrop.TONE.GRAY,   label = _lc("Gray") },
                    }
                    for _i, option in ipairs(SUIStyle.paletteOptions(_lc)) do
                        options[#options + 1] = option
                    end
                    return options
                end,
                get     = function() return activeTone(pfx, inst_id) end,
                set     = function(v)
                    if v == nil then
                        SUISettings:del(activeKey(pfx, inst_id))
                    else
                        SUISettings:saveSetting(activeKey(pfx, inst_id), v)
                    end
                end,
                refresh = refresh,
            },
            Config.makeTextStyleItem{
                mod_id  = inst_id,
                elem    = TAB_TEXT_ELEM,
                title   = _lc("Text"),
                info    = _lc("Size of the tab labels.\n100% matches the homescreen section labels."),
                pfx     = pfx,
                refresh = refresh,
                _lc     = _lc,
            },
            background,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Instance factory
-- ---------------------------------------------------------------------------
local function makeInstance(inst_id)
    local store     = tabStore(inst_id)
    local cache_key = "_tab_grid_fps_" .. inst_id

    -- State of this instance within a ctx, lost together with the ctx:
    --   signature  identity of the tab the grid was last built for
    --   tab        the active tab of the last build
    --   params     the source params of that tab, options included
    --   first      position of the tab window
    local function instState(ctx)
        local all = ctx._tab_grid
        if not all then
            all = {}
            ctx._tab_grid = all
        end
        local state = all[inst_id]
        if not state then
            state = {}
            all[inst_id] = state
        end
        return state
    end

    local function repaint(ctx)
        GridRenderer.requestRepaint(ctx, inst_id)
    end

    -- Params a tab hands to its source: its content plus the values of the
    -- options of the source.
    local function sourceParams(pfx, tab)
        return Sources.withOptions(tab.source, tab.params, function(key)
            return store.option(pfx, tab.id, key)
        end)
    end

    -- Makes the stored selection the active tab of this build and returns it.
    -- When it differs from the tab last built, what belongs to the previous
    -- one (cached book list, page) is reset; the tab window stays where it is
    -- and moves only as far as needed to show the new tab.
    local function selectActiveTab(ctx, pfx, tabs)
        local active, active_index = store.activeTab(pfx, tabs)
        local state     = instState(ctx)
        local signature = tabSignature(active)
        state.tab    = active
        state.params = sourceParams(pfx, active)
        if state.signature == signature then return active end

        state.signature = signature
        ctx[cache_key] = nil
        PageState.setPage(ctx, inst_id, 1)
        if state.first then
            state.first = TabWindow.reveal(state.first, active_index, #tabs, VISIBLE_TABS)
        end
        return active
    end

    -- Returns the grid of the active tab to its first page.
    local function showFirstPage(ctx)
        local page = PageState.get(ctx, inst_id)
        if page > 1 then GridRenderer.requestPageTurn(ctx, inst_id, 1 - page) end
    end

    local function buildTabBar(col_w, ctx, tabs, active, layout)
        local state   = instState(ctx)
        local pfx     = layout.pfx
        local bar     = layout.bar
        local entries = {}
        for _i, tab in ipairs(tabs) do
            entries[#entries + 1] = { id = tab.id, label = tabLabel(tab) }
        end
        local strip = TabStrip.new{
            width         = columnWidth(col_w),
            height        = layout.strip_h,
            face          = layout.face,
            tabs          = entries,
            style         = bar.style,
            visible_count = VISIBLE_TABS,
            radius        = bar.shape == STYLE_SQUARE and ModuleChrome.frameRadius(layout.scale) or nil,
            surface       = bar.surface,
            indicator     = bar.indicator,
            fgcolor       = bar.surface.foreground,
            active        = active.id,
            first         = state.first,
            on_select     = function(id)
                if id == active.id then
                    showFirstPage(ctx)
                    return
                end
                store.setActive(pfx, id)
                repaint(ctx)
            end,
            on_scroll     = function(first)
                state.first = first
                repaint(ctx)
            end,
        }
        if ctx.kbStops then ctx.kbStops(inst_id .. ":tabs", strip:getStops()) end
        return FrameContainer:new{
            bordersize     = 0,
            padding        = 0,
            padding_bottom = TAB_BAR_GAP,
            ModuleChrome.inset(strip, col_w, layout.scale),
        }
    end

    -- Group cells of the group tabs. Their description comes from the source
    -- of the tab the grid is built for.
    local group_settings = GroupCell.makeSettings{
        keyFor        = function(pfx, field) return pfx .. inst_id .. "_group_" .. field end,
        default_style = "auto",
    }
    local group_cell = GroupCell.new{
        owner_id = inst_id,
        settings = group_settings,
        describe = function(item, ctx)
            local state = instState(ctx)
            return Sources.describe(state.tab.source, item, ctx, state.params)
        end,
    }

    -- Settings of a tab: the rows of its source. Nil when there is nothing to
    -- configure.
    local function tabSettings(ctx_menu, tab)
        if not SourceMenu.hasItems(tab.source) then return nil end
        local pfx = ctx_menu.pfx
        return function()
            return SourceMenu.makeItems(ctx_menu, tab.source, tab.params, {
                get = function(key) return store.option(pfx, tab.id, key) end,
                set = function(key, value) store.setOption(pfx, tab.id, key, value) end,
            })
        end
    end

    -- Tabs the user can still add: a source without parameters is offered
    -- until its tab exists, a parameterised source offers the choices that
    -- have no tab yet, under the source or directly when it has inline
    -- choices, and is left out once none remains. Unavailable sources
    -- are not offered.
    local function addChoices(pfx)
        local taken, nodes = store.contentKeys(pfx), {}

        local function choiceLeaves(source_id)
            local leaves = {}
            for _j, choice in ipairs(Sources.choices(source_id)) do
                if not taken[contentKey(source_id, choice.params)] then
                    leaves[#leaves + 1] = {
                        title = choice.label,
                        value = { source = source_id, params = choice.params },
                    }
                end
            end
            return leaves
        end

        for _i, source_id in ipairs(Sources.list()) do
            if Sources.isAvailable(source_id) then
                if Sources.hasInlineChoices(source_id) then
                    for _j, leaf in ipairs(choiceLeaves(source_id)) do nodes[#nodes + 1] = leaf end
                elseif Sources.choices(source_id) then
                    nodes[#nodes + 1] = {
                        title    = Sources.label(source_id),
                        children = function() return choiceLeaves(source_id) end,
                    }
                elseif not taken[contentKey(source_id, nil)] then
                    nodes[#nodes + 1] = {
                        title = Sources.tabLabel(source_id),
                        value = { source = source_id, params = {} },
                    }
                end
            end
        end
        return nodes
    end

    -- Tabs row, prepended to the generic items generated by makeModule: the
    -- list of tabs with its add button.
    local function tabsMenuItems(ctx_menu)
        local _lc = ctx_menu._
        local pfx = ctx_menu.pfx
        return {
            Arrange.makeMenuItem{
                ctx_menu = ctx_menu,
                title    = _lc("Tabs"),
                labels   = {
                    action  = _lc("Arrange Tabs"),
                    header  = _lc("Tabs"),
                    empty   = _lc("No tabs."),
                    too_few = _lc("Add at least 2 tabs to arrange."),
                    add     = _lc("Add Tab"),
                },
                getEntries = function()
                    local entries = {}
                    for _i, tab in ipairs(store.read(pfx)) do
                        entries[#entries + 1] = {
                            value    = tab.id,
                            title    = tabLabel(tab),
                            settings = tabSettings(ctx_menu, tab),
                        }
                    end
                    return entries
                end,
                saveOrder   = function(ids) store.reorder(pfx, ids) end,
                removeEntry = function(id) store.remove(pfx, id) end,
                add = {
                    choices = function() return addChoices(pfx) end,
                    onAdd   = function(pick) store.add(pfx, pick.source, pick.params) end,
                },
            },
        }
    end

    -- Cell kind of a tab: the group cell for a group source, nil for books.
    local function cellOf(tab)
        return Sources.isGroupSource(tab.source) and group_cell or nil
    end

    -- True when the cells of `tab` end in a line of text: the group name of a
    -- group tab, the progress text of a book tab.
    local function hasTextBelow(pfx, tab)
        local cell = cellOf(tab)
        if cell then return cell.hasTextBelow(pfx) end
        return GridRenderer.progressDrawsText(GridRenderer.getProgressStyle(pfx, inst_id, PROGRESS_STYLE))
    end

    -- Space a bottom indicator takes under the tallest grid: its row and the
    -- largest gap any of the `tabs` asks for.
    local function bottomPagerHeight(ctx, tabs, pager)
        if pager.position ~= POSITION_BOTTOM then return 0 end
        local pfx, has_text = pfxOf(ctx), false
        for _i, tab in ipairs(tabs) do
            if hasTextBelow(pfx, tab) then
                has_text = true
                break
            end
        end
        return pagerGap(pager, has_text) + pagerRowHeight(ctx, pager)
    end

    -- Group Covers submenu: cover style, book stack, count badge and name
    -- label, shared by every group tab.
    local function groupCoversMenuItem(ctx_menu)
        return {
            text           = ctx_menu._("Group Covers"),
            sub_item_table = GroupCell.makeMenuItems(ctx_menu, group_settings),
        }
    end

    local mod = GridRenderer.makeModule{
        id          = inst_id,
        name        = _("Tabbed Grid"),
        text_elems  = TEXT_ELEMS,
        text_label  = _("Text"),
        default_on  = false,
        is_book_mod = true,   -- needed for the surgical repaint of tab and page changes
        max_items   = GRID_COLS,
        paged       = true,
        cache_key   = cache_key,

        -- Tabs that read the reading history ask for it to be prefetched.
        needs = { recent = function(pfx) return recentDemand(store.read(pfx)) end },

        -- The source of the tab selected by the build in progress.
        getSource = function(ctx)
            local state  = instState(ctx)
            local params = state.params
            local source = Sources.bind(state.tab.source, function() return params end)
            source.cell = cellOf(state.tab)
            return source
        end,
        -- The cells of every tab, for the height of the grid. The tabs being
        -- measured arrive with the ctx; they are read when it carries none.
        getSources = function(ctx)
            local sources = {}
            local tabs = ctx and ctx.measured_tabs or store.read(pfxOf(ctx))
            for _i, tab in ipairs(tabs) do
                sources[#sources + 1] = { cell = cellOf(tab) }
            end
            return sources
        end,
        extra_menu_items_before = tabsMenuItems,
        extra_appearance_items  = function(ctx_menu)
            return {
                tabBarMenuItem(inst_id, ctx_menu),
                pagerMenuItem(inst_id, ctx_menu),
                groupCoversMenuItem(ctx_menu),
            }
        end,

        badges         = { pages = "off", series = "off", new = "off" },
        progress_style = PROGRESS_STYLE,

        grid         = true,
        default_rows = GRID_ROWS,
        default_cols = GRID_COLS,

        reset = function() GridRenderer.reset() end,
    }

    mod.owns_chrome = true

    local buildGrid        = mod.build
    local updateGridStats  = mod.updateStats
    local updateGridCovers = mod.updateCovers
    local coverGridHeight  = mod.getGridHeight

    -- Height of the cover grid of `tabs`. The cover size follows the width of
    -- the grid box, so the height is measured for that width rather than the
    -- column's.
    local function gridHeight(ctx, chrome, tabs)
        local box_ctx = setmetatable({
            col_w         = ctx.col_w and ModuleChrome.contentWidth(ctx.col_w, chrome),
            measured_tabs = tabs,
        }, { __index = ctx })
        return coverGridHeight(box_ctx)
    end

    -- Every measure of the module for `tabs`, computed once and shared by the
    -- height and the build. The module height is the same for every tab and
    -- page: the tab bar and the pager row are always reserved.
    local function measure(ctx, tabs)
        local pfx    = pfxOf(ctx)
        local chrome = ModuleChrome.resolve(pfx, inst_id)
        local bar    = barLook(pfx, inst_id)
        local pager  = pagerLook(pfx, inst_id)
        local face   = tabFace(ctx, inst_id)
        local layout = {
            pfx      = pfx,
            scale    = GridRenderer.landscapeFactor(ctx),
            chrome   = chrome,
            bar      = bar,
            pager    = pager,
            face     = face,
            strip_h  = TabStrip.height(bar.style, face, bar.surface),
            grid_h   = gridHeight(ctx, chrome, tabs),
            bottom_h = bottomPagerHeight(ctx, tabs, pager),
        }
        layout.total = layout.strip_h + TAB_BAR_GAP + topPagerHeight(ctx, pager)
            + layout.grid_h + layout.bottom_h + ModuleChrome.boxInset(chrome)
        return layout
    end

    function mod.getHeight(ctx)
        return measure(ctx, store.read(pfxOf(ctx))).total
    end

    -- `col_w` is the full column width: the module insets its own boxes.
    function mod.build(col_w, ctx)
        local pfx    = pfxOf(ctx)
        local tabs   = store.read(pfx)
        local layout = measure(ctx, tabs)

        if #tabs == 0 then
            -- A tab added later starts from a clean state.
            instState(ctx).signature = nil
            local hold_on = SUISettings:nilOrTrue(pfx .. "settings_on_hold")
            return compose(col_w, layout.total, ctx, inst_id, buildNotice(col_w, layout.total,
                hold_on and _("No tabs  —  long press to configure") or _("No tabs")))
        end

        local active  = selectActiveTab(ctx, pfx, tabs)
        local pager   = layout.pager
        local grid_w  = ModuleChrome.contentWidth(col_w, layout.chrome)
        -- The rows of D-pad stops follow the visual order: tab bar, top
        -- pager (built after the grid, which sets the page count), grid
        -- rows, bottom pager.
        local tab_bar = buildTabBar(col_w, ctx, tabs, active, layout)
        if ctx.kbStops and pager.position == POSITION_TOP then ctx.kbStops(inst_id .. ":pager", {}) end
        -- The grid cells and the pager inside the box take the box's ink.
        local ink     = ModuleChrome.ink(layout.chrome)
        ctx.ink       = ink
        local pager_ink = ink ~= ModuleChrome.PLAIN_INK and ink or nil
        local grid    = buildGrid(grid_w, ctx)
        local content = grid or emptyTabNotice(grid_w, layout.grid_h, active)
        local body    = VerticalGroup:new{ align = "left", content }
        local used    = content:getSize().h
        if pager.position == POSITION_BOTTOM then
            -- The pager follows the content of the active tab.
            local gap = pagerGap(pager, hasTextBelow(pfx, active))
            body[#body + 1] = VerticalSpan:new{ width = gap }
            body[#body + 1] = buildPager(grid_w, ctx, inst_id, pager, pager_ink)
            used = used + gap + pagerRowHeight(ctx, pager)
        end
        local column = VerticalGroup:new{ align = "left", tab_bar }
        if pager.position == POSITION_TOP then
            column[#column + 1] = buildTopPager(col_w, grid_w, ctx, inst_id, pager)
        end
        column[#column + 1] = ModuleChrome.wrap(body, layout.chrome, col_w, layout.scale)
        -- What the tallest tab needs beyond the active one stays under the box.
        column[#column + 1] = VerticalSpan:new{
            width = math.max(0, layout.grid_h + layout.bottom_h - used),
        }
        local widget = compose(col_w, layout.total, ctx, inst_id, column)
        -- The grid is the widget the cover and stats updaters operate on.
        widget._grid = grid
        return widget
    end

    function mod.updateCovers(widget, ctx)
        return updateGridCovers(widget._grid, ctx)
    end

    -- A patch in place cannot move the pager: when the page count changed the
    -- module is rebuilt instead.
    function mod.updateStats(widget, ctx)
        if not widget._grid then return false end
        local _page, npages = PageState.get(ctx, inst_id)
        if not updateGridStats(widget._grid, ctx) then return false end
        local _new_page, new_npages = PageState.get(ctx, inst_id)
        return new_npages == npages
    end

    return mod
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------
local M = {}
M.id               = "tab_grid"
M.name             = _("Tabbed Grid")
M.instanciable     = true
M.instances_key    = "simpleui_tab_grid_instances"
M.setting_suffixes = {
    "_tabs", "_active_tab", "_tab_options", "_tab_style",
    "_pager_style", "_pager_position", "_pager_align", "_tabbar_show_frame", "_tabbar_backdrop", "_tabbar_tone",
    "_group_cover_style", "_group_hide_pile", "_group_badge_position",
    "_group_badge_color", "_group_badge_hidden", "_group_badge_scale", "_group_label",
}
M.text_elems       = TEXT_ELEMS
M.makeInstance     = makeInstance

-- Layout-editor summary of an instance: its tabs.
function M.getSummary(inst_id, pfx)
    local titles = {}
    for _i, tab in ipairs(tabStore(inst_id).read(pfx)) do
        titles[#titles + 1] = tabLabel(tab)
    end
    if #titles == 0 then return _("No tabs") end
    return table.concat(titles, "  ·  ")
end

return M
