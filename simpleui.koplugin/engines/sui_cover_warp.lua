-- sui_cover_warp.lua — Simple UI
-- Perspective warp of a rectangular cover into a vertical trapezoid.
--
--   Warp.columnAt(t, rho) → u, relative_h
--   Warp.profile(w, h, rho, outer_left, src_w) → { key, w, h, src_w, x0, x1, fx, tops, heights } | nil
--   Warp.warp(src, w, h, rho, outer_left) → { bb, tops, heights } | nil
--
-- The outer edge (nearest the viewer) is the left edge when outer_left is
-- true, otherwise the right edge. rho is the inner/outer edge height ratio
-- (0 < rho ≤ 1). tops[x+1] and heights[x+1] describe the painted span of
-- column x so callers can blit only the trapezoid without an alpha channel.
-- The source is h rows tall and src_w columns wide (w when omitted); the warp
-- fits its width to w along with the perspective, so a cover keeps one
-- resampling step. The profile depends on the geometry alone, so it is shared
-- by every cover warped to the same size and tilt, and is read-only.
--
-- Every pixel is bilinearly interpolated from the four source pixels around
-- its position, so the warp neither drops nor repeats source rows and columns.
-- The profile holds the horizontal part of that sampling per column: the
-- source columns x0 and x1 (0-based) and the weight fx (0-255) of x1.
--
-- The returned bb is owned by the caller and must be freed when no longer
-- needed. On failure (unsupported pixel format, size mismatch, allocation
-- error) returns nil; the caller is responsible for any fallback.

local Blitbuffer = require("ffi/blitbuffer")
local bit        = require("bit")
local ffi        = require("ffi")
local SUIStyle   = require("features/sui_style")

local arshift = bit.arshift
local floor  = math.floor
local max    = math.max
local min    = math.min

local Warp = {}

-- Perspective mapping of one column. t runs from 0 at the outer edge
-- (nearest, tallest) to 1 at the inner edge; rho is the inner/outer edge
-- height ratio. Returns the position along the cover (0 at the outer edge,
-- 1 at the inner one) and the column height relative to the outer edge.
function Warp.columnAt(t, rho)
    if not rho or rho <= 0 then return t, 1 end
    if rho >= 1 then return t, 1 end
    local denom = 1 - t * (1 - rho)
    if denom <= 0 then return 1, rho end
    local u = t * rho / denom
    return u, 1 / (1 + (1 / rho - 1) * u)
end

-- Bytes per pixel of the formats whose channels can be interpolated bytewise:
-- 8-bit gray, RGB24 and RGB32. Returns nil for every other format (nibble,
-- 16-bit, gray with alpha), which need conversion first.
local BYTES_PER_BPP = { [8] = 1, [24] = 3, [32] = 4 }

local function bytesPerPixel(bb)
    return BYTES_PER_BPP[bb:getBpp()]
end

-- Ensure src is a tightly packed, byte-addressable buffer of exactly w×h.
-- Converts formats that cannot be interpolated bytewise to RGB32 via blitFrom.
-- Returns the working buffer and a flag indicating the caller must free it.
local function prepareSource(src, w, h)
    local src_w, src_h = src:getWidth(), src:getHeight()
    if src_w ~= w or src_h ~= h then return nil end

    -- Optional rotation check — only when the method exists (not every
    -- BlitBuffer C struct exposes inverse/rotation fields).
    if type(src.getRotation) == "function" then
        local ok_rot, rot = pcall(src.getRotation, src)
        if ok_rot and rot and rot ~= 0 then return nil end
    end

    if bytesPerPixel(src) then
        return src, false
    end

    local ok, rgb = pcall(Blitbuffer.new, w, h, Blitbuffer.TYPE_BBRGB32)
    if not (ok and rgb) then return nil end
    local ok_blit = pcall(rgb.blitFrom, rgb, src, 0, 0, 0, 0, w, h)
    if not ok_blit then
        pcall(rgb.free, rgb)
        return nil
    end
    return rgb, true
end

-- Value `f`/256 of the way from channel value a to b (f in 0-255).
local function lerp(a, b, f)
    return a + arshift((b - a) * f + 128, 8)
end

local PROFILE_CACHE_MAX = 8   -- distinct geometries kept: a few sizes per side
local _profiles, _profile_count = {}, 0

-- Column layout of a w × h cover warped with tilt `rho` from a source src_w
-- columns wide: for every column the two source columns it blends (x0 and x1,
-- 0-based) with the weight fx of x1, and its painted span (tops, heights).
-- Returns nil for a size or tilt that cannot be warped.
function Warp.profile(w, h, rho, outer_left, src_w)
    w, h = floor(w), floor(h)
    src_w = floor(src_w or w)
    if w < 2 or h < 2 or src_w < 2 or not rho or rho <= 0 or rho > 1 then return nil end

    local key = table.concat({ w, h, src_w, rho, outer_left and "left" or "right" }, "|")
    local profile = _profiles[key]
    if profile then return profile end

    local last, src_last = w - 1, src_w - 1
    local x0, x1, fx, tops, heights = {}, {}, {}, {}, {}
    for x = 0, last do
        local t = (outer_left and x or (last - x)) / last
        local u, relative_h = Warp.columnAt(t, rho)
        local pos = max(0, min(src_last, (outer_left and u or (1 - u)) * src_last))
        local left = min(floor(pos), src_last)
        local col_h = min(h, max(1, floor(h * relative_h + 0.5)))
        x0[x + 1]      = left
        x1[x + 1]      = min(left + 1, src_last)
        fx[x + 1]      = floor((pos - left) * 256)
        heights[x + 1] = col_h
        tops[x + 1]    = floor((h - col_h) / 2)
    end

    profile = { key = key, w = w, h = h, src_w = src_w, x0 = x0, x1 = x1, fx = fx, tops = tops, heights = heights }
    if _profile_count >= PROFILE_CACHE_MAX then _profiles, _profile_count = {}, 0 end
    _profiles[key] = profile
    _profile_count = _profile_count + 1
    return profile
end

-- Warps src (h rows tall, any width of at least 2) into a w-wide vertical
-- trapezoid.
-- bb.data is typed (Color8*, ColorRGB32*, …): pointer arithmetic advances by
-- element, not by byte. Cast to uint8_t* and address by byte offsets so the
-- same path works for every packed format.
function Warp.warp(src, w, h, rho, outer_left)
    if not src then return nil end
    local profile = Warp.profile(w, h, rho, outer_left, src:getWidth())
    if not profile then return nil end
    w, h = profile.w, profile.h

    local working, own_working = prepareSource(src, profile.src_w, h)
    if not working then return nil end

    local bytes_pp = bytesPerPixel(working)
    if not bytes_pp then
        if own_working then pcall(working.free, working) end
        return nil
    end

    local ok_dst, dst = pcall(Blitbuffer.new, w, h, working:getType())
    if not (ok_dst and dst) then
        if own_working then pcall(working.free, working) end
        return nil
    end
    pcall(dst.fill, dst, Blitbuffer.COLOR_WHITE)

    -- Byte-addressable views. Typed pointers would advance by pixel and
    -- overshoot by a factor of bytes_pp on RGB buffers.
    local src_data = ffi.cast("uint8_t*", working.data)
    local dst_data = ffi.cast("uint8_t*", dst.data)
    local src_stride = tonumber(working.stride)
    local dst_stride = tonumber(dst.stride)
    if not src_data or not dst_data or not src_stride or not dst_stride then
        pcall(dst.free, dst)
        if own_working then pcall(working.free, working) end
        return nil
    end

    -- Each column blends two source columns (weight fx) and stretches them
    -- vertically from h rows to col_h; the sample position of a row is the
    -- centre of the span it covers, and its fractional part weights the two
    -- source rows around it.
    local tops, heights = profile.tops, profile.heights
    local x0s, x1s, fxs = profile.x0, profile.x1, profile.fx
    local last_row = h - 1
    for x = 0, w - 1 do
        local col_h = heights[x + 1]
        local left  = src_data + x0s[x + 1] * bytes_pp
        local right = src_data + x1s[x + 1] * bytes_pp
        local fx    = fxs[x + 1]
        local out   = dst_data + x * bytes_pp + tops[x + 1] * dst_stride
        local ratio = h / col_h
        for y = 0, col_h - 1 do
            local sy = max(0, (y + 0.5) * ratio - 0.5)
            local row = floor(sy)
            local fy  = floor((sy - row) * 256)
            local r0  = row * src_stride
            local r1  = min(row + 1, last_row) * src_stride
            local px  = out + y * dst_stride
            for c = 0, bytes_pp - 1 do
                local l = lerp(left[r0 + c],  left[r1 + c],  fy)
                local r = lerp(right[r0 + c], right[r1 + c], fy)
                px[c] = lerp(l, r, fx)
            end
        end
    end

    if own_working then pcall(working.free, working) end

    -- Thin border along the trapezoid silhouette.
    local color, border = SUIStyle.COLOR.text_primary, SUIStyle.BADGE_BORDER_SZ
    if border and border > 0 then
        for x = 0, w - 1 do
            local top, col_h = tops[x + 1], heights[x + 1]
            local b = min(border, floor(col_h / 2))
            if b > 0 then
                dst:paintRect(x, top, 1, b, color)
                dst:paintRect(x, top + col_h - b, 1, b, color)
            end
        end
        local edge = min(border, w)
        dst:paintRect(0, tops[1], edge, heights[1], color)
        dst:paintRect(w - edge, tops[w], edge, heights[w], color)
    end

    return { bb = dst, tops = tops, heights = heights }
end

return Warp
