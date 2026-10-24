-- sui_page_nav.lua — Simple UI
-- Page-turn controls shared by every surface that paginates inline (section
-- labels, tab bars, bottom pagers): the chevrons, the pager row, the progress
-- bar, the indicator metrics and the swipe direction.
--
-- Chevron buttons are built as a pair so both share one geometry: `prev` is
-- dimmed and inert on the first page, `next` on the last, unless the caller
-- asks for the unavailable one to be left out. The chevrons are symbol-font
-- glyphs, so they blend with whatever surface they sit on. buildPager adds
-- the indicator text between them. buildProgressBar draws the current page
-- as a read-only bar.

local BD              = require("ui/bidi")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font            = require("ui/font")
local GestureRange    = require("ui/gesturerange")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Screen          = require("device").screen
local Size            = require("ui/size")
local Widget          = require("ui/widget/widget")

local AAPaint  = require("infra/sui_aa_paint")
local SUIStyle = require("features/sui_style")
local UI       = require("infra/sui_core")

local M = {}

-- Size of the chevron glyphs (base pixels, scaled at use time).
M.ICON_SIZE = 16

-- Face of the page indicator text: the detail size of a section label's right
-- text, at `scale`.
function M.indicatorFace(scale)
    return Font:getFace(SUIStyle.FACE_REGULAR, math.max(8, math.floor(SUIStyle.FS_DETAIL * scale)))
end

-- Height of a pager row whose indicator text uses `face`: the taller of the
-- text and the chevron glyphs.
function M.rowHeight(face)
    return math.max(SUIStyle.faceHeight(face), Screen:scaleBySize(M.ICON_SIZE))
end

-- Page turn that the horizontal swipe `ges` asks for: 1 for the next page, -1
-- for the previous one (reversed in a mirrored layout), nil for any other
-- direction.
function M.swipeDelta(ges)
    local dir = ges.direction
    if BD.mirroredUILayout() then
        if dir == "west" then dir = "east" elseif dir == "east" then dir = "west" end
    end
    if dir == "west" then return 1 end
    if dir == "east" then return -1 end
end

-- Chevron `glyph` in a `w` x `h` tap area, dimmed and inert unless `enabled`;
-- a tap is acknowledged with the standard inversion flash. `ink`, when given,
-- colours it for a tinted surface (see ModuleChrome.ink).
local function buildChevron(glyph, enabled, glyph_px, w, h, on_tap, focusable, ink)
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            UI.makeColoredText{
                text    = glyph,
                face    = SUIStyle.glyphFace(glyph_px),
                fgcolor = enabled and ink and ink.blk
                    or not enabled and (ink and ink.bar_bg or SUIStyle.COLOR.disabled)
                    or nil,
                padding = 0,
            },
        },
    }
    if enabled then
        tappable.ges_events = {
            TapPageNav = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
        }
        function tappable:onTapPageNav()
            UI.runWithTapFeedback(self, on_tap)
            return true
        end
        if focusable then UI.makeFocusable(tappable, tappable.onTapPageNav) end
    end
    return tappable
end

-- Builds the chevron pair for a row `row_h` pixels tall.
--   page, npages   current page and page count (1-based)
--   row_h          height of the row the buttons sit in; each button is
--                  padded vertically up to that height, never below the
--                  standard button padding
--   turn_page      function(delta) called on tap with -1 or 1
--   opts           optional table:
--     h_pad          horizontal padding on each side of the glyph, to widen
--                    the tap zone (default: standard button padding)
--     hide_disabled  a button that cannot turn the page is returned as nil
--                    instead of dimmed
--     focusable      an enabled button is also a D-pad focus stop (see
--                    UI.makeFocusable)
--     ink            colours of a tinted surface (see ModuleChrome.ink)
-- Returns prev_button, next_button.
function M.buildButtons(page, npages, row_h, turn_page, opts)
    opts = opts or {}
    local glyph_px = Screen:scaleBySize(M.ICON_SIZE)
    local w = glyph_px + 2 * (opts.h_pad or Size.padding.button)
    local h = glyph_px + 2 * math.max(Size.padding.button, math.floor((row_h - glyph_px) / 2))
    local function make(glyph, enabled, delta)
        if not enabled and opts.hide_disabled then return nil end
        return buildChevron(glyph, enabled, glyph_px, w, h, function() turn_page(delta) end, opts.focusable, opts.ink)
    end
    return make(SUIStyle.icon("chevron_left"), page > 1, -1),
           make(SUIStyle.icon("chevron"), page < npages, 1)
end

-- Builds a pager row: prev chevron, `text_widget` (the page indicator), next
-- chevron. Takes the buildButtons arguments, plus
--   text_widget    widget shown between the chevrons
--   gap            space between the chevrons and the text
--   focusable      the chevrons that can turn the page are D-pad focus stops
--   ink            colours of a tinted surface (see ModuleChrome.ink)
-- Returns a HorizontalGroup `row_h` tall and the list of its focus stops,
-- { id, widget } from left to right (empty unless `focusable`).
function M.buildPager(page, npages, row_h, text_widget, gap, turn_page, focusable, ink)
    local prev_btn, next_btn = M.buildButtons(page, npages, row_h, turn_page, { focusable = focusable, ink = ink })
    local stops = {}
    if focusable then
        if page > 1 then stops[#stops + 1] = { id = "prev", widget = prev_btn } end
        if page < npages then stops[#stops + 1] = { id = "next", widget = next_btn } end
    end
    return HorizontalGroup:new{
        align = "center",
        prev_btn,
        HorizontalSpan:new{ width = gap },
        CenterContainer:new{
            dimen = Geom:new{ w = text_widget:getSize().w, h = row_h },
            text_widget,
        },
        HorizontalSpan:new{ width = gap },
        next_btn,
    }, stops
end

-- ---------------------------------------------------------------------------
-- Progress bar
-- ---------------------------------------------------------------------------

-- Pill track with a pill filled from the left up to `fraction` of its width.
-- The fill is never narrower than the bar is tall, so it stays a full pill.
local ProgressBar = Widget:extend{
    width    = 0,
    height   = 0,
    fraction = 0,
    ink      = nil, -- colours of a tinted surface (see ModuleChrome.ink)
}

function ProgressBar:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function ProgressBar:getSize()
    return self.dimen
end

function ProgressBar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local fill_w = math.min(self.width, math.max(self.height, math.floor(self.width * self.fraction + 0.5)))
    local ink = self.ink
    AAPaint.fillPill(bb, x, y, self.width, self.height, ink and ink.bar_bg or SUIStyle.COLOR.track, 255)
    AAPaint.fillPill(bb, x, y, fill_w, self.height, ink and ink.bar_fg or SUIStyle.COLOR.text_primary, 255)
end

-- Builds a `w` x `h` bar showing page `page` of `npages` (1-based): full on
-- the last page.
function M.buildProgressBar(page, npages, w, h, ink)
    return ProgressBar:new{ width = w, height = h, fraction = page / npages, ink = ink }
end

return M
