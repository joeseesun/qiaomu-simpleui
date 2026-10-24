-- sui_label_style.lua — Simple UI
-- Owner of the "module label" text style: the heading drawn above a homescreen
-- module ("Currently Reading" / "CURRENTLY READING"). Settings-window section
-- headers (System Icons, Title Bar, …) use a fixed all-caps look via
-- M.makeFixedCapsText and do not follow the user's module-label choice.
--
-- The style is a global Style ▸ Module Labels choice:
--   • style      classic | all caps   (classic by default)
-- and each style keeps its own text settings, the same Font / Style / Size
-- entries every module offers for its text elements (stored as the text
-- elements "section_label/label" for all caps and "section_label/label_classic"
-- for classic):
--   • font       family
--   • variant    regular…
--   • size       % of base
-- plus, for all caps only:
--   • tracking   % of the font size added after every character
--
-- Everything that draws such a label goes through M.makeText, and everything
-- that reserves room for one through M.height / M.gapBelow, so the drawn and
-- the reserved sizes cannot diverge.

local Device          = require("device")
local Font            = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local TextWidget      = require("ui/widget/textwidget")
local Screen          = Device.screen

local Config   = require("infra/sui_config")
local SUIStyle = require("features/sui_style")
local SUISettings = require("infra/sui_store")
local UI       = require("infra/sui_core")
local util     = require("util")

local M = {}

-- ---------------------------------------------------------------------------
-- Upper-casing that survives accents (Lua's string.upper is ASCII-only, which
-- would leave "ações" as "AçõES"): every code point goes through the Unicode
-- case mapping of the UTF-8 library KOReader ships.
-- ---------------------------------------------------------------------------

local ok_utf8, Utf8Proc = pcall(require, "ffi/utf8proc")

--- `text` in capitals, accent-aware. "ß" is spelled out as "SS", the usual
--- capital form, before the library maps the remaining code points.
function M.upper(text)
    if not text or text == "" then return text or "" end
    if ok_utf8 then
        local spelled = util.fixUtf8(text, "?"):gsub("ß", "SS")
        local ok, res = pcall(Utf8Proc.uppercase_dumb, spelled)
        if ok and type(res) == "string" then return res end
    end
    return text:upper()
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

-- Section labels have no module of their own; their text style lives under
-- this pseudo module id so presets and backups carry it ("simpleui_hs_…").
M.MOD_ID       = "section_label"
M.ELEM_CAPS    = "label"
M.ELEM_CLASSIC = "label_classic"

-- Bold until the user picks another variant.
Config.declareTextVariants(M.MOD_ID, { [M.ELEM_CAPS] = "bold", [M.ELEM_CLASSIC] = "bold" })

-- Unscaled text size of each style. The caps base is the detail size enlarged
-- by 10%; it stays fractional so every scale applied on top rounds only once.
local BASE_CAPS    = SUIStyle.FS_DETAIL * 1.1
local BASE_CLASSIC = SUIStyle.FS_BODY
M.BASE_CAPS = BASE_CAPS
M.TRACK_MIN   = 0
M.TRACK_MAX   = 60
M.TRACK_DEF   = 10
M.TRACK_STEP  = 5

local KEY_CAPS  = "simpleui_hs_section_label_caps"
local KEY_TRACK = "simpleui_hs_section_label_tracking"
local KEY_COLOR = "simpleui_hs_section_label_color"

-- Classic is the default; caps is on only when the user turns it on.
function M.isCaps()
    return SUISettings:isTrue(KEY_CAPS)
end

function M.setCaps(on)
    SUISettings:saveSetting(KEY_CAPS, on and true or false)
end

function M.getTrackingPct()
    local n = tonumber(SUISettings:get(KEY_TRACK))
    if not n then return M.TRACK_DEF end
    return math.max(M.TRACK_MIN, math.min(M.TRACK_MAX, math.floor(n)))
end

function M.setTrackingPct(pct)
    pct = math.max(M.TRACK_MIN, math.min(M.TRACK_MAX, math.floor(pct)))
    SUISettings:set(KEY_TRACK, pct)
end

--- The palette choice ("accent" | "secondary") the labels are drawn in; nil is
--- the plain text colour.
function M.getColor()
    local choice = SUISettings:get(KEY_COLOR)
    return SUIStyle.isPaletteChoice(choice) and choice or nil
end

function M.setColor(choice)
    if choice then SUISettings:set(KEY_COLOR, choice) else SUISettings:del(KEY_COLOR) end
end

--- Colour of a label, nil for the plain text colour: the chosen palette colour
--- while it is on screen. A label inside a module box (`inside`) takes it only
--- where it stands out from the box fill (`inside.palette`, see
--- ModuleChrome.palette).
function M.color(inside)
    local choice = M.getColor()
    if not choice then return nil end
    if inside then return inside.palette and inside.palette[choice] or nil end
    return SUIStyle.resolveColor(choice)
end

M.STYLE_CAPS    = "caps"
M.STYLE_CLASSIC = "classic"

--- `style` when given, else the style the user selected. Surfaces that always
--- draw one style pass it explicitly; it shares that style's text settings.
function M.resolveStyle(style)
    return style or (M.isCaps() and M.STYLE_CAPS or M.STYLE_CLASSIC)
end

--- The user's text style (family, scale, variant) of `style` (default: the
--- selected one).
function M.textStyle(style)
    local elem = M.resolveStyle(style) == M.STYLE_CAPS and M.ELEM_CAPS or M.ELEM_CLASSIC
    return Config.getTextStyle(M.MOD_ID, elem)
end

--- Everything that shapes a label, as one string: a cached widget stays valid
--- exactly while this string is unchanged.
function M.signature()
    local caps = M.isCaps()
    local s = M.textStyle()
    return table.concat({
        caps and "caps" or "classic", s.family or "", s.variant or "", s.scale or 1,
        caps and M.getTrackingPct() or 0,
    }, ":")
end

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

-- Extra room between a caps label and the content below it.
local function extraGapBase() return Screen:scaleBySize(6) end

--- Extra vertical space (px) a label adds below its text on top of the
--- standard padding: 0 for the classic style.
function M.extraGap(scale, style)
    if M.resolveStyle(style) ~= M.STYLE_CAPS then return 0 end
    return math.floor(extraGapBase() * (scale or 1))
end

-- Unscaled size of `style` unless the caller gives one.
local function baseSize(base, style)
    return base or (style == M.STYLE_CAPS and BASE_CAPS or BASE_CLASSIC)
end

--- Face, and whether the widget must still embolden it, of a label.
--- `base` is the unscaled size (default: that of the style); `scale` the
--- caller's multiplier (label scale × landscape factor, menu text size, …);
--- `style` the label style (default: the selected one).
function M.face(scale, base, style)
    style = M.resolveStyle(style)
    local text_style = M.textStyle(style)
    local size = math.max(8, math.floor(baseSize(base, style) * (scale or 1) * (text_style.scale or 1)))
    return SUIStyle.getTextFace(text_style, size)
end

--- Height of the text line of a label. A classic label in the default font
--- reserves its nominal size; any other label reserves the measured line.
function M.textHeight(scale, base, style)
    style = M.resolveStyle(style)
    local text_style = M.textStyle(style)
    if style == M.STYLE_CAPS or text_style.family then
        return SUIStyle.faceHeight((M.face(scale, base, style)))
    end
    return math.max(8, math.floor(Screen:scaleBySize(baseSize(base, style)) * (scale or 1) * (text_style.scale or 1)))
end

-- ---------------------------------------------------------------------------
-- Widget
-- ---------------------------------------------------------------------------

-- Text laid out one character at a time with `track` pixels after each. A
-- TextWidget cannot add letter spacing, and shaping does not matter for
-- capitals. Returns nil when the result would not fit `max_width`.
local function trackedText(text, face, bold, fgcolor, track, max_width, native_color)
    local group = HorizontalGroup:new{ align = "center" }
    local chars = util.splitToChars(text)
    for i, ch in ipairs(chars) do
        local args = { text = ch, face = face, bold = bold, fgcolor = fgcolor, padding = 0 }
        group[#group + 1] = native_color and TextWidget:new(args) or UI.makeColoredText(args)
        if track > 0 and i < #chars then
            group[#group + 1] = HorizontalSpan:new{ width = track }
        end
    end
    if max_width and group:getSize().w > max_width then
        group:free()
        return nil
    end
    return group
end

--- Builds a section label text.
---   text       string   as written; capitalised here in the caps style
---   fgcolor    colour   optional (tinted surface)
---   max_width  number   optional; the text is truncated (letter spacing is
---                       dropped first) so it never exceeds it
---   scale      number   multiplier of the base size (default 1)
---   base       number   unscaled size (default: that of the style)
---   style      string   M.STYLE_CAPS / M.STYLE_CLASSIC; default: the one the
---                       user selected
---   native_color bool   hand `fgcolor` to TextWidget as it is instead of
---                       masking it (text drawn on the plain window surface)
function M.makeText(opts)
    local build = opts.native_color and function(a) return TextWidget:new(a) end
                  or UI.makeColoredText
    local style = M.resolveStyle(opts.style)
    local face, bold = M.face(opts.scale, opts.base, style)
    if style ~= M.STYLE_CAPS then
        return build{
            text = opts.text, face = face, bold = bold,
            width = opts.max_width, max_width = opts.max_width, fgcolor = opts.fgcolor,
        }
    end

    local text  = M.upper(opts.text)
    local track = math.floor(face.size * M.getTrackingPct() / 100 + 0.5)

    local group = trackedText(text, face, bold, opts.fgcolor, track, opts.max_width, opts.native_color)
    if group then return group end

    -- Too long for the spaced layout: a plain, truncated caps line.
    return build{
        text = text, face = face, bold = bold, fgcolor = opts.fgcolor, padding = 0,
        max_width = opts.max_width, truncate_with_ellipsis = true,
    }
end

--- Fixed all-caps label for settings-window section headers. Same look as the
--- default all-caps module label (bold, BASE_CAPS, TRACK_DEF) but independent
--- of the Style ▸ Module Labels choice and of any user font/size/tracking.
function M.makeFixedCapsText(opts)
    local build = opts.native_color and function(a) return TextWidget:new(a) end
                  or UI.makeColoredText
    local size = math.max(8, math.floor((opts.base or BASE_CAPS) * (opts.scale or 1)))
    local face = Font:getFace(SUIStyle.FACE_REGULAR, size)
    local bold = true
    local text  = M.upper(opts.text)
    local track = math.floor(size * M.TRACK_DEF / 100 + 0.5)

    local group = trackedText(text, face, bold, opts.fgcolor, track, opts.max_width, opts.native_color)
    if group then return group end

    return build{
        text = text, face = face, bold = bold, fgcolor = opts.fgcolor, padding = 0,
        max_width = opts.max_width, truncate_with_ellipsis = true,
    }
end

return M
