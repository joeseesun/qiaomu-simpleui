-- sui_arrange.lua — Simple UI
-- Editable ordered list for the settings menus: reorder entries, remove them
-- and, optionally, add new ones from a picker. One implementation serves the
-- native menu and the SUIWindow settings.
--
-- Two entry points:
--
--   Arrange.makeMenuItem{ ... }   entries with their own identity and an
--                                 optional tree of choices to add from
--   Arrange.makeListItem{ ... }   ordered list of ids drawn from a flat pool
--   Arrange.makeSectionedItem{ ... }  ids drawn from a flat pool and spread
--                                 over named sections, in one list
--
-- makeMenuItem opts
--   ctx_menu    menu context (`_`, `refresh`, `is_sui`, `UIManager`, `SortWidget`)
--   title       translated row and page title (default "Arrange")
--   text_func   optional native row text, evaluated on every draw
--   labels      already translated
--     action      title of the reorder action and of its widget
--     header      caption above the per-entry removal list
--     empty       text shown when there are no entries
--     too_few     toast shown when there are fewer than two entries to reorder
--     add         title of the add button and of the picker (default "Add Item")
--     full        function(max) -> toast when the list is full
--     at_min      function(min) -> toast when entries cannot be removed
--     settings    header of the per-entry settings in the native menu
--                 (default "Settings")
--   getEntries  function() -> { { value = v, title = "...", settings = f,
--                                  detail = f, on_select = f }, ... }
--               `settings` is optional: function() -> { menu item, ... }, the
--               settings of that entry. The SUIWindow page opens them when the
--               entry is tapped, the native menu lists them under a header.
--               `on_select` is optional too: function(done), run when the entry
--               is tapped instead of opening `settings`; `done()` repaints the
--               lists. `detail` is optional: function() -> the text under the
--               entry (the value of its row in the native menu), evaluated
--               only when the entry is drawn.
--   count       optional function() -> number of entries, when cheaper than
--               building them
--   saveOrder   function(values)   values of the entries in their new order
--   removeEntry function(value)
--   max, min    optional limits, a number or a function() -> number
--   add         optional
--     choices     function() -> { node, ... } with node being either
--                   { title = "...", value = v }              a leaf, or
--                   { title = "...", children = function() -> { node, ... } }
--                 Branches without any leaf are left out.
--     onAdd       function(value)
--   isEnabled   function() -> bool, default true
--   isMember    function(value) -> bool; removal rows are shown checked
--               while true
--
--   `value` is the stable identity of an entry (never a position): callbacks
--   receive values, so they stay valid while the list changes under an open
--   widget.
--   An entry with `divider = true` is a section header ({ value, title,
--   divider }): it is listed and reordered with the others, but cannot be
--   removed, counted or opened. `saveOrder` then receives the dividers' values
--   among the entries', and decides whether the arrangement is valid (see
--   makeSectionedItem, which builds such lists).
--
-- makeListItem opts: ctx_menu, title, text_func, labels, max, min, isEnabled
--   as above, plus
--   getIds      function() -> { id, ... }   current ids, in order
--   setIds      function(ids)               persists the ids; the menu is
--                                           refreshed after every change
--   pool        function() -> { { id = id, label = "...", group = "..." }, ... }
--               `group` is optional. When any entry has one, the pool keeps its
--               own order and is listed under its groups (a header per group
--               in the native menu, one picker level per group in the SUIWindow
--               settings); without groups the pool is listed alphabetically.
--   label       optional function(id) -> string for ids missing from the pool
--   detail      optional function(id) -> string shown under the entry
--   onSelect    optional function(id, done): runs when the entry is tapped
--               instead of opening its settings; call `done()` once what it
--               showed has closed, so the lists repaint
--   The native menu lists the whole pool as checkable rows next to the
--   reorder action; the SUIWindow settings add from a picker.

local UI = require("infra/sui_core")

local M = {}

local SUMMARY_SEPARATOR = "  ·  "

local function resolve(value)
    if type(value) == "function" then return value() end
    return value
end

local function isEnabled(opts)
    return not opts.isEnabled or opts.isEnabled()
end

local function translate(opts)
    return opts.ctx_menu._
end

-- Entries of `opts` that are not section headers.
local function realEntries(opts)
    local entries = {}
    for _i, entry in ipairs(opts.getEntries()) do
        if not entry.divider then entries[#entries + 1] = entry end
    end
    return entries
end

local function entryCount(opts)
    if opts.count then return opts.count() end
    return #realEntries(opts)
end

-- ---------------------------------------------------------------------------
-- Limits
-- ---------------------------------------------------------------------------

local function toast(text)
    UI.Notify.toast(text, 2)
end

-- Adds `value` unless the list is full; says why when it is.
local function addEntry(opts, value)
    local max = resolve(opts.max)
    if max and entryCount(opts) >= max then
        local full = opts.labels.full
        toast(full and full(max)
            or string.format(translate(opts)("The maximum of %d items has been reached. Remove one first."), max))
        return false
    end
    opts.add.onAdd(value)
    return true
end

-- Removes `value` unless the list is at its minimum; says why when it is.
local function removeEntry(opts, value)
    local min = resolve(opts.min) or 0
    if entryCount(opts) <= min then
        local at_min = opts.labels.at_min
        toast(at_min and at_min(min)
            or string.format(translate(opts)("At least %d items are required."), min))
        return false
    end
    opts.removeEntry(value)
    return true
end

-- ---------------------------------------------------------------------------
-- Choices
-- ---------------------------------------------------------------------------

-- The nodes with their branches resolved; branches left without leaves are
-- dropped.
local function liveChoices(nodes)
    local live = {}
    for _i, node in ipairs(nodes) do
        if node.children then
            local children = liveChoices(node.children())
            if #children > 0 then live[#live + 1] = { title = node.title, children = children } end
        else
            live[#live + 1] = node
        end
    end
    return live
end

local function hasChoices(opts)
    return #liveChoices(opts.add.choices()) > 0
end

-- ---------------------------------------------------------------------------
-- Native menu
-- ---------------------------------------------------------------------------

local function valuesOf(items, field)
    local values = {}
    for _i, item in ipairs(items) do values[#values + 1] = item[field] end
    return values
end

local function arrangeAction(opts)
    local ctx_menu = opts.ctx_menu
    local labels   = opts.labels
    return {
        text           = labels.action,
        enabled_func   = function() return entryCount(opts) > 1 end,
        keep_menu_open = true,
        callback       = function()
            if #realEntries(opts) < 2 then
                toast(labels.too_few)
                return
            end
            local sort_items = {}
            for _i, entry in ipairs(opts.getEntries()) do
                sort_items[#sort_items + 1] = { text = entry.title, value = entry.value, mandatory = "" }
            end
            local UIManager  = ctx_menu.UIManager or require("ui/uimanager")
            local SortWidget = ctx_menu.SortWidget or require("ui/widget/sortwidget")
            UIManager:show(SortWidget:new{
                title             = labels.action,
                item_table        = sort_items,
                covers_fullscreen = true,
                callback          = function()
                    opts.saveOrder(valuesOf(sort_items, "value"))
                    ctx_menu.refresh()
                end,
            })
        end,
    }
end

local function nativeChoiceRows(opts, nodes)
    local rows = {}
    for _i, node in ipairs(nodes) do
        if node.children then
            rows[#rows + 1] = { text = node.title, sub_item_table = nativeChoiceRows(opts, node.children) }
        else
            local value = node.value
            rows[#rows + 1] = {
                text           = node.title,
                keep_menu_open = true,
                callback       = function()
                    if addEntry(opts, value) then opts.ctx_menu.refresh() end
                end,
            }
        end
    end
    return rows
end

-- One removal row per entry; a tap removes the entry.
local function removalRows(opts)
    local rows = {}
    if #realEntries(opts) == 0 then
        rows[1] = { text = opts.labels.empty, enabled = false }
        return rows
    end
    for _i, entry in ipairs(opts.getEntries()) do
        local value = entry.value
        if entry.divider then
            rows[#rows + 1] = { text = entry.title, enabled = false, separator = true }
        else
            rows[#rows + 1] = {
                text           = entry.title,
                checked_func   = opts.isMember and function() return opts.isMember(value) end or nil,
                keep_menu_open = true,
                callback       = function()
                    if removeEntry(opts, value) then opts.ctx_menu.refresh() end
                end,
            }
        end
    end
    return rows
end

-- One row per entry that has settings or an action: a submenu of settings, or
-- a row that runs the entry's `on_select`, with its `detail` as value.
local function settingsRows(opts)
    local rows = {}
    for _i, entry in ipairs(opts.getEntries()) do
        if entry.on_select then
            rows[#rows + 1] = {
                text      = entry.title,
                mandatory = entry.detail and entry.detail(),
                callback  = function() entry.on_select(opts.ctx_menu.refresh) end,
            }
        elseif entry.settings then
            rows[#rows + 1] = { text = entry.title, sub_item_table_func = entry.settings }
        end
    end
    return rows
end

-- Appends the per-entry settings to the native menu `items`, under a header.
local function appendSettingsRows(items, opts)
    local settings_rows = settingsRows(opts)
    if #settings_rows == 0 then return end
    if #items > 0 then items[#items].separator = true end
    items[#items + 1] = {
        text      = opts.labels.settings or translate(opts)("Settings"),
        enabled   = false,
        separator = true,
    }
    for _i, row in ipairs(settings_rows) do items[#items + 1] = row end
end

local function nativeSubItems(opts)
    local items = {}
    if opts.add then
        items[#items + 1] = {
            text                = opts.labels.add,
            enabled_func        = function() return hasChoices(opts) end,
            sub_item_table_func = function()
                return nativeChoiceRows(opts, liveChoices(opts.add.choices()))
            end,
        }
    end
    items[#items + 1] = arrangeAction(opts)
    items[#items + 1] = { text = opts.labels.header, enabled = false, separator = true }
    for _i, row in ipairs(removalRows(opts)) do items[#items + 1] = row end
    appendSettingsRows(items, opts)
    return items
end

-- ---------------------------------------------------------------------------
-- SUIWindow settings
-- ---------------------------------------------------------------------------

-- Opens the picker for `nodes`; a leaf adds its entry and returns to the
-- arrange page, a branch opens the picker of its children.
local function pushPicker(opts, ctx, nodes, title, depth, onAdded)
    local picker_items = {}
    for _i, node in ipairs(nodes) do
        picker_items[#picker_items + 1] = {
            text         = node.title,
            show_chevron = node.children ~= nil,
            on_tap       = function(picker_ctx)
                if node.children then
                    pushPicker(opts, picker_ctx, node.children, node.title, depth + 1, onAdded)
                elseif addEntry(opts, node.value) then
                    onAdded()
                    for _level = 0, depth do picker_ctx.pop() end
                end
            end,
        }
    end
    ctx.push("item_picker", { title = title, items = picker_items })
end

-- Pushes the arrange page. Its items mirror the entries and are re-filled
-- after every change, so the page also reflects what the callbacks adjusted.
local function pushPage(opts, ctx)
    local ctx_menu = opts.ctx_menu
    local labels   = opts.labels
    local items    = {}

    local sync
    local function changed()
        sync()
        ctx_menu.refresh()
        ctx.repaint()
    end

    function sync()
        for i = #items, 1, -1 do items[i] = nil end
        for _i, entry in ipairs(opts.getEntries()) do
            local item = { text = entry.title, orig_item = entry.value }
            if entry.divider then
                item.is_divider = true
                item.pin_top    = #items == 0
            elseif entry.on_select then
                item.subtitle     = entry.detail and entry.detail()
                item.show_chevron = true
                item.on_tap       = function() entry.on_select(changed) end
            elseif entry.settings then
                item.show_chevron = true
                item.on_tap = function()
                    ctx.push("nested_menu", { title = entry.title, items = entry.settings() })
                end
            end
            items[#items + 1] = item
        end
        local removable = entryCount(opts) > (resolve(opts.min) or 0)
        for _i, item in ipairs(items) do
            local value = item.orig_item
            item.on_delete = removable and not item.is_divider and function()
                if removeEntry(opts, value) then changed() end
            end or nil
        end
    end
    sync()

    local function added()
        sync()
        ctx_menu.refresh()
    end

    local page = {
        title      = opts.title,
        items      = items,
        empty_text = labels.empty,
        on_change  = function(arranged)
            opts.saveOrder(valuesOf(arranged, "orig_item"))
            sync()
            ctx_menu.refresh()
        end,
    }
    if opts.add then
        page.footer_text    = labels.add
        page.item_count     = function() return entryCount(opts) end
        page.max_items      = opts.max
        page.footer_enabled = function()
            local max = resolve(opts.max)
            return (not max or entryCount(opts) < max) and hasChoices(opts)
        end
        page.footer_action  = function(page_ctx)
            pushPicker(opts, page_ctx, liveChoices(opts.add.choices()), labels.add, 0, added)
        end
    end
    ctx.push("arrange", page)
end

local function suiRow(opts, ctx)
    local SUIWindow = require("engines/sui_window")
    local row = {
        title        = opts.title,
        subtitle     = function()
            local entries = realEntries(opts)
            if #entries == 0 then return opts.labels.empty end
            local titles = {}
            for _i, entry in ipairs(entries) do titles[#titles + 1] = entry.title end
            return table.concat(titles, SUMMARY_SEPARATOR)
        end,
        inner_w      = ctx.inner_w,
        show_chevron = true,
        enabled      = isEnabled(opts),
        on_tap       = function() pushPage(opts, ctx) end,
    }
    if opts.max then
        row.item_count = function() return entryCount(opts) end
        row.max_items  = opts.max
    end
    return SUIWindow.ListRow(row)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Returns the menu item for an editable list (see the header for `opts`).
function M.makeMenuItem(opts)
    local ctx_menu = opts.ctx_menu
    local _lc      = ctx_menu._
    opts.title            = opts.title or _lc("Arrange")
    opts.labels.add       = opts.labels.add or _lc("Add Item")
    return {
        text                = opts.title,
        text_func           = opts.text_func,
        enabled_func        = function() return isEnabled(opts) end,
        sub_item_table_func = function() return nativeSubItems(opts) end,
        sui_build           = ctx_menu.is_sui and function(ctx) return suiRow(opts, ctx) end or nil,
    }
end

local function sortedByLabel(pool)
    local sorted = {}
    for _i, entry in ipairs(pool) do sorted[#sorted + 1] = entry end
    table.sort(sorted, function(a, b) return a.label:lower() < b.label:lower() end)
    return sorted
end

local function isGrouped(pool)
    for _i, entry in ipairs(pool) do
        if entry.group then return true end
    end
    return false
end

-- Pool entries in menu order: alphabetical without groups; with groups, each
-- group gathered at its first entry and its entries in the pool's order.
local function menuOrder(pool)
    if not isGrouped(pool) then return sortedByLabel(pool) end
    local ordered, placed = {}, {}
    for _i, entry in ipairs(pool) do
        if not entry.group then
            ordered[#ordered + 1] = entry
        elseif not placed[entry.group] then
            placed[entry.group] = true
            for _j, other in ipairs(pool) do
                if other.group == entry.group then ordered[#ordered + 1] = other end
            end
        end
    end
    return ordered
end

-- Choices for adding an entry of `pool` (see makeListItem), leaving out the
-- ids in `taken`. A grouped pool gives one node per group, in the order of
-- their first entry, and omits groups with nothing left to add; an ungrouped
-- one gives the entries as leaves, alphabetically.
function M.poolChoices(pool, taken)
    local nodes, groups = {}, {}
    for _i, entry in ipairs(menuOrder(pool)) do
        if not taken[entry.id] then
            local leaf = { title = entry.label, value = entry.id }
            if not entry.group then
                nodes[#nodes + 1] = leaf
            else
                local group = groups[entry.group]
                if not group then
                    group = {}
                    groups[entry.group] = group
                    nodes[#nodes + 1] = { title = entry.group, children = function() return group end }
                end
                group[#group + 1] = leaf
            end
        end
    end
    return nodes
end

-- Rows of the native submenu of makeListItem: the reorder action followed by
-- every pool entry as a checkable row. Rows of entries not yet added show how
-- many places are left once the list is close to its maximum.
local function poolToggleRows(opts, list)
    local N_   = require("infra/sui_i18n").ngettext
    local rows = { arrangeAction(opts) }
    rows[1].separator = true

    local function selected(id)
        for _i, v in ipairs(list.getIds()) do
            if v == id then return true end
        end
        return false
    end

    local group
    for _i, entry in ipairs(menuOrder(list.pool())) do
        local id, label = entry.id, entry.label
        if entry.group and entry.group ~= group then
            group = entry.group
            rows[#rows].separator = true
            rows[#rows + 1] = { text = group, enabled = false, separator = true }
        end
        rows[#rows + 1] = {
            text_func = function()
                local max = resolve(opts.max)
                if not max or selected(id) then return label end
                local left = max - entryCount(opts)
                if left > 2 then return label end
                return label .. string.format(N_("  (%d left)", "  (%d left)", left), left)
            end,
            checked_func   = function() return selected(id) end,
            keep_menu_open = true,
            callback       = function()
                local done
                if selected(id) then done = removeEntry(opts, id) else done = addEntry(opts, id) end
                if done then opts.ctx_menu.refresh() end
            end,
        }
    end
    appendSettingsRows(rows, opts)
    return rows
end

-- Returns the menu item for an ordered list of ids (see the header for `opts`).
function M.makeListItem(opts)
    -- A copy: `opts.getIds` may hand out the stored list.
    local function currentIds()
        local ids = {}
        for i, id in ipairs(opts.getIds()) do ids[i] = id end
        return ids
    end

    local function without(ids, id)
        local kept = {}
        for _i, v in ipairs(ids) do
            if v ~= id then kept[#kept + 1] = v end
        end
        return kept
    end

    local core = {
        ctx_menu  = opts.ctx_menu,
        title     = opts.title,
        text_func = opts.text_func,
        labels    = opts.labels,
        max       = opts.max,
        min       = opts.min,
        isEnabled = opts.isEnabled,
        count      = function() return #opts.getIds() end,
        getEntries = function()
            local labels = {}
            for _i, entry in ipairs(opts.pool()) do labels[entry.id] = entry.label end
            local entries = {}
            for _i, id in ipairs(opts.getIds()) do
                entries[#entries + 1] = {
                    value     = id,
                    title     = labels[id] or (opts.label and opts.label(id)) or tostring(id),
                    detail    = opts.detail and function() return opts.detail(id) end or nil,
                    on_select = opts.onSelect and function(done) opts.onSelect(id, done) end or nil,
                }
            end
            return entries
        end,
        saveOrder   = opts.setIds,
        removeEntry = function(id) opts.setIds(without(opts.getIds(), id)) end,
        add = {
            choices = function()
                local taken = {}
                for _i, id in ipairs(opts.getIds()) do taken[id] = true end
                return M.poolChoices(opts.pool(), taken)
            end,
            onAdd = function(id)
                local ids = currentIds()
                ids[#ids + 1] = id
                opts.setIds(ids)
            end,
        },
    }

    local item = M.makeMenuItem(core)
    item.sub_item_table_func = function() return poolToggleRows(core, opts) end
    return item
end

-- ---------------------------------------------------------------------------
-- Sectioned list
-- ---------------------------------------------------------------------------

local function sameIds(a, b)
    if #a ~= #b then return false end
    for i, id in ipairs(a) do
        if b[i] ~= id then return false end
    end
    return true
end

-- Returns the menu item for ids of a flat pool spread over named sections, in
-- one list: the sections' headers stand in the list and an entry moves from a
-- section to the next one by passing the header between them. The pool is
-- offered once, each entry choosing its section (or none). An id belongs to one
-- section at most.
--   ctx_menu, title, text_func, labels (action, empty, too_few, add, full,
--   invalid), pool and label as in makeListItem, plus
--   sections   { { id = "...", label = "..." }, ... } in list order
--   max        most ids a section holds
--   getIds     function(section_id) -> { id, ... }
--   setIds     function(section_id, ids)
function M.makeSectionedItem(opts)
    local sections = opts.sections
    local max      = opts.max
    local _lc      = opts.ctx_menu._

    local function headerValue(section) return "__section_" .. section.id .. "__" end

    local header_of = {}   -- header value -> section index
    for i, section in ipairs(sections) do header_of[headerValue(section)] = i end

    -- Ids of every section, and the set of all of them. An id kept by two
    -- sections belongs to the first.
    local function layout()
        local lists, seen = {}, {}
        for _i, section in ipairs(sections) do
            local ids = {}
            for _j, id in ipairs(opts.getIds(section.id)) do
                if not seen[id] then
                    seen[id] = true
                    ids[#ids + 1] = id
                end
            end
            lists[section.id] = ids
        end
        return lists, seen
    end

    local function without(ids, id)
        local kept = {}
        for _i, v in ipairs(ids) do
            if v ~= id then kept[#kept + 1] = v end
        end
        return kept
    end

    local function full()
        toast(opts.labels.full(max))
    end

    local core = {
        ctx_menu  = opts.ctx_menu,
        title     = opts.title,
        text_func = opts.text_func,
        labels    = opts.labels,
        count     = function()
            local total = 0
            for _id, ids in pairs((layout())) do total = total + #ids end
            return total
        end,
        getEntries = function()
            local names = {}
            for _i, entry in ipairs(opts.pool()) do names[entry.id] = entry.label end
            local lists   = layout()
            local entries = {}
            for _i, section in ipairs(sections) do
                entries[#entries + 1] = {
                    value = headerValue(section), title = section.label, divider = true,
                }
                for _j, id in ipairs(lists[section.id]) do
                    entries[#entries + 1] = {
                        value = id,
                        title = names[id] or (opts.label and opts.label(id)) or tostring(id),
                    }
                end
            end
            return entries
        end,
        add = {
            choices = function()
                local lists, taken = layout()
                local nodes = {}
                for _i, entry in ipairs(menuOrder(opts.pool())) do
                    if not taken[entry.id] then
                        local id = entry.id
                        nodes[#nodes + 1] = {
                            title    = entry.label,
                            children = function()
                                local places = {}
                                for _j, section in ipairs(sections) do
                                    if #lists[section.id] < max then
                                        places[#places + 1] = {
                                            title = section.label,
                                            value = { section = section.id, id = id },
                                        }
                                    end
                                end
                                return places
                            end,
                        }
                    end
                end
                return nodes
            end,
            onAdd = function(value)
                local ids = {}
                for i, id in ipairs(opts.getIds(value.section)) do ids[i] = id end
                ids[#ids + 1] = value.id
                opts.setIds(value.section, ids)
            end,
        },
    }

    -- `values` are the entries and headers in their new order: the headers must
    -- keep their order and no section may hold more than `max`.
    function core.saveOrder(values)
        local lists, current, expected = {}, nil, 1
        local valid = true
        for _i, value in ipairs(values) do
            local index = header_of[value]
            if index then
                valid = valid and index == expected
                expected, current = expected + 1, sections[index].id
                lists[current] = {}
            elseif current then
                lists[current][#lists[current] + 1] = value
            else
                valid = false
            end
        end
        if not valid or expected ~= #sections + 1 then
            toast(opts.labels.invalid or _lc("Invalid arrangement."))
            return
        end
        for _i, section in ipairs(sections) do
            if #lists[section.id] > max then full(); return end
        end
        local before = layout()
        for _i, section in ipairs(sections) do
            if not sameIds(before[section.id], lists[section.id]) then opts.setIds(section.id, lists[section.id]) end
        end
    end

    function core.removeEntry(value)
        local lists = layout()
        for _i, section in ipairs(sections) do
            for _j, id in ipairs(lists[section.id]) do
                if id == value then
                    opts.setIds(section.id, without(lists[section.id], value))
                    return
                end
            end
        end
    end

    -- Native menu: the reorder action, then the pool once, each entry choosing
    -- the section it stands in (or none).
    local function nativeRows()
        local Config = require("infra/sui_config")
        local rows   = { arrangeAction(core) }
        rows[1].separator = true

        local options = { { value = "", label = _lc("None") } }
        for _i, section in ipairs(sections) do
            options[#options + 1] = { value = section.id, label = section.label }
        end

        for _i, entry in ipairs(menuOrder(opts.pool())) do
            local id = entry.id
            rows[#rows + 1] = Config.makeRadioSubmenuItem{
                text    = entry.label,
                options = options,
                get     = function()
                    for _j, section in ipairs(sections) do
                        for _k, v in ipairs((layout())[section.id]) do
                            if v == id then return section.id end
                        end
                    end
                    return ""
                end,
                set     = function(target)
                    local lists = layout()
                    if target ~= "" then
                        for _j, v in ipairs(lists[target]) do
                            if v == id then return end
                        end
                        if #lists[target] >= max then full(); return end
                    end
                    for _j, section in ipairs(sections) do
                        if section.id ~= target then
                            for _k, v in ipairs(lists[section.id]) do
                                if v == id then opts.setIds(section.id, without(lists[section.id], id)) end
                            end
                        end
                    end
                    if target ~= "" then
                        local ids = { unpack(lists[target]) }
                        ids[#ids + 1] = id
                        opts.setIds(target, ids)
                    end
                end,
                refresh = opts.ctx_menu.refresh,
            }
        end
        return rows
    end

    local item = M.makeMenuItem(core)
    item.sub_item_table_func = nativeRows
    return item
end

return M
