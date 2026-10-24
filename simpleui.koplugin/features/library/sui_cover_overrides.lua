-- sui_cover_overrides.lua — Simple UI
-- Single source of truth for "the user manually picked this book as the
-- cover for this folder/group". Previously duplicated three times (plain
-- folders, in-folder series groups, virtual author/series/tag leaves) —
-- all three now share this one settings-backed table.
--
-- Keys are whatever the caller uses to identify a group: a real directory
-- path, a virtual path (see sui_virtual_path), or a series-group synthetic
-- path. The override store doesn't care which — it's just a string key.
--
-- Public API
-- ----------
--   CoverOverrides.get(key, validate)  -- validate: check file still exists on disk
--   CoverOverrides.set(key, book_path)
--   CoverOverrides.clear(key)
--   CoverOverrides.invalidateGridItem(menu, key)  -- force a repaint of one cell

local lfs         = require("libs/libkoreader-lfs")
local SUISettings = require("infra/sui_store")

local CoverOverrides = {}

local SETTINGS_KEY = "simpleui_fc_covers"

local _cache = nil -- loaded lazily, mutated in place, saved on every write

local function store()
    if not _cache then
        _cache = SUISettings:readSetting(SETTINGS_KEY) or {}
    end
    return _cache
end

-- Returns the overridden book path for `key`, or nil if there is none (or
-- it no longer points at a real file, when validate is true).
function CoverOverrides.get(key, validate)
    local book_path = store()[key]
    if not book_path then return nil end
    if validate and lfs.attributes(book_path, "mode") ~= "file" then
        return nil
    end
    return book_path
end

function CoverOverrides.set(key, book_path)
    local t = store()
    t[key] = book_path
    SUISettings:saveSetting(SETTINGS_KEY, t)
end

function CoverOverrides.clear(key)
    local t = store()
    if t[key] == nil then return end
    t[key] = nil
    SUISettings:saveSetting(SETTINGS_KEY, t)
end

-- Clears the "already painted" flag on the grid cell for `key` and asks the
-- menu to redraw — used right after set()/clear() so the new cover shows
-- immediately instead of waiting for the next full list rebuild.
function CoverOverrides.invalidateGridItem(menu, key)
    if not menu or not menu.layout then return end
    for _, row in ipairs(menu.layout) do
        for _, item in ipairs(row) do
            if item._foldercover_processed and item.entry and item.entry.path == key then
                item._foldercover_processed = false
            end
        end
    end
    menu:updateItems(1, true)
end

return CoverOverrides
