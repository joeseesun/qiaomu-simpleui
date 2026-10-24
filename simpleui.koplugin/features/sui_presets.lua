-- sui_presets.lua — SimpleUI Presets
--
-- This module contains two independent preset systems with the same
-- architecture: snapshot → storage in a single key → restore.
--
-- ══════════════════════════════════════════════════════════════════════════
-- 1. HOMESCREEN PRESETS  (SUIPresets)
-- ══════════════════════════════════════════════════════════════════════════
-- Saves and restores complete snapshots of the homescreen configuration.
-- Covers: modules, order, quick actions per slot, wallpaper, backdrop
-- strength (bars, chrome, modules), per-module label visibility.
-- Does NOT include: topbar/bottombar, the preset storage key itself.
-- Storage: "simpleui_hs_presets" → { [name] = {k=v, ...}, ... }
--
-- API:
--   SUIPresets.save(name)       SUIPresets.apply(name)    SUIPresets.delete(name)
--   SUIPresets.listNames()      SUIPresets.exists(name)   SUIPresets.rename(old,new)
--   SUIPresets.getAll()
--
-- ══════════════════════════════════════════════════════════════════════════
-- 2. ICON PRESETS  (SUIIconPresets)
-- ══════════════════════════════════════════════════════════════════════════
-- Saves and restores snapshots of all icon customizations:
--   • System icon overrides      simpleui_sysicon_*
--   • Default action icon overr. simpleui_action_*_icon
--   • Custom QA icon fields      simpleui_qa_<id>.icon  (only the icon field)
-- Does NOT include: labels, paths/collections of CQAs, the storage key itself.
-- Storage: "simpleui_icon_presets" → { [name] = {_scalar={}, _cqa={}}, ... }
--
-- API:
--   SUIIconPresets.save(name)           SUIIconPresets.apply(name, QA_module)
--   SUIIconPresets.delete(name)         SUIIconPresets.listNames()
--   SUIIconPresets.exists(name)         SUIIconPresets.rename(old, new)
--   SUIIconPresets.getAll()

local SUISettings = require("infra/sui_store")
local logger      = require("logger")
local _           = require("infra/sui_i18n").translate
local deepCopy    = require("util").tableDeepCopy

-- ============================================================================
-- § 1  HOMESCREEN PRESETS
-- ============================================================================

local HS_PRESET_KEY = "simpleui_hs_presets"

local HS_PREFIXES = {
    "simpleui_hs_",
    "simpleui_style_",
    "simpleui_hide_label_",  -- per-module instance "hide label" toggle
    "simpleui_label_outside_", -- per-module label placement (outside the background)
    "simpleui_coll_",        -- Collections module: list, badges, cover style, sort, etc.
}

local HS_EXACT = {
    ["simpleui_layout"]                       = true,
    ["simpleui_statusbar_transparent"]        = true,
    ["simpleui_navbar_transparent"]           = true,
    ["simpleui_statusbar_backdrop"]           = true,
    ["simpleui_statusbar_tone"]               = true,
    ["simpleui_statusbar_show_frame"]         = true,
    ["simpleui_navbar_backdrop"]              = true,
    ["simpleui_navbar_tone"]                  = true,
    ["simpleui_navbar_show_frame"]            = true,
    ["simpleui_pagination_backdrop"]          = true,
    ["simpleui_pagination_tone"]              = true,
    ["simpleui_pagination_show_frame"]        = true,
    ["simpleui_titlebar_backdrop"]            = true,
    ["simpleui_titlebar_tone"]                = true,
    ["simpleui_titlebar_show_frame"]          = true,
    ["simpleui_module_backdrop"]              = true,
    ["simpleui_wallpaper_show_in_fm"]         = true,  -- "show wallpaper in file manager" toggle
    ["simpleui_reading_goals_show_annual"]    = true,
    ["simpleui_reading_goals_show_monthly"]   = true,
    ["simpleui_reading_goals_show_daily"]     = true,
    ["simpleui_reading_goals_layout"]         = true,
    ["simpleui_reading_goals_ring_style"]     = true,
}

-- Whether `key` persists a module instance list (owned by the registry).
local function _isInstanceListKey(key)
    for _i, instance_key in ipairs(require("modules/moduleregistry").getInstanceKeys()) do
        if key == instance_key then return true end
    end
    return false
end

local function _hsMatchesKey(key)
    if type(key) ~= "string" then return false end
    if HS_EXACT[key] or _isInstanceListKey(key) then return true end
    for _i, pfx in ipairs(HS_PREFIXES) do
        if key:sub(1, #pfx) == pfx then
            return key ~= HS_PRESET_KEY and key ~= "simpleui_hs_active_preset"
        end
    end
    return false
end

local function _getDirs()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or not DataStorage then return nil, nil end
    local base = DataStorage:getSettingsDir() .. "/simpleui/sui_presets"
    local exp_dir = base .. "/sui_presets_export"
    local imp_dir = base .. "/sui_presets_import"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs then
        if lfs.attributes(base, "mode") ~= "directory" then lfs.mkdir(base) end
        if lfs.attributes(exp_dir, "mode") ~= "directory" then lfs.mkdir(exp_dir) end
        if lfs.attributes(imp_dir, "mode") ~= "directory" then lfs.mkdir(imp_dir) end
    end
    return exp_dir, imp_dir
end

local function _getExportDir()
    local exp, _ = _getDirs()
    return exp
end

local function _getImportDir()
    local _, imp = _getDirs()
    return imp
end

local function _listImportFiles(suffix)
    local dir = _getImportDir()
    local files = {}
    if not dir then return files end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return files end
    local pattern = suffix and (suffix:gsub("%.", "%%.") .. "$") or "%.lua$"
    if lfs.attributes(dir, "mode") == "directory" then
        for fname in lfs.dir(dir) do
            if fname ~= "." and fname ~= ".." and fname:lower():match(pattern:lower()) then
                files[#files + 1] = {
                    name = fname,
                    path = dir .. "/" .. fname
                }
            end
        end
        table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
    end
    return files
end

-- Removes every setting a homescreen preset covers. The caller flushes.
local function _clearHsKeys()
    local keys = {}
    for k in SUISettings:iterateKeys() do
        if _hsMatchesKey(k) then keys[#keys + 1] = k end
    end
    for _i, k in ipairs(keys) do SUISettings:delNoFlush(k) end
end

local function _countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local SUIPresets = {}

local BUILTIN_PRESETS = {
    {
        id = "builtin_at_a_glance",
        name = _("At a Glance"),
        desc = _("Currently Reading") .. ", " .. _("Tabbed Grid"),
        layout = { pages = { { id = 1, modules = { "currently", "tab_grid_glance" } } } },
        settings = {
            -- Deterministic instance of the tabbed grid (4 cols × 1 row).
            -- "currently" is left unconfigured so it follows
            -- applyFirstRunDefaults() or the user's own customization.
            simpleui_tab_grid_instances = { "tab_grid_glance" },
            simpleui_hs_tab_grid_glance_grid_rows = 1,
            simpleui_hs_tab_grid_glance_grid_cols = 4,
        }
    },
    {
        id = "builtin_mindful_reading",
        name = _("Mindful Reading"),
        desc = _("Clock") .. ", " .. _("Currently Reading") .. ", " .. _("Quote of the Day"),
        layout = { pages = { { id = 1, modules = { "clock", "quote", "currently" } } } },
        settings = {
            simpleui_hs_clock_scale = 100,
            simpleui_hide_label_clock = false,
            -- module_quote.lua's SETTING_SOURCE/SETTING_ALIGN constants
            -- already carry a "simpleui_" prefix of their own, on top of
            -- the pfx ("simpleui_hs_") every setter/getter concatenates in
            -- front of them — unlike module_clock's bare "clock_align"
            -- suffix. The resulting on-disk key really is double-prefixed.
            simpleui_hs_simpleui_quote_source = "quotes",
            simpleui_hs_simpleui_quote_align = "center",
            -- "currently" is deliberately left unconfigured here — it renders
            -- with whatever sui_config.lua's applyFirstRunDefaults() (or the
            -- user's own customization, if any) currently defines.
        }
    },
    {
        id = "builtin_momentum",
        name = _("Momentum"),
        desc = _("Cover Deck") .. ", " .. _("Reading Goals") .. ", " .. _("Reading Stats"),
        layout = { pages = { { id = 1, modules = { "coverdeck", "reading_goals", "reading_stats" } } } },
        settings = {
            simpleui_hs_coverdeck_source = "recent",
            simpleui_hs_coverdeck_main_order = { "title", "author", "covers", "progress", "stats" },
            simpleui_hs_coverdeck_scale = 100,
            simpleui_hs_coverdeck_thumb_scale = 100,
            simpleui_hs_coverdeck_item_label_scale = 100,
            simpleui_hide_label_coverdeck = false,
            -- Element visibility (show_*) and stats_order are deliberately
            -- left unconfigured so nothing is hidden — coverdeck renders with
            -- whatever sui_config.lua's applyFirstRunDefaults() (or the
            -- user's own customization, if any) currently defines.
        }
    },
    {
        id = "builtin_library_view",
        name = _("Library View"),
        desc = _("Cover Deck") .. ", " .. _("Recent Books"),
        layout = { pages = { { id = 1, modules = { "coverdeck", "recent" } } } },
        settings = {
            simpleui_hs_coverdeck_source = "tbr",
            simpleui_hs_coverdeck_scale = 100,
            simpleui_hs_coverdeck_thumb_scale = 100,
            simpleui_hs_coverdeck_item_label_scale = 100,
            simpleui_hide_label_coverdeck = false,
            -- Visibility/order (show_*, main_order, stats_order) deliberately
            -- left unconfigured so nothing is hidden — coverdeck renders with
            -- whatever sui_config.lua's applyFirstRunDefaults() (or the
            -- user's own customization, if any) currently defines.
            simpleui_hs_recent_show_progress = true,
            simpleui_hs_recent_show_text = true,
            simpleui_hs_recent_show_overlay = false,
            simpleui_hs_recent_scale = 100,
            simpleui_hs_recent_thumb_scale = 100,
            simpleui_hs_recent_item_label_scale = 100,
            simpleui_hs_recent_show_frame = false,
            simpleui_hs_recent_solid_bg = false,
            simpleui_hide_label_recent = false,
        }
    },
    {
        id = "builtin_dashboard",
        name = _("Dashboard"),
        desc = _("Clock") .. ", " .. _("Quote of the Day") .. ", " .. _("Currently Reading") .. ", "
            .. _("Reading Goals") .. ", " .. _("Reading Stats"),
        layout = { pages = { { id = 1, modules = { "clock", "quote", "currently", "reading_goals", "reading_stats" } } } },
        settings = {
            simpleui_hs_clock_scale       = 70,
            simpleui_hs_clock_align       = "left",
            simpleui_hs_bento_width_clock = 33,

            simpleui_hs_quote_scale             = 80,
            simpleui_hs_simpleui_quote_align    = "right",  -- see note on the double prefix above
            simpleui_hs_bento_width_quote       = 67,

            -- "currently" is deliberately left unconfigured here — it renders
            -- with whatever sui_config.lua's applyFirstRunDefaults() (or the
            -- user's own customization, if any) currently defines.

            -- simpleui_reading_goal is deliberately left unconfigured here —
            -- it uses the module's own default annual goal (12 books/year).
            simpleui_reading_goals_layout              = "rings",
            simpleui_hs_bento_width_reading_goals      = 33,
            simpleui_hide_label_reading_goals          = true,
            simpleui_hs_reading_goals_ring_content     = "outside",  -- "Detail Below Ring"
            simpleui_hs_reading_goals_scale            = 90,
            simpleui_hs_reading_goals_item_label_scale = 130,

            -- Scale is left unconfigured so the module renders at its default
            -- text size. Only "Today — Time" and "Streak" are shown.
            simpleui_hs_reading_stats_type        = "list",
            simpleui_hs_bento_width_reading_stats = 67,
            simpleui_hs_reading_stats_items       = { "today_time", "streak" },
        }
    }
}

local function isBuiltinName(name)
    for _, bp in ipairs(BUILTIN_PRESETS) do
        if bp.name == name then return true end
    end
    return false
end

-- Rows of the preset picker, shared by the welcome card and the settings
-- window: the built-in presets as titled rows with their module list, then the
-- user's presets. Once both groups exist each one gets a heading; rows are
-- separated by a line, except after the last one.
--   inner_w     number
--   user        bool                   include the user's presets
--   is_checked  function(id) -> bool   id: built-in id or user preset name
--   on_builtin  function(bp)           a built-in preset was tapped
--   on_user     function(name)         a user preset was tapped
function SUIPresets.buildListRows(opts)
    local SUIWindow = require("engines/sui_window")
    local names  = opts.user and SUIPresets.listNames() or {}
    local headed = #BUILTIN_PRESETS > 0 and #names > 0
    local rows   = {}

    local function addHeading(text)
        rows[#rows + 1] = SUIWindow.SectionLabel{ text = text, inner_w = opts.inner_w }
    end

    if headed then addHeading(_("System Presets")) end
    for i, bp in ipairs(BUILTIN_PRESETS) do
        rows[#rows + 1] = SUIWindow.ListRow{
            title     = bp.name,
            subtitle  = bp.desc,
            inner_w   = opts.inner_w,
            radio     = true,
            checked   = opts.is_checked(bp.id),
            separator = headed or i < #BUILTIN_PRESETS,
            on_tap    = function() opts.on_builtin(bp) end,
        }
    end
    if headed then addHeading(_("My Presets")) end
    for i, name in ipairs(names) do
        rows[#rows + 1] = SUIWindow.ListRow{
            title     = name,
            inner_w   = opts.inner_w,
            radio     = true,
            checked   = opts.is_checked(name),
            separator = i < #names,
            on_tap    = function() opts.on_user(name) end,
        }
    end
    return rows
end

-- Asks for the name of a preset of `opts.store` (any preset store: it needs
-- exists()). `on_submit(name)` runs once the name is accepted, after the sheet
-- closed; submitting the unchanged `value` does nothing.
--   store      table     the preset store the name is checked against
--   title, hint, value, ok_text   as in Dialogs.prompt
--   reserved   function  name -> true when the name may not be used
--   overwrite  bool      an existing name is allowed once the user confirms
--                        replacing that preset, on a page of the same sheet;
--                        otherwise it is refused
local function promptName(opts)
    local Dialogs = require("features/dialogs/sui_dialogs")
    local store   = opts.store
    Dialogs.prompt{
        title       = opts.title,
        value       = opts.value,
        hint        = opts.hint,
        ok_text     = opts.ok_text,
        empty_error = _("Please enter a name for the preset."),
        validate    = function(name)
            if name == opts.value then return nil end
            if opts.reserved and opts.reserved(name) then
                return _("This name is reserved by a built-in preset.")
            end
            if not opts.overwrite and store.exists(name) then
                return string.format(_("A preset named \"%s\" already exists."), name)
            end
        end,
        confirm     = opts.overwrite and function(texts)
            local name = texts[1]
            if name ~= opts.value and store.exists(name) then
                return {
                    title   = _("Overwrite preset"),
                    text    = string.format(
                        _("A preset named \"%s\" already exists.\nOverwrite it?"), name),
                    ok_text = _("Overwrite"),
                }
            end
        end or nil,
        on_submit   = function(name)
            if name ~= opts.value then opts.on_submit(name) end
        end,
    }
end

-- Renames the homescreen preset `name` after asking for the new name;
-- `on_done` runs once the rename is applied. The active-preset pointer follows.
local function promptRenameHS(name, on_done)
    promptName{
        store    = SUIPresets,
        title    = string.format(_("Rename \"%s\""), name),
        value    = name,
        ok_text  = _("Rename"),
        reserved = isBuiltinName,
        on_submit = function(new_name)
            SUIPresets.rename(name, new_name)
            if SUISettings:get("simpleui_hs_active_preset") == name then
                SUISettings:set("simpleui_hs_active_preset", new_name)
            end
            on_done()
        end,
    }
end

function SUIPresets.getAll()
    local v = SUISettings:get(HS_PRESET_KEY)
    return type(v) == "table" and v or {}
end

function SUIPresets.save(name)
    if type(name) ~= "string" or name == "" then
        logger.warn("simpleui/presets: save() called with invalid name")
        return false
    end
    local snapshot = {}
    for k, v in SUISettings:iterateKeys() do
        if _hsMatchesKey(k) then snapshot[k] = deepCopy(v) end
    end
    local presets = SUIPresets.getAll()
    presets[name] = snapshot
    SUISettings:set(HS_PRESET_KEY, presets)
    logger.dbg("simpleui/presets: saved preset '", name, "' with", _countKeys(snapshot), "keys")
    return true
end

function SUIPresets.apply(name)
    if type(name) ~= "string" or name == "" then return false end
    local presets  = SUIPresets.getAll()
    local snapshot = presets[name]
    if type(snapshot) ~= "table" then
        logger.warn("simpleui/presets: apply() — preset '", name, "' not found")
        return false
    end
    _clearHsKeys()
    -- Copies, so editing the live settings never alters the stored preset.
    for k, v in pairs(snapshot) do
        if _hsMatchesKey(k) then SUISettings:setNoFlush(k, deepCopy(v)) end
    end
    -- The saved instance lists may differ from the ones the registry loaded.
    require("modules/moduleregistry").invalidate()
    SUISettings:flush()
    logger.dbg("simpleui/presets: applied preset '", name, "'")
    return true
end

function SUIPresets.applyBuiltin(id)
    local bp = nil
    for _, b in ipairs(BUILTIN_PRESETS) do
        if b.id == id then bp = b; break end
    end
    if not bp then return false end

    -- Wipe every homescreen-scoped key first, so modules a built-in preset
    -- leaves "unconfigured" (see comments above) fall back to their own
    -- shipped defaults instead of inheriting whatever was set by a previous
    -- preset or by manual customization. Config.applyFirstRunDefaults()
    -- then repopulates the keys it explicitly tracks — it's idempotent, so
    -- it only fills what was just cleared. Any module-owned key with no
    -- entry there simply reads back as nil, and per-module getters already
    -- fall back to their own local default in that case.
    _clearHsKeys()
    require("infra/sui_config").applyFirstRunDefaults()

    -- Copies, so editing the live settings never alters the built-in preset.
    SUISettings:setNoFlush("simpleui_layout", deepCopy(bp.layout))

    -- Preset settings (including instance lists and per-instance keys) are
    -- written before the registry is consulted so instanciable modules are
    -- materialised for the enable/order pass.
    if bp.settings then
        for k, v in pairs(bp.settings) do
            SUISettings:setNoFlush(k, deepCopy(v))
        end
    end

    local active_set = {}
    local function entry_id(entry)
        if type(entry) == "table" then return entry.id end
        return entry
    end
    for _, page in ipairs(bp.layout.pages) do
        for _, entry in ipairs(page.modules) do
            local mod_id = entry_id(entry)
            if mod_id then active_set[mod_id] = true end
        end
    end

    local Registry = require("modules/moduleregistry")
    Registry.invalidate()
    local flat_order = {}
    for _, page in ipairs(bp.layout.pages) do
        for _, entry in ipairs(page.modules) do
            local mod_id = entry_id(entry)
            if mod_id then table.insert(flat_order, mod_id) end
        end
    end
    for _, mod in ipairs(Registry.list()) do
        if not active_set[mod.id] then table.insert(flat_order, mod.id) end
        local is_active = (active_set[mod.id] == true)
        if type(mod.setEnabled) == "function" then mod.setEnabled("simpleui_hs_", is_active)
        elseif mod.enabled_key then SUISettings:set("simpleui_hs_" .. mod.enabled_key, is_active) end
    end
    SUISettings:set("simpleui_hs_module_order", flat_order)

    SUISettings:flush()
    return true
end

function SUIPresets.delete(name)
    if type(name) ~= "string" or name == "" then return end
    local presets = SUIPresets.getAll()
    if presets[name] then
        presets[name] = nil
        SUISettings:set(HS_PRESET_KEY, presets)
        logger.dbg("simpleui/presets: deleted preset '", name, "'")
    end
end

function SUIPresets.rename(old_name, new_name)
    if type(old_name) ~= "string" or old_name == "" then return false end
    if type(new_name) ~= "string" or new_name == "" then return false end
    if old_name == new_name then return true end
    local presets = SUIPresets.getAll()
    if not presets[old_name] then return false end
    presets[new_name] = presets[old_name]
    presets[old_name] = nil
    SUISettings:set(HS_PRESET_KEY, presets)
    return true
end

function SUIPresets.exists(name)
    if type(name) ~= "string" or name == "" then return false end
    return SUIPresets.getAll()[name] ~= nil
end

function SUIPresets.listNames()
    local names = {}
    for name in pairs(SUIPresets.getAll()) do names[#names + 1] = name end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

function SUIPresets.export(name)
    local dir = _getExportDir()
    if not dir then return nil, _("No export directory") end
    local preset = SUIPresets.getAll()[name]
    if not preset then return nil, _("Preset not found") end

    local filename = name:gsub("[^%w_.-]", "_") .. "_sui_hs.lua"
    local filepath = dir .. "/" .. filename

    local ok, LuaSettings = pcall(require, "luasettings")
    if not ok or not LuaSettings then return nil, _("LuaSettings module unavailable") end

    local f = LuaSettings:open(filepath)
    f:saveSetting("type", "simpleui_homescreen_preset")
    f:saveSetting("name", name)
    f:saveSetting("data", preset)
    f:flush()
    return filepath
end

function SUIPresets.import(filepath)
    local ok, LuaSettings = pcall(require, "luasettings")
    if not ok or not LuaSettings then return nil, _("LuaSettings module unavailable") end

    local f = LuaSettings:open(filepath)
    local typ = f:readSetting("type")
    if typ ~= "simpleui_homescreen_preset" then
        return nil, _("Invalid preset file")
    end
    local name = f:readSetting("name") or "Imported Preset"
    local data = f:readSetting("data")
    if type(data) ~= "table" then return nil, _("Invalid data") end

    local presets = SUIPresets.getAll()
    local final_name = name
    local i = 1
    while presets[final_name] do
        final_name = name .. " (" .. i .. ")"
        i = i + 1
    end
    presets[final_name] = data
    SUISettings:set(HS_PRESET_KEY, presets)
    return final_name
end

function SUIPresets.getBuiltinPresets()
    return BUILTIN_PRESETS
end

-- ============================================================================
-- § 2  ICON PRESETS
-- ============================================================================

local ICON_PRESET_KEY    = "simpleui_icon_presets"
local SYSICON_PREFIX     = "simpleui_sysicon_"
local ACTION_PREFIX      = "simpleui_action_"
local ACTION_ICON_SUFFIX = "_icon"
local CQA_PREFIX         = "simpleui_qa_"
local CQA_LIST_KEY       = "simpleui_qa_list"

local function _hasPrefix(key, pfx)
    return key:sub(1, #pfx) == pfx
end

-- System icon overrides and default-action icon overrides (labels excluded).
local function _isScalarIconKey(key)
    if type(key) ~= "string" then return false end
    return _hasPrefix(key, SYSICON_PREFIX)
        or (_hasPrefix(key, ACTION_PREFIX) and key:sub(-#ACTION_ICON_SUFFIX) == ACTION_ICON_SUFFIX)
end

local SUIIconPresets = {}

function SUIIconPresets.getAll()
    local v = SUISettings:get(ICON_PRESET_KEY)
    return type(v) == "table" and v or {}
end

--- Saves the current state of all icons as a preset with the given name.
function SUIIconPresets.save(name)
    if type(name) ~= "string" or name == "" then
        logger.warn("simpleui/icon_presets: save() invalid name")
        return false
    end
    local snapshot = { _scalar = {}, _cqa = {} }

    -- Scalar keys: sysicon overrides + default action icon overrides.
    for k, v in SUISettings:iterateKeys() do
        if _isScalarIconKey(k) then snapshot._scalar[k] = v end
    end

    -- .icon field of each CQA (without touching other fields).
    local cqa_list = SUISettings:get(CQA_LIST_KEY) or {}
    for _i, qa_id in ipairs(cqa_list) do
        local cfg = SUISettings:get(CQA_PREFIX .. qa_id)
        if type(cfg) == "table" and cfg.icon ~= nil then
            snapshot._cqa[qa_id] = cfg.icon
        end
    end

    local presets = SUIIconPresets.getAll()
    presets[name] = snapshot
    SUISettings:set(ICON_PRESET_KEY, presets)
    logger.dbg("simpleui/icon_presets: saved '", name, "'")
    return true
end

--- Applies an icon preset.
--- QA: sui_quickactions module (to invalidate the cache after changing CQAs).
function SUIIconPresets.apply(name, QA)
    if type(name) ~= "string" or name == "" then return false end
    local snapshot = SUIIconPresets.getAll()[name]
    if type(snapshot) ~= "table" then
        logger.warn("simpleui/icon_presets: apply() — '", name, "' not found")
        return false
    end

    -- 1. Clear all current scalar icon keys.
    local to_delete = {}
    for k in SUISettings:iterateKeys() do
        if _isScalarIconKey(k) then to_delete[#to_delete + 1] = k end
    end
    for _i, k in ipairs(to_delete) do SUISettings:del(k) end

    -- 2. Restore scalar keys.
    local scalars = type(snapshot._scalar) == "table" and snapshot._scalar or {}
    for k, v in pairs(scalars) do
        if _isScalarIconKey(k) and type(v) == "string" then SUISettings:set(k, v) end
    end

    -- 3. Apply .icon to each existing CQA; CQAs missing from snapshot → reset.
    local cqa_list = SUISettings:get(CQA_LIST_KEY) or {}
    local cqa_icons = type(snapshot._cqa) == "table" and snapshot._cqa or {}
    for _i, qa_id in ipairs(cqa_list) do
        local cfg = SUISettings:get(CQA_PREFIX .. qa_id)
        if type(cfg) == "table" then
            local icon = cqa_icons[qa_id]
            cfg.icon = type(icon) == "string" and icon or nil  -- nil = reset to default
            SUISettings:set(CQA_PREFIX .. qa_id, cfg)
        end
    end

    -- 4. Invalidate QA cache.
    if QA and QA.invalidateCustomQACache then QA.invalidateCustomQACache() end

    logger.dbg("simpleui/icon_presets: applied '", name, "'")
    return true
end

function SUIIconPresets.delete(name)
    if type(name) ~= "string" or name == "" then return end
    local presets = SUIIconPresets.getAll()
    if presets[name] then
        presets[name] = nil
        SUISettings:set(ICON_PRESET_KEY, presets)
        logger.dbg("simpleui/icon_presets: deleted '", name, "'")
    end
end

function SUIIconPresets.rename(old_name, new_name)
    if type(old_name) ~= "string" or old_name == "" then return false end
    if type(new_name) ~= "string" or new_name == "" then return false end
    if old_name == new_name then return true end
    local presets = SUIIconPresets.getAll()
    if not presets[old_name] then return false end
    presets[new_name] = presets[old_name]
    presets[old_name] = nil
    SUISettings:set(ICON_PRESET_KEY, presets)
    return true
end

function SUIIconPresets.exists(name)
    if type(name) ~= "string" or name == "" then return false end
    return SUIIconPresets.getAll()[name] ~= nil
end

function SUIIconPresets.listNames()
    local names = {}
    for n in pairs(SUIIconPresets.getAll()) do names[#names + 1] = n end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

function SUIIconPresets.export(name)
    local dir = _getExportDir()
    if not dir then return nil, _("No export directory") end
    local preset = SUIIconPresets.getAll()[name]
    if not preset then return nil, _("Preset not found") end

    local filename = name:gsub("[^%w_.-]", "_") .. "_sui_icn.lua"
    local filepath = dir .. "/" .. filename

    local ok, LuaSettings = pcall(require, "luasettings")
    if not ok or not LuaSettings then return nil, _("LuaSettings module unavailable") end

    local f = LuaSettings:open(filepath)
    f:saveSetting("type", "simpleui_icon_preset")
    f:saveSetting("name", name)
    f:saveSetting("data", preset)
    f:flush()
    return filepath
end

function SUIIconPresets.import(filepath)
    local ok, LuaSettings = pcall(require, "luasettings")
    if not ok or not LuaSettings then return nil, _("LuaSettings module unavailable") end

    local f = LuaSettings:open(filepath)
    local typ = f:readSetting("type")
    if typ ~= "simpleui_icon_preset" then
        return nil, _("Invalid preset file")
    end
    local name = f:readSetting("name") or "Imported Icon Preset"
    local data = f:readSetting("data")
    if type(data) ~= "table" then return nil, _("Invalid data") end

    local presets = SUIIconPresets.getAll()
    local final_name = name
    local i = 1
    while presets[final_name] do
        final_name = name .. " (" .. i .. ")"
        i = i + 1
    end
    presets[final_name] = data
    SUISettings:set(ICON_PRESET_KEY, presets)
    return final_name
end

SUIPresets.getExportDir = _getExportDir
SUIPresets.getImportDir = _getImportDir
SUIPresets.listImportFiles = function() return _listImportFiles("_sui_hs.lua") end

-- ============================================================================
-- § 1b  HOMESCREEN PRESETS — KOReader menu item list
-- ============================================================================
-- Returns the canonical list of KOReader menu items for the Homescreen Presets
-- sub-menu.  Both sui_menu.lua (native KOReader menu) and sui_layout_editor.lua
-- (SUIWindow via C.MenuTable) call this function so the two surfaces are always
-- identical and never drift apart.
--
-- opts (all optional):
--   on_apply  function()  — called after a preset is successfully applied
--                           (sui_menu passes _applyFullLayoutRefresh;
--                            sui_layout_editor passes ctx.repaint)
--   on_save   function()  — called after save / update / rename / delete
--                           (useful for a SUIWindow to repaint its list)
--   in_window bool       — the menu is shown inside a SUIWindow: the preset
--                           pickers and manager use SUIWindow rows
--
-- Usage from a SUIWindow screen builder:
--
--   local SUIPresets = require("features/sui_presets")
--   local function buildPresets(ctx)
--       return C.MenuTable{
--           inner_w    = ctx.inner_w,
--           items      = SUIPresets.makeMenuItems{
--                            on_apply = function() ctx.repaint() end,
--                            on_save  = function() ctx.repaint() end,
--                        },
--           repaint    = function() ctx.repaint() end,
--           push_stack = function(_, params)
--               table.insert(st.settings_stack, params)
--               ctx.repaint()
--           end,
--           on_close   = function() ctx.pop() end,
--       }
--   end
--
function SUIPresets.makeMenuItems(opts)
    opts = opts or {}
    local on_apply       = opts.on_apply       or function() end
    local on_save        = opts.on_save        or function() end

    local UIManager   = require("ui/uimanager")
    local UI          = require("infra/sui_core")
    local function Dialogs() return require("features/dialogs/sui_dialogs") end
    local T = require("ffi/util").template

    -- Applies a homescreen preset with visible feedback for the blocking
    -- window: shows an "Applying preset…" notice, flushed to the e-ink
    -- screen immediately so it's visible before apply_fn (the settings-
    -- snapshot swap) runs, then closes it once the deferred homescreen
    -- rebuild (on_apply, scheduled via nextTick like every call site
    -- already does) has actually finished. Mirrors
    -- the loading notice of screens/sui_stats_launcher.lua for the same
    -- "otherwise the screen just sits frozen for a few seconds" problem.
    --
    -- Thin wrapper around infra/sui_core.lua's applyPresetWithNotice(),
    -- the single shared implementation used by every preset-apply flow
    -- in the plugin (Homescreen presets here, Icon presets in
    -- screens/sui_menu.lua).
    local function _applyPresetWithNotice(apply_fn, sync_repaint)
        return require("infra/sui_core").applyPresetWithNotice(apply_fn, on_apply, sync_repaint)
    end

    local items = {}
    local names = SUIPresets.listNames()

    -- ── Select Preset ─────────────────────────────────────────────────
    local select_items = {}
    
    for _, bp in ipairs(BUILTIN_PRESETS) do
        local _bp = bp
        select_items[#select_items + 1] = {
            text_func    = function() return _bp.name .. "\n" .. _bp.desc end,
            radio        = true,
            checked_func = function() return SUISettings:get("simpleui_hs_active_preset") == _bp.id end,
            callback = function()
                _applyPresetWithNotice(function()
                    SUIPresets.applyBuiltin(_bp.id)
                    SUISettings:set("simpleui_hs_active_preset", _bp.id)
                    return true
                end)
            end,
        }
    end

    if #BUILTIN_PRESETS > 0 and #names > 0 then
        select_items[#select_items].separator = true
    end

    for _i, name in ipairs(names) do
        local _name = name
        select_items[#select_items + 1] = {
            text_func    = function() return _name end,
            radio        = true,
            checked_func = function()
                return SUISettings:get("simpleui_hs_active_preset") == _name
            end,
            callback = function()
                local ok = _applyPresetWithNotice(function()
                    if not SUIPresets.apply(_name) then return false end
                    SUISettings:set("simpleui_hs_active_preset", _name)
                    return true
                end)
                if not ok then
                    UI.Notify.toast(string.format(_("Preset \"%s\" not found."), _name), 2)
                end
            end,
        }
    end

    items[#items + 1] = {
        text           = _("Select Preset"),
        enabled        = #names > 0 or #BUILTIN_PRESETS > 0,
        dim            = #names == 0 and #BUILTIN_PRESETS == 0,
        sub_item_table = select_items,
        separator      = true,
        sui_build      = opts.in_window and function(ctx, _item)
            local SUIWindow = require("engines/sui_window")
            return SUIWindow.ListRow{
                title        = _("Select Preset"),
                inner_w      = ctx.inner_w,
                show_chevron = true,
                on_tap       = function()
                    ctx.push("nested_menu", {
                        title = _("Select Preset"),
                        items_func = function()
                            return {
                                {
                                    text = "Items List",
                                    sui_build = function(ctx2)
                                        return SUIPresets.buildListRows{
                                            inner_w    = ctx2.inner_w,
                                            user       = true,
                                            is_checked = function(id)
                                                return SUISettings:get("simpleui_hs_active_preset") == id
                                            end,
                                            on_builtin = function(bp)
                                                _applyPresetWithNotice(function()
                                                    SUIPresets.applyBuiltin(bp.id)
                                                    SUISettings:set("simpleui_hs_active_preset", bp.id)
                                                    return true
                                                end, ctx2.repaint)
                                            end,
                                            on_user    = function(name)
                                                local ok = _applyPresetWithNotice(function()
                                                    if not SUIPresets.apply(name) then return false end
                                                    SUISettings:set("simpleui_hs_active_preset", name)
                                                    return true
                                                end, ctx2.repaint)
                                                if not ok then
                                                    UI.Notify.toast(string.format(_("Preset \"%s\" not found."), name), 2)
                                                end
                                            end,
                                        }
                                    end
                                }
                            }
                        end
                    })
                end
            }
        end or nil,
    }

    -- ── Save as new preset ────────────────────────────────────────────
    items[#items + 1] = {
        text            = _("Save as new preset"),
        keep_menu_open  = true,
        callback = function()
            promptName{
                store     = SUIPresets,
                title     = _("Save preset"),
                hint      = _("Preset name"),
                ok_text   = _("Save"),
                reserved  = isBuiltinName,
                overwrite = true,
                on_submit = function(name)
                    SUIPresets.save(name)
                    SUISettings:set("simpleui_hs_active_preset", name)
                    UI.Notify.toast(string.format(_("Preset \"%s\" saved."), name), 2)
                    UIManager:nextTick(on_save)
                end,
            }
        end,
    }

    -- ── Manage presets ────────────────────────────────────────────────
    if #names > 0 then
        items[#items + 1] = {
            text = _("Manage presets"),
            sub_item_table_func = function()
                local sub = {}
                for _i, name in ipairs(SUIPresets.listNames()) do
                    local _name = name
                    sub[#sub + 1] = {
                        text = _name,
                        sub_item_table = {
                            { text = _("Update with current settings"), callback = function()
                                Dialogs().confirm{
                                    text = string.format(_("Overwrite preset \"%s\" with the current homescreen settings?"), _name),
                                    ok_text     = _("Overwrite"),
                                    cancel_text = _("Cancel"),
                                    ok_callback = function()
                                        SUIPresets.save(_name)
                                        SUISettings:set("simpleui_hs_active_preset", _name)
                                        UI.Notify.toast(string.format(_("Preset \"%s\" updated."), _name), 2)
                                        UIManager:nextTick(on_save)
                                    end,
                                }
                            end },
                            { text = _("Rename"), callback = function()
                                promptRenameHS(_name, function() UIManager:nextTick(on_save) end)
                            end },
                            { text = _("Delete"), callback = function()
                                Dialogs().confirm{
                                    text        = string.format(_("Delete preset \"%s\"?"), _name),
                                    ok_text     = _("Delete"),
                                    cancel_text = _("Cancel"),
                                    ok_callback = function()
                                        SUIPresets.delete(_name)
                                        local active = SUISettings:get("simpleui_hs_active_preset")
                                        if active == _name then SUISettings:del("simpleui_hs_active_preset") end
                                        UIManager:nextTick(on_save)
                                    end,
                                }
                            end },
                        }
                    }
                end
                return sub
            end,
            sui_build = opts.in_window and function(ctx, _item)
                local SUIWindow = require("engines/sui_window")
                return SUIWindow.ListRow{
                    title        = _("Manage presets"),
                    inner_w      = ctx.inner_w,
                    show_chevron = true,
                    on_tap       = function()
                        ctx.push("nested_menu", {
                            title = _("Manage presets"),
                            items_func = function()
                                return {
                                    {
                                        text = "Items List",
                                        sui_build = function(ctx2)
                                            local SUIWindow2 = require("engines/sui_window")
                                            local rows = {}
                                            for _k, _name in ipairs(SUIPresets.listNames()) do
                                                rows[#rows + 1] = SUIWindow2.ListRow{
                                                    title     = _name,
                                                    inner_w   = ctx2.inner_w,
                                                    on_delete = function()
                                                        Dialogs().confirm{
                                                            text        = string.format(_("Delete preset \"%s\"?"), _name),
                                                            ok_text     = _("Delete"),
                                                            cancel_text = _("Cancel"),
                                                            ok_callback = function()
                                                                SUIPresets.delete(_name)
                                                                local active = SUISettings:get("simpleui_hs_active_preset")
                                                                if active == _name then SUISettings:del("simpleui_hs_active_preset") end
                                                                ctx2.repaint()
                                                                UIManager:nextTick(on_save)
                                                            end,
                                                        }
                                                    end,
                                                    on_edit = function()
                                                        promptRenameHS(_name, function()
                                                            ctx2.repaint()
                                                            UIManager:nextTick(on_save)
                                                        end)
                                                    end,
                                                    on_update = function()
                                                        Dialogs().confirm{
                                                            text = string.format(_("Overwrite preset \"%s\" with the current homescreen settings?"), _name),
                                                            ok_text     = _("Overwrite"),
                                                            cancel_text = _("Cancel"),
                                                            ok_callback = function()
                                                                SUIPresets.save(_name)
                                                                SUISettings:set("simpleui_hs_active_preset", _name)
                                                                UI.Notify.toast(string.format(_("Preset \"%s\" updated."), _name), 2)
                                                                ctx2.repaint()
                                                                UIManager:nextTick(on_save)
                                                            end,
                                                        }
                                                    end,
                                                }
                                            end
                                            if #rows == 0 then
                                                rows[#rows + 1] = SUIWindow2.ListRow{ title = _("No presets found."), inner_w = ctx2.inner_w }
                                            end
                                            return rows
                                        end
                                    }
                                }
                            end
                        })
                    end
                }
            end or nil,
        }
    end

    -- ── Import ────────────────────────────────────────────────────────
    items[#items + 1] = {
        text = _("Import preset"),
        sub_item_table_func = function()
            local sub   = {}
            local files = SUIPresets.listImportFiles()

            if #files == 0 then
                sub[#sub + 1] = {
                    text    = T(_("No preset files found.\nPlace .lua files in:\n%1"),
                                SUIPresets.getImportDir() or ""),
                    enabled = false,
                }
            else
                for _i, f in ipairs(files) do
                    local _f = f
                    sub[#sub + 1] = {
                        text            = _f.name,
                        keep_menu_open  = true,
                        callback = function()
                            local imported_name, err = SUIPresets.import(_f.path)
                            if imported_name then
                                UI.Notify.toast(string.format(_("Preset \"%s\" imported."), imported_name))
                                UIManager:nextTick(on_save)
                            else
                                UI.Notify.toast(_("Error importing preset: ") .. tostring(err), 4)
                            end
                        end,
                    }
                end
            end
            return sub
        end,
        separator = true,
    }

    -- ── Export ────────────────────────────────────────────────────────
    if #names > 0 then
        items[#items + 1] = {
            text = _("Export preset"),
            sub_item_table_func = function()
                local sub = {}
                for _i, name in ipairs(SUIPresets.listNames()) do
                    local _name = name
                    sub[#sub + 1] = {
                        text     = _name,
                        callback = function()
                            local filepath, err = SUIPresets.export(_name)
                            if filepath then
                                UI.Notify.toast(string.format(_("Preset exported to:\n%s"), filepath), 4)
                            else
                                UI.Notify.toast(_("Error exporting preset: ") .. tostring(err), 4)
                            end
                        end,
                    }
                end
                return sub
            end,
        }
    end

    return items
end

SUIIconPresets.getExportDir = _getExportDir
SUIIconPresets.getImportDir = _getImportDir
SUIIconPresets.listImportFiles = function() return _listImportFiles("_sui_icn.lua") end

-- ============================================================================
-- Exports
-- ============================================================================

return {
    -- Homescreen presets (compatibility with existing code that does
    -- local P = require("features/sui_presets") and calls P.save / P.apply / etc.)
    save      = SUIPresets.save,
    apply     = SUIPresets.apply,
    delete    = SUIPresets.delete,
    listNames = SUIPresets.listNames,
    exists    = SUIPresets.exists,
    rename    = SUIPresets.rename,
    getAll    = SUIPresets.getAll,
    export    = SUIPresets.export,
    import    = SUIPresets.import,
    getExportDir    = _getExportDir,
    getImportDir    = _getImportDir,
    listImportFiles = SUIPresets.listImportFiles,
    getBuiltinPresets = SUIPresets.getBuiltinPresets,
        applyBuiltin = SUIPresets.applyBuiltin,

    -- Homescreen preset menu items (shared between sui_menu and sui_layout_editor)
    makeMenuItems = SUIPresets.makeMenuItems,
    icons = SUIIconPresets,

    -- Shared name prompt for any preset store (see promptName)
    promptName = promptName,
}
