-- sui_label_options.lua — Simple UI
-- Options of the name label drawn inside a cover (see
-- CoverWidgets.buildLabel), shared by every surface that offers it: the folder
-- covers of the library and the group covers of the modules.
--
-- A set of label options is a plain table of fields:
--   layout     "floating" | "band"
--   position   "top" | "center" | "bottom"
--   color      "light" | "gray" | "dark" | "accent" | "secondary"
--   opacity    0–100, opacity of the background (the text stays solid)
--   scale_pct  50–200, text size
--
-- Public API
-- ----------
--   LabelOptions.DEFAULTS
--   LabelOptions.normalize(field, value)   -> value, or the default when invalid
--   LabelOptions.resolve(stored)           -> every field normalised
--   LabelOptions.makeDisplay(fields)       -> `display` table of CoverWidgets.buildLabel
--   LabelOptions.makeMenuItems(opts)       -> { item, ... }

local _ = require("infra/sui_i18n").translate

local Accent   = require("infra/sui_accent")
local Backdrop = require("infra/sui_backdrop")
local Config   = require("infra/sui_config")

local LabelOptions = {}

local LAYOUTS   = { "floating", "band" }
local POSITIONS = { "top", "center", "bottom" }
local COLORS    = { "light", "gray", "dark", "accent", "secondary" }

local SCALE_MIN, SCALE_MAX = 50, 200

LabelOptions.DEFAULTS = {
    layout    = "floating",
    position  = "bottom",
    color     = "light",
    opacity   = Backdrop.SURFACE_DEFAULT.folder_label.strength,
    scale_pct = 100,
}
local DEFAULTS = LabelOptions.DEFAULTS

local function choiceNormalizer(field, values)
    return function(value) return Config.resolveChoice(value, values, DEFAULTS[field]) end
end

local NORMALIZERS = {
    layout   = choiceNormalizer("layout", LAYOUTS),
    position = choiceNormalizer("position", POSITIONS),
    color    = choiceNormalizer("color", COLORS),
    opacity  = function(value)
        return Backdrop.clampBackdropStrength(value) or DEFAULTS.opacity
    end,
    scale_pct = function(value)
        value = tonumber(value)
        if not value then return DEFAULTS.scale_pct end
        return math.max(SCALE_MIN, math.min(SCALE_MAX, math.floor(value)))
    end,
}

-- `value` of `field` when valid, else the default.
function LabelOptions.normalize(field, value)
    return NORMALIZERS[field](value)
end

-- Every field of `stored` (a table, possibly empty or nil) normalised.
function LabelOptions.resolve(stored)
    stored = stored or {}
    local fields = {}
    for field, normalize in pairs(NORMALIZERS) do fields[field] = normalize(stored[field]) end
    return fields
end

-- `display` table of CoverWidgets.buildLabel for a label that is shown.
-- `scale` multiplies the text size of the fields; `text_style` (optional) is
-- the text style of the name.
function LabelOptions.makeDisplay(fields, scale, text_style)
    return {
        show_name     = true,
        label_opacity = fields.opacity,
        label_layout  = fields.layout,
        label_pos     = fields.position,
        label_color   = fields.color,
        label_scale   = fields.scale_pct / 100 * (scale or 1),
        label_style   = text_style,
    }
end

-- Menu items editing a set of label options: layout, position, color,
-- background opacity and, when `opts.size_title` is given, text size.
--   opts.get(field)         -> current value of a field
--   opts.set(field, value)
--   opts.refresh            called after a change
--   opts.enabled_func       optional, disables every item
--   opts.size_title/info    title and description of the text size dialog;
--                           without a title there is no text size entry
--   opts._lc                optional translator
function LabelOptions.makeMenuItems(opts)
    local _lc, get, set, refresh = opts._lc or _, opts.get, opts.set, opts.refresh

    local function radioItem(field, text, options)
        return Config.makeRadioSubmenuItem{
            text         = text,
            options      = options,
            get          = function() return get(field) end,
            set          = function(value) set(field, value) end,
            refresh      = refresh,
            enabled_func = opts.enabled_func,
        }
    end

    local size_item
    if opts.size_title then
        size_item = Config.makeScaleItem{
            text_func = function() return _lc("Text Size") end,
            title     = opts.size_title,
            info      = opts.size_info,
            value_min = SCALE_MIN,
            value_max = SCALE_MAX,
            get       = function() return get("scale_pct") end,
            set       = function(value) set("scale_pct", value) end,
            refresh   = refresh,
        }
        size_item.enabled_func = opts.enabled_func
    end

    local color_options = {
        { value = "light", label = _lc("Light") },
        { value = "gray",  label = _lc("Gray") },
        { value = "dark",  label = _lc("Dark") },
    }
    if Accent.isSupported() then
        color_options[#color_options + 1] = { value = "accent",    label = _lc("Accent") }
        color_options[#color_options + 1] = { value = "secondary", label = _lc("Secondary") }
    end

    local items = {
        radioItem("layout", _lc("Layout"), {
            { value = "floating", label = _lc("Floating") },
            { value = "band",     label = _lc("Full Width") },
        }),
        radioItem("position", _lc("Position"), {
            { value = "top",    label = _lc("Top") },
            { value = "center", label = _lc("Center") },
            { value = "bottom", label = _lc("Bottom") },
        }),
        radioItem("color", _lc("Color"), color_options),
        Config.makeBackdropStrengthItem{
            title         = _lc("Background Opacity"),
            info          = _lc("0% transparent, 100% solid. Only the background changes; the text stays solid."),
            get           = function() return get("opacity") end,
            set           = function(value) set("opacity", value) end,
            default_value = DEFAULTS.opacity,
            enabled_func  = opts.enabled_func,
            refresh       = refresh,
            _lc           = _lc,
        },
    }
    items[#items + 1] = size_item
    return items
end

return LabelOptions
