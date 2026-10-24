-- sui_native_widgets.lua — Simple UI
-- Shows the confirm boxes, number pickers, text inputs and notices of the
-- desktop (file manager, collections, history, folder and path pickers)
-- through the dialog facade (features/dialogs/sui_dialogs.lua,
-- engines/sui_toast.lua), so they share the look of the dialogs Simple UI
-- opens itself.
--
-- A widget is converted when it is about to be shown (see the intercept steps
-- in infra/sui_window_hooks.lua). Its callers are not aware of it: closing the
-- widget closes whatever stands in for it, and the callbacks the widget
-- carries run as they would on the native one.
--
-- Which widgets are converted
--   * only the exact classes ConfirmBox, SpinWidget, DoubleSpinWidget,
--     InfoMessage and InputDialog, never a subclass;
--   * only while the file manager is the active environment, never over a
--     book, and over a Simple UI window only inside showOverWindows (see
--     NativeSheets.canReplace);
--   * only widgets whose options the facade covers:
--       ConfirmBox        no timeout, not kept open after an answer;
--       SpinWidget        whole numbers, no value table, no extra or option
--                         button, not kept shown after apply, no wrap;
--       DoubleSpinWidget  whole numbers, no range constraint;
--       InfoMessage       text only (no image), not invisible;
--       InputDialog       only while an entry point wrapped by
--                         features/dialogs/sui_native_inputs.lua shows it,
--                         and only a single line of text (see that module).
-- Everything else is shown as usual.
--
-- Public API
--   NativeWidgets.interceptShow(widget) -> boolean   show step (consumes the call)
--   NativeWidgets.interceptClose(widget) -> boolean  close step (consumes the call)
--   NativeWidgets.showOverWindows(fn, ...) -> ...    runs fn; widgets it shows are
--                                                    converted even above a Simple UI window

local logger = require("logger")

local NativeSheets = require("features/dialogs/sui_native_sheets")
local NativeInputs = require("features/dialogs/sui_native_inputs")

local NativeWidgets = {}

-- True while showOverWindows runs its function.
local over_windows = false

-- Native widget → function that closes what stands in for it. Weak, so a
-- widget nobody references any more is not kept alive.
local stand_ins = setmetatable({}, { __mode = "k" })

local function Dialogs() return require("features/dialogs/sui_dialogs") end

local function isWhole(value)
    return type(value) == "number" and value == math.floor(value)
end

-- True when every value is nil or a whole number.
local function allWhole(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value ~= nil and not isWhole(value) then return false end
    end
    return true
end

-- True when every button of `rows` is a plain text button.
local function hasTextButtons(rows)
    for _i, row in ipairs(rows or {}) do
        if type(row) ~= "table" then return false end
        for _j, spec in ipairs(row) do
            if type(spec.text) ~= "string" then return false end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------

-- Each kind lists the module of its class and two functions: `eligible(widget)`
-- and `show(widget)`, which returns the function that closes the replacement.
local KINDS = {
    {
        module   = "ui/widget/confirmbox",
        eligible = function(w)
            return type(w.text) == "string"
                and not w.timeout
                and not w.keep_dialog_open
                and hasTextButtons(w.other_buttons)
        end,
        show = function(w)
            local window = Dialogs().confirm{
                text                = w.text,
                ok_text             = w.ok_text,
                cancel_text         = w.cancel_text,
                ok_callback         = w.ok_callback,
                cancel_callback     = w.cancel_callback,
                no_ok_button        = w.no_ok_button,
                dismissable         = w.dismissable,
                other_buttons       = w.other_buttons,
                other_buttons_first = w.other_buttons_first,
            }
            return function() window:close() end
        end,
    },
    {
        module   = "ui/widget/spinwidget",
        eligible = function(w)
            return isWhole(w.value) and isWhole(w.value_min) and isWhole(w.value_max)
                and allWhole(w.value_step, w.value_hold_step, w.default_value)
                and not w.precision
                and not w.value_table
                and not w.extra_text
                and not w.option_text
                and not w.wrap
        end,
        show = function(w)
            local window = Dialogs().spin{
                title       = w.title_text,
                info        = w.info_text,
                value       = w.value,
                min         = w.value_min,
                max         = w.value_max,
                step        = w.value_step,
                hold_step   = w.value_hold_step,
                unit        = w.unit,
                default     = w.default_value,
                ok_text     = w.ok_text,
                cancel_text = w.cancel_text,
                keep_open   = w.keep_shown_on_apply,
                on_apply    = function(value)
                    -- Callers read the picked value from the widget they
                    -- were handed.
                    w.value = value
                    if w.callback then w.callback(w) end
                    if w.close_callback and not w.keep_shown_on_apply then
                        w.close_callback()
                    end
                end,
                on_cancel   = w.close_callback,
            }
            return function() window:close() end
        end,
    },
    {
        module   = "ui/widget/doublespinwidget",
        eligible = function(w)
            return isWhole(w.left_value) and isWhole(w.left_min) and isWhole(w.left_max)
                and isWhole(w.right_value) and isWhole(w.right_min) and isWhole(w.right_max)
                and allWhole(w.left_step, w.left_hold_step, w.left_default,
                             w.right_step, w.right_hold_step, w.right_default)
                and not w.precision
                and not w.is_range
        end,
        show = function(w)
            local window = Dialogs().spin2{
                title       = w.title_text,
                info        = w.info_text,
                ok_text     = w.ok_text,
                cancel_text = w.cancel_text,
                keep_open   = w.keep_shown_on_apply,
                left = {
                    text = w.left_text, value = w.left_value,
                    min = w.left_min, max = w.left_max,
                    step = w.left_step, hold_step = w.left_hold_step,
                    unit = w.unit, default = w.left_default,
                },
                right = {
                    text = w.right_text, value = w.right_value,
                    min = w.right_min, max = w.right_max,
                    step = w.right_step, hold_step = w.right_hold_step,
                    unit = w.unit, default = w.right_default,
                },
                on_apply    = function(left, right)
                    w.left_value, w.right_value = left, right
                    if w.callback then w.callback(left, right) end
                    if w.close_callback and not w.keep_shown_on_apply then
                        w.close_callback()
                    end
                end,
                on_cancel   = w.close_callback,
            }
            return function() window:close() end
        end,
    },
    {
        module   = "ui/widget/infomessage",
        eligible = function(w)
            return type(w.text) == "string"
                and not w.image
                and not w.invisible
        end,
        show = function(w)
            local UIManager = require("ui/uimanager")
            local toast = require("engines/sui_toast"):new{
                text             = w.text,
                timeout          = w.timeout,
                dismiss_callback = w.dismiss_callback,
            }
            UIManager:show(toast)
            return function() UIManager:close(toast) end
        end,
    },
    {
        module   = "ui/widget/inputdialog",
        eligible = NativeInputs.eligible,
        show     = NativeInputs.show,
    },
}

-- The kind of `widget`, or nil. Compares the metatable with the loaded
-- classes only, so a widget of any other class costs a few lookups.
local function kindOf(widget)
    local class = getmetatable(widget)
    if class == nil then return nil end
    for _i, kind in ipairs(KINDS) do
        if package.loaded[kind.module] == class then return kind end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Showing and closing
-- ---------------------------------------------------------------------------

--- Show step: replaces an eligible native widget. Returns true when the widget
--- was consumed.
function NativeWidgets.interceptShow(widget)
    if widget == nil then return false end
    local kind = kindOf(widget)
    if not kind or not NativeSheets.canReplace(over_windows) or not kind.eligible(widget) then
        return false
    end

    local ok, close = pcall(kind.show, widget)
    if ok then
        stand_ins[widget] = close
        return true
    end
    logger.warn("simpleui/native_widgets: replacement failed, showing the widget:",
        tostring(close))
    return false
end

--- Runs `fn(...)` with native widgets it shows converted even while a Simple UI
--- window is open. Returns what `fn` returns.
function NativeWidgets.showOverWindows(fn, ...)
    local previous = over_windows
    over_windows = true
    local results = table.pack(pcall(fn, ...))
    over_windows = previous
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

--- Close step: closing a widget that something stands in for closes that. The
--- callbacks of the widget do not run, as when the native one is closed by
--- code.
function NativeWidgets.interceptClose(widget)
    local close = stand_ins[widget]
    if not close then return false end
    stand_ins[widget] = nil
    pcall(close)
    return true
end

return NativeWidgets
