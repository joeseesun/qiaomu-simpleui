-- sui_hold_rows.lua — Simple UI
-- Building blocks shared by the book and folder action sheets.
--
-- A sheet is assembled from rows of items ({ text, sui_icon, enabled,
-- callback }, the button format of ButtonDialog). This module provides the
-- pieces both sheets need:
--   * a context carrying the target path and the close/refresh callbacks;
--   * rows registered through FileManager:addFileDialogButtons;
--   * items that act on the file or folder itself (select, cut, copy, paste,
--     rename, delete);
--   * showing the sheet in place of the file browser's own dialog.
--
-- Options understood by every sheet (opts)
--   on_close      function?  Called when the sheet closes, for any reason.
--   refresh_fn    function?  Called after an action that may change state.
--   navigate_fn   function?  Called after a row that navigates inside the
--                            file browser (see NAVIGATING_ROW_IDS).
--   file_chooser  table?     The file browser's chooser, when the sheet is
--                            opened from it. Enables the file operation rows
--                            and lets rows that close `file_chooser.file_dialog`
--                            close the sheet. `refresh_fn` defaults to
--                            refreshing the chooser.
--   item          table?     The chooser item that was held.

local Device      = require("device")
local C_          = require("gettext").pgettext
local _           = require("infra/sui_i18n").translate

local ActionSheet = require("engines/sui_action_sheet")
local DialogIcons = require("features/dialogs/sui_dialog_icons")

local M = {}

-- Registered row replaced in place by "Delete" on book sheets.
M.DELETE_ROW_ID = "coverbrowser_2"

-- Registered rows whose action navigates inside the file browser instead of
-- changing the state of the item.
M.NAVIGATING_ROW_IDS = {
    sui_browse_author = true,
}

--- The running file manager, or nil.
function M.getFileManager()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    return ok and FileManager and FileManager.instance or nil
end

--- True when `item` was held in the file manager's own chooser and the
--- file manager is not in selection mode.
function M.isBrowserItem(file_chooser, item)
    local fm = M.getFileManager()
    return fm ~= nil
        and fm.file_chooser == file_chooser
        and not fm.selected_files
        and type(item) == "table"
        and type(item.path) == "string"
end

--- Tags a button spec with the icon the sheet draws for it.
function M.tag(spec, icon)
    if spec then spec.sui_icon = icon end
    return spec
end

-- Items without holes, in order. An item without an icon gets the one its
-- label maps to, so rows from any source are drawn alike.
local function compact(...)
    local row = {}
    for i = 1, select("#", ...) do
        local item = select(i, ...)
        if item then
            item.sui_icon = item.sui_icon or DialogIcons.forSpec(item)
            row[#row + 1] = item
        end
    end
    return row
end

--- Appends a row made of the given items; nil items are skipped and an empty
--- row is not added.
function M.pushRow(rows, ...)
    local row = compact(...)
    if #row > 0 then rows[#rows + 1] = row end
end

--- Appends an existing row (an array of items).
function M.appendRow(rows, row)
    M.pushRow(rows, (table.unpack or unpack)(row))
end

-- ---------------------------------------------------------------------------
-- Context
-- ---------------------------------------------------------------------------

--- Creates the context of a sheet for `path`.
--- Fields: path, opts, file_manager, file_chooser, item, sheet (set once
--- shown) and the callbacks close, refresh, closeAndRefresh, closeAndNavigate.
function M.newContext(path, opts)
    local ctx = {
        path         = path,
        opts         = opts,
        file_manager = M.getFileManager(),
        file_chooser = opts.file_chooser,
        item         = opts.item,
    }

    function ctx.close()
        if ctx.sheet then ctx.sheet:close() end
    end
    function ctx.refresh()
        if opts.refresh_fn then
            opts.refresh_fn()
        elseif ctx.file_chooser then
            ctx.file_chooser:refreshPath()
        end
    end
    function ctx.closeAndRefresh()
        ctx.close()
        ctx.refresh()
    end
    function ctx.closeAndNavigate()
        ctx.close()
        if opts.navigate_fn then opts.navigate_fn() end
    end

    return ctx
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------

--- "Delete" row: confirms and deletes `ctx.path` through the file manager.
--- `enabled` is passed on to the item (nil keeps it enabled).
function M.deleteItem(ctx, enabled)
    return {
        text     = _("Delete"),
        sui_icon = "delete",
        enabled  = enabled,
        callback = function()
            ctx.close()
            ctx.file_manager:showDeleteFileDialog(ctx.path, ctx.refresh)
        end,
    }
end

-- Registered rows in registration order: { { id = row_id, func = row_func } }.
local function registeredRows(file_manager)
    local registry = file_manager and file_manager.file_dialog_added_buttons
    if not registry then return {} end

    -- The registry maps row ids to positions; invert it to name each row.
    local id_by_pos = {}
    for id, pos in pairs(registry.index or {}) do id_by_pos[pos] = id end

    local rows = {}
    for pos, func in ipairs(registry) do
        rows[#rows + 1] = { id = id_by_pos[pos], func = func }
    end
    return rows
end

-- Returns `fn` limited to its first call.
local function once(fn)
    local called = false
    return function(...)
        if called then return end
        called = true
        return fn(...)
    end
end

-- Makes every item of `row` call `close` after its own callback. The file
-- browser's dialog closes after each action and redraws its list; registered
-- rows do that on the browser's widgets only, so outside the browser the sheet
-- has to be closed and its caller refreshed here.
local function closeAfterAction(row, close)
    for _i, item in ipairs(row) do
        local run = item.callback
        if run then
            item.callback = function(...)
                run(...)
                close()
            end
        end
    end
end

--- Appends the rows registered through FileManager:addFileDialogButtons.
--- Each row function receives (path, is_file, book_props, close_callback).
--- `delete_item` decides the DELETE_ROW_ID row: an item takes its place, false
--- drops it (the sheet offers "Delete" elsewhere), nil leaves it as registered.
--- Returns true when the delete item was placed.
function M.appendRegisteredRows(ctx, rows, is_file, book_props, delete_item)
    local placed = false
    for _i, row in ipairs(registeredRows(ctx.file_manager)) do
        if row.id == M.DELETE_ROW_ID and delete_item ~= nil then
            if delete_item then
                M.pushRow(rows, delete_item)
                placed = true
            end
        else
            local navigates = M.NAVIGATING_ROW_IDS[row.id]
            local close = navigates and ctx.closeAndNavigate or once(ctx.closeAndRefresh)
            local ok, built = pcall(row.func, ctx.path, is_file, book_props, close)
            if ok and built ~= nil then
                if not (navigates or ctx.file_chooser) then closeAfterAction(built, close) end
                M.appendRow(rows, built)
            end
        end
    end
    return placed
end

-- Item running `run` on `ctx.path` after closing the sheet. `enabled` is
-- passed on to the item (nil keeps it enabled).
local function operation(ctx, text, icon, run, enabled)
    return {
        text     = text,
        sui_icon = icon,
        enabled  = enabled,
        callback = function()
            ctx.close()
            run()
        end,
    }
end

-- True when the parent-folder entry was held: it cannot be renamed, deleted,
-- cut or copied.
local function isParentEntry(ctx)
    return ctx.item ~= nil and ctx.item.is_go_up == true
end

--- Items of the file browser's own dialog that act on the clipboard and the
--- selection: select, cut, copy and paste. Empty unless the sheet was opened
--- from the file browser. `is_file` tells a book from a folder.
function M.clipboardItems(ctx, is_file)
    local fm, fc, item = ctx.file_manager, ctx.file_chooser, ctx.item
    if not (fm and fc) then return {} end

    local path    = ctx.path
    local movable = not isParentEntry(ctx)
    return {
        operation(ctx, _("Select"), "select", function()
            fm:onToggleSelectMode()
            if is_file then
                fm.selected_files[path] = true
                item.dim = true
                fc:updateItems(1, true)
            end
        end),
        operation(ctx, _("Cut"), "cut", function() fm:cutFile(path) end, movable),
        operation(ctx, C_("File", "Copy"), "copy", function() fm:copyFile(path) end, movable),
        operation(ctx, C_("File", "Paste"), "paste", function()
            fm:pasteFileFromClipboard(path)
        end, fm.clipboard and true or false),
    }
end

--- Row with "Delete" and "Rename", acting on the file or folder itself; nil
--- unless the sheet was opened from the file browser.
function M.manageRow(ctx, is_file)
    local fm = ctx.file_manager
    if not (fm and ctx.file_chooser) then return nil end

    local movable = not isParentEntry(ctx)
    return {
        M.deleteItem(ctx, movable),
        operation(ctx, _("Rename"), "edit", function()
            fm:showRenameFileDialog(ctx.path, is_file)
        end, movable),
    }
end

--- "Execute script" row, or nil when the device cannot run `file`.
function M.executeScriptItem(ctx)
    if not Device:canExecuteScript(ctx.path) then return nil end
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    return M.tag(filemanagerutil.genExecuteScriptButton(ctx.path, ctx.close), "terminal")
end

-- ---------------------------------------------------------------------------
-- Showing
-- ---------------------------------------------------------------------------

--- Shows the sheet described by `sheet_opts` (see ActionSheet.show) and keeps
--- `ctx.sheet`. When opened from the file browser, `file_chooser.file_dialog`
--- refers to the sheet while it is open.
function M.show(ctx, sheet_opts)
    local fc       = ctx.file_chooser
    local on_close = ctx.opts.on_close

    sheet_opts.on_close = function()
        if fc and ctx.sheet and fc.file_dialog == ctx.sheet:getWidget() then
            fc.file_dialog = nil
        end
        if on_close then on_close() end
    end

    ctx.sheet = ActionSheet.show(sheet_opts)
    if fc then fc.file_dialog = ctx.sheet:getWidget() end
    return ctx.sheet
end

return M
