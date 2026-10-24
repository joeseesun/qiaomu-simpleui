-- Copyright (c) 2026 向阳乔木. GPL-3.0-or-later.
-- Visibility only: never moves books, deletes sidecars, or edits history.
local Settings = require("infra/sui_store")
local _ = require("infra/sui_i18n").translate
local Hidden = {}
local KEY = "simpleui_hidden_books"

function Hidden.key(path)
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" then return nil end
    path = path:gsub("^/mnt/base%-us/", "/mnt/us/")
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then table.remove(parts)
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    return "/" .. table.concat(parts, "/")
end

local function records()
    local value = Settings:get(KEY)
    return type(value) == "table" and value or {}
end

function Hidden.isHidden(path)
    local key = Hidden.key(path)
    return key ~= nil and records()[key] ~= nil
end

function Hidden.hide(path)
    local key = Hidden.key(path)
    if not key then return false end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return false end
    local copy = {}
    for k, value in pairs(records()) do copy[k] = value end
    copy[key] = { file = path, hidden_at = os.time() }
    Settings:set(KEY, copy)
    return true
end

function Hidden.restore(path)
    local key = Hidden.key(path)
    if not key or records()[key] == nil then return false end
    local copy = {}
    for k, value in pairs(records()) do if k ~= key then copy[k] = value end end
    Settings:set(KEY, copy)
    return true
end

function Hidden.list()
    local result = {}
    for key, entry in pairs(records()) do
        result[#result + 1] = {
            key = key,
            file = type(entry) == "table" and entry.file or key,
        }
    end
    table.sort(result, function(a, b) return a.key < b.key end)
    return result
end

function Hidden.filterPaths(paths)
    local visible = {}
    for _i, path in ipairs(paths or {}) do
        if not Hidden.isHidden(path) then visible[#visible + 1] = path end
    end
    return visible
end

-- Cached home-screen state can predate the visibility change or a restart.
function Hidden.filterState(state)
    if not state then return nil end
    local copy = {}
    for key, value in pairs(state) do copy[key] = value end
    if Hidden.isHidden(copy.current_fp) then copy.current_fp = nil end
    copy.recent_fps = Hidden.filterPaths(copy.recent_fps)
    return copy
end

-- Invalidate before the caller closes/repaints its action sheet. The caller
-- owns that paint: a second refresh of the underlying file manager changes
-- its navbar/path state and can paint white rectangles over the home screen.
function Hidden.refresh(caller_refresh)
    local Scan = package.loaded["engines/sui_library_scan"]
    if Scan then Scan.invalidate() end
    local Engine = package.loaded["engines/sui_screen_engine"]
    if Engine then Engine.markAllStale() end
    local FM = package.loaded["apps/filemanager/filemanager"]
    local fm = FM and FM.instance
    if fm then fm._sui_lazy_refresh_path = true end
    if caller_refresh then
        caller_refresh()
        return
    end
    -- Restore is invoked from a settings row, without a book-sheet callback.
    -- Let its event finish, then choose a single owner for the visible view.
    require("ui/uimanager"):nextTick(function()
        if Engine and #Engine.liveScreenIds() > 0 then
            Engine.refreshAllLiveImmediate(false)
        else
            local current_fm = FM and FM.instance
            local fc = current_fm and current_fm.file_chooser
            if not fc then return end
            local previous = current_fm._navbar_suppress_path_change
            current_fm._navbar_suppress_path_change = true
            local ok, err = pcall(fc.refreshPath, fc)
            current_fm._navbar_suppress_path_change = previous
            if not ok then error(err) end
        end
    end)
end

function Hidden.makeMenuItem()
    return {
        text = _("Hidden books and documents"),
        mandatory_func = function() return tostring(#Hidden.list()) end,
        sub_item_table_func = function()
            local rows = {}
            for _i, entry in ipairs(Hidden.list()) do
                local file = entry.file
                local title = file:match("([^/]+)$") or file
                local SH = package.loaded["modules/module_books_shared"]
                if SH then
                    local ok, data = pcall(SH.getBookData, file)
                    if ok and data and data.title and data.title ~= "" then title = data.title end
                end
                rows[#rows + 1] = {
                    text = title,
                    help_text = file,
                    sub_item_table = {
                        {
                            text = _("Restore visibility"),
                            callback = function()
                                Hidden.restore(file)
                                Hidden.refresh()
                            end,
                        },
                    },
                }
            end
            if #rows == 0 then
                rows[1] = { text = _("No hidden books or documents"), enabled = false }
            end
            return rows
        end,
    }
end

function Hidden.registerHoldAction(fm)
    fm:addFileDialogButtons("sui_hide_book", function(file, is_file, book_props, close)
        if not is_file then return nil end
        return {{
            text = _("Hide from home and library"),
            sui_icon = "hide",
            callback = function()
                if Hidden.hide(file) then
                    Hidden.refresh(close)
                end
            end,
        }}
    end)
end

return Hidden
