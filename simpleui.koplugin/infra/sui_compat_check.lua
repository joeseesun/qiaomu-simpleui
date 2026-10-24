-- Compatibility checks at plugin startup.
-- Detects conflicting plugins and verifies CoverBrowser.

local _ = require("gettext")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function get_dir_from_loaded(sentinel)
    local mod = package.loaded[sentinel]
    if not mod then return nil end
    local src
    if type(mod) == "table" then
        for _k, v in pairs(mod) do
            if type(v) == "function" then
                local info = debug.getinfo(v, "S")
                src = info and info.source
                break
            end
        end
    elseif type(mod) == "function" then
        local info = debug.getinfo(mod, "S")
        src = info and info.source
    end
    if src and src:sub(1, 1) == "@" then
        local dir = src:sub(2):match("^(.*)/[^/]+%.lua$")
        return dir and (dir .. "/")
    end
end

local function get_folder_key(dir)
    if not dir then return nil end
    return dir:match("^.*/([^/]+)%.koplugin/")
end

local function plugin_folder_exists(folder_key)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return false end

    local paths = { "plugins" }
    local extra_paths = G_reader_settings and G_reader_settings:readSetting("extra_plugin_paths")
    if type(extra_paths) == "string" then extra_paths = { extra_paths } end
    if type(extra_paths) == "table" then
        for _i, path in ipairs(extra_paths) do
            paths[#paths + 1] = path
        end
    end

    for _i, path in ipairs(paths) do
        if type(path) == "string" then
            path = path:gsub("/+$", "")
            if lfs.attributes(path .. "/" .. folder_key .. ".koplugin", "mode") == "directory" then
                return true
            end
        end
    end
    return false
end

local function is_pt_detected()
    return package.loaded["ptutil"] ~= nil
end

-- Plugins that will be auto-disabled (plugins_disabled + restart).
local AUTO_DISABLE = {
    {
        sentinel = "common/zen_logger",
        label = "ZenOS",
        fallback_key = "zenos",
        folder_key = "zenos",
    },
    {
        sentinel = "burrow_util",
        label = "Burrow",
        fallback_key = "burrow",
        folder_key = "burrow",
    },
    {
        sentinel = "qui_utils",
        label = "QuickUI",
        fallback_key = "quickui",
        folder_key = "quickui",
    },
    {
        sentinel = "readermenuredesign_installer",
        label = "Reader Menu Redesign",
        fallback_key = "zzz-readermenuredesign",
        folder_key = "zzz-readermenuredesign",
    },
}

-- Extra detection for ZenOS when its logger sentinel is not yet loaded.
local function is_zenos_present()
    if package.loaded["common/zen_logger"] ~= nil then return true end
    if package.loaded["common/plugin_root"] ~= nil then return true end
    if rawget(_G, "__ZEN_UI_PLUGIN") ~= nil then return true end
    return plugin_folder_exists("zenos")
end

local function schedule_coverbrowser_check()
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(1.0, function()
        local ok_cm = pcall(require, "covermenu")
        if ok_cm then return end

        local disabled_list = {}
        if G_reader_settings then
            local dl = G_reader_settings:readSetting("plugins_disabled")
            if type(dl) == "table" then disabled_list = dl end
        end
        local plugin_available = disabled_list["coverbrowser"] ~= nil

        local function enable()
            if G_reader_settings then
                disabled_list["coverbrowser"] = nil
                G_reader_settings:saveSetting("plugins_disabled", disabled_list)
                G_reader_settings:flush()
            end
            local Event = require("ui/event")
            require("features/dialogs/sui_dialogs").confirm{
                text        = _("Please restart KOReader for the change to take effect."),
                ok_text     = _("Restart now"),
                ok_callback = function()
                    UIManager:broadcastEvent(Event:new("Restart"))
                end,
            }
        end

        require("features/dialogs/sui_dialogs").confirm{
            text         = _("CoverBrowser plugin is not enabled, some features will not work correctly."),
            ok_text      = _("Enable"),
            cancel_text  = _("OK"),
            no_ok_button = not plugin_available,
            ok_callback  = enable,
        }
    end)
end

-- Returns true when startup should stop (manual block or restart required).
local function apply_compat_check()
    local logger
    do
        local ok, log = pcall(require, "logger")
        logger = ok and log or { dbg = function() end, info = function() end, warn = function() end }
    end

    if is_pt_detected() then
        logger.warn("simpleui: incompatible plugin detected (manual block)")
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0.5, function()
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("Project: Title is not compatible with Simple UI.")
                    .. "\n\n" .. _("Please delete the Project: Title plugin from your plugins folder and restart KOReader."),
                show_icon = false,
            })
        end)
        return true
    end

    if not G_reader_settings then
        schedule_coverbrowser_check()
        return false
    end

    local disabled_list = G_reader_settings:readSetting("plugins_disabled")
    if type(disabled_list) ~= "table" then disabled_list = {} end

    local needs_restart = false
    local disabled_labels = {}

    -- ZenOS: folder or known runtime markers, even if sentinel not loaded yet.
    if is_zenos_present() and disabled_list["zenos"] == nil then
        disabled_list["zenos"] = true
        disabled_labels[#disabled_labels + 1] = "ZenOS"
        needs_restart = true
    elseif disabled_list["zenos"] ~= nil and is_zenos_present()
            and package.loaded["common/zen_logger"] ~= nil then
        disabled_labels[#disabled_labels + 1] = "ZenOS"
        needs_restart = true
    end

    for _i, entry in ipairs(AUTO_DISABLE) do
        if entry.folder_key == "zenos" then
            -- handled above
        else
            local sentinel_loaded = package.loaded[entry.sentinel] ~= nil
            local folder_installed = entry.folder_key and plugin_folder_exists(entry.folder_key)
            local folder_enabled = folder_installed and disabled_list[entry.folder_key] == nil
            if sentinel_loaded or folder_enabled then
                local dir = get_dir_from_loaded(entry.sentinel)
                local folder_key = folder_enabled and entry.folder_key or get_folder_key(dir)
                if entry.expected_folder_key and folder_key and folder_key ~= entry.expected_folder_key then
                    -- skip false positive from a different plugin
                else
                    folder_key = folder_key or entry.folder_key or entry.fallback_key
                    if disabled_list[folder_key] ~= nil and sentinel_loaded then
                        disabled_labels[#disabled_labels + 1] = entry.label
                        needs_restart = true
                    elseif disabled_list[folder_key] == nil then
                        disabled_list[folder_key] = true
                        disabled_labels[#disabled_labels + 1] = entry.label
                        needs_restart = true
                    end
                end
            end
        end
    end

    if needs_restart then
        G_reader_settings:saveSetting("plugins_disabled", disabled_list)
        G_reader_settings:flush()
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0.5, function()
            local ConfirmBox = require("ui/widget/confirmbox")
            local Event = require("ui/event")
            UIManager:show(ConfirmBox:new{
                text = _("Incompatible items have been disabled:")
                    .. "\n" .. table.concat(disabled_labels, "\n"),
                dismissable = false,
                no_ok_button = true,
                cancel_text = _("Restart now"),
                cancel_callback = function()
                    UIManager:broadcastEvent(Event:new("Restart"))
                end,
            })
        end)
        return true
    end

    schedule_coverbrowser_check()
    return false
end

return apply_compat_check
