-- sui_icon_registry.lua — Simple UI
-- Makes icon files resolvable by bare name: IconWidget:new{ icon = name }.
--
-- PUBLIC API
--   Registry.register(name, file) → boolean
--       Registers `file` (.svg/.png) under `name`. The file is copied to the
--       user icons directory; returns false when the copy failed, in which
--       case the name still resolves to `file` for the current session.
--   Registry.addDir(dir)
--       Adds `dir` to the directories searched for icons by name.
--
-- A name is made visible three ways, in order of preference:
--   1. A copy in the user icons directory, searched first on every lookup.
--   2. An entry in the lookup tables IconWidget's init closes over, so the
--      change applies immediately.
--   3. A wrapper of IconWidget.init, used when those tables cannot be reached.

local DataStorage = require("datastorage")
local logger      = require("logger")

local Registry = {}

-- Lookup tables closed over by IconWidget's init: icon name → file, and the
-- directories searched by name. Both nil when they cannot be reached. The
-- unwrapped init is preferred, since a wrapper has no such upvalues.
local function iconTables()
    local ok, IconWidget = pcall(require, "ui/widget/iconwidget")
    if not ok then return end
    local init = IconWidget._simpleui_orig_init_for_scan or rawget(IconWidget, "init")
    if type(init) ~= "function" then return end

    local paths, dirs
    for i = 1, 64 do
        local name, value = debug.getupvalue(init, i)
        if name == nil then break end
        if name == "ICONS_PATH" and type(value) == "table" then
            paths = value
        elseif name == "ICONS_DIRS" and type(value) == "table" then
            dirs = value
        end
        if paths and dirs then break end
    end
    return paths, dirs
end

-- Copies `file` to the user icons directory as <name>.<ext>. Returns the copy's
-- path, or nil when it could not be made.
local function copyToUserIcons(name, file)
    local ext = file:match("%.([^.]+)$")
    if not ext then return end

    local lfs     = require("libs/libkoreader-lfs")
    local ffiutil = require("ffi/util")
    local dir     = DataStorage:getDataDir() .. "/icons"
    if lfs.attributes(dir, "mode") ~= "directory" then
        pcall(lfs.mkdir, dir)
    end

    local dst = dir .. "/" .. name .. "." .. ext
    if pcall(ffiutil.copyFile, file, dst) and lfs.attributes(dst, "mode") == "file" then
        return dst
    end
end

-- Files served by the IconWidget.init wrapper: icon name → file. nil until
-- the wrapper is installed.
local _wrapped_files

local function serveFromInitWrapper(name, file)
    if not _wrapped_files then
        _wrapped_files = {}
        local IconWidget = require("ui/widget/iconwidget")
        local orig_init  = IconWidget.init
        IconWidget.init = function(self, ...)
            local served = _wrapped_files[self.icon]
            if served and not self.file and not self.image then
                self.file = served
            end
            if type(orig_init) == "function" then orig_init(self, ...) end
        end
        logger.info("simpleui/icons: resolving names through the IconWidget.init wrapper")
    end
    _wrapped_files[name] = file
end

function Registry.register(name, file)
    if type(name) ~= "string" or type(file) ~= "string" then return false end

    local copy = copyToUserIcons(name, file)
    local paths = iconTables()
    if paths then
        paths[name] = copy or file
    else
        serveFromInitWrapper(name, copy or file)
    end
    return copy ~= nil
end

function Registry.addDir(dir)
    local _paths, dirs = iconTables()
    if not dirs then return end
    for _i, existing in ipairs(dirs) do
        if existing == dir then return end
    end
    table.insert(dirs, 1, dir)
end

return Registry
