-- sui_native_inputs.lua — Simple UI
-- Shows the text inputs of selected file manager, history and collection
-- actions (searches, rename, collection name, file type filter) through the
-- dialog facade (features/dialogs/sui_dialogs.lua), so they share
-- the look of the dialogs Simple UI opens itself.
--
-- The native dialog is an InputDialog, a class many other actions use. Only
-- the one shown while an entry point wrapped with NativeInputs.scoped runs is
-- converted (see INPUT_DIALOGS in infra/sui_patches.lua), so inputs opened by
-- anything else are never touched. The conversion itself is a kind of
-- features/dialogs/sui_native_widgets.lua, which also decides when the file
-- manager is the active environment.
--
-- The sheet stands in for the dialog without owning its behaviour: the text
-- is handed to the dialog and the callback of the button runs as it would on
-- the native one. The sheet stays open until that callback closes the dialog,
-- so a callback that ignores an empty text or reports an error leaves the
-- sheet as it leaves the dialog.
--
-- Which dialogs are converted
--   * only the exact InputDialog class with its default input widget;
--   * a single line of text: no password, no multi-line, full-screen or
--     read-only text, no save/reset buttons, no per-keystroke callbacks;
--   * one row of text buttons with a "close" button and at least one action;
--     the action flagged `is_enter_default` (else the last one) becomes OK,
--     in the order of the row; Enter presses OK only when an action is
--     flagged;
--   * added widgets, if any, are plain check buttons; they are drawn as rows
--     with a check box below the input, like the toggles of the settings
--     windows.
--
-- Public API
--   NativeInputs.scoped(show_dialog) -> function   wraps the function that
--                                                  shows a dialog; the dialog
--                                                  it shows is converted
--   NativeInputs.eligible(dialog) -> boolean       whether `dialog` is converted
--   NativeInputs.show(dialog) -> function          shows the sheet; returns the
--                                                  function that closes it

local CheckButton = require("ui/widget/checkbutton")
local InputText   = require("ui/widget/inputtext")

local NativeInputs = {}

-- Number of wrapped functions currently running.
local scope_depth = 0

-- InputDialog options the sheet does not cover.
local UNSUPPORTED = {
    "fullscreen", "readonly", "allow_newline", "add_nav_bar", "add_scroll_buttons",
    "use_available_height", "text_type", "save_callback", "reset_callback",
    "edited_callback", "strike_callback", "view_pos_callback", "title_bar_left_icon",
}

local function Dialogs() return require("features/dialogs/sui_dialogs") end

-- Ends a scope, then returns the results of the protected call.
local function endScope(ok, ...)
    scope_depth = scope_depth - 1
    if not ok then error((...), 0) end
    return ...
end

--- Wraps `show_dialog` so the input dialog it shows is converted.
function NativeInputs.scoped(show_dialog)
    return function(...)
        scope_depth = scope_depth + 1
        return endScope(pcall(show_dialog, ...))
    end
end

-- True when `spec` is a plain text button that runs a callback.
local function isPlainButton(spec)
    return type(spec) == "table"
        and type(spec.text) == "string"
        and type(spec.callback) == "function"
        and not spec.icon and not spec.text_func and not spec.enabled_func
        and not spec.hidden
end

-- Buttons of the dialog: { close, ok, extras, enter }, or nil when the row
-- does not fit the sheet. `enter` tells whether an action is flagged for Enter.
local function describeButtons(rows)
    if type(rows) ~= "table" or #rows ~= 1 then return nil end

    local close
    local actions = {}
    for _i, spec in ipairs(rows[1]) do
        if not isPlainButton(spec) then return nil end
        if spec.id == "close" then
            if close then return nil end
            close = spec
        else
            actions[#actions + 1] = spec
        end
    end
    if not close or #actions == 0 then return nil end

    -- The action Enter runs on the dialog: the flagged one, else the last.
    local ok_index, enter = #actions, false
    for i, spec in ipairs(actions) do
        if spec.is_enter_default then ok_index, enter = i, true end
    end
    local ok = table.remove(actions, ok_index)
    if ok.enabled == false then return nil end
    return { close = close, ok = ok, extras = actions, enter = enter }
end

-- Check buttons added to the dialog, or nil when it holds anything else.
local function describeBoxes(dialog)
    local boxes = {}
    for _i, container in ipairs(dialog._added_widgets or {}) do
        local box = container[1]
        if getmetatable(box) ~= CheckButton or box.radio
            or box.tap_input or box.tap_input_func or type(box.text) ~= "string" then
            return nil
        end
        boxes[#boxes + 1] = box
    end
    return boxes
end

-- What the sheet needs from `dialog`: { buttons, boxes }, or nil when it
-- cannot stand in for it.
local function describe(dialog)
    if dialog.inputtext_class ~= InputText then return nil end
    for _i, option in ipairs(UNSUPPORTED) do
        if dialog[option] then return nil end
    end
    if type(dialog.title) ~= "string" or type(dialog.input) ~= "string"
        or type(dialog.input_hint) ~= "string" then
        return nil
    end

    local buttons = describeButtons(dialog.buttons)
    local boxes   = buttons and describeBoxes(dialog)
    if not boxes then return nil end
    return { buttons = buttons, boxes = boxes }
end

function NativeInputs.eligible(dialog)
    return scope_depth > 0 and describe(dialog) ~= nil
end

function NativeInputs.show(dialog)
    local spec    = describe(dialog)
    local buttons = spec.buttons
    local window

    -- Hands the text of the sheet, as typed, to the dialog, whose callbacks
    -- read it.
    local function sync()
        dialog:setInputText(window:getFieldText(1))
    end

    -- Runs the callback of a native button on the text of the sheet.
    local function run(button)
        return function()
            sync()
            button.callback()
        end
    end

    -- Check buttons as toggle rows. Their state is written to the check button, the
    -- field the callbacks of the dialog read.
    local function toggles()
        local rows = {}
        for _i, box in ipairs(spec.boxes) do
            rows[#rows + 1] = {
                text     = box.text,
                toggle   = box.checked and true or false,
                enabled  = box.enabled ~= false,
                callback = function()
                    box.checked = not box.checked
                    if box.callback then box.callback() end
                    window:setActions(toggles())
                end,
            }
        end
        return rows
    end

    local extras = {}
    for _i, button in ipairs(buttons.extras) do
        extras[#extras + 1] = {
            text     = button.text,
            enabled  = button.enabled ~= false,
            callback = run(button),
        }
    end

    window = Dialogs().prompt{
        title           = dialog.title,
        description     = dialog.description,
        value           = dialog.input,
        hint            = dialog.input_hint ~= "" and dialog.input_hint or nil,
        input_type      = dialog.input_type,
        ok_text         = buttons.ok.text,
        cancel_text     = buttons.close.text,
        allow_empty     = true,
        keep_open       = true,
        cancel_first    = true,
        submit_on_enter = buttons.enter,
        actions         = #spec.boxes > 0 and toggles() or nil,
        buttons         = extras,
        on_submit       = run(buttons.ok),
        on_cancel       = buttons.close.callback,
    }

    -- The dialog never reaches the screen: its keyboard stays down.
    dialog.skip_first_show_keyboard = true

    return function()
        window:close()
        -- Frees the input widget and its keyboard, as closing the dialog would.
        dialog._input_widget:onCloseWidget()
    end
end

return NativeInputs
