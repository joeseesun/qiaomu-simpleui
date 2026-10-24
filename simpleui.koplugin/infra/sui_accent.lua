-- sui_accent.lua — Simple UI
-- Optional accent colour for the active state of controls (slider fill,
-- progress bars, active tab indicator, selected segments, ...). Unset by
-- default, and only available on colour screens: consumers keep their
-- black/gray look until a colour is chosen.
--
-- A second colour, the secondary, is a soft surface tone for the backgrounds of
-- modules and bars. Until one is chosen it follows the accent: the accent hue at
-- low saturation, as light as the flat gray fill it replaces. It has no colour
-- while neither a secondary nor an accent is set. The track colour (progress
-- bars, slider rails) is the same tint at the darker gray of those tracks.
--
-- Public API
--   Accent.isSupported()        -> boolean  colour screen with colour rendering on
--   Accent.isEnabled()          -> boolean  supported and a colour is set
--   Accent.getHex()             -> "#RRGGBB" | nil
--   Accent.normalizeHex(text)   -> "#RRGGBB" | nil  typed text: optional "#", 3 or 6 hex digits
--   Accent.setHex(hex | nil)    stores the colour; nil clears it
--   Accent.toColor(hex)         -> Blitbuffer colour showing `hex` (night-aware) | nil
--   Accent.toHex(color)         -> "#RRGGBB" that toColor shows as `color` (night-aware)
--   Accent.color()              -> Blitbuffer colour | nil    (nil: not enabled)
--   Accent.foreground([strength]) -> Blitbuffer colour | nil  black/white text on color() painted at
--                               `strength` (0..100, default 100) over white paper
--   Accent.isReadableOn(color)  -> boolean  accent contrasts enough with `color` for text/glyphs
--   Accent.contrastsWith(surface [, strength [, color]]) -> boolean  `color` (default: the accent)
--                               stands out from `surface` painted at `strength` (0..100,
--                               default 100) over white paper
--   Accent.getSecondaryHex()    -> "#RRGGBB" | nil  the chosen secondary, else the one derived
--                               from the accent
--   Accent.setSecondaryHex(hex | nil)  stores the secondary; nil goes back to the derived one
--   Accent.isSecondaryCustom()  -> boolean  a secondary is stored
--   Accent.secondaryColor()     -> Blitbuffer colour | nil    (nil: no secondary on screen)
--   Accent.secondaryForeground([strength]) -> as foreground(), for secondaryColor()
--   Accent.trackColor()         -> Blitbuffer colour | nil    track tint of the secondary (nil: no secondary)
--   Accent.INK                  blackness (Blitbuffer.gray level) of the gray fills the secondary
--                               replaces: { flat, track }
--   Accent.stamp()              -> string   cache-key part for the painted colours ("" if off)
--   Accent.hexToHsv(hex)        -> h 0..359, s 0..100, v 0..100 | nil
--   Accent.hsvToHex(h, s, v)    -> "#RRGGBB"
--   Accent.PALETTE              preset colours of the picker

local Blitbuffer  = require("ffi/blitbuffer")
local Device      = require("device")
local SUISettings = require("infra/sui_store")
local Screen      = Device.screen

local KEY           = "simpleui_style_accent"
local SECONDARY_KEY = "simpleui_style_secondary"

-- Saturation (at most), in percent, of the derived secondary and track tints.
local SECONDARY_SATURATION = 10

local Accent = {}

-- Blackness (Blitbuffer.gray level) of the gray fills that follow the secondary.
Accent.INK = { flat = 0.08, track = 0.15 }

Accent.PALETTE = {
    "#2F6FDB", "#1B9AAA", "#2E8B57", "#B8860B",
    "#E07B1F", "#C93C3C", "#B03A8C", "#7A4FC7",
}

-- Relative luminance above which black text reads better than white.
local LUMINANCE_SPLIT = 0.179

-- Least contrast ratio at which the accent counts as standing out from a fill.
local MIN_CONTRAST = 2

local function parseHex(hex)
    if type(hex) ~= "string" then return nil end
    local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
    if not r then return nil end
    return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

local function linear(channel)
    channel = channel / 255
    return channel <= 0.04045 and channel / 12.92 or ((channel + 0.055) / 1.055) ^ 2.4
end

function Accent.isSupported()
    return Screen.isColorScreen and Screen:isColorScreen()
        and Screen.isColorEnabled and Screen:isColorEnabled()
        or false
end

-- Stored "#RRGGBB" under `key`, or nil when unset or invalid.
local function readHex(key)
    local hex = SUISettings:get(key)
    return parseHex(hex) and hex:upper() or nil
end

-- Stores `hex` under `key`; nil clears it, an invalid value is ignored.
local function writeHex(key, hex)
    if hex == nil then
        SUISettings:del(key)
    elseif parseHex(hex) then
        SUISettings:set(key, hex:upper())
    end
end

function Accent.getHex()
    return readHex(KEY)
end

-- Canonical "#RRGGBB" for text typed by a person: the "#" is optional and a
-- three digit form is expanded. nil when the text is not a colour.
function Accent.normalizeHex(text)
    if type(text) ~= "string" then return nil end
    local digits = text:match("^%s*#?(%x+)%s*$")
    if not digits then return nil end
    if #digits == 3 then
        digits = digits:gsub("%x", "%0%0")
    elseif #digits ~= 6 then
        return nil
    end
    return "#" .. digits:upper()
end

function Accent.setHex(hex)
    writeHex(KEY, hex)
end

-- "#RRGGBB" with the hue of `base_hex`, its saturation capped, and the same
-- relative luminance as the gray of blackness `ink`.
local function tintHex(base_hex, ink)
    local h, s = Accent.hexToHsv(base_hex)
    s = math.min(s, SECONDARY_SATURATION)
    local target = linear(Blitbuffer.gray(ink):getColor8().a)
    local lo, hi = 0, 100
    for _ = 1, 12 do
        local mid = (lo + hi) / 2
        local r, g, b = parseHex(Accent.hsvToHex(h, s, mid))
        if 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) < target then lo = mid else hi = mid end
    end
    return Accent.hsvToHex(h, s, hi)
end

-- Tint of `base_hex` at gray `ink`, remembered for the last base asked per
-- slot: it is read on every paint.
local tints = { flat = {}, track = {} }

local function tintOf(slot, base_hex)
    local memo = tints[slot]
    if memo.from ~= base_hex then
        memo.from = base_hex
        memo.hex  = tintHex(base_hex, Accent.INK[slot])
    end
    return memo.hex
end

function Accent.getSecondaryHex()
    local accent_hex = Accent.getHex()
    return readHex(SECONDARY_KEY) or accent_hex and tintOf("flat", accent_hex) or nil
end

function Accent.setSecondaryHex(hex)
    writeHex(SECONDARY_KEY, hex)
end

function Accent.isSecondaryCustom()
    return readHex(SECONDARY_KEY) ~= nil
end

function Accent.isEnabled()
    return Accent.isSupported() and Accent.getHex() ~= nil
end

-- Colour that shows `hex` on screen. KOReader inverts the whole screen at
-- night, so the colour is pre-inverted there to keep the chosen hue.
function Accent.toColor(hex)
    local r, g, b = parseHex(hex)
    if not r then return nil end
    local color = Blitbuffer.ColorRGB32(r, g, b, 0xFF)
    return Screen.night_mode and color:invert() or color
end

-- "#RRGGBB" that Accent.toColor shows as `color`.
function Accent.toHex(color)
    local rgb = color:getColorRGB32()
    local r, g, b = rgb.r, rgb.g, rgb.b
    if Screen.night_mode then r, g, b = 255 - r, 255 - g, 255 - b end
    return string.format("#%02X%02X%02X", r, g, b)
end

local function luminance(color)
    local rgb = color:getColorRGB32()
    return 0.2126 * linear(rgb.r) + 0.7152 * linear(rgb.g) + 0.0722 * linear(rgb.b)
end

-- Black or white, whichever reads better on `color`.
local function foregroundOn(color)
    return luminance(color) > LUMINANCE_SPLIT and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
end

-- `color` painted at `strength` percent (default 100) over white paper.
local function overPaper(color, strength)
    if not strength or strength >= 100 then return color end
    local rgb, keep = color:getColorRGB32(), math.max(0, strength) / 100
    local function mix(channel) return math.floor(255 + (channel - 255) * keep + 0.5) end
    return Blitbuffer.ColorRGB32(mix(rgb.r), mix(rgb.g), mix(rgb.b), 0xFF)
end

-- Colour and text colour of each palette slot for its hex and the current night
-- mode, kept in a table per slot.
local accent_cache, secondary_cache, track_cache = {}, {}, {}

-- State of `cache` for `hex`; nil without a hex or on a screen without colour.
local function resolveState(cache, hex)
    if not hex or not Accent.isSupported() then return nil end
    local night = Screen.night_mode and true or false
    if cache.hex ~= hex or cache.night ~= night then
        cache.hex, cache.night = hex, night
        cache.color = Accent.toColor(hex)
        cache.foreground = foregroundOn(cache.color)
    end
    return cache
end

local function resolve()
    return resolveState(accent_cache, Accent.getHex())
end

local function resolveSecondary()
    return resolveState(secondary_cache, Accent.getSecondaryHex())
end

function Accent.color()
    local state = resolve()
    return state and state.color
end

function Accent.secondaryColor()
    local state = resolveSecondary()
    return state and state.color
end

function Accent.trackColor()
    local secondary_hex = Accent.getSecondaryHex()
    local state = secondary_hex and resolveState(track_cache, tintOf("track", secondary_hex))
    return state and state.color
end

-- Text colour for `state` painted at `strength` percent over white paper: a
-- weak scrim is mostly paper, so it takes the text colour of a light fill.
local function foregroundAt(state, strength)
    if not strength or strength >= 100 then return state.foreground end
    return foregroundOn(overPaper(state.color, strength))
end

function Accent.foreground(strength)
    local state = resolve()
    return state and foregroundAt(state, strength)
end

function Accent.secondaryForeground(strength)
    local state = resolveSecondary()
    return state and foregroundAt(state, strength)
end

-- True when the accent colour stands out against `surface` (the colour of the
-- paper it is drawn on): one of the two takes white text, the other black.
function Accent.isReadableOn(surface)
    local state = resolve()
    return state ~= nil and state.foreground ~= foregroundOn(surface)
end

-- True when `color` (default: the accent) stands out from `surface` painted at
-- `strength` percent (default 100) over white paper, by contrast ratio of their
-- luminances.
function Accent.contrastsWith(surface, strength, color)
    if not color then
        local state = resolve()
        color = state and state.color
    end
    if not color then return false end
    local a, b = luminance(color), luminance(overPaper(surface, strength))
    return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05) >= MIN_CONTRAST
end

-- Hex and night mode of a resolved state; empty without one.
local function stampOf(state)
    return state and (state.hex .. (state.night and "n" or "d")) or ""
end

-- Identifies the painted colours (accent and secondary, each with its hex and
-- night mode), for the keys of caches that hold rendered bitmaps. Empty when
-- neither is on screen.
function Accent.stamp()
    local accent, secondary = stampOf(resolve()), stampOf(resolveSecondary())
    return secondary == "" and accent or (accent .. "/" .. secondary)
end

function Accent.hexToHsv(hex)
    local r, g, b = parseHex(hex)
    if not r then return nil end
    r, g, b = r / 255, g / 255, b / 255
    local max, min = math.max(r, g, b), math.min(r, g, b)
    local delta = max - min
    local h = 0
    if delta > 0 then
        if max == r then
            h = ((g - b) / delta) % 6
        elseif max == g then
            h = (b - r) / delta + 2
        else
            h = (r - g) / delta + 4
        end
        h = h * 60
    end
    local s = max > 0 and delta / max or 0
    return math.floor(h + 0.5) % 360, math.floor(s * 100 + 0.5), math.floor(max * 100 + 0.5)
end

function Accent.hsvToHex(h, s, v)
    s, v = s / 100, v / 100
    local c = v * s
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - c
    local sector = math.floor((h % 360) / 60)
    local r, g, b
    if sector == 0 then r, g, b = c, x, 0
    elseif sector == 1 then r, g, b = x, c, 0
    elseif sector == 2 then r, g, b = 0, c, x
    elseif sector == 3 then r, g, b = 0, x, c
    elseif sector == 4 then r, g, b = x, 0, c
    else r, g, b = c, 0, x end
    return string.format("#%02X%02X%02X",
        math.floor((r + m) * 255 + 0.5), math.floor((g + m) * 255 + 0.5), math.floor((b + m) * 255 + 0.5))
end

return Accent
