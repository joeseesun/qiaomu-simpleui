-- sui_cover_shadow.lua — Simple UI
-- Soft drop shadow of a cover, cast down and to the right.
--
--   Shadow.bandStrength(d, reach) → shading of the band `d` px from the card
--   Shadow.paintRect(bb, x, y, w, h, offset)
--       Shadow around a w × h rectangular card at (x, y).
--   Shadow.paintSilhouette(bb, x, y, shape, offset)
--       Shadow around a card whose outline is `shape` (see below).
--   Shadow.buildWidget(card_w, card_h, offset, shape) → widget | nil
--       Widget wrapper around either painter; nil when `offset` is 0. The
--       card sits at the widget's top-left corner and the shadow falls
--       down-right. `shape` is optional: without it the card is a rectangle.
--
-- A shape describes an outline by columns: { key, w, tops, heights }, where
-- tops[x + 1] and heights[x + 1] give the painted span of column x, and `key`
-- identifies the geometry for caching.
--
-- A shadow is built from one-pixel bands that fade with their distance from
-- the card, which approximates a blurred edge. The bands are coverage masks
-- blended in black, which shades what is already painted instead of laying a
-- fixed grey, so the shadow reads on any background and on the covers behind.
-- Rectangle and silhouette shadows share the same bands, so a shadow looks the
-- same whatever the cover's shape.

local Blitbuffer  = require("ffi/blitbuffer")
local Device      = require("device")
local Geom        = require("ui/geometry")
local RasterCache = require("infra/sui_raster_cache")

local Screen = Device.screen
local floor  = math.floor
local max    = math.max
local min    = math.min

local Shadow = {}

local _PEAK         = 0.22   -- shading of the band touching the card
local _MIN_STRENGTH = 0.02   -- fainter bands are not visible: skipped

-- Shading of the band `d` px away from the card (0 = touching it) in a shadow
-- `reach` px deep: a smoothstep from the peak down to nothing.
function Shadow.bandStrength(d, reach)
    local t = 1 - d / reach
    return _PEAK * t * t * (3 - 2 * t)
end

-- Coverage of band `d` as an 8-bit mask value.
local function bandCoverage(d, offset)
    return Blitbuffer.Color8(floor(Shadow.bandStrength(d, offset) * 255 + 0.5))
end

-- Number of bands of a shadow `offset` px deep that are dark enough to show.
local function visibleBands(offset)
    local n = 0
    while n < offset and Shadow.bandStrength(n, offset) >= _MIN_STRENGTH do n = n + 1 end
    return n
end

-- Night frames are inverted after painting, so blending towards white is what
-- darkens the shadow on screen.
local function shadowColor()
    return Screen.night_mode and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
end

-- ── Rectangle ─────────────────────────────────────────────────────────────────

-- Coverage masks of a rectangle shadow's right and bottom strips. The strips
-- never overlap: right band `d` is the column `d` px past the card, bottom
-- band `d` the row `d` px below it, and the corner belongs to whichever band
-- is farther along its own axis.
local function buildRectMasks(w, h, offset)
    local right  = Blitbuffer.new(offset, h, Blitbuffer.TYPE_BB8)
    local bottom = Blitbuffer.new(w, offset, Blitbuffer.TYPE_BB8)
    right:fill(Blitbuffer.Color8(0))
    bottom:fill(Blitbuffer.Color8(0))
    for d = 0, visibleBands(offset) - 1 do
        local coverage = bandCoverage(d, offset)
        right:paintRect(d, 0, 1, h - offset + d, coverage)
        bottom:paintRect(0, d, w - offset + d + 1, 1, coverage)
    end
    return { right = right, bottom = bottom }
end

-- Paints the part of a soft shadow that shows around a w × h card at (x, y),
-- `offset` px deep. The shadow is the card's rectangle shifted down-right by
-- `offset`, minus the card itself.
function Shadow.paintRect(bb, x, y, w, h, offset)
    if offset <= 0 then return end
    local masks = RasterCache.get("shadow", (w * 4096 + h) * 64 + offset, buildRectMasks, w, h, offset)
    local color = shadowColor()
    bb:colorblitFromRGB32(masks.right,  x + w,      y + offset, 0, 0, offset, h,      color)
    bb:colorblitFromRGB32(masks.bottom, x + offset, y + h,      0, 0, w,      offset, color)
end

-- ── Silhouette ────────────────────────────────────────────────────────────────

-- Coverage mask of a silhouette shadow, as large as the shape plus `offset`.
-- The shadow is the shape shifted down-right by `offset`, minus the shape
-- itself. A pixel takes the band of the smallest diagonal step `k` that lands
-- it back on the shape, which for a rectangle gives the same bands as
-- buildRectMasks.
--
-- Per column, steps run from the farthest to the nearest so that nearer, darker
-- bands overwrite fainter ones. Each step covers the column's span of the shape
-- `k` columns to the left, moved down `k` px, cut to the shifted shape and to
-- what lies below the shape's own column.
local function buildSilhouetteMask(shape, offset)
    local tops, heights, w = shape.tops, shape.heights, shape.w
    local bottom = 0
    for i = 1, w do bottom = max(bottom, tops[i] + heights[i]) end

    local mask = Blitbuffer.new(w + offset, bottom + offset, Blitbuffer.TYPE_BB8)
    mask:fill(Blitbuffer.Color8(0))

    local bands = visibleBands(offset)
    local coverage = {}
    for k = 1, bands do coverage[k] = bandCoverage(k - 1, offset) end

    for x = 0, w + offset - 1 do
        local shifted = x - offset
        if shifted >= 0 and shifted < w then
            local lo_limit = x < w and tops[x + 1] + heights[x + 1] or 0
            local hi_limit = tops[shifted + 1] + heights[shifted + 1] + offset
            lo_limit = max(lo_limit, tops[shifted + 1] + offset)
            for k = bands, 1, -1 do
                local source = x - k
                if source >= 0 and source < w then
                    local lo = max(tops[source + 1] + k, lo_limit)
                    local hi = min(tops[source + 1] + heights[source + 1] + k, hi_limit)
                    if hi > lo then mask:paintRect(x, lo, 1, hi - lo, coverage[k]) end
                end
            end
        end
    end
    return { mask = mask }
end

-- Paints the shadow of `shape` placed at (x, y), `offset` px deep. `key` is the
-- raster cache key of that shape and depth (see buildWidget).
function Shadow.paintSilhouette(bb, x, y, shape, offset, key)
    if offset <= 0 then return end
    key = key or (shape.key .. "|" .. offset)
    local mask = RasterCache.get("silhouette_shadow", key, buildSilhouetteMask, shape, offset).mask
    bb:colorblitFromRGB32(mask, x, y, 0, 0, mask:getWidth(), mask:getHeight(), shadowColor())
end

-- ── Widget ────────────────────────────────────────────────────────────────────

local ShadowWidget = {}
ShadowWidget.__index = ShadowWidget

function ShadowWidget:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function ShadowWidget:paintTo(bb, x, y)
    if self.shape then
        Shadow.paintSilhouette(bb, x, y, self.shape, self.offset, self.mask_key)
    else
        Shadow.paintRect(bb, x, y, self.card_w, self.card_h, self.offset)
    end
end

-- Not interactive: containers forward events to every child, and a child
-- without a handler would raise.
function ShadowWidget:handleEvent()
    return false
end

function Shadow.buildWidget(card_w, card_h, offset, shape)
    if offset <= 0 then return nil end
    return setmetatable({
        w = card_w + offset, h = card_h + offset,
        card_w = card_w,     card_h = card_h,
        offset = offset,
        shape = shape,
        mask_key = shape and (shape.key .. "|" .. offset) or nil,
    }, ShadowWidget)
end

return Shadow
