-- sui_manual_books.lua — Simple UI
-- Dialogs and settings entry for the books the user enters by hand.
--
-- A manual book lives in the finished-books ledger (see infra/sui_store) and
-- is counted by the stats provider like any other finished book. This module
-- only collects the input and hands it to the provider.
--
-- Books are entered in one of two ways:
--   • one book with its details: title, author, start and finish stamps
--     ("YYYY-MM-DD" or "YYYY"; at least one of the two);
--   • a plain number of books for a year.
--
-- Public API:
--   ManualBooks.showBookDialog(book, on_done)    add a book (`book` nil) or edit
--                                                one (`book` is a provider entry)
--   ManualBooks.showCountDialog(year, on_done)   number of books for `year`
--   ManualBooks.showYearCountDialog(on_done)     asks the year, then the number
--   ManualBooks.menuTitle()                      title of the menu listing the two ways above
--   ManualBooks.makeEntryItems(on_done)          the items of that menu
--   ManualBooks.makeMenuItem(refresh)            settings entry opening that menu

local _         = require("infra/sui_i18n").translate

local MIN_YEAR  = 1900
local MAX_COUNT = 999

local ManualBooks = {}

local function _provider()
    return require("modules/module_stats_provider")
end

local function _dialogs()
    return require("features/dialogs/sui_dialogs")
end

local function _blankToNil(text)
    return text ~= "" and text or nil
end

-- Turns the trimmed form texts {title, author, started, finished} into book fields.
-- Returns nil and the message to show when the input is not acceptable.
local function _readForm(fields)
    local title    = _blankToNil(fields[1])
    local started  = _blankToNil(fields[3])
    local finished = _blankToNil(fields[4])
    local parse    = _provider().parseStamp

    if not title then
        return nil, _("Please enter a title.")
    end
    if (started and not parse(started)) or (finished and not parse(finished)) then
        return nil, _("Please enter dates as YYYY-MM-DD or YYYY.")
    end
    if not (started or finished) then
        return nil, _("Please enter a start or finish date.")
    end
    if started and finished then
        -- Compared at the precision of the shorter stamp.
        local len = math.min(#started, #finished)
        if started:sub(1, len) > finished:sub(1, len) then
            return nil, _("The start date is after the finish date.")
        end
    end
    return {
        title    = title,
        authors  = _blankToNil(fields[2]),
        started  = started,
        finished = finished,
    }
end

function ManualBooks.showBookDialog(book, on_done)
    local dialog

    local function finish(apply)
        apply()
        if on_done then on_done() end
    end

    local actions
    if book then
        actions = {
            {
                text     = _("Delete"),
                sui_icon = "delete",
                callback = function()
                    _dialogs().confirm{
                        text        = _("Delete this book?"),
                        ok_text     = _("Delete"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            dialog:close()
                            finish(function() _provider().removeManualBook(book.key) end)
                        end,
                    }
                end,
            },
        }
    end

    local date_hint = _("YYYY-MM-DD or YYYY")
    local current   = book or {}
    dialog = _dialogs().form{
        title     = book and _("Edit Book") or _("Add Book"),
        ok_text   = _("Save"),
        fields    = {
            { label = _("Title"),    value = current.title },
            { label = _("Author"),   value = current.authors },
            { label = _("Started"),  value = current.date_started,  hint = date_hint },
            { label = _("Finished"), value = current.date_finished, hint = date_hint },
        },
        actions   = actions,
        validate  = function(texts)
            local _values, err = _readForm(texts)
            return err
        end,
        on_submit = function(texts)
            local values = _readForm(texts)
            finish(function() _provider().saveManualBook(book and book.key, values) end)
        end,
    }
end

function ManualBooks.showCountDialog(year, on_done)
    local SP = _provider()
    _dialogs().spin{
        title     = string.format(_("Manual Yearly Count — %d"), year),
        info      = string.format(_("Extra books read in %d, on top of the automatic count:"), year),
        value     = SP.getManualCount(year),
        min       = 0,
        max       = MAX_COUNT,
        hold_step = 10,
        ok_text   = _("Save"),
        on_apply  = function(value)
            SP.setManualCount(year, math.floor(value))
            if on_done then on_done() end
        end,
    }
end

function ManualBooks.showYearCountDialog(on_done)
    local this_year = tonumber(os.date("%Y"))
    _dialogs().spin{
        title     = _("Manual Yearly Count"),
        info      = _("Year:"),
        value     = this_year,
        min       = MIN_YEAR,
        max       = this_year,
        hold_step = 10,
        ok_text   = _("Next"),
        on_apply  = function(value)
            ManualBooks.showCountDialog(math.floor(value), on_done)
        end,
    }
end

function ManualBooks.menuTitle()
    return _("Add Manual Books")
end

-- Menu items for the two ways of entering books. `on_done` runs after a book
-- or a count has been saved.
function ManualBooks.makeEntryItems(on_done)
    return {
        {
            text           = _("Add Single Book"),
            keep_menu_open = true,
            callback       = function() ManualBooks.showBookDialog(nil, on_done) end,
        },
        {
            text           = _("Add Manual Count"),
            keep_menu_open = true,
            callback       = function() ManualBooks.showYearCountDialog(on_done) end,
        },
    }
end

function ManualBooks.makeMenuItem(refresh)
    return {
        text                = ManualBooks.menuTitle(),
        sub_item_table_func = function() return ManualBooks.makeEntryItems(refresh) end,
    }
end

return ManualBooks
