-- sprite.lua — Simple UI
-- Image widget of the Critter module.
--
-- A PNG whose longest side is at most PIXEL_ART_MAX is pixel art: it is
-- decoded at its own size and enlarged by a whole factor with nearest-
-- neighbour scaling, so its pixels stay sharp. The factor is the largest one
-- that fits the box, at most `max_pixel` when that is given, and the widget
-- reports it as `pixel`, so images drawn together can share one pixel size.
-- Any other PNG is scaled smoothly to fit the box, and an SVG is rasterised
-- into it, keeping its proportions.
--
-- The decoded bitmap lives in the shared RasterCache (kind "critter") and is
-- looked up on every paint, so the widget keeps no bitmap of its own. The
-- transparent rows at the bottom of an image are not part of the widget.

local Blitbuffer  = require("ffi/blitbuffer")
local Device      = require("device")
local Geom        = require("ui/geometry")
local RenderImage = require("ui/renderimage")
local Widget      = require("ui/widget/widget")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

local RasterCache = require("infra/sui_raster_cache")

local Screen = Device.screen

local KIND           = "critter"
local PIXEL_ART_MAX  = 64

-- Blit method by [straight alpha][software dithering].
local BLIT = {
    [false] = { [false] = "pmulalphablitFrom", [true] = "ditherpmulalphablitFrom" },
    [true]  = { [false] = "alphablitFrom",     [true] = "ditheralphablitFrom" },
}

-- Decodes `path` for a box of max_w x max_h. Returns the bitmap, whether its
-- alpha is straight (SVG) rather than premultiplied (PNG), and the pixel
-- factor of a pixel-art image.
local function decode(path, max_w, max_h, max_pixel)
    if path:lower():sub(-4) == ".svg" then
        -- Rendered to the box height; to the width when that is too wide.
        local bb, straight = RenderImage:renderSVGImageFile(path, nil, max_h)
        if bb and bb:getWidth() > max_w then
            bb:free()
            bb, straight = RenderImage:renderSVGImageFile(path, max_w, nil)
        end
        return bb, straight
    end

    local bb = RenderImage:renderImageFile(path, false)
    if not bb then return nil end
    local w, h = bb:getWidth(), bb:getHeight()
    if math.max(w, h) <= PIXEL_ART_MAX then
        local k = math.min(math.floor(max_h / h), math.floor(max_w / w), max_pixel or math.huge)
        if k >= 1 then
            if k > 1 then
                local enlarged = bb:scale(w * k, h * k)
                bb:free()
                bb = enlarged
            end
            return bb, false, k
        end
    end
    bb:free()
    return RenderImage:renderImageFile(path, false, max_w, max_h)
end

-- Number of fully transparent rows at the bottom of `bb`, 0 for a bitmap
-- without alpha. The widget leaves them out, so the lowest opaque row of the
-- image stands on the bottom of its box.
local function transparentFoot(bb)
    local bb_type = bb:getType()
    if bb_type ~= Blitbuffer.TYPE_BB8A and bb_type ~= Blitbuffer.TYPE_BBRGB32 then return 0 end
    local w, h = bb:getWidth(), bb:getHeight()
    for py = h - 1, 0, -1 do
        for px = 0, w - 1 do
            if bb:getPixel(px, py):getColorRGB32().alpha > 0 then return h - 1 - py end
        end
    end
    return h
end

-- RasterCache entry of `path`; an entry without bitmap when it cannot be
-- decoded, so a broken file is not retried on every paint.
local function buildEntry(path, max_w, max_h, max_pixel)
    local ok, bb, straight, pixel = pcall(decode, path, max_w, max_h, max_pixel)
    if not ok or not bb then
        logger.warn("simpleui: critter: cannot decode " .. path)
        return { w = 0, h = 0, foot = 0 }
    end
    return {
        bb = bb, w = bb:getWidth(), h = bb:getHeight(), foot = transparentFoot(bb),
        straight = straight == true, pixel = pixel,
    }
end

local Sprite = Widget:extend{
    path      = nil,   -- image file
    max_w     = 0,     -- box the image has to fit in
    max_h     = 0,
    max_pixel = nil,   -- largest pixel factor of a pixel-art image
    pixel     = nil,   -- pixel factor in use (nil unless the image is pixel art)
}

function Sprite:init()
    local mtime = lfs.attributes(self.path, "modification") or 0
    self.key = table.concat({ self.path, mtime, self.max_w, self.max_h, self.max_pixel or "" }, "|")
    local entry = self:_entry()
    self.dimen = Geom:new{ w = entry.w, h = entry.h - entry.foot }
    self.pixel = entry.pixel
end

function Sprite:_entry()
    return RasterCache.get(KIND, self.key, buildEntry, self.path, self.max_w, self.max_h, self.max_pixel)
end

function Sprite:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local entry = self:_entry()
    local src = entry.bb
    if not src then return end

    local w, h = entry.w, entry.h - entry.foot
    local src_type = src:getType()
    -- The night-mode inversion of the screen is undone for the sprite alone:
    -- opaque pixels are inverted after the blit, and with an alpha channel the
    -- area is inverted on both sides of it so transparent pixels keep the
    -- background.
    local night = Screen.night_mode
    if src_type ~= Blitbuffer.TYPE_BB8A and src_type ~= Blitbuffer.TYPE_BBRGB32 then
        bb:blitFrom(src, x, y, 0, 0, w, h)
        if night then bb:invertRect(x, y, w, h) end
        return
    end

    if night then bb:invertRect(x, y, w, h) end
    local method = BLIT[entry.straight][Screen.sw_dithering == true]
    bb[method](bb, src, x, y, 0, 0, w, h)
    if night then bb:invertRect(x, y, w, h) end
end

return Sprite
