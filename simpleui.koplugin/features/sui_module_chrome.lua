-- Per-module chrome: a surface (tone, opacity and optional AA frame; see
-- infra/sui_backdrop.lua) behind the module (Appearance ▸ Background).
-- Always inset (aligned with section labels). Applied once by the homescreen.

local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")

local Accent = require("infra/sui_accent")
local Backdrop = require("infra/sui_backdrop")
local UI = require("infra/sui_core")
local SUIStyle = require("features/sui_style")
local SUIWallpaper = require("features/sui_wallpaper")

local M = {}
local PAD = UI.PAD
local _ = require("infra/sui_i18n").translate

-- Modules whose design is element-level (cards, buttons, empty space): the
-- module-wide card chrome does not apply. Match base ids and dynamic instances
-- (e.g. quick_actions_row_a1b2c3, spacer_row_..., reading_stats_...).
function M.skipsModuleChrome(id)
    if not id or id == "" then return false end
    if id:find("^reading_stats", 1, false) then return true end
    if id:find("^quick_actions_row", 1, false) then return true end
    if id:find("^spacer_row", 1, false) then return true end
    return false
end

-- Chrome of a surface drawn without any box: only the lateral inset applies.
M.NO_CHROME = { strength = 0, border_sz = 0 }

-- Descriptor of the surface of module `id` under `pfx`. `kind` names the
-- Backdrop.SURFACE_DEFAULT entry whose defaults apply; plain modules omit it.
function M.surface(pfx, id, kind)
    return Backdrop.surface(kind or "module", pfx .. id)
end

-- Opacity of a module surface. Over a wallpaper it is the stored one; without
-- one the tone decides: a coloured tone is solid and white is transparent,
-- which leaves the plain background.
function M.strength(surface, pfx, id, default_strength)
    if SUIWallpaper.isWallpaperActive() then
        return SUIWallpaper.getModuleBackdropStrength(pfx, id, default_strength)
    end
    return Backdrop.readTone(surface) ~= Backdrop.TONE.WHITE and Backdrop.STRENGTH_MAX
        or Backdrop.STRENGTH_MIN
end

-- Resolved chrome of a module: its surface (strength, tone, color, frame and
-- the frame's `border_sz` in pixels, 0 = no frame) plus `pfx` and `id`.
-- Modules that skip chrome resolve to neither fill nor frame. While the user
-- has chosen nothing, `kind` defaults apply; plain modules fall back to the
-- global module opacity.
function M.resolve(pfx, id, kind)
    pfx = pfx or "simpleui_hs_"
    id = id or ""
    if M.skipsModuleChrome(id) then
        return { strength = 0, border_sz = 0, pfx = pfx, id = id }
    end
    local surface = M.surface(pfx, id, kind)
    local default_strength = kind and surface.defaults.strength
    local chrome = Backdrop.resolve(surface, M.strength(surface, pfx, id, default_strength))
    chrome.pfx, chrome.id = pfx, id
    return chrome
end

-- Colours of the content drawn on a module: text (`blk` primary, `sub`
-- secondary; both the same ink) and, when set, the fill and track of
-- progress bars and rings (`bar_fg`, `bar_bg`; nil keeps the plain UI's).
M.PLAIN_INK = { blk = SUIStyle.COLOR.text_primary, sub = UI.CLR_TEXT_SUB }

-- Ink of a resolved chrome: over a tinted fill it follows the fill's
-- `foreground`, otherwise it is PLAIN_INK. Progress bars keep the accent
-- where it stands out from the fill, else they take the `foreground`.
function M.ink(chrome)
    if not (chrome and chrome.foreground) then return M.PLAIN_INK end
    local COLOR = SUIStyle.COLOR
    local blk = Backdrop.contentColors(chrome)
    return {
        blk = blk, sub = blk,
        bar_fg = Backdrop.accentOn(chrome) or blk,
        bar_bg = blk == COLOR.text_primary and COLOR.track or COLOR.text_dim,
    }
end

-- Palette colours that read on a resolved chrome, keyed by choice ("accent",
-- "secondary"); a colour that does not stand out from the fill is absent. Empty
-- (the shared NO_PALETTE) while no palette colour is on screen and for a chrome
-- without a surface (modules that skip it, see M.skipsModuleChrome).
M.NO_PALETTE = {}

function M.palette(chrome)
    if not (chrome and chrome.color and Accent.isEnabled()) then return M.NO_PALETTE end
    return {
        accent    = Backdrop.paletteOn(chrome, "accent"),
        secondary = Backdrop.paletteOn(chrome, "secondary"),
    }
end

function M.hasChrome(chrome)
    return chrome.strength > 0 or chrome.border_sz > 0
end

-- True when the surface paints a fill behind the module content.
function M.hasFill(chrome)
    return chrome.strength > 0
end

-- Lateral inset matching section labels (padding_left/right = PAD).
-- Always applied so module content lines up with labels whether or not
-- a visual card (fill/frame) is drawn.
function M.outerMargin(_chrome)
    return PAD
end

-- Space between the boxes of modules that share a bento row: the same as the
-- gap between the cards inside a module, so a row reads as one block.
M.GUTTER = Screen:scaleBySize(12)

function M.innerPad(chrome)
    return M.hasChrome(chrome) and PAD or 0
end

-- Size the box adds to its content on each axis: padding and border on both
-- sides.
function M.boxInset(chrome)
    return (M.innerPad(chrome) + chrome.border_sz) * 2
end

-- Corner radius of every module frame, at the given landscape factor.
function M.frameRadius(scale)
    return math.floor(Screen:scaleBySize(12) * (scale or 1))
end

function M.radius(chrome, scale)
    if not M.hasChrome(chrome) then return 0 end
    return M.frameRadius(scale)
end

function M.contentWidth(col_w, chrome)
    return math.max(1, col_w - M.outerMargin(chrome) * 2 - M.boxInset(chrome))
end

-- Space left of a box narrower than its column, for the given alignment.
local function leadingGap(free_w, align)
    if align == "right" then return free_w end
    if align == "center" then return math.floor(free_w / 2) end
    return 0
end

-- Grows the box of a widget returned by `wrap` to `box_h` pixels and centres
-- its body in the extra space; a smaller `box_h` restores the natural height.
-- Returns the resulting box height, or nil when the widget has no box.
function M.stretch(wrapped, box_h)
    local st = wrapped and wrapped._sui_box
    if not st then return nil end
    box_h = math.max(box_h or 0, st.natural_h)
    local extra = box_h - st.natural_h
    local body = st.body
    if extra > 0 then
        local sz = body:getSize()
        st.parent[st.index] = CenterContainer:new{
            dimen = Geom:new{ w = sz.w, h = sz.h + extra },
            body,
        }
    else
        st.parent[st.index] = body
    end
    if st.parent.resetLayout then st.parent:resetLayout() end
    st.box.dimen.h, st.fc.dimen.h, st.bg.dimen.h, st.bg.height = box_h, box_h, box_h, box_h
    if wrapped.resetLayout then wrapped:resetLayout() end
    return box_h
end

-- Insets `content` to the label column and draws the module chrome around it.
-- The box spans the column unless `content.fit_align` ("left" | "center" |
-- "right") is set: the box is then sized to the content and placed in the
-- column according to that alignment. `body` is the part of `content` that
-- `stretch` centres (default: all of it); `min_h` stretches the box at once.
function M.wrap(content, chrome, col_w, scale, body, min_h)
    if not content then return content end

    local outer_m = M.outerMargin(chrome)
    local frame_pad = M.innerPad(chrome) + chrome.border_sz
    local col_box_w = math.max(1, col_w - outer_m * 2)

    local box_w = col_box_w
    if content.fit_align then
        box_w = math.min(col_box_w, content:getSize().w + M.boxInset(chrome))
    end
    local free_w = col_box_w - box_w
    local lead_w = leadingGap(free_w, content.fit_align)

    -- Outer inset matching section labels. Cap the content width so a
    -- wide child (e.g. heatmap grid) cannot paint past the label column.
    local function withOuter(widget)
        if outer_m <= 0 then return widget end
        if widget and widget.dimen then
            local sz = widget.getSize and widget:getSize()
            local wh = (sz and sz.h) or 0
            widget.dimen = Geom:new{ w = box_w, h = widget.dimen.h or wh }
        end
        return HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = outer_m + lead_w },
            widget,
            HorizontalSpan:new{ width = outer_m + free_w - lead_w },
        }
    end

    -- No card: only lateral inset so content lines up with section labels.
    if not M.hasChrome(chrome) then
        return withOuter(content)
    end

    local radius = M.radius(chrome, scale)

    -- Content inset; fill/frame drawn by a sibling under it in OverlapGroup.
    local fc = FrameContainer:new{
        bordersize = 0,
        radius = 0,
        padding = frame_pad,
        background = nil,
        content,
    }
    local sz = fc:getSize()
    local box_h = math.max(1, sz.h)

    local bg = Backdrop.BackdropFill:new{
        width = box_w,
        height = box_h,
        surface = chrome,
        radius = radius,
    }

    fc.dimen = Geom:new{ w = box_w, h = box_h }
    bg.dimen = Geom:new{ w = box_w, h = box_h }

    local box = OverlapGroup:new{
        dimen = Geom:new{ w = box_w, h = box_h },
        bg,
        fc,
    }

    local wrapped = withOuter(box)
    local parent, index = fc, 1
    if body and body ~= content then
        parent = content
        for i, child in ipairs(content) do
            if child == body then index = i break end
        end
    end
    wrapped._sui_box = {
        box = box, fc = fc, bg = bg, body = body or content,
        parent = parent, index = index, natural_h = box_h,
    }
    if min_h and min_h > box_h then M.stretch(wrapped, min_h) end
    return wrapped
end

-- Insets `content` to the label column without drawing any chrome, for
-- modules that draw their own boxes (see `owns_chrome` in moduleregistry.lua).
function M.inset(content, col_w, scale)
    return M.wrap(content, M.NO_CHROME, col_w, scale)
end

-- "Background" submenu of a module: Color, Frame and Background Opacity. The
-- opacity row is listed only while a wallpaper is active. Returns nil for modules that skip module-wide chrome.
-- `kind` is as in M.resolve.
function M.makeBackgroundItem(pfx, id, refresh, _lc, kind)
    if M.skipsModuleChrome(id) then return nil end
    local Config = require("infra/sui_config")
    return Config.makeSurfaceMenu{
        surface      = M.surface(pfx, id, kind),
        refresh      = refresh,
        get_strength = function() return M.resolve(pfx, id, kind).strength end,
        set_strength = function(n) SUIWallpaper.setModuleBackdropStrength(n, pfx, id) end,
        _lc          = _lc or _,
    }
end

local function isAppearance(entry, _lc)
    local label = entry.text
    if type(entry.text_func) == "function" then
        local ok, s = pcall(entry.text_func)
        if ok then label = s end
    end
    return label == _lc("Appearance")
end

-- Adds the Background submenu first in the module's Appearance submenu,
-- creating that submenu when the module has none.
function M.mergeAppearanceIntoItems(items, pfx, id, refresh, _lc)
    _lc = _lc or _
    local background = M.makeBackgroundItem(pfx, id, refresh, _lc)
    if type(items) ~= "table" or not background then return items end

    for _, entry in ipairs(items) do
        if isAppearance(entry, _lc) then
            if type(entry.sub_item_table) == "table" then
                table.insert(entry.sub_item_table, 1, background)
            else
                entry.sub_item_table = { background }
            end
            return items
        end
    end

    items[#items + 1] = { text = _lc("Appearance"), sub_item_table = { background } }
    return items
end

return M
