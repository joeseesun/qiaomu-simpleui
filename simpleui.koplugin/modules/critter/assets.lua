-- assets.lua — Simple UI
-- The critters and decorations available to the Critter module.
--
-- A critter is a folder holding one image per mood — neutral.png (required)
-- and any of the moods listed in phrases.lua; .svg works too — or a single
-- loose .png/.svg file, used for every mood. A mood without an image shows
-- neutral. The images of a critter should share one canvas size, so the
-- critter keeps its scale from mood to mood.
--
-- A decoration is an image in a decor/ folder. Where it stands in the row
-- depends on the subfolder: loose images stand on the floor, wall/ holds the
-- ones hung on the wall (centred vertically) and ceiling/ the ones that hang
-- from the top. Both kinds come from two places:
--   * the plugin: modules/critter/assets/ (critters) and modules/critter/decor/
--   * the user folder, <settings>/simpleui/sui_critters/ (critters) and its
--     decor/ subfolder, which survive plugin updates and win when a name
--     exists in both

local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local util        = require("util")

local PluginPaths = require("infra/sui_paths")
local RasterCache = require("infra/sui_raster_cache")

local Assets = {}

Assets.DEFAULT_ID = "suey"

local IMAGE_EXTS    = { "png", "svg" }
local IMAGE_EXT_SET = { png = true, svg = true }

local DECOR_DIR_NAME = "decor"

-- Placement of a decoration; the default one is for loose images, the others
-- are named after their subfolder of decor/.
local DEFAULT_ANCHOR = "floor"
local ANCHOR_DIRS    = { wall = true, ceiling = true }
local BUNDLED_DIR       = PluginPaths.getPluginDir() .. "modules/critter/assets"
local BUNDLED_DECOR_DIR = PluginPaths.getPluginDir() .. "modules/critter/" .. DECOR_DIR_NAME

function Assets.userDir()
    return DataStorage:getSettingsDir() .. "/simpleui/sui_critters"
end

--- Folder of the user's decorations.
function Assets.userDecorDir()
    return Assets.userDir() .. "/" .. DECOR_DIR_NAME
end

--- Path of the user's phrase file.
function Assets.phrasesFile()
    return Assets.userDir() .. "/phrases.lua"
end

--- Creates the user folders when they do not exist yet.
function Assets.ensureUserDir()
    local dir = Assets.userDecorDir()
    if lfs.attributes(dir, "mode") ~= "directory" then util.makePath(dir) end
end

-- Readable name of a critter id: "my_dog" -> "My dog".
local function displayName(id)
    local name = id:gsub("[_%-]+", " ")
    return (name:gsub("^%l", string.upper))
end

-- Path of <dir>/<stem>.<ext> for the first supported extension that exists.
local function findImage(dir, stem)
    for _i, ext in ipairs(IMAGE_EXTS) do
        local path = dir .. "/" .. stem .. "." .. ext
        if lfs.attributes(path, "mode") == "file" then return path end
    end
end

-- Entries of `dir` in name order, so that when two files share an id the same
-- one always wins (the last).
local function sortedNames(dir)
    local names = {}
    for name in lfs.dir(dir) do names[#names + 1] = name end
    table.sort(names)
    return names
end

-- Adds the critters found under `root` to `by_id`, replacing same-named ones.
local function scan(root, by_id)
    if lfs.attributes(root, "mode") ~= "directory" then return end
    for _i, name in ipairs(sortedNames(root)) do
        if name:sub(1, 1) ~= "." and name ~= DECOR_DIR_NAME then
            local path = root .. "/" .. name
            local mode = lfs.attributes(path, "mode")
            if mode == "directory" then
                local neutral = findImage(path, "neutral")
                if neutral then
                    by_id[name] = { id = name, name = displayName(name), dir = path, files = { neutral = neutral } }
                end
            elseif mode == "file" then
                local stem, ext = name:match("^(.+)%.(%w+)$")
                if stem and IMAGE_EXT_SET[ext:lower()] then
                    by_id[stem] = { id = stem, name = displayName(stem), files = { neutral = path } }
                end
            end
        end
    end
end

-- Adds the images found in `dir` to `by_id`, replacing same-named ones; the
-- ones of the placement subfolders are added with that placement.
local function scanDecor(dir, by_id, anchor)
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for _i, name in ipairs(sortedNames(dir)) do
        local path = dir .. "/" .. name
        local stem, ext = name:match("^([^.].*)%.(%w+)$")
        if stem and IMAGE_EXT_SET[ext:lower()] and lfs.attributes(path, "mode") == "file" then
            by_id[stem] = { id = stem, name = displayName(stem), path = path, anchor = anchor }
        elseif anchor == DEFAULT_ANCHOR and ANCHOR_DIRS[name] then
            scanDecor(path, by_id, name)
        end
    end
end

local _list, _decor

--- Available critters, sorted by name.
function Assets.list()
    if not _list then
        local by_id = {}
        scan(BUNDLED_DIR, by_id)
        scan(Assets.userDir(), by_id)
        _list = {}
        for _id, entry in pairs(by_id) do _list[#_list + 1] = entry end
        table.sort(_list, function(a, b) return a.name:lower() < b.name:lower() end)
    end
    return _list
end

--- Available decorations, sorted by name: { id, name, path, anchor }, the anchor
--- being "floor", "wall" or "ceiling".
function Assets.decorList()
    if not _decor then
        local by_id = {}
        scanDecor(BUNDLED_DECOR_DIR, by_id, DEFAULT_ANCHOR)
        scanDecor(Assets.userDecorDir(), by_id, DEFAULT_ANCHOR)
        _decor = {}
        for _id, entry in pairs(by_id) do _decor[#_decor + 1] = entry end
        table.sort(_decor, function(a, b) return a.name:lower() < b.name:lower() end)
    end
    return _decor
end

--- Forgets the listings, so the folders are read again on the next use. The
--- rendered images stay: their cache keys carry the file's modification time.
function Assets.relist()
    _list, _decor = nil, nil
end

--- Forgets the listings and the images rendered from them.
function Assets.rescan()
    Assets.relist()
    RasterCache.clear("critter")
end

--- Critter with `id`; the default one, else the first, when it is missing.
function Assets.get(id)
    local list, fallback = Assets.list(), nil
    for _i, entry in ipairs(list) do
        if entry.id == id then return entry end
        if entry.id == Assets.DEFAULT_ID then fallback = entry end
    end
    return fallback or list[1]
end

--- Image file of `entry` for `mood`, falling back to neutral.
function Assets.imagePath(entry, mood)
    local files = entry.files
    if files[mood] == nil then
        files[mood] = entry.dir and findImage(entry.dir, mood) or false
    end
    return files[mood] or files.neutral
end

return Assets
