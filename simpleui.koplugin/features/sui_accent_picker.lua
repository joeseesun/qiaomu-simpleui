-- sui_accent_picker.lua — Simple UI
-- Sheet to choose a palette colour (accent or secondary): round preset
-- swatches, a pill previewing the colour (a tap on it types a hex code), plus
-- hue, saturation and brightness steppers for a custom colour. Everything is
-- reachable with touch or with the D-pad (swatches, the pill and the steppers
-- are focus stops).
--
--   AccentPicker.show{
--     title      = _("Accent Color"),   -- sheet title
--     name       = "sui_win_accent",    -- window name (optional)
--     hex        = "#2F6FDB",           -- stored colour; nil while none is set
--     clear_text = _("Clear"),          -- label of the button that clears the colour
--     on_apply   = function(hex_or_nil) end,
--   }
--     While no colour is set the pill is an empty outline, no swatch is selected and
--     the steppers start at the first preset; the first change sets the colour.
--     Apply needs a colour that differs from the stored one; Clear needs a stored one.
--     on_apply receives the chosen "#RRGGBB", or nil when the colour is cleared.

local ActionSheet = require("engines/sui_action_sheet")
local Accent      = require("infra/sui_accent")
local Dialogs     = require("features/dialogs/sui_dialogs")
local _           = require("infra/sui_i18n").translate

local AccentPicker = {}

local HUE_STEP, SB_STEP = 5, 5

function AccentPicker.show(opts)
    local stored = opts.hex
    local hex = stored
    local hue, sat, val = Accent.hexToHsv(hex or Accent.PALETTE[1])
    local window, sections, footer   -- assigned below the helpers that rebuild them

    local function refresh()
        window:update{ sections = sections(), footer = footer() }
    end

    local function setHsv(h, s, v)
        hue, sat, val = h, s, v
        hex = Accent.hsvToHex(hue, sat, val)
        refresh()
    end

    -- Takes a colour as it is, steppers included.
    local function setHex(new_hex)
        hex = new_hex
        hue, sat, val = Accent.hexToHsv(hex)
        refresh()
    end

    -- Sheet over the picker with a text input for the hex code of the colour.
    local function editHex()
        local invalid = _("Enter a color like #2F6FDB.")
        Dialogs.prompt{
            title       = _("Hex Color"),
            value       = hex or "",
            hint        = "#RRGGBB",
            empty_error = invalid,
            validate    = function(text)
                if not Accent.normalizeHex(text) then return invalid end
            end,
            on_submit   = function(text) setHex(Accent.normalizeHex(text)) end,
        }
    end

    sections = function()
        local presets = {}
        for i, preset in ipairs(Accent.PALETTE) do
            presets[i] = {
                color    = Accent.toColor(preset),
                selected = preset == hex,
                callback = function() setHex(preset) end,
            }
        end
        return {
            { type = "swatches", items = presets },
            { type = "swatches", items = { {
                color    = hex and Accent.toColor(hex) or nil,
                label    = not hex and _("Choose a color") or nil,
                pill     = true,
                callback = editHex,
            } } },
            { type = "stepper", label = _("Hue"), unit = "°", min = 0, max = 359,
              step = HUE_STEP, hold_step = 3 * HUE_STEP, value = hue,
              on_change = function(v) hue = v end,
              on_commit = function() setHsv(hue, sat, val) end },
            { type = "stepper", label = _("Saturation"), unit = "%", min = 0, max = 100,
              step = SB_STEP, hold_step = 2 * SB_STEP, value = sat,
              on_change = function(v) sat = v end,
              on_commit = function() setHsv(hue, sat, val) end },
            { type = "stepper", label = _("Brightness"), unit = "%", min = 0, max = 100,
              step = SB_STEP, hold_step = 2 * SB_STEP, value = val,
              on_change = function(v) val = v end,
              on_commit = function() setHsv(hue, sat, val) end },
        }
    end

    footer = function()
        return {
            { text = opts.clear_text or _("Clear"), enabled = stored ~= nil,
              callback = function() window:close(); opts.on_apply(nil) end },
            { text = _("Cancel"), callback = function() window:close() end },
            { text = _("Apply"), primary = true, enabled = hex ~= nil and hex ~= stored,
              callback = function() window:close(); opts.on_apply(hex) end },
        }
    end

    window = ActionSheet.show{
        name     = opts.name or "sui_win_accent",
        title    = opts.title,
        flow     = true,
        sections = sections(),
        footer   = footer(),
    }
    return window
end

return AccentPicker
