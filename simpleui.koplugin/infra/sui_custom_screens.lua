-- infra/sui_custom_screens.lua — Custom Screens store.
--
-- A "Custom Screen" is a user-created page that behaves like the built-in
-- Homescreen (its own modules, layout, gestures) but is opened on demand
-- instead of living on a fixed tab. Rendering is delegated to
-- engines/sui_screen_engine.lua; this module owns the CRUD side: the
-- persisted list, settings-namespace allocation, and each screen's Quick
-- Action lifecycle.
--
-- DATA MODEL — "simpleui_custom_screens" = { { id, name, icon, pfx, layout_key }, ... }
--   id          short stable id, e.g. "cs_3f9a02" (see _newId)
--   name        user-facing label, also the Quick Action's label
--   icon        absolute path to a custom icon, or nil (falls back to
--               Config.ICON.custom wherever the screen is rendered)
--   pfx         settings-key prefix for everything owned by this screen
--               (module toggles/options/instances, gesture overrides) —
--               mirrors the Homescreen's own "simpleui_hs_"
--   layout_key  settings key holding this screen's { pages = {...} } layout
--               — mirrors the Homescreen's own "simpleui_layout"
--
-- QUICK ACTION LIFECYCLE — every screen owns exactly one Quick Action, id
-- "open_custom_screen:<id>". QA.register()/QA.unregister() only touch an
-- in-memory registry with no on-disk component of its own, so:
--   M.create()/rename()/setIcon()  (re)register the QA immediately
--   M.delete()                     unregisters it FIRST, before anything else
--   M.registerAllQuickActions()    must run once per plugin boot (main.lua)
--
-- Always go through this module for create/rename/delete — never write
-- "simpleui_custom_screens" directly, or the Quick Action side falls out of
-- sync with the stored list.

local logger      = require("logger")
local SUISettings = require("infra/sui_store")
local _           = require("infra/sui_i18n").translate

local LIST_KEY = "simpleui_custom_screens"

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Lazy require to avoid a load-order cycle: features/sui_quickactions may
-- itself want to enumerate custom screens (e.g. a "manage screens"
-- shortcut), and this module needs it for QA.register/unregister.
local function _QA()
    local ok, QA = pcall(require, "features/sui_quickactions")
    if ok and QA then return QA end
    logger.warn("simpleui: sui_custom_screens: features/sui_quickactions unavailable")
    return nil
end

local function _list()
    local raw = SUISettings:readSetting(LIST_KEY)
    if type(raw) ~= "table" then return {} end
    return raw
end

local function _save(list)
    SUISettings:saveSetting(LIST_KEY, list)
end

-- Same convention as Registry.createInstance (modules/moduleregistry.lua):
-- a 6-hex-char suffix derived from the current time in milliseconds.
local function _newId()
    return "cs_" .. string.format("%06x", math.floor(os.time() * 1000) % 0xFFFFFF)
end

local function _findIndex(list, id)
    for i, s in ipairs(list) do
        if s.id == id then return i end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Quick Action id + (re)registration
-- ---------------------------------------------------------------------------

function M.qaId(screen_id)
    return "open_custom_screen:" .. screen_id
end

-- Registers (or refreshes) the Quick Action that opens `screen`. Safe to
-- call repeatedly — QA.register replaces any existing descriptor sharing
-- the same id, so this doubles as the "label/icon changed" update path.
function M.registerQuickAction(screen)
    local QA = _QA()
    if not QA then return end
    local Config = require("infra/sui_config")
    QA.register{
        id          = M.qaId(screen.id),
        label       = screen.name,
        icon        = screen.icon or Config.ICON.custom,
        is_in_place = false,
        execute     = function(_ctx)
            local ok, err = pcall(function()
                require("engines/sui_screen_engine").showCustomScreen(screen.id)
            end)
            if not ok then
                logger.warn("simpleui: open_custom_screen QA failed for "
                    .. tostring(screen.id) .. ": " .. tostring(err))
            end
        end,
    }
end

-- Repopulates the in-memory QA registry for every persisted screen. Must be
-- called once per plugin boot (main.lua SimpleUIPlugin:init) — QA.register
-- has no on-disk component of its own.
function M.registerAllQuickActions()
    for _, screen in ipairs(_list()) do
        M.registerQuickAction(screen)
    end
end

-- ---------------------------------------------------------------------------
-- Public CRUD
-- ---------------------------------------------------------------------------

function M.list()
    return _list()
end

function M.get(id)
    for _, s in ipairs(_list()) do
        if s.id == id then return s end
    end
    return nil
end

-- Creates a new screen, persists it, and registers its Quick Action.
-- Returns the new screen descriptor.
-- Modules whose Registry.isEnabled() resolves to true on an unset settings
-- prefix (i.e. mod.default_on == true, or — for "clock", which has no
-- enabled_key — its own isEnabled() falls back to nilOrTrue on each of its
-- three visibility flags). Every other registered module already defaults
-- to OFF when its settings are unset, so no explicit write is needed for
-- those. A brand-new Custom Screen must start with NO modules visible, so
-- these are force-written to false right on creation — mirroring how
-- sui_config.lua's applyFirstRunDefaults() makes the Homescreen's defaults
-- explicit and greppable rather than relying on each module's intrinsic
-- default_on.
local NEW_SCREEN_OFF_KEYS = {
    "clock_enabled", "clock_date", "clock_battery",
    "currently_enabled",
    "reading_goals_enabled",
}

function M.create(name)
    local list = _list()
    local id = _newId()
    while _findIndex(list, id) do id = _newId() end -- collision guard

    local screen = {
        id         = id,
        name       = (name and name ~= "") and name or _("Custom Screen"),
        icon       = nil,
        pfx        = "simpleui_cs_" .. id .. "_",
        layout_key = "simpleui_layout_cs_" .. id,
    }
    list[#list + 1] = screen
    _save(list)

    -- Force a genuinely empty screen — see NEW_SCREEN_OFF_KEYS above.
    -- setNoFlush() + a single trailing flush() avoids one disk write per key.
    for _, key in ipairs(NEW_SCREEN_OFF_KEYS) do
        SUISettings:setNoFlush(screen.pfx .. key, false)
    end
    SUISettings:flush()

    M.registerQuickAction(screen)
    logger.dbg("simpleui: sui_custom_screens: created", id)
    return screen
end

function M.rename(id, new_name)
    local list = _list()
    local idx = _findIndex(list, id)
    if not idx then return false end
    if new_name and new_name ~= "" then
        list[idx].name = new_name
    end
    _save(list)
    M.registerQuickAction(list[idx])
    return true
end

function M.setIcon(id, icon_path)
    local list = _list()
    local idx = _findIndex(list, id)
    if not idx then return false end
    list[idx].icon = icon_path
    _save(list)
    M.registerQuickAction(list[idx])
    return true
end

-- Reorders the list to match `ordered_ids`. Any existing screen not
-- mentioned is kept, appended in its previous relative order (defensive —
-- callers are expected to pass every id).
function M.reorder(ordered_ids)
    local list = _list()
    local by_id = {}
    for _, s in ipairs(list) do by_id[s.id] = s end

    local new_list = {}
    for _, id in ipairs(ordered_ids) do
        if by_id[id] then
            new_list[#new_list + 1] = by_id[id]
            by_id[id] = nil
        end
    end
    for _, s in ipairs(list) do
        if by_id[s.id] then new_list[#new_list + 1] = s end
    end
    _save(new_list)
end

-- Deletes a custom screen entirely:
--   1. unregisters its Quick Action first — a dangling QA pointing at a
--      dead screen is the failure mode a user would actually notice
--   2. removes its layout and its entry in the screen list
--   3. purges every "<pfx>*" settings key it owns (module toggles/options/
--      instances placed on this screen, gesture overrides)
function M.delete(id)
    local screen = M.get(id)
    if not screen then return false end

    local QA = _QA()
    if QA then QA.unregister(M.qaId(id)) end

    SUISettings:delSetting(screen.layout_key)

    local list, kept = _list(), {}
    for _, s in ipairs(list) do
        if s.id ~= id then kept[#kept + 1] = s end
    end
    _save(kept)

    -- iterateKeys() forbids mutating the store mid-iteration (see
    -- infra/sui_store.lua), so collect matching keys first, then delete.
    local pfx = screen.pfx
    local doomed = {}
    for k in SUISettings:iterateKeys() do
        if type(k) == "string" and k:sub(1, #pfx) == pfx then
            doomed[#doomed + 1] = k
        end
    end
    for _, k in ipairs(doomed) do
        SUISettings:delSetting(k)
    end

    logger.dbg("simpleui: sui_custom_screens: deleted", id,
        "(" .. #doomed .. " settings keys purged)")
    return true
end

return M
