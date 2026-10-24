-- module_spacer.lua — Simple UI
-- Module: Spacer Row (dynamic instances).
-- Blank space block to give extra spacing between modules.
-- Exposes M.instanciable = true and M.makeInstance(id) for the registry.
-- The only configurable setting is the size (a spin dialog, as a percentage),
-- following the same mechanics as the other modules.

local Device       = require("device")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen       = Device.screen
local _            = require("infra/sui_i18n").translate

local Config      = require("infra/sui_config")
local SUISettings = require("infra/sui_store")

-- Base spacer height at 100% scale.
local _BASE_SPACER_H = Screen:scaleBySize(50)

-- Spacer's own scale limits — wider than the global SCALE_MAX (200), and with
-- no practical lower floor beyond 1% so narrow gaps can be fine-tuned. The
-- actual rendered height is still floored at 2px in getHeight()/build().
local _SCALE_MIN  = 1
local _SCALE_MAX  = 400
local _SCALE_STEP = 10
local _SCALE_DEF  = 100

local function _scaleKey(mod_id, pfx)
    return (pfx or "simpleui_hs_") .. mod_id .. "_scale"
end

local function _clampSpacerScale(n)
    return math.max(_SCALE_MIN, math.min(_SCALE_MAX, math.floor(n)))
end

local function _getScalePct(mod_id, pfx)
    local v = SUISettings:get(_scaleKey(mod_id, pfx))
    local n = tonumber(v)
    if not n then return _SCALE_DEF end
    return _clampSpacerScale(n)
end

local function _getScale(mod_id, pfx)
    return _getScalePct(mod_id, pfx) / 100
end

local function _setScale(pct, mod_id, pfx)
    SUISettings:set(_scaleKey(mod_id, pfx), _clampSpacerScale(pct))
end

-- ---------------------------------------------------------------------------
-- Slot factory — creates a module descriptor per instance
-- ---------------------------------------------------------------------------
local function makeInstance(inst_id)
    local slot_suffix = inst_id

    local S = {}
    S.id             = inst_id
    S.name           = _("Spacer")
    S.label          = nil
    S.default_on     = false
    S.no_top_margin  = true  -- suppresses the "Top Margin" item in the settings menu

    function S.isEnabled(pfx)
        return SUISettings:readSetting(pfx .. slot_suffix .. "_enabled") == true
    end

    function S.setEnabled(pfx, on)
        SUISettings:saveSetting(pfx .. slot_suffix .. "_enabled", on)
    end

    function S.build(w, ctx)
        if not S.isEnabled(ctx.pfx) then return nil end
        local h = math.max(2, math.floor(_BASE_SPACER_H * _getScale(S.id, ctx.pfx)))
        -- VerticalSpan uses the `width` field as height — this is KOReader's convention.
        return VerticalSpan:new{ width = h }
    end

    function S.getHeight(ctx)
        return math.max(2, math.floor(_BASE_SPACER_H * _getScale(S.id, ctx.pfx)))
    end

    function S.getMenuItems(ctx_menu)
        local pfx     = ctx_menu.pfx
        local refresh = ctx_menu.refresh
        local _lc     = ctx_menu._ or _

        return {
            Config.makeScaleItem({
                text_func       = function() return _lc("Spacer Size") end,
                title           = _lc("Spacer Size"),
                info            = _lc("Height of the spacer.\n100% is the default size.\nTap the arrows for fine steps, hold for larger ones."),
                get             = function() return _getScalePct(S.id, pfx) end,
                set             = function(v) _setScale(v, S.id, pfx) end,
                refresh         = refresh,
                value_min       = _SCALE_MIN,
                value_max       = _SCALE_MAX,
                value_step      = 1,
                value_hold_step = _SCALE_STEP,
                default_value   = _SCALE_DEF,
            }),
        }
    end

    return S
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------
local M = {}
M.id            = "spacer_row"
M.name          = _("Spacer")
M.instanciable  = true
M.makeInstance  = makeInstance
M.instances_key = "simpleui_spacer_row_instances"
M.menu_group    = "quick_actions"

-- Layout-editor summary of an instance: its height as a scale percentage.
function M.getSummary(inst_id, pfx)
    return Config.getModuleScalePct(inst_id, pfx) .. "%"
end

return M
