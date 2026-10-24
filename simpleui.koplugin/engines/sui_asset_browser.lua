-- engines/sui_asset_browser.lua — Simple UI
-- Generic filesystem browser with optional thumbnail preview, built on top
-- of KOReader's PathChooser widget. Lets the user navigate directories and
-- pick a file matching a set of extensions, with an optional name filter
-- bar and — for image formats — a live thumbnail rendered next to each
-- matching entry.
--
-- This widget is deliberately generic: it knows nothing about icons,
-- wallpapers, or icon packs specifically. Every filesystem-specific detail
-- (starting directory, accepted extensions, title, whether thumbnails make
-- sense at all) is supplied by the caller through the options table. This
-- is Simple UI's single external-file-selection widget: every feature that
-- needs the user to pick a file from outside its own managed directory
-- goes through this, instead of each feature building its own PathChooser
-- wrapper or being stuck with a flat, non-navigable list.
--
-- show_thumbnails defaults to true, but should be set to false by callers
-- picking a non-image file type (e.g. a .zip icon pack) — there is nothing
-- meaningful to preview for those, and skipping the thumbnail column also
-- skips the widget-tree reach-around described below entirely.
--
-- CONSUMERS:
--   features/sui_quickactions.lua — QA.showIconPicker's "Browse…" button,
--     opened with path = QA.getIconsDir(), extensions = SUIStyle's
--     SUPPORTED_ICON_EXTS, show_thumbnails = true (default).
--   screens/sui_menu.lua — the "Select Wallpaper" submenu's "Browse…"
--     entry, extensions = SUIWallpaper.SUPPORTED_WALLPAPER_EXTS,
--     show_thumbnails = true (default).
--   screens/sui_menu.lua — the "Install pack from ZIP" submenu's
--     "Browse…" entry, extensions = {zip=true}, show_thumbnails = false.
--
-- IMPLEMENTATION NOTE — thumbnail injection is not public PathChooser API:
-- PathChooser/Menu do not expose a supported way to render a thumbnail next
-- to a list entry. This widget reaches into the built ListMenuItem's widget
-- tree (_underline_container) to insert an ImageWidget, and into Menu's
-- internal dimension calculation (_recalculateDimen) to reserve column
-- space for it. Both are implementation details of the current KOReader
-- widget tree, not a contract PathChooser guarantees to keep stable across
-- versions. _injectThumbnail() is therefore wrapped in pcall and logs a
-- warning instead of raising when the tree doesn't match what's expected,
-- so a future core change degrades to "no thumbnail" rather than a crash.
-- This whole code path is skipped when show_thumbnails is false, so
-- non-image consumers (icon packs) are entirely unaffected by it.

local BD = require("ui/bidi")
local Device = require("device")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local InputText = require("ui/widget/inputtext")
local Menu = require("ui/widget/menu")
local PathChooser = require("ui/widget/pathchooser")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("infra/sui_i18n").translate
local Screen = Device.screen

local DEFAULT_THUMB_SIZE = Screen:scaleBySize(32)
local DEFAULT_THUMB_GAP = Screen:scaleBySize(6)

-- Builds a lowercase-extension lookup predicate from an {ext=true, ...} set.
local function _makeExtMatcher(extensions)
    return function(filename)
        local ext = filename:lower():match("%.([^.]+)$")
        return ext ~= nil and extensions[ext] == true
    end
end

-- ---------------------------------------------------------------------------
-- Inner PathChooser subclass with thumbnail preview
-- ---------------------------------------------------------------------------
local _InnerChooser = PathChooser:extend{
    select_directory = false,
    select_file = true,
    onConfirm = nil,
    extensions = nil,       -- {ext=true, ...}, required
    show_thumbnails = true, -- set false for non-image extensions (e.g. zip)
    thumb_size = nil,       -- resolved in init() if not supplied
    _filter_text = "",
    _all_items = nil,
    stop_events_propagation = true,
}

function _InnerChooser:init()
    self.title = self.title or _("Choose file")
    self.extensions = self.extensions or {}
    self._matches_ext = _makeExtMatcher(self.extensions)

    self.file_filter = function(filename)
        return self._matches_ext(filename)
    end

    -- The override below also accounts for the filter bar's height, which
    -- is needed regardless of thumbnails — always install it, and only
    -- branch on show_thumbnails for the thumbnail-column sizing itself.
    self._base_thumb_size = self.thumb_size or DEFAULT_THUMB_SIZE
    self.state_w = self.show_thumbnails and (self._base_thumb_size + DEFAULT_THUMB_GAP) or 0
    self._recalculateDimen = _InnerChooser._recalculateDimen
    PathChooser.init(self)
    if not self._all_items then
        self:refreshPath()
    end
end

function _InnerChooser:_recalculateDimen(no_recalculate_dimen)
    Menu._recalculateDimen(self, no_recalculate_dimen)
    if not self.item_dimen then return end

    if self._filter_bar_height and self._filter_bar_height > 0 and not no_recalculate_dimen then
        self.available_height = self.available_height - self._filter_bar_height
        self.item_dimen.h = math.floor(self.available_height / self.perpage)
    end

    if not self.show_thumbnails then
        self.state_w = 0
        return
    end
    local content_w = math.max(0, self.item_dimen.w - 2 * Size.padding.fullscreen)
    local max_state_w = math.max(1, math.floor(content_w / 4))
    local ts = self._base_thumb_size or DEFAULT_THUMB_SIZE
    local tg = DEFAULT_THUMB_GAP
    self.state_w = math.min(ts + tg, max_state_w)
    self._thumb_size = math.max(0, math.min(ts, self.state_w - tg))
end

function _InnerChooser:getCollate()
    return self.collates.strcoll, "strcoll"
end

function _InnerChooser:refreshPath()
    local _unused, folder_name = util.splitFilePathName(self.path)
    Screen:setWindowTitle(folder_name)
    self._all_items = self:genItemTableFromPath(self.path)
    self:_applyCurrentFilter()
end

function _InnerChooser:_applyCurrentFilter()
    local filter_text = self._filter_text or ""
    local items

    if filter_text == "" then
        items = self._all_items
    else
        items = {}
        local pattern = filter_text:lower()
        for _, item in ipairs(self._all_items) do
            if item.is_go_up or (item.text and item.text:lower():find(pattern, 1, true)) then
                table.insert(items, item)
            end
        end
    end

    local itemmatch
    if self.focused_path then
        itemmatch = {path = self.focused_path}
        self.focused_path = nil
    end

    local subtitle = BD.directory(filemanagerutil.abbreviate(self.path))
    self:switchItemTable(nil, items, filter_text == "" and self.path_items[self.path] or 1, itemmatch, subtitle)
end

function _InnerChooser:applyFilter(text)
    self._filter_text = text or ""
    if self._all_items then
        self:_applyCurrentFilter()
    end
end

-- Inserts a thumbnail ImageWidget into a built ListMenuItem's widget tree.
-- See the file-level note on why this is not stable public API and must
-- never raise on an unexpected tree shape.
local function _injectThumbnail(item_widget, filepath, thumb_size, center_y)
    local ok, err = pcall(function()
        local uc = item_widget._underline_container
        if not uc then return end
        local hg = uc[1]
        if not hg then return end
        local og = hg[1]
        if not og then return end

        table.insert(og, 1, ImageWidget:new{
            file = filepath,
            width = thumb_size,
            height = thumb_size,
            alpha = true,
            overlap_offset = { 0, center_y },
        })
        og._size = nil
    end)
    if not ok then
        logger.warn("simpleui/asset_browser: thumbnail injection failed, showing no preview:", err)
    end
end

function _InnerChooser:updateItems(select_number, no_recalculate_dimen)
    Menu.updateItems(self, select_number, no_recalculate_dimen)
    self.path_items[self.path] = (self.page - 1) * self.perpage + (select_number or 1)

    if not self.show_thumbnails then return end
    local eff_thumb = self._thumb_size or 0
    if eff_thumb <= 0 then return end

    local item_h = self.item_dimen and self.item_dimen.h or eff_thumb
    local center_y = math.max(0, math.floor((item_h - eff_thumb) / 2))

    for _, item_widget in ipairs(self.item_group) do
        local entry = item_widget.entry
        local filepath = entry and entry.path
        if filepath and self._matches_ext(filepath) then
            _injectThumbnail(item_widget, filepath, eff_thumb, center_y)
        end
    end
end

-- Tap to select (no confirmation dialog) for matching files.
function _InnerChooser:onMenuSelect(item)
    local path = item.path or ""
    if self._matches_ext(path) then
        local real_path = ffiUtil.realpath(path) or path
        if self.show_parent then
            self.show_parent._confirmed = true
            self.show_parent:onClose()
        else
            UIManager:close(self)
        end
        if self.onConfirm then
            self.onConfirm(real_path)
        end
        return true
    end
    return PathChooser.onMenuSelect(self, item)
end

function _InnerChooser:onMenuHold(item)
    local path = item.path or ""
    if self._matches_ext(path) then
        return true
    end
    return PathChooser.onMenuHold(self, item)
end

-- ---------------------------------------------------------------------------
-- Outer wrapper with filter bar
-- ---------------------------------------------------------------------------
local AssetBrowser = WidgetContainer:extend{
    path = nil,             -- required: starting directory
    extensions = nil,       -- required: {ext=true, ...}, lowercase, no dot
    title = nil,            -- optional dialog title
    show_thumbnails = true, -- set false for non-image extensions (e.g. zip)
    thumb_size = nil,       -- optional thumbnail size override
    onConfirm = nil,        -- required: function(real_path)
    onCancel = nil,         -- optional: function()
    is_always_active = true,
}

function AssetBrowser:init()
    assert(type(self.path) == "string" and self.path ~= "",
        "sui_asset_browser: 'path' is required")
    assert(type(self.extensions) == "table",
        "sui_asset_browser: 'extensions' is required")

    self.dimen = Geom:new{x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight()}

    -- Filter input
    self._filter_input = InputText:new{
        text = "",
        hint = _("Filter by name…"),
        width = self.dimen.w - 4 * Size.padding.default,
        height = nil,
        face = Font:getFace("smallinfofont"),
        padding = Size.padding.small,
        margin = 0,
        bordersize = Size.border.inputtext,
        parent = self,
        scroll = false,
        focused = false,
        edit_callback = function()
            self:_applyFilter()
        end,
    }

    -- Intercept Enter key
    self._filter_input.addChars = function(inp, chars)
        if chars == "\n" then
            inp:onCloseKeyboard()
            return
        end
        InputText.addChars(inp, chars)
    end

    self._filter_bar = FrameContainer:new{
        padding = Size.padding.default,
        padding_top = Size.padding.small,
        padding_bottom = Size.padding.small,
        bordersize = 0,
        self._filter_input,
    }

    local filter_h = self._filter_bar:getSize().h

    self._chooser = _InnerChooser:new{
        show_parent = self,
        path = self.path,
        extensions = self.extensions,
        title = self.title,
        show_thumbnails = self.show_thumbnails,
        thumb_size = self.thumb_size,
        onConfirm = self.onConfirm,
        height = self.dimen.h,
        close_callback = function() self:onClose() end,
    }

    table.insert(self._chooser.content_group, 2, self._filter_bar)
    self._chooser._filter_bar_height = filter_h
    self._chooser:refreshPath()

    self[1] = self._chooser
end

function AssetBrowser:_applyFilter()
    if not self._chooser then return end
    local text = self._filter_input and self._filter_input:getText() or ""
    self._chooser:applyFilter(text)
end

function AssetBrowser:getFocusableWidgetXY()
    return nil, nil
end

function AssetBrowser:moveFocusTo() end

function AssetBrowser:onClose()
    if self._filter_input then
        self._filter_input:onCloseKeyboard()
    end
    UIManager:close(self)
    if self.onCancel and not self._confirmed then
        self.onCancel()
    end
end

return AssetBrowser
