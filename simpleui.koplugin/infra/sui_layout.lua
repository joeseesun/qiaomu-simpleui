-- sui_layout.lua — Simple UI
-- Layout data layer: loads and saves a screen's page layout (pages of module
-- ids), keeps the flat module order and the enabled flags in step with it, and
-- repaints the screen the layout belongs to.
--
--   Layout.load(pfx, layout_key)                         -> layout
--   Layout.save(layout, pfx, layout_key, screen_id, opts)   opts.silent: no repaint
--   Layout.entryId(entry) / Layout.getModuleName(id)
--   Layout.screenFor(pfx)                                -> layout_key, screen_id | nil
--   Layout.findPage(layout, id)                          -> page, page_index
--   Layout.setSpan(layout, pfx, id, span)                -> changed ids
--   Layout.move(layout, pfx, id, dir)                    -> changed ids
--   Layout.pageSpans(page, pfx)                          -> ids, spans
--   Layout.pageRows(page, pfx)                           -> bento rows, spans

local Registry    = require("modules/moduleregistry")
local SUISettings = require("infra/sui_store")
local Bento       = require("infra/sui_bento")

local LayoutService = {}

-- Normalize layout module entries to plain ids. Legacy { id, width } tables
-- (brief experimental schema) migrate width into Config bento settings and
-- collapse back to a string id so the layout stays a pure order list.
function LayoutService.entryId(entry)
    if type(entry) == "table" then return entry.id end
    return entry
end

local function _normalizeLayoutModules(layout, pfx)
    if type(layout) ~= "table" or type(layout.pages) ~= "table" then return layout end
    local Config = require("infra/sui_config")
    local changed = false
    for _, page in ipairs(layout.pages) do
        if type(page.modules) == "table" then
            local out = {}
            for _, entry in ipairs(page.modules) do
                if type(entry) == "table" and entry.id then
                    if type(entry.width) == "number" then
                        Config.setBentoWidth(entry.width, entry.id, pfx)
                    end
                    out[#out + 1] = entry.id
                    changed = true
                else
                    out[#out + 1] = entry
                end
            end
            page.modules = out
        end
    end
    return layout, changed
end


local _DEFAULT_PFX        = "simpleui_hs_"
local _DEFAULT_LAYOUT_KEY = "simpleui_layout"

-- Module membership of each layout as of its last load/save, keyed by layout
-- key. The editor mutates the stored layout table in place, so membership
-- changes can only be detected against this independent snapshot.
local _committed_sets = {}

-- Returns the set of module ids placed in a layout.
local function _activeSet(layout)
    local set = {}
    for _, page in ipairs(layout.pages) do
        for _, entry in ipairs(page.modules) do
            local mod_id = LayoutService.entryId(entry)
            if mod_id then set[mod_id] = true end
        end
    end
    return set
end

function LayoutService.load(pfx, layout_key)
    pfx        = pfx or _DEFAULT_PFX
    layout_key = layout_key or _DEFAULT_LAYOUT_KEY

    local saved = SUISettings:readSetting(layout_key)
    if type(saved) == "table" and saved.pages then
        local _, changed = _normalizeLayoutModules(saved, pfx)
        if changed then SUISettings:saveSetting(layout_key, saved) end
        _committed_sets[layout_key] = _activeSet(saved)
        return saved
    end

    local order          = Registry.loadOrder(pfx)
    local pages          = {}
    local cur_page       = { id = 1, modules = {} }

    for _, mod_id in ipairs(order) do
        if mod_id == "__page_break__" then
            table.insert(pages, cur_page)
            cur_page = { id = #pages + 1, modules = {} }
        else
            local mod = Registry.get(mod_id)
            if mod and Registry.isEnabled(mod, pfx) then
                table.insert(cur_page.modules, mod_id)
            end
        end
    end

    table.insert(pages, cur_page)

    local layout = { pages = pages }
    _committed_sets[layout_key] = _activeSet(layout)
    return layout
end

function LayoutService.save(layout, pfx, layout_key, screen_id, opts)
    pfx        = pfx or _DEFAULT_PFX
    layout_key = layout_key or _DEFAULT_LAYOUT_KEY
    screen_id  = screen_id or "hs"

    SUISettings:saveSetting(layout_key, layout)

    local active_set = _activeSet(layout)
    -- Membership before this save, used to apply enable/disable only to the
    -- modules that were actually added to or removed from the layout.
    local previous_set = _committed_sets[layout_key] or active_set
    _committed_sets[layout_key] = active_set
    local flat_order = {}

    for _, page in ipairs(layout.pages) do
        for _, entry in ipairs(page.modules) do
            local mod_id = LayoutService.entryId(entry)
            if mod_id then table.insert(flat_order, mod_id) end
        end
    end

    for _, mod in ipairs(Registry.list()) do
        if not active_set[mod.id] then
            table.insert(flat_order, mod.id)
        end
    end

    SUISettings:saveSetting(pfx .. "module_order", flat_order)

    for _, mod in ipairs(Registry.list()) do
        local is_active = (active_set[mod.id] == true)
        -- Modules that stay in (or out of) the layout keep their own settings,
        -- including per-item visibility.
        if is_active ~= (previous_set[mod.id] == true) then
            -- A module taken out of the layout drops its text styles, so adding
            -- it back later starts from the defaults.
            if not is_active and mod.text_elems then
                require("infra/sui_config").resetTextStyles(mod.id, mod.text_elems, pfx)
            end
            if type(mod.setEnabled) == "function" then
                mod.setEnabled(pfx, is_active)
            elseif mod.enabled_key then
                SUISettings:saveSetting(pfx .. mod.enabled_key, is_active)
            end
        end
    end

    if opts and opts.silent then return end

    -- Repaint whichever screen this layout belongs to, if it's currently
    -- open. The built-in Homescreen keeps going through the flat HS.refresh
    -- (unchanged codepath); any other screen_id uses the generic, id-aware
    -- refreshScreen — see engines/sui_screen_engine.lua.
    local HS = package.loaded["screens/sui_homescreen"]
    if HS then
        if screen_id == "hs" then
            if HS._instance then
                pcall(function() HS.refresh(false) end)
            end
        elseif HS.refreshScreen then
            pcall(function() HS.refreshScreen(screen_id, false) end)
        end
    end
end

function LayoutService.getModuleName(mod_id)
    local mod = Registry.get(mod_id)
    local mod_name = mod and mod.name or mod_id
    -- Instances are numbered by creation order once there is more than one.
    local idx, count = Registry.getInstanceIndex(mod_id)
    if idx and count > 1 then
        return mod_name .. " " .. idx
    end
    return mod_name
end

-- Layout setting key and id of the screen that owns the settings prefix, or nil.
function LayoutService.screenFor(pfx)
    if pfx == _DEFAULT_PFX then return _DEFAULT_LAYOUT_KEY, "hs" end
    for _i, screen in ipairs(require("infra/sui_custom_screens").list()) do
        if screen.pfx == pfx then return screen.layout_key, screen.id end
    end
end

-- Page holding the module and its index in layout.pages.
function LayoutService.findPage(layout, mod_id)
    for idx, page in ipairs(layout.pages) do
        for _, entry in ipairs(page.modules) do
            if LayoutService.entryId(entry) == mod_id then return page, idx end
        end
    end
end

-- Takes the module out of its page, destroying it when it is a dynamic
-- instance. The caller saves the layout. Returns whether it was placed.
function LayoutService.remove(layout, pfx, mod_id)
    local page = LayoutService.findPage(layout, mod_id)
    if not page then return false end
    for i, entry in ipairs(page.modules) do
        if LayoutService.entryId(entry) == mod_id then
            table.remove(page.modules, i)
            break
        end
    end
    if Registry.isInstance(mod_id) then
        Registry.purgeInstanceSettings(mod_id, pfx)
        Registry.destroyInstance(mod_id)
    end
    return true
end

-- Ordered ids of a page and the span of each module.
function LayoutService.pageSpans(page, pfx)
    local Config = require("infra/sui_config")
    local ids, spans = {}, {}
    for _, entry in ipairs(page.modules) do
        local id = LayoutService.entryId(entry)
        if id then
            ids[#ids + 1] = id
            spans[id] = Config.getBentoSpan(id, pfx)
        end
    end
    return ids, spans
end

-- Bento rows of a page, as rendered: { { ids = {...}, sum = n }, ... }, and
-- the span of each module.
function LayoutService.pageRows(page, pfx)
    local ids, spans = LayoutService.pageSpans(page, pfx)
    return Bento.pack(ids, spans), spans
end

-- Gives a module a width; unless the screen has auto-adjust off, the
-- neighbour of its row adjusts to fill it. A module that is on no page just
-- stores its width.
-- Updates the stored spans only: the caller saves the layout.
function LayoutService.setSpan(layout, pfx, mod_id, span)
    local Config = require("infra/sui_config")
    local page = LayoutService.findPage(layout, mod_id)
    if not page then
        Config.setBentoSpan(span, mod_id, pfx)
        return { mod_id }
    end
    local ids, spans = LayoutService.pageSpans(page, pfx)
    local new_spans, changed = Bento.setSpan(ids, spans, mod_id, span, Config.isBentoAutofit(pfx))
    for _, id in ipairs(changed) do
        Config.setBentoSpan(new_spans[id], id, pfx)
    end
    return changed
end

-- Moves a module one step (left, right, up or down) inside its page.
-- Updates the page order and the stored spans: the caller saves the layout.
function LayoutService.move(layout, pfx, mod_id, dir)
    local page = LayoutService.findPage(layout, mod_id)
    if not page then return {} end
    local Config = require("infra/sui_config")
    local ids, spans = LayoutService.pageSpans(page, pfx)
    local new_ids, new_spans, changed = Bento.move(ids, spans, mod_id, dir)
    page.modules = new_ids
    for _, id in ipairs(changed) do
        Config.setBentoSpan(new_spans[id], id, pfx)
    end
    return changed
end

return LayoutService
