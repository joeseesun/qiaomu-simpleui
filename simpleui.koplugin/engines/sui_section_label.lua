-- sui_section_label.lua — Simple UI
-- Single owner of a module's section label (the title row above a module):
--   • descriptor — what the label shows: text, right-aligned text, page state
--   • PageState  — per-module pagination state stored in the screen ctx
--   • rendering  — label widget construction and a per-screen widget cache
--   • height     — vertical space the label reserves
--
-- Descriptor: { text, right_text, page, npages }. A module supplies it through
-- an optional M.getLabel(ctx); without one it is derived from M.label and
-- M.label_right_func (see M.describe). A nil descriptor means "no label"
-- (the module declares none, or the user hid it).
--
-- Widgets reference nothing but the descriptor and the callbacks handed to
-- M.get, so a cache owned by one screen instance never outlives the callbacks
-- it holds.
--
-- A label is drawn either above its module's box (the default of M.get) or
-- inside it: `inside` then drops the lateral padding, since the box already
-- insets its content, and may carry the `ink` of a tinted fill.

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LeftContainer   = require("ui/widget/container/leftcontainer")

local Config     = require("infra/sui_config")
local LabelStyle = require("features/sui_label_style")
local PageNav    = require("engines/sui_page_nav")
local UI         = require("infra/sui_core")

local PAD = UI.PAD

local M = {}

-- ---------------------------------------------------------------------------
-- Pagination state
-- ---------------------------------------------------------------------------

-- Page and page count per module id, stored in the screen ctx so it lives as
-- long as that ctx does. A module that was never paged reads as 1 of 1.
local PageState = {}
M.PageState = PageState

local function pageEntry(ctx, id)
    local pages = ctx._pages
    if not pages then
        pages = {}
        ctx._pages = pages
    end
    local entry = pages[id]
    if not entry then
        entry = { page = 1, npages = 1 }
        pages[id] = entry
    end
    return entry
end

-- Returns page, npages.
function PageState.get(ctx, id)
    local entry = ctx and ctx._pages and ctx._pages[id]
    if not entry then return 1, 1 end
    return entry.page, entry.npages
end

function PageState.setPage(ctx, id, page)
    pageEntry(ctx, id).page = page
end

function PageState.setCount(ctx, id, npages)
    pageEntry(ctx, id).npages = npages
end

-- ---------------------------------------------------------------------------
-- Descriptor
-- ---------------------------------------------------------------------------

-- Builds the descriptor for module `id`. Returns nil when `text` is nil or
-- the user hid the label. `right_text` defaults to the "page/npages"
-- indicator when the module has more than one page.
function M.makeDescriptor(id, text, ctx, right_text)
    if not text or Config.isLabelHidden(id) then return nil end
    local page, npages = PageState.get(ctx, id)
    if not right_text and npages > 1 then
        right_text = string.format("%d/%d", page, npages)
    end
    return { text = text, right_text = right_text, page = page, npages = npages }
end

-- Descriptor for `mod`: its own getLabel(ctx) when defined, otherwise derived
-- from the declared M.label and optional M.label_right_func(ctx).
function M.describe(mod, ctx)
    if type(mod.getLabel) == "function" then return mod.getLabel(ctx) end
    local right_text = type(mod.label_right_func) == "function" and mod.label_right_func(ctx) or nil
    return M.makeDescriptor(mod.id, mod.label, ctx, right_text)
end

-- ---------------------------------------------------------------------------
-- Height
-- ---------------------------------------------------------------------------

-- Vertical space reserved for the label of module `id`: 0 when hidden.
function M.height(id, landscape_factor)
    if Config.isLabelHidden(id) then return 0 end
    return Config.getScaledLabelH(landscape_factor)
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- Title row with the right-aligned text and, when `turn_page` is given,
-- chevrons on both sides of it. All three share one row height so they
-- centre on a single line. Returns the row and the D-pad focus stops of the
-- chevrons (see PageNav.buildPager), empty when `focusable` is not set.
-- `inside` carries the ink of a tinted surface (see ModuleChrome.ink) and the
-- palette colours that read on it.
local function buildTitleRow(desc, avail_w, scale, turn_page, focusable, inside)
    local ink = inside and inside.ink or nil
    local fg = ink and ink.blk or nil
    local title_fg = LabelStyle.color(inside) or fg
    local face_right = PageNav.indicatorFace(scale)
    local right_widget = UI.makeColoredText{ text = desc.right_text, face = face_right, bold = false, fgcolor = fg }
    local title_widget = LabelStyle.makeText{
        text = desc.text, fgcolor = title_fg, scale = scale,
        max_width = math.max(1, avail_w - right_widget:getSize().w - PAD),
    }
    local row_h = math.max(title_widget:getSize().h, right_widget:getSize().h)
    local gap   = PAD

    local right
    local stops = {}
    if turn_page then
        right, stops = PageNav.buildPager(desc.page, desc.npages, row_h, right_widget, gap, turn_page, focusable, ink)
    else
        right = CenterContainer:new{
            dimen = Geom:new{ w = right_widget:getSize().w, h = row_h },
            right_widget,
        }
    end

    -- The title gets a real-width slot so the right side stays at the row's
    -- right edge (a TextWidget only reports its glyph width).
    local row = HorizontalGroup:new{ align = "center" }
    row[#row + 1] = LeftContainer:new{
        dimen = Geom:new{ w = math.max(1, avail_w - right:getSize().w - gap), h = row_h },
        title_widget,
    }
    row[#row + 1] = HorizontalSpan:new{ width = gap }
    row[#row + 1] = right
    return row, stops
end

local function buildWidget(desc, w, scale, turn_page, focusable, inside)
    local side    = inside and 0 or PAD
    local ink     = inside and inside.ink or nil
    local avail_w = w - side * 2
    local content
    local stops = {}
    if desc.right_text then
        content, stops = buildTitleRow(desc, avail_w, scale, desc.npages > 1 and turn_page or nil, focusable, inside)
    else
        content = LabelStyle.makeText{
            text = desc.text, scale = scale, max_width = avail_w,
            fgcolor = LabelStyle.color(inside) or (ink and ink.blk or nil),
        }
    end
    return FrameContainer:new{
        bordersize = 0, padding = 0,
        padding_left = side, padding_right = side,
        -- The caps style leaves a little more room before the content.
        padding_bottom = UI.LABEL_PAD_BOT + LabelStyle.extraGap(scale),
        content,
    }, stops
end

-- Returns the label widget for module `id`, reusing the one in `cache` while
-- everything it shows is unchanged (same widget identity = nothing to
-- repaint). `cache` is a table owned by one screen instance.
--   desc             descriptor (see M.describe)
--   w                column width the label spans
--   landscape_factor label scale multiplier (default 1)
--   turn_page        function(id, delta) invoked by the chevrons
--   focusable        the chevrons are D-pad focus stops
--   inside           nil for a label above the module's box; a table for one
--                    inside it: { ink = colours of a tinted fill | nil,
--                    palette = ModuleChrome.palette of the box | nil }
-- Returns the widget and its focus stops, { id, widget } from left to right.
function M.get(cache, id, desc, w, landscape_factor, turn_page, focusable, inside)
    local scale  = Config.getLabelScale() * (landscape_factor or 1)
    local paged  = desc.right_text ~= nil and desc.npages > 1
    local ink    = inside and inside.ink
    local key = table.concat({
        desc.text, w, scale, desc.right_text or "",
        paged and desc.page or 0, paged and desc.npages or 0,
        inside and 1 or 0, ink and tostring(ink.blk) or "",
        tostring(LabelStyle.color(inside)),
        LabelStyle.signature(),
    }, "|")

    local entry = cache[id]
    if entry and entry.key == key then return entry.widget, entry.stops end

    local nav = paged and turn_page and function(delta) turn_page(id, delta) end or nil
    local widget, stops = buildWidget(desc, w, scale, nav, focusable, inside)

    -- A cached label is mounted in one tree after another, and a replaced tree
    -- is freed: a freed label would draw nothing. The tree's free is ignored;
    -- M.release frees the label together with the cache.
    local free = widget.free
    widget.free = function() end
    cache[id] = { key = key, widget = widget, stops = stops, release = function() free(widget) end }
    return widget, stops
end

-- Frees every widget of `cache` and empties it; to be called once the screen
-- that owns the cache is closed.
function M.release(cache)
    for id, entry in pairs(cache) do
        entry.release()
        cache[id] = nil
    end
end

return M
