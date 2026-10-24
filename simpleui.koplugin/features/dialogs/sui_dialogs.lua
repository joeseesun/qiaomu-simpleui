-- sui_dialogs.lua — Simple UI
-- The dialogs Simple UI opens itself, drawn as sheets (engines/sui_action_sheet.lua)
-- so they share one look with the action sheets of books, folders and menus.
-- Option names follow the native widgets they stand for.
--
-- Public API
--   Dialogs.confirm(opts) -> SUIWindow
--     A question with a Cancel and an action button.
--       text             string    the question; line breaks start new paragraphs
--       ok_text          string    label of the action button (default "OK")
--       cancel_text      string    label of the other button (default "Cancel")
--       ok_callback      function  action button tapped
--       cancel_callback  function  Cancel tapped, or the sheet dismissed (tap
--                                  outside, Back key)
--       no_ok_button     bool      only the Cancel button
--       dismissable      bool      false: tap outside and Back do nothing, so
--                                  the question is answered with a button
--       other_buttons    table     rows of further buttons, { { { text,
--                                  enabled, callback }, ... }, ... }, one
--                                  segments row each
--       other_buttons_first bool   the other rows above the Cancel / action row
--                                  instead of below it
--       title            string    heading, needed by a page for its back button
--       parent           SUIWindow a sheet created with `flow` to show the question
--                                  on as a page; the buttons go back to it
--                                  (`levels` pages, default 1) before any callback
--                                  runs, and Cancel goes back one page
--       close_parent     bool      with `parent`, the answer closes that sheet
--     The sheet closes before any callback runs.
--
--   Dialogs.askRestart(opts) -> SUIWindow
--     Offers a restart for a change that needs one. The settings are saved
--     when the question is shown. The restart goes through the "Restart"
--     event, which closes the file manager or the open book first.
--       text             string    the question
--       ok_text          string    label of the restart button (default "Restart")
--       cancel_text      string    label of the other button (default "Later")
--
--   Dialogs.askReboot(opts) -> SUIWindow
--     Asks whether to reboot the device; the reboot is the one the device
--     menu runs. The settings are saved when the reboot is confirmed.
--       text             string    the question (default: the device menu's)
--
--   Dialogs.spin(opts) -> SUIWindow
--     Picks a number with a slider and minus / plus controls. Buttons:
--     [Default | Cancel | Apply]; Default only when `default` is given and
--     only moves the slider back, Apply is always enabled.
--       title, info      string    header and the description under it
--       value            number    initial value
--       min, max         number    range
--       step             number    change of a tap on a control (default 1)
--       hold_step        number    change of a long press (default `step`)
--       unit             string    shown after the value (e.g. "%")
--       default          number    value restored by Default
--       ok_text          string    label of Apply (default "Apply")
--       cancel_text      string    label of Cancel (default "Cancel")
--       on_apply         function  called with the value; the sheet closes first
--       on_cancel        function  Cancel tapped, or the sheet dismissed
--       on_preview       function  called with the value each time it settles (a
--                                  tap, a step, the end of a drag, Default), to
--                                  show the result behind the sheet; the caller
--                                  restores the old value in on_cancel
--
--   Dialogs.spin2(opts) -> SUIWindow
--     Two numbers, one above the other, with one Apply. `title`, `info`, `on_cancel`,
--     `ok_text`, `cancel_text` as in spin, plus
--       left, right      table     { text, value, min, max, step, hold_step,
--                                  unit, default, on_preview, auto, auto_text };
--                                  `text` captions the slider. `auto` marks a
--                                  value that is automatic: it shows `auto_text`
--                                  as its caption until the slider moves, and
--                                  Default restores it (Default needs `default`
--                                  as the number to show meanwhile)
--       keep_open        bool      Apply leaves the sheet open, to show the
--                                  result behind it
--       on_apply         function  called with the left and the right value,
--                                  then a table flagging by index (1, 2) the
--                                  values still automatic
--
--   Dialogs.prompt(opts) -> SUIWindow
--     Asks for one line of text, with the keyboard below the sheet. Buttons:
--     [extra buttons | Cancel | OK]; Enter presses OK.
--       title, description  string  header and the text under it
--       value             string    initial text
--       hint              string    shown while the input is empty
--       input_type        string    InputText input type (default "text")
--       ok_text           string    label of OK (default "OK")
--       cancel_text       string    label of Cancel (default "Cancel")
--       allow_empty       bool      an empty text is submitted as "" instead of
--                                   being ignored (the sheet stays open)
--       empty_error       string    shown inline when an empty text is ignored
--       keep_open         bool      OK and the extra buttons leave the sheet open:
--                                   their callbacks close it (window:close()) when
--                                   they accept the text
--       submit_on_enter   bool      false: Enter does not press OK (default true)
--       cancel_first      bool      Cancel leads the buttons, before the extra
--                                   ones, instead of following them
--       validate          function  called with the trimmed text; returns an
--                                   error message to show inline and keep the
--                                   sheet open, false to keep it open without a
--                                   message, or nil to accept. Not called for an
--                                   empty text
--       on_submit         function  called with the trimmed text; the sheet
--                                   closes first
--       on_cancel         function  Cancel tapped, or the sheet dismissed
--       buttons           table     extra buttons before Cancel: { text,
--                                   enabled, callback }; the sheet closes
--                                   first and `callback` gets the array of
--                                   trimmed texts (one for prompt)
--       confirm           function  called with the array of trimmed texts once
--                                   `validate` accepts them; returns nil to
--                                   submit, or { title, text, ok_text } to ask
--                                   first on a page of the sheet: OK submits,
--                                   Cancel returns to the inputs
--
--   Dialogs.form(opts) -> SUIWindow
--     Several lines of text, one above the other. `title`, `description`,
--     `ok_text`, `cancel_text`, `on_cancel` as in prompt, plus
--       fields            table     { { label, value, hint, input_type }, ... }
--       actions           table     rows listed below the fields: { text,
--                                   sui_icon, toggle, callback }; they leave the
--                                   sheet open. `toggle` draws a check box
--       validate          function  called with the array of trimmed texts;
--                                   returns as in prompt
--       on_submit         function  called with the array of trimmed texts
--       buttons           table     as in prompt; `callback` gets the array
--     The returned sheet also has getValues(), the array of trimmed texts, and
--     setActions(actions), which replaces `actions` while the sheet shows its
--     own screen.
--
--   prompt and form can also be a page of a sheet created with `flow`
--   (ActionSheet.show), instead of a sheet of their own:
--       parent           SUIWindow the page is shown on; it returns that sheet
--       close_parent     bool      OK, and a button of `buttons`, close the
--                                  parent sheet instead of going back to it
--       levels           number    OK, and a button of `buttons`, leave this
--                                  many pages at once (default 1)
--       flow             bool      the sheet of a prompt or form can show pages
--                                  (without `parent` only)
--     Cancel goes back to the parent, whose screen below keeps its state;
--     `on_cancel` runs after it.

local ActionSheet = require("engines/sui_action_sheet")
local util        = require("util")
local Event       = require("ui/event")
local UIManager   = require("ui/uimanager")
local SUISettings = require("infra/sui_store")
local _           = require("infra/sui_i18n").translate

local unpack = table.unpack or unpack

local Dialogs = {}

-- Leaves what `window` shows: its page, or the sheet itself. A page of a
-- `parent` goes back `opts.levels` pages, or one when `cancelled`; with
-- `opts.close_parent` an answer closes the whole sheet.
local function leave(opts, window, cancelled)
    if opts.parent and (cancelled or not opts.close_parent) then
        window:closePage(not cancelled and opts.levels or nil)
    else
        window:close()
    end
end

function Dialogs.confirm(opts)
    local window = opts.parent

    -- Button callback: leaves the sheet, then runs `callback`.
    local function answer(callback, cancelled)
        return function()
            leave(opts, window, cancelled)
            if callback then callback() end
        end
    end

    local main = { { text = opts.cancel_text or _("Cancel"), callback = answer(opts.cancel_callback, true) } }
    if not opts.no_ok_button then
        main[#main + 1] = { text = opts.ok_text or _("OK"), primary = true, callback = answer(opts.ok_callback) }
    end

    local others = {}
    for _i, row in ipairs(opts.other_buttons or {}) do
        local items = {}
        for _j, spec in ipairs(row) do
            items[#items + 1] = {
                text     = spec.text,
                enabled  = spec.enabled,
                callback = answer(spec.callback),
            }
        end
        if #items > 0 then others[#others + 1] = { type = "segments", items = items } end
    end

    local sections = { { type = "segments", items = main } }
    for _i, section in ipairs(others) do
        table.insert(sections, opts.other_buttons_first and #sections or #sections + 1, section)
    end

    if window then
        window:showPage{ title = opts.title, message = opts.text, sections = sections }
        return window
    end
    window = ActionSheet.show{
        name        = "sui_win_confirm",
        message     = opts.text,
        dismissable = opts.dismissable,
        on_dismiss  = opts.cancel_callback,
        sections    = sections,
    }
    return window
end

function Dialogs.askRestart(opts)
    SUISettings:flush()
    return Dialogs.confirm{
        text        = opts.text,
        ok_text     = opts.ok_text or _("Restart"),
        cancel_text = opts.cancel_text or _("Later"),
        ok_callback = function()
            UIManager:broadcastEvent(Event:new("Restart"))
        end,
    }
end

function Dialogs.askReboot(opts)
    return Dialogs.confirm{
        text        = opts and opts.text or _("Are you sure you want to reboot the device?"),
        ok_text     = _("Reboot"),
        ok_callback = function()
            SUISettings:flush()
            UIManager:nextTick(UIManager.reboot_action)
        end,
    }
end

-- Sheet of one stepper per entry of `fields`, with the [Default | Cancel |
-- Apply] footer. `on_apply` receives the values in the order of `fields`.
local function showSteppers(opts, fields)
    local window
    local values = {}
    -- auto: the value is automatic; shown: what the captions currently say.
    local auto, shown = {}, {}
    for i, field in ipairs(fields) do
        values[i] = field.value
        auto[i]   = field.auto and true or false
    end

    -- The sections are built from `values`, which the steppers keep current,
    -- so the sheet can be rebuilt at any point.
    local function sections()
        local built = {}
        for i, field in ipairs(fields) do
            shown[i] = auto[i]
            built[i] = {
                type      = "stepper",
                label     = auto[i] and field.auto_text or field.text,
                value     = values[i],
                min       = field.min,
                max       = field.max,
                step      = field.step,
                hold_step = field.hold_step,
                unit      = field.unit,
                on_change = function(value)
                    values[i] = value
                    auto[i]   = false
                end,
                -- The caption leaves "automatic" once the change settles, not
                -- mid-drag.
                on_commit = function(value)
                    if field.on_preview then field.on_preview(value) end
                    if shown[i] ~= auto[i] then window:update{ sections = sections() } end
                end,
            }
        end
        return built
    end

    local footer = {}
    local has_default = false
    for _i, field in ipairs(fields) do
        has_default = has_default or field.default ~= nil
    end
    if has_default then
        footer[#footer + 1] = {
            text     = _("Default"),
            callback = function()
                for i, field in ipairs(fields) do
                    if field.default ~= nil then
                        values[i] = field.default
                        auto[i]   = field.auto_text ~= nil
                        if field.on_preview then field.on_preview(field.default) end
                    end
                end
                window:update{ sections = sections() }
            end,
        }
    end
    footer[#footer + 1] = {
        text     = opts.cancel_text or _("Cancel"),
        callback = function()
            window:close()
            if opts.on_cancel then opts.on_cancel() end
        end,
    }
    footer[#footer + 1] = {
        text     = opts.ok_text or _("Apply"),
        primary  = true,
        callback = function()
            if not opts.keep_open then window:close() end
            if opts.on_apply then
                local args = { unpack(values, 1, #fields) }
                args[#fields + 1] = auto
                opts.on_apply(unpack(args, 1, #fields + 1))
            end
        end,
    }

    window = ActionSheet.show{
        name       = "sui_win_spin",
        title      = opts.title,
        message    = opts.info,
        on_dismiss = opts.on_cancel,
        footer     = footer,
        sections   = sections(),
    }
    return window
end

function Dialogs.spin(opts)
    return showSteppers(opts, { opts })
end

function Dialogs.spin2(opts)
    return showSteppers(opts, { opts.left, opts.right })
end

-- Sheet of one text input per entry of `fields`, with the [extra buttons |
-- Cancel | OK] footer. `validate` and `finish` receive the array of trimmed
-- texts; `finish` runs once `validate` accepts them, after the sheet closed.
local function showInputs(opts, fields, validate, finish)
    local window = opts.parent
    local message   -- inline error, shown under the inputs

    local function values()
        local texts = {}
        for i = 1, #fields do texts[i] = util.trim(window:getFieldText(i)) end
        return texts
    end

    -- The inputs are created with the sheet and keep their text, so a build
    -- only needs their position, label, hint and type.
    local function sections()
        local built = {}
        for i, field in ipairs(fields) do
            built[i] = {
                type       = "field",
                id         = i,
                label      = field.label,
                value      = field.value,
                hint       = field.hint,
                input_type = field.input_type,
            }
        end
        built[#built + 1] = { type = "note", text = message }
        if opts.actions then built[#built + 1] = ActionSheet.list(opts.actions) end
        return built
    end

    local function setMessage(text)
        if message == text then return end
        message = text
        window:update{ sections = sections() }
    end

    local function submit()
        local texts = values()
        local problem = validate(texts)
        if problem == nil then
            local ask = opts.confirm and opts.confirm(texts)
            if ask then
                -- OK leaves the confirmation and then the inputs, as submitting does.
                Dialogs.confirm{
                    parent       = window,
                    title        = ask.title,
                    text         = ask.text,
                    ok_text      = ask.ok_text,
                    close_parent = not opts.parent or opts.close_parent,
                    levels       = (opts.levels or 1) + 1,
                    ok_callback  = function() finish(texts) end,
                }
                return
            end
            if not opts.keep_open then leave(opts, window) end
            finish(texts)
        else
            setMessage(problem or nil)
        end
    end

    local extras = {}
    for _i, extra in ipairs(opts.buttons or {}) do
        extras[#extras + 1] = {
            text     = extra.text,
            enabled  = extra.enabled,
            callback = function()
                local texts = values()
                if not opts.keep_open then leave(opts, window) end
                if extra.callback then extra.callback(texts) end
            end,
        }
    end
    local cancel = {
        text     = opts.cancel_text or _("Cancel"),
        callback = function()
            leave(opts, window, true)
            if opts.on_cancel then opts.on_cancel() end
        end,
    }

    local footer = {}
    if opts.cancel_first then footer[1] = cancel end
    for _i, extra in ipairs(extras) do footer[#footer + 1] = extra end
    if not opts.cancel_first then footer[#footer + 1] = cancel end
    footer[#footer + 1] = {
        text     = opts.ok_text or _("OK"),
        primary  = true,
        callback = submit,
    }

    local content = {
        title    = opts.title,
        message  = opts.description,
        footer   = footer,
        sections = sections(),
        on_enter = opts.submit_on_enter ~= false and submit or nil,
        on_edit  = function() setMessage(nil) end,
    }
    if window then
        window:showPage(content)
        return window
    end
    content.name       = "sui_win_input"
    content.flow       = opts.flow or opts.confirm ~= nil or nil
    content.on_dismiss = opts.on_cancel
    window = ActionSheet.show(content)
    function window:getValues() return values() end
    -- Replaces the rows listed below the fields and redraws the sheet.
    function window:setActions(actions)
        opts.actions = actions
        self:update{ sections = sections() }
    end
    return window
end

function Dialogs.prompt(opts)
    local function validate(texts)
        local text = texts[1]
        if text == "" then
            if opts.allow_empty then return nil end
            return opts.empty_error or false
        end
        return opts.validate and opts.validate(text)
    end
    return showInputs(opts, { opts }, validate, function(texts)
        if opts.on_submit then opts.on_submit(texts[1]) end
    end)
end

function Dialogs.form(opts)
    return showInputs(opts, opts.fields,
        function(texts) return opts.validate and opts.validate(texts) end,
        function(texts) if opts.on_submit then opts.on_submit(texts) end end)
end

return Dialogs
