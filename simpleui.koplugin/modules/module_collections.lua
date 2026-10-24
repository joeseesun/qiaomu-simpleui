-- module_collections.lua — Simple UI
-- Module: Collections.
--
-- A grid with one cell per collection: representative cover, book count and
-- name. Built on GridRenderer.makeModule with the group cell of
-- engines/sui_group_cell.lua, so it gets the configurable grid (rows and
-- columns), swipe pagination and the cover styles (single cover, 4-cover grid
-- or automatic) from the engines.
--
-- Collection selection is opt-out: every existing collection is shown unless
-- the person hides it. Persistence:
--   EXCLUDED_KEY  names of the hidden collections
--   ORDER_KEY     manual arrangement order (read when the sort mode is manual)
--   SORT_KEY      "manual" | "alpha_asc" | "alpha_desc"
-- The cover chosen for a collection lives in the shared cover override store,
-- under COVER_KEY_PREFIX .. name.

local CenterContainer = require("ui/widget/container/centercontainer")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local _  = require("infra/sui_i18n").translate
local N_ = require("infra/sui_i18n").ngettext

local Config         = require("infra/sui_config")
local GridRenderer   = require("engines/sui_book_grid")
local GroupCell      = require("engines/sui_group_cell")
local CoverOverrides = require("features/library/sui_cover_overrides")
local GroupActions   = require("features/library/sui_group_actions")
local ScreenNav      = require("infra/sui_screen_nav")
local SUISettings    = require("infra/sui_store")
local SUIStyle       = require("features/sui_style")
local Chrome       = require("features/sui_module_chrome")
local UI             = require("infra/sui_core")

local PAD = UI.PAD

local MODULE_ID = "collections"

-- Default number of columns of the grid.
local MAX_ITEMS = 5

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------
local ORDER_KEY          = "simpleui_coll_list"
local EXCLUDED_KEY       = "simpleui_coll_excluded"
local SORT_KEY           = "simpleui_coll_sort_mode"
local LEGACY_COVERS_KEY  = "simpleui_coll_covers"
local COVER_KEY_PREFIX   = "collection/"

-- Presentation settings of the group cell. They are global to the module, not
-- per screen.
local PRESENTATION_KEYS = {
    cover_style    = "simpleui_coll_cover_style",
    hide_pile      = "simpleui_coll_hide_spine",
    badge_position = "simpleui_coll_badge_position",
    badge_color    = "simpleui_coll_badge_color",
    badge_hidden   = "simpleui_coll_badge_hidden",
    badge_scale    = "simpleui_coll_badge_scale",
    label          = "simpleui_coll_label",
}

local settings = GroupCell.makeSettings{
    keyFor        = function(_pfx, field) return PRESENTATION_KEYS[field] end,
    default_style = "single",
}

-- ---------------------------------------------------------------------------
-- Cover overrides
-- ---------------------------------------------------------------------------

local function coverKey(coll_name)
    return COVER_KEY_PREFIX .. coll_name
end

-- Moves the covers chosen before the shared override store existed into it.
local _covers_migrated = false
local function migrateLegacyCovers()
    if _covers_migrated then return end
    _covers_migrated = true
    local legacy = SUISettings:readSetting(LEGACY_COVERS_KEY)
    if type(legacy) ~= "table" then return end
    for coll_name, book_path in pairs(legacy) do
        CoverOverrides.set(coverKey(coll_name), book_path)
    end
    SUISettings:delSetting(LEGACY_COVERS_KEY)
end

-- ---------------------------------------------------------------------------
-- ReadCollection helpers
-- ---------------------------------------------------------------------------
local function getRC()
    local ok_rc, rc = pcall(require, "readcollection")
    if ok_rc and rc then return rc end
    return nil
end

-- Every existing collection: the default collection first, then the rest
-- alphabetically. An empty To Be Read collection is left out.
local function listAllCollectionNames()
    local rc = getRC()
    local all_colls = {}
    if rc then
        local fav = rc.default_collection_name or "favorites"
        local coll_set = {}
        if rc.coll then for n in pairs(rc.coll) do coll_set[n] = true end end
        if rc.coll_folders then for n in pairs(rc.coll_folders) do coll_set[n] = true end end
        if coll_set[fav] then
            all_colls[#all_colls + 1] = fav
            coll_set[fav] = nil
        end
        local others = {}
        for name in pairs(coll_set) do others[#others + 1] = name end
        table.sort(others, function(a, b) return a:lower() < b:lower() end)
        for _i, n in ipairs(others) do all_colls[#all_colls + 1] = n end
    end
    local TBR = package.loaded["modules/module_tbr"]
    if TBR then
        local filtered = {}
        for _i, n in ipairs(all_colls) do
            if n ~= TBR.TBR_COLL_NAME or TBR.getTBRCount() > 0 then
                filtered[#filtered + 1] = n
            end
        end
        all_colls = filtered
    end
    return all_colls
end

local function displayNameFor(coll_name)
    local TBR = package.loaded["modules/module_tbr"]
    if TBR and coll_name == TBR.TBR_COLL_NAME then return TBR.getDisplayName() end
    return coll_name
end

-- Book paths of a collection, in the order of the collection.
local function getCollectionFiles(coll_name)
    local rc = getRC()
    local coll = rc and rc.coll and rc.coll[coll_name]
    if not coll then return {} end
    local entries = {}
    for fp, info in pairs(coll) do
        entries[#entries + 1] = { filepath = fp, order = (type(info) == "table" and info.order) or 9999 }
    end
    table.sort(entries, function(a, b) return a.order < b.order end)
    local files = {}
    for i, entry in ipairs(entries) do files[i] = entry.filepath end
    return files
end

-- ---------------------------------------------------------------------------
-- Collection selection — opt-out model.
-- ---------------------------------------------------------------------------
local function saveExcludedCollections(list)
    SUISettings:saveSetting(EXCLUDED_KEY, list)
end

-- Names of the hidden collections. The first read after an upgrade from the
-- positive-selection model derives them from the old selection, which stays in
-- ORDER_KEY as the initial manual order.
local function getExcludedCollections()
    local raw = SUISettings:readSetting(EXCLUDED_KEY)
    if raw ~= nil then return raw end

    local legacy_selection = SUISettings:readSetting(ORDER_KEY)
    if legacy_selection == nil then
        saveExcludedCollections({})
        return {}
    end

    local all = listAllCollectionNames()
    -- The collections subsystem is not loaded yet: derive nothing, retry later.
    if #all == 0 and not getRC() then return {} end
    local selected_set = {}
    for _i, n in ipairs(legacy_selection) do selected_set[n] = true end
    local excluded = {}
    for _i, n in ipairs(all) do
        if not selected_set[n] then excluded[#excluded + 1] = n end
    end
    saveExcludedCollections(excluded)
    return excluded
end

local function isExcluded(coll_name)
    for _i, n in ipairs(getExcludedCollections()) do
        if n == coll_name then return true end
    end
    return false
end

local function hideCollection(coll_name)
    if isExcluded(coll_name) then return end
    local excluded = getExcludedCollections()
    excluded[#excluded + 1] = coll_name
    saveExcludedCollections(excluded)
end

local function unhideCollection(coll_name)
    local kept = {}
    for _i, n in ipairs(getExcludedCollections()) do
        if n ~= coll_name then kept[#kept + 1] = n end
    end
    saveExcludedCollections(kept)
end

local function getManualOrder()
    return SUISettings:readSetting(ORDER_KEY) or {}
end
local function saveManualOrder(list)
    SUISettings:saveSetting(ORDER_KEY, list)
end

local SORT_MODE_ORDER  = { "manual", "alpha_asc", "alpha_desc" }
local SORT_MODE_LABELS = {
    manual     = _("Manual order"),
    alpha_asc  = _("Name (A–Z)"),
    alpha_desc = _("Name (Z–A)"),
}
local DEFAULT_SORT_MODE = "manual"

local function getSortMode()
    return Config.readChoice(SORT_KEY, SORT_MODE_ORDER, DEFAULT_SORT_MODE)
end
local function saveSortMode(mode)
    SUISettings:saveSetting(SORT_KEY, mode)
end

-- Orders `names` by the sort mode. In manual mode the known names keep their
-- arrangement order and the others follow in their natural order.
local function orderCollections(names)
    local mode = getSortMode()
    if mode == "alpha_asc" or mode == "alpha_desc" then
        local sorted = {}
        for _i, n in ipairs(names) do sorted[#sorted + 1] = n end
        table.sort(sorted, function(a, b)
            local da, db = displayNameFor(a):lower(), displayNameFor(b):lower()
            if mode == "alpha_desc" then return da > db end
            return da < db
        end)
        return sorted
    end

    local pos = {}
    for i, n in ipairs(getManualOrder()) do pos[n] = i end
    local known, new_ones = {}, {}
    for _i, n in ipairs(names) do
        if pos[n] then known[#known + 1] = n else new_ones[#new_ones + 1] = n end
    end
    table.sort(known, function(a, b) return pos[a] < pos[b] end)
    for _i, n in ipairs(new_ones) do known[#known + 1] = n end
    return known
end

-- Collections shown by the grid, in order.
local function getVisibleCollections()
    local visible = {}
    for _i, n in ipairs(listAllCollectionNames()) do
        if not isExcluded(n) then visible[#visible + 1] = n end
    end
    return orderCollections(visible)
end

-- Every collection, hidden ones included, in the order they would have if
-- none were hidden.
local function getAllCollectionsOrdered()
    return orderCollections(listAllCollectionNames())
end

-- ---------------------------------------------------------------------------
-- Opening a collection
-- ---------------------------------------------------------------------------

-- Shows the collection in the file manager. Showing it closes the open
-- screen, whose state is kept; going back returns to that screen instead of
-- the list of collections.
local function openCollection(coll_name)
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FM and FM.instance
    if not fm then return end

    local screen_id = ScreenNav.handOff(function()
        if fm.collections and type(fm.collections.onShowColl) == "function" then
            pcall(function() fm.collections:onShowColl(coll_name) end)
        elseif fm.collections and type(fm.collections.onShowCollList) == "function" then
            pcall(function() fm.collections:onShowCollList() end)
        end
    end)

    local booklist = fm.collections and fm.collections.booklist_menu
    if booklist and screen_id then
        booklist.onReturn = function()
            booklist.close_callback()
            ScreenNav.reopen(screen_id)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Cell
-- ---------------------------------------------------------------------------

-- The books of `files` as entries of the cover picker.
local function pickerBooks(files)
    local ok, bim = pcall(require, "bookinfomanager")
    local books = {}
    for i, fp in ipairs(files) do
        local info = ok and bim and bim:getBookInfo(fp, false)
        books[i] = { path = fp, title = info and info.title }
    end
    return books
end

local function openCoverPicker(coll_name, files, on_change)
    GroupActions.openCoverPicker{
        title         = string.format(_("Cover for \"%s\""), coll_name),
        override_key  = coverKey(coll_name),
        items         = pickerBooks(files),
        on_change     = on_change,
        empty_message = _("Collection is empty."),
    }
end

local function describeCollection(coll_name)
    local files = getCollectionFiles(coll_name)
    return {
        name           = displayNameFor(coll_name),
        paths          = files,
        count          = #files,
        cover_key      = coverKey(coll_name),
        open           = function() openCollection(coll_name) end,
        books          = function() return pickerBooks(files) end,
        set_cover_text = _("Set collection cover"),
    }
end

local cell = GroupCell.new{
    owner_id = MODULE_ID,
    settings = settings,
    describe = describeCollection,
}

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

-- Collections row: selection and arrangement, with no limit on the items.
local function extraMenuItemsBefore(ctx_menu)
    local _UIManager = ctx_menu.UIManager
    local SortWidget = ctx_menu.SortWidget
    local refresh    = ctx_menu.refresh
    local _lc        = ctx_menu._

    return {{
        text = _lc("Collections"), keep_menu_open = true,
        callback = function()
            local visible = getVisibleCollections()
            if #visible < 2 then
                UI.Notify.toast(_lc("Select at least 2 collections to arrange."), 2)
                return
            end
            local sort_items = {}
            for _i, n in ipairs(visible) do
                sort_items[#sort_items + 1] = { text = displayNameFor(n), orig_item = n }
            end
            _UIManager:show(SortWidget:new{
                title             = _lc("Collections"),
                item_table        = sort_items,
                covers_fullscreen = true,
                callback          = function()
                    local order = {}
                    for _i, item in ipairs(sort_items) do order[#order + 1] = item.orig_item end
                    saveManualOrder(order)
                    refresh()
                end,
            })
        end,
        sui_build = ctx_menu.is_sui and function(ctx, _item)
            local SUIWindow = require("engines/sui_window")
            return SUIWindow.ListRow{
                title        = _lc("Collections"),
                subtitle     = function()
                    local visible = getVisibleCollections()
                    if #visible == 0 then return _lc("No items selected.") end
                    local names = {}
                    for _i, n in ipairs(visible) do names[#names + 1] = displayNameFor(n) end
                    return table.concat(names, "  ·  ")
                end,
                inner_w      = ctx.inner_w,
                item_count   = function() return #getVisibleCollections() end,
                show_chevron = true,
                on_tap       = function()
                    -- Hidden collections stay listed, dimmed, with an eye
                    -- toggle that hides or shows them without moving the row.
                    local excluded_set = {}
                    for _i, n in ipairs(getExcludedCollections()) do excluded_set[n] = true end

                    local sort_items = {}
                    for _i, n in ipairs(getAllCollectionsOrdered()) do
                        sort_items[#sort_items + 1] = Config.applyVisibilityToggle({
                            text      = displayNameFor(n),
                            orig_item = n,
                        }, {
                            is_visible  = function() return not excluded_set[n] end,
                            set_visible = function(visible)
                                if visible then unhideCollection(n) else hideCollection(n) end
                                excluded_set[n] = not visible or nil
                            end,
                            on_change   = refresh,
                            repaint     = ctx.repaint,
                        })
                    end

                    ctx.push("arrange", {
                        title      = _lc("Collections"),
                        items      = sort_items,
                        empty_text = _lc("No collections found."),
                        on_change  = function(items_to_save)
                            local order = {}
                            for _j, it in ipairs(items_to_save) do order[#order + 1] = it.orig_item end
                            saveManualOrder(order)
                            refresh()
                        end,
                    })
                end
            }
        end or nil,
    }}
end

-- Sort, cover style, badge and the checklist of available collections.
local function extraMenuItemsAfter(ctx_menu)
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._
    local pfx     = ctx_menu.pfx

    local items = {}

    local sort_options = {}
    for _i, mode in ipairs(SORT_MODE_ORDER) do
        sort_options[#sort_options + 1] = { value = mode, label = SORT_MODE_LABELS[mode] }
    end
    items[#items + 1] = Config.makeRadioSubmenuItem{
        text      = _lc("Sort"),
        options   = sort_options,
        get       = getSortMode,
        set       = saveSortMode,
        refresh   = refresh,
        separator = true,
    }

    for _i, item in ipairs(GroupCell.makeMenuItems(ctx_menu, settings)) do
        items[#items + 1] = item
    end

    local all_colls = listAllCollectionNames()
    if #all_colls == 0 then
        items[#items + 1] = { text = _lc("No collections found."), enabled = false }
        return items
    end
    for _i, coll_name in ipairs(all_colls) do
        local files = getCollectionFiles(coll_name)
        local single = GroupCell.resolveStyle(settings.coverStyle(pfx), #files) == "single"
        items[#items + 1] = {
            text           = displayNameFor(coll_name),
            checked_func   = function() return not isExcluded(coll_name) end,
            keep_menu_open = true,
            callback       = function()
                if isExcluded(coll_name) then unhideCollection(coll_name) else hideCollection(coll_name) end
                refresh()
            end,
            hold_callback  = single and function() openCoverPicker(coll_name, files, refresh) end or nil,
            sui_hidden     = ctx_menu.is_sui or nil,
        }
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------
local mod = GridRenderer.makeModule{
    id          = MODULE_ID,
    name        = _("Collections"),
    label       = _("Collections"),
    text_label  = _("Label"),
    default_on  = false,
    is_book_mod = true,   -- needed for the surgical repaint of the swipe between pages
    max_items   = MAX_ITEMS,
    paged       = true,
    hold_dialog_label = _("Collection Menu"),

    getFileList = function()
        migrateLegacyCovers()
        return getVisibleCollections()
    end,

    renderCell    = cell.renderCell,
    getCellHeight = cell.getCellHeight,
    updateCovers  = cell.updateCovers,

    -- A collection has no reading progress to show.
    progress_style = { locked = "none" },

    grid          = true,
    default_rows  = 1,
    default_cols  = MAX_ITEMS,

    extra_menu_items_before = extraMenuItemsBefore,
    extra_menu_items_after  = extraMenuItemsAfter,
}

-- Centered notice while no collection is shown.
local build_grid = mod.build
function mod.build(w, ctx)
    local widget = build_grid(w, ctx)
    if widget then return widget end

    local hold_on = SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = mod.getHeight(ctx) },
        UI.makeColoredText{
            text  = hold_on and _("No collections selected  —  long press to configure")
                             or _("No collections selected"),
            face    = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY),
            fgcolor = (ctx.ink or Chrome.PLAIN_INK).sub,
            width   = w - PAD * 2,
        },
    }
end

-- Visible collections and their replacement as a whole. Whatever is not in the
-- list becomes hidden and the list becomes the manual order.
function mod.getSelected() return getVisibleCollections() end
function mod.saveSelected(list)
    saveManualOrder(list)
    local keep = {}
    for _i, n in ipairs(list) do keep[n] = true end
    local excluded = {}
    for _i, n in ipairs(listAllCollectionNames()) do
        if not keep[n] then excluded[#excluded + 1] = n end
    end
    saveExcludedCollections(excluded)
end

function mod.getCountLabel(_pfx)
    local n = #mod.getSelected()
    if n == 0 then return nil end
    return string.format(N_("(%d collection)", "(%d collections)", n), n)
end

return mod
