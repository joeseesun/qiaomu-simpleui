-- sui_native_choices.lua — Simple UI
-- Selection state of the choice buttons in the native dialogs of the history
-- and of a collection: the status of a book and the filters of the list.
--
-- Those dialogs list their choices as plain buttons and do not show which one
-- is active. This module describes the active choices of each dialog to the
-- sheet that stands in for it (see NativeSheets.withChoices), so the active
-- choice is drawn selected, like the status of a book in its action sheet.
-- Choices that apply in place keep the sheet open and move the selection.
-- Choices that open another screen (collections, search, metadata lists) only
-- show whether they are active.
--
-- The filters of both lists follow one model (FILTER_MODELS):
--   * the statuses form one group led by "All": exclusive in the history,
--     toggles that add up in a collection;
--   * "All" stands for no filter at all and is selected only while nothing
--     narrows the list; choosing it clears every filter;
--   * the other filters are additive and only show whether they are active.
--
-- A button is matched to its choice by its label, with or without a trailing
-- count ("Reading (3)"). A button that is not recognised keeps its plain look.
--
-- Public API
--   Each function wraps the function that shows a dialog and returns the
--   wrapped function, called as `show_dialog(owner, ...)`.
--   NativeChoices.historyFilters(show_dialog)      owner: the history manager
--   NativeChoices.collectionFilters(show_dialog)   owner: a collections manager
--   NativeChoices.bookStatus(show_dialog)          owner: a book list menu;
--                                                  the second argument is the
--                                                  held item

local BookList = require("ui/widget/booklist")
local gettext  = require("gettext")
local util     = require("util")

local NativeSheets = require("features/dialogs/sui_native_sheets")

local NativeChoices = {}

local STATUS_GROUP = "status"
local BOOK_STATUSES = { "reading", "abandoned", "complete" }

-- True when `text` is `label`, optionally followed by a count in parentheses.
local function hasLabel(text, label)
    return text == label or text:sub(1, #label + 2) == label .. " ("
end

-- A choice is described as `label` (the text of its button) plus the fields
-- of a NativeSheets choice: `checked`, `keep_open`, `toggle`, `text`, `group`
-- and `rank`. A choice without a label is not listed.
local function addChoice(choices, choice)
    if choice.label then choices[#choices + 1] = choice end
end

-- Resolver for NativeSheets.withChoices: the choice whose label matches the
-- button label.
local function resolverOf(choices)
    return function(text)
        for _i, choice in ipairs(choices) do
            if hasLabel(text, choice.label) then return choice end
        end
    end
end

-- Wraps `show_dialog` so the dialog it shows is annotated with the choices
-- built by `describe(owner, ...)`.
local function annotated(show_dialog, describe)
    return function(owner, ...)
        return NativeSheets.withChoices(resolverOf(describe(owner, ...)), show_dialog, owner, ...)
    end
end

-- ---------------------------------------------------------------------------
-- Filters of the history and of a collection
-- ---------------------------------------------------------------------------

-- Label of the button that filters a collection by the metadata property
-- `prop`: the name of the property.
local function propLabel(manager, prop)
    local name = util.tableGetValue(manager, "ui", "bookinfo", "prop_text", prop)
    return name and name:gsub(":", "")
end

-- Additive filter of a collection on the metadata property `prop`.
local function propFilter(prop)
    return {
        label  = function(manager) return propLabel(manager, prop) end,
        active = function(manager)
            return util.tableGetValue(manager, "match_table", "props", prop) ~= nil
        end,
    }
end

-- Model of a filter dialog:
--   statuses         status choices in display order; "all" leads
--   toggle_statuses  whether a status is cleared by choosing it again; the
--                    selected statuses then add up
--   reset_label      source text of the dialog's own button that clears the
--                    filters, when it is not already the "all" status
--   has_status       function(manager, status) -> whether it is selected
--   is_filtered      function(manager) -> whether anything narrows the list
--   extras           additive filters: { { label, active } }, `label` being
--                    function(manager) -> the text of their button
local FILTER_MODELS = {
    history = {
        statuses    = { "all", "new", "deleted", "reading", "abandoned", "complete" },
        has_status  = function(history, status) return history.filter == status end,
        is_filtered = function(history)
            return history.filter ~= "all"
                or history.selected_collections ~= nil
                or history.search_string ~= nil
        end,
        extras = {
            {
                label  = function() return gettext("Filter by collections") end,
                active = function(history) return history.selected_collections ~= nil end,
            },
            {
                label  = function() return gettext("Search in filename and book metadata") end,
                active = function(history) return history.search_string ~= nil end,
            },
        },
    },
    collection = {
        statuses        = { "all", "new", "reading", "abandoned", "complete" },
        toggle_statuses = true,
        reset_label     = "Reset all filters",
        has_status      = function(manager, status)
            return util.tableGetValue(manager, "match_table", "status", status) == true
        end,
        is_filtered     = function(manager) return manager.match_table ~= nil end,
        extras          = {
            propFilter("authors"),
            propFilter("series"),
            propFilter("language"),
            propFilter("keywords"),
        },
    },
}

local function describeFilters(model, manager)
    local choices = {}
    local reset_label = model.reset_label and gettext(model.reset_label)

    for rank, status in ipairs(model.statuses) do
        local is_all = status == "all"
        local text   = BookList.getBookStatusString(status)
        addChoice(choices, {
            label     = is_all and reset_label or text,
            -- The dialog's reset button is drawn as the "all" status.
            text      = is_all and reset_label and text or nil,
            checked   = function()
                if is_all then return not model.is_filtered(manager) end
                return model.has_status(manager, status)
            end,
            keep_open = true,
            toggle    = not is_all and model.toggle_statuses,
            group     = STATUS_GROUP,
            rank      = rank,
        })
    end
    for _i, extra in ipairs(model.extras) do
        addChoice(choices, {
            label   = extra.label(manager),
            checked = function() return extra.active(manager) end,
        })
    end
    return choices
end

local function describeHistoryFilters(history)
    return describeFilters(FILTER_MODELS.history, history)
end

local function describeCollectionFilters(manager)
    return describeFilters(FILTER_MODELS.collection, manager)
end

-- ---------------------------------------------------------------------------
-- Book status
-- ---------------------------------------------------------------------------

local function describeBookStatus(_menu, item)
    local choices = {}
    local file = item and item.file
    if not file then return choices end

    for _i, status in ipairs(BOOK_STATUSES) do
        addChoice(choices, {
            label     = BookList.getBookStatusString(status, false, true),
            checked   = function() return BookList.getBookStatus(file) == status end,
            keep_open = true,
        })
    end
    return choices
end

function NativeChoices.historyFilters(show_dialog)
    return annotated(show_dialog, describeHistoryFilters)
end

function NativeChoices.collectionFilters(show_dialog)
    return annotated(show_dialog, describeCollectionFilters)
end

function NativeChoices.bookStatus(show_dialog)
    return annotated(show_dialog, describeBookStatus)
end

return NativeChoices
