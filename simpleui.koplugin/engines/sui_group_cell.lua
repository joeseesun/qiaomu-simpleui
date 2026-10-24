-- sui_group_cell.lua — Simple UI
-- Grid cell of a group of books: a representative cover (single, or a 2x2
-- mosaic), an optional stack of book edges behind it, a count badge and the
-- group name underneath. Used by every grid whose unit is a group rather than
-- a book (collections, authors, series, tags).
--
-- A cell presenter is bound to the module that owns the grid, so that scale and
-- text styles come from that module:
--
--   local cell = GroupCell.new{
--       owner_id = "collections",
--       settings = GroupCell.makeSettings{ ... },
--       describe = function(item, ctx) return group end,
--   }
--   cell.renderCell(item, cw, cell_h, ctx)  -> widget, cover_slots
--   cell.getCellHeight(cw, pfx)             -> height
--   cell.updateCovers(widget, ctx)          -> all_done
--   cell.hasTextBelow(pfx)                  -> true when the name is under the cover
--
-- The first three are the cell hooks of GridRenderer (see sui_book_grid.lua);
-- the last tells a host module whether the cells end in a line of text.
--
-- The group name is shown under the cover or inside it, as the name label of
-- the library folder covers (see features/library/sui_label_options.lua).
-- Its options are shared by every group of the grid.
--
-- Group description, returned by `describe(item, ctx)`:
--   name           string      text under the cover
--   paths          { fp, ... } books the cover is made of, in order
--   count          number      value of the count badge
--   cover_key      string?     CoverOverrides key; enables choosing the cover
--   open           function    () called on tap
--   books          function?   () -> { { path, title? }, ... } every book of the
--                              group, offered by the cover picker
--   set_cover_text string?     label of the cover picker action
--   extra_actions  function?   () -> { { text, sui_icon?, callback }, ... } rows
--                              added to the long-press sheet, drawn with a chevron.
--                              The sheet stays open when a row is tapped and is
--                              passed to `callback`, which shows a page on it or
--                              closes it.
--
-- Public API
-- ----------
--   GroupCell.QUAD_SLOTS, GroupCell.QUAD_MIN_BOOKS
--   GroupCell.resolveStyle(style, count)  -- "auto" -> "single" | "quad"
--   GroupCell.makeSettings(opts)          -> settings (see below)
--   GroupCell.makeMenuItems(ctx_menu, settings) -> { item, ... }
--   GroupCell.new(opts)                   -> cell presenter
--   GroupCell.updateCovers(widget, ctx)

local Font            = require("ui/font")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = require("device").screen
local lfs             = require("libs/libkoreader-lfs")
local Text            = require("infra/sui_text")
local _               = require("infra/sui_i18n").translate

local Config         = require("infra/sui_config")
local SUISettings    = require("infra/sui_store")
local UI             = require("infra/sui_core")
local Chrome         = require("features/sui_module_chrome")
local SUIStyle       = require("features/sui_style")
local CoverOverrides = require("features/library/sui_cover_overrides")
local CoverWidgets   = require("features/library/sui_cover_widgets")
local GroupActions   = require("features/library/sui_group_actions")
local LabelOptions   = require("features/library/sui_label_options")

local GroupCell = {}

-- Cover styles.
local STYLE_SINGLE, STYLE_QUAD, STYLE_AUTO = "single", "quad", "auto"

-- Covers of the 2x2 mosaic.
GroupCell.QUAD_SLOTS = 4
local QUAD_SLOTS = GroupCell.QUAD_SLOTS

-- Books from which "auto" shows the mosaic: enough to fill it.
GroupCell.QUAD_MIN_BOOKS = QUAD_SLOTS

-- Where the group name goes: under the cover or inside it.
local PLACE_BELOW, PLACE_INSIDE = "below", "inside"
local PLACES = { PLACE_BELOW, PLACE_INSIDE }

-- Scope of the name label options of a grid with a single kind of group.
local LABEL_ENTRY = "default"

-- The count badge is drawn 20% larger than the shared corner badges.
local COUNT_BADGE_BOOST = 1.2

-- Aspect ratio of a single cover. It is the ratio of every other single book
-- cover, so a cover is stretched once and shared through the cover cache.
local COVER_ASPECT = 3 / 2

local BASE_LABEL_GAP      = Screen:scaleBySize(4)
local BASE_BADGE_SZ       = Screen:scaleBySize(16)
local BASE_BADGE_MARGIN_T = Screen:scaleBySize(8)
local BASE_PLACEHOLDER_FS = SUIStyle.FS_TITLE
local BASE_LABEL_FS       = SUIStyle.FS_DETAIL
local BASE_BADGE_FS       = 8

-- Placeholder text length, in characters.
local INITIALS_LENGTH = 2

-- ---------------------------------------------------------------------------
-- Style
-- ---------------------------------------------------------------------------

-- Effective cover style of a group of `count` books. Only "auto" depends on
-- the count.
function GroupCell.resolveStyle(style, count)
    if style ~= STYLE_AUTO then return style end
    return (count or 0) >= GroupCell.QUAD_MIN_BOOKS and STYLE_QUAD or STYLE_SINGLE
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local function shallowCopy(t)
    local copy = {}
    for key, value in pairs(t or {}) do copy[key] = value end
    return copy
end

-- Presentation settings of a group grid, stored under the keys `opts.keyFor`
-- gives. Every accessor takes the settings prefix of the screen.
--   opts.keyFor(pfx, field) -> settings key, for the fields cover_style,
--                              hide_pile, badge_position, badge_color,
--                              badge_hidden, badge_scale and label
--   opts.default_style      cover style until one is chosen
function GroupCell.makeSettings(opts)
    local keyFor = opts.keyFor
    local s = {}

    local function read(pfx, field, default)
        local value = SUISettings:readSetting(keyFor(pfx, field))
        if value == nil then return default end
        return value
    end
    local function write(pfx, field, value)
        SUISettings:saveSetting(keyFor(pfx, field), value)
    end

    function s.coverStyle(pfx)
        local style = read(pfx, "cover_style", opts.default_style or STYLE_SINGLE)
        -- Former id of the single cover style.
        if style == "stack" then return STYLE_SINGLE end
        return style
    end
    function s.setCoverStyle(pfx, v) write(pfx, "cover_style", v) end

    -- The stack behind the cover is independent of the cover style, so every
    -- cell of a grid has it or none does.
    function s.hidePile(pfx) return read(pfx, "hide_pile", false) end
    function s.setHidePile(pfx, v) write(pfx, "hide_pile", v) end

    function s.badgeHidden(pfx) return read(pfx, "badge_hidden", false) end
    function s.setBadgeHidden(pfx, v) write(pfx, "badge_hidden", v) end

    function s.badgePosition(pfx) return read(pfx, "badge_position", "top") end
    function s.setBadgePosition(pfx, v) write(pfx, "badge_position", v) end

    -- "dark": black background and white text; "light": the opposite;
    -- "accent" (default) / "secondary": the palette colour (see SUIStyle.badgeColors).
    function s.badgeColor(pfx) return SUIStyle.badgeChoice(read(pfx, "badge_color", "accent"), "accent") end
    function s.setBadgeColor(pfx, v) write(pfx, "badge_color", v) end

    function s.badgeScalePct(pfx) return Config.getScalePctByKey(keyFor(pfx, "badge_scale")) end
    function s.setBadgeScalePct(pfx, pct) Config.setScaleByKey(pct, keyFor(pfx, "badge_scale")) end
    function s.badgeScale(pfx) return s.badgeScalePct(pfx) / 100 * COUNT_BADGE_BOOST end

    -- Options of the name label, stored under one key as
    -- { [LABEL_ENTRY] = { place = ..., layout = ..., ... } }. The stored
    -- tables are shared with the settings, so a change writes copies.
    local function labelStore(pfx)
        local stored = SUISettings:readSetting(keyFor(pfx, "label"))
        return type(stored) == "table" and stored or {}
    end

    -- Options of the name label with the defaults filled in: `place` and the
    -- fields of LabelOptions, which apply while the name is inside the cover.
    function s.label(pfx)
        local stored = labelStore(pfx)[LABEL_ENTRY] or {}
        local label  = LabelOptions.resolve(stored)
        label.place  = Config.resolveChoice(stored.place, PLACES, PLACE_BELOW)
        return label
    end

    function s.setLabelField(pfx, field, value)
        local store  = shallowCopy(labelStore(pfx))
        local fields = shallowCopy(store[LABEL_ENTRY])
        fields[field] = value
        store[LABEL_ENTRY] = fields
        SUISettings:saveSetting(keyFor(pfx, "label"), store)
    end

    return s
end

-- ---------------------------------------------------------------------------
-- Settings menu
-- ---------------------------------------------------------------------------

-- Name label entries: where the name goes and, while it is inside the cover,
-- how it looks. The font and size of the name come from the text style of the
-- owner module.
local function makeLabelItems(ctx_menu, settings)
    local _lc     = ctx_menu._
    local refresh = ctx_menu.refresh
    local pfx     = ctx_menu.pfx

    local function label() return settings.label(pfx) end
    local function inside() return label().place == PLACE_INSIDE end

    local items = {
        Config.makeRadioSubmenuItem{
            text      = _lc("Placement"),
            separator = true,
            options   = {
                { value = PLACE_BELOW,  label = _lc("Below Cover") },
                { value = PLACE_INSIDE, label = _lc("Inside Cover") },
            },
            get       = function() return label().place end,
            set       = function(value) settings.setLabelField(pfx, "place", value) end,
            refresh   = refresh,
        },
    }
    for _i, item in ipairs(LabelOptions.makeMenuItems{
        get          = function(field) return label()[field] end,
        set          = function(field, value) settings.setLabelField(pfx, field, value) end,
        refresh      = refresh,
        enabled_func = inside,
        _lc          = _lc,
    }) do
        items[#items + 1] = item
    end
    return items
end

-- Cover Style, Hide Book Stack, Badge and Label entries of a group grid.
function GroupCell.makeMenuItems(ctx_menu, settings)
    local _lc     = ctx_menu._
    local refresh = ctx_menu.refresh
    local pfx     = ctx_menu.pfx
    local items   = {}

    items[#items + 1] = Config.makeRadioSubmenuItem{
        text    = _lc("Cover Style"),
        options = {
            { value = STYLE_SINGLE, label = _lc("Single Cover") },
            { value = STYLE_QUAD,   label = _lc("4-Cover Grid") },
            { value = STYLE_AUTO,   label = _lc("Auto (Single ↔ 4-Cover Grid)") },
        },
        get     = function() return settings.coverStyle(pfx) end,
        set     = function(v) settings.setCoverStyle(pfx, v) end,
        refresh = refresh,
    }

    items[#items + 1] = {
        text           = _lc("Hide Book Stack"),
        separator      = true,
        checked_func   = function() return settings.hidePile(pfx) end,
        keep_menu_open = true,
        callback       = function()
            settings.setHidePile(pfx, not settings.hidePile(pfx))
            refresh()
        end,
    }

    local function badgeShown() return not settings.badgeHidden(pfx) end

    local badge_items = {
        {
            text           = _lc("Hidden"),
            checked_func   = function() return settings.badgeHidden(pfx) end,
            keep_menu_open = true,
            separator      = true,
            callback       = function()
                settings.setBadgeHidden(pfx, not settings.badgeHidden(pfx))
                refresh()
            end,
        },
    }
    Config.appendRadioItems(badge_items, {
        options = {
            { value = "top",    label = _lc("Top"),    enabled_func = badgeShown },
            { value = "bottom", label = _lc("Bottom"), enabled_func = badgeShown, separator = true },
        },
        get     = function() return badgeShown() and settings.badgePosition(pfx) or nil end,
        set     = function(v) settings.setBadgePosition(pfx, v) end,
        refresh = refresh,
    })
    Config.appendRadioItems(badge_items, {
        options = SUIStyle.badgeColorOptions(_lc),
        get     = function() return SUIStyle.badgeChoiceShown(settings.badgeColor(pfx)) end,
        set     = function(v) settings.setBadgeColor(pfx, v) end,
        refresh = refresh,
    })
    badge_items[#badge_items + 1] = Config.makeBadgeSizeItem{
        separator    = true,
        enabled_func = badgeShown,
        info         = _lc("Scale for the group count badge."),
        get          = function() return settings.badgeScalePct(pfx) end,
        set          = function(pct) settings.setBadgeScalePct(pfx, pct) end,
        refresh      = refresh,
        _lc          = _lc,
    }
    items[#items + 1] = { text = _lc("Badge"), sub_item_table = badge_items }
    items[#items + 1] = {
        text                = _lc("Label"),
        sub_item_table_func = function() return makeLabelItems(ctx_menu, settings) end,
    }

    return items
end

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

-- Cell geometry for a column `cw` wide. `backing` is the room the cover gives
-- up to what is drawn behind it (see CoverWidgets.backingInset), so the cover
-- and its backing always add up to `cw`. The backing does not depend on the
-- cover style, which keeps every cell of a grid the same height whatever
-- style it resolves to.
local function getDims(scale, thumb_scale, label_style, cw, hide_pile, badge_scale)
    local cs = scale * thumb_scale
    local badge_sz       = math.max(6, math.floor(BASE_BADGE_SZ * cs * badge_scale))
    local badge_margin_t = math.max(1, math.floor(BASE_BADGE_MARGIN_T * cs))
    local label_gap      = math.max(1, math.floor(BASE_LABEL_GAP * scale))
    local label_fs       = math.max(6, math.floor(BASE_LABEL_FS * scale * (label_style.scale or 1)))
    local label_h        = SUIStyle.faceHeight((SUIStyle.getTextFace(label_style, label_fs)))

    local backing = CoverWidgets.backingInset(SUIStyle.SHADOW_MODULES, hide_pile, cs)
    local border  = SUIStyle.BADGE_BORDER_SZ
    local cover_w = math.max(1, cw - backing.left - backing.right)
    local cover_h = math.max(1, math.floor(cover_w * COVER_ASPECT))

    return {
        cover_w        = cover_w,
        cover_h        = cover_h,
        -- The image or mosaic inside the border.
        img_w          = math.max(1, cover_w - 2 * border),
        img_h          = math.max(1, cover_h - 2 * border),
        border         = border,
        label_h        = label_h,
        label_gap      = label_gap,
        label_fs       = label_fs,
        badge_sz       = badge_sz,
        badge_fs       = math.floor(badge_sz * (BASE_BADGE_FS / BASE_BADGE_SZ)),
        -- 8% of the cover's shorter side, like the other corner badges.
        badge_margin   = math.max(1, math.floor(math.min(cover_w, cover_h) * 0.08)),
        badge_margin_t = badge_margin_t,
        backing        = backing,
        cell_w         = cover_w + backing.left + backing.right,
        cell_h         = cover_h + backing.bottom,
        full_h         = cover_h + backing.bottom + label_gap + label_h,
        placeholder_fs = math.max(7, math.floor(BASE_PLACEHOLDER_FS * cs)),
    }
end

-- Height of a whole cell: the name below the cover adds to it, the name
-- inside the cover does not.
local function fullHeight(d, label)
    return label.place == PLACE_INSIDE and d.cell_h or d.full_h
end

-- Scales of the owner module (module and cover) and its text style of the
-- group name.
local function ownerScales(owner_id, pfx, landscape_factor)
    local styles = Config.resolveTextStyles({ pfx = pfx }, owner_id, { "label" })
    return Config.getModuleScale(owner_id, pfx) * landscape_factor,
           Config.getThumbScale(owner_id, pfx) * landscape_factor,
           styles.label
end

local function currentLandscapeFactor()
    return UI.isLandscape() and UI.getLandscapeFactor() or 1
end

-- ---------------------------------------------------------------------------
-- Cover and count badge
-- ---------------------------------------------------------------------------

-- Cover of one book stretched to w x h, or nil while it is unavailable.
local function singleCoverImage(fp, w, h)
    local bb = Config.getStretchedCoverBB(fp, w, h)
    if not bb then return nil end
    local ok, img = pcall(ImageWidget.new, ImageWidget, {
        image            = bb,
        image_disposable = false,  -- owned by the cover cache
        width            = w,
        height           = h,
    })
    return ok and img or nil
end

local function framed(content, d)
    return FrameContainer:new{
        bordersize = d.border, color = SUIStyle.COLOR.text_primary,
        padding    = 0, margin = 0,
        content,
    }
end

-- First characters of a name, whole UTF-8 characters.
local function initialsOf(name)
    return Text.cut(name or "", INITIALS_LENGTH):upper()
end

-- The name label laid over the cover, or nil while the name is under it.
local function buildInnerLabel(group, d, label, scale, text_style)
    if label.place ~= PLACE_INSIDE then return nil end
    local widget = CoverWidgets.buildLabel({ text = group.name }, { w = d.img_w, h = d.img_h },
        d.border, LabelOptions.makeDisplay(label, scale * (text_style.scale or 1), text_style))
    if widget then widget.overlap_offset[1] = d.backing.left end
    return widget
end

-- The cover (or mosaic) `content` with the stack of book edges behind it, the
-- name label `label` (optional) and the count badge over it, `cell_w` x
-- `cell_h`.
local function wrapBackingAndBadge(content, count, d, settings, pfx, label)
    local group = OverlapGroup:new{ dimen = Geom:new{ w = d.cell_w, h = d.cell_h } }
    local behind = CoverWidgets.buildBacking(d.cover_w, d.cover_h, d.backing)
    if behind then group[#group + 1] = behind end
    content.overlap_offset = { d.backing.left, 0 }
    group[#group + 1] = content
    if label then group[#group + 1] = label end

    if settings.badgeHidden(pfx) then return group end

    local bg_color, fg_color = SUIStyle.badgeColors(settings.badgeColor(pfx))

    local badge_text = UI.makeColoredText{
        text    = tostring(math.min(count, 99)),
        face    = Font:getFace(SUIStyle.FACE_REGULAR, d.badge_fs),
        fgcolor = fg_color,
        bold    = true,
    }
    -- Optical centring of the digits.
    local paint_text = badge_text.paintTo
    badge_text.paintTo = function(self, bb, x, y) paint_text(self, bb, x, y + 1) end

    local badge = FrameContainer:new{
        bordersize = SUIStyle.BADGE_BORDER_SZ,
        color      = SUIStyle.BADGE_BORDER_CLR,
        background = bg_color,
        radius     = math.floor(d.badge_sz / 2),
        padding    = 0,
        dimen      = Geom:new{ w = d.badge_sz, h = d.badge_sz },
        CenterContainer:new{
            dimen = Geom:new{ w = d.badge_sz, h = d.badge_sz },
            badge_text,
        },
    }
    local at_bottom = settings.badgePosition(pfx) == "bottom"
    badge.overlap_offset = {
        d.backing.left + d.cover_w - d.badge_sz - d.badge_margin,
        at_bottom and (d.cover_h - d.badge_sz - d.badge_margin_t) or d.badge_margin_t,
    }
    group[#group + 1] = badge
    return group
end

-- Single cover: the chosen book, else the first one. Returns the widget and
-- the cover slots updateCovers fills in once the cover is ready.
local function buildSingleCell(group, d, settings, pfx, label)
    local front_fp = group.cover_key and CoverOverrides.get(group.cover_key, true) or nil
    front_fp = front_fp or group.paths[1]
    local is_file = front_fp ~= nil and lfs.attributes(front_fp, "mode") == "file"

    local cover
    local image = is_file and singleCoverImage(front_fp, d.img_w, d.img_h)
    if image then
        cover = framed(image, d)
    else
        cover = FrameContainer:new{
            bordersize = d.border, color = SUIStyle.COLOR.text_primary,
            background = SUIStyle.COLOR.gray_strong, padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = d.img_w, h = d.img_h },
                TextWidget:new{
                    text = initialsOf(group.name),
                    face = Font:getFace(SUIStyle.FACE_REGULAR, d.placeholder_fs),
                },
            },
        }
    end

    -- Single-slot container: updateCovers swaps the loaded cover in.
    local content = HorizontalGroup:new{ align = "top", cover }
    local slots = is_file and {
        { kind = "single", container = content, idx = 1, fp = front_fp, w = d.img_w, h = d.img_h },
    } or nil
    return wrapBackingAndBadge(content, group.count, d, settings, pfx, label), slots
end

-- 2x2 mosaic of the first covers of the group.
local function buildQuadCell(group, d, settings, pfx, label)
    local half_w, half_h, half_w2, half_h2 = CoverWidgets.computeQuadCellSizes(d.img_w, d.img_h)
    local sizes = { { half_w, half_h }, { half_w2, half_h }, { half_w, half_h2 }, { half_w2, half_h2 } }

    local img_list = {}
    for i = 1, QUAD_SLOTS do
        local fp = group.paths[i]
        local bb = fp and Config.getCroppedCoverBB(fp, sizes[i][1], sizes[i][2])
        if bb then img_list[i] = { data = bb } end
    end
    local grid, cells = CoverWidgets.buildQuadGrid(img_list, d.img_w, d.img_h, d.border)

    -- Only the quadrants still being extracted need a slot.
    local slots = {}
    for i = 1, QUAD_SLOTS do
        local fp = group.paths[i]
        if fp and not img_list[i] then
            slots[#slots + 1] = {
                kind = "quad", container = cells[i], idx = 1,
                fp = fp, w = sizes[i][1], h = sizes[i][2],
            }
        end
    end
    return wrapBackingAndBadge(grid, group.count, d, settings, pfx, label), #slots > 0 and slots or nil
end

-- Fills in the covers that were not ready when the cells were built. Single
-- covers are stretched to a fixed ratio, mosaic quadrants are cropped to fill.
function GroupCell.updateCovers(widget, _ctx)
    if not widget or not widget._cover_slots then return true end
    local all_done = true
    for _i, slot in ipairs(widget._cover_slots) do
        local is_quad = slot.kind == "quad"
        local bb = is_quad and Config.getCroppedCoverBB(slot.fp, slot.w, slot.h)
            or Config.getStretchedCoverBB(slot.fp, slot.w, slot.h)
        if bb then
            local ok, img = pcall(ImageWidget.new, ImageWidget, {
                image            = bb,
                image_disposable = false,
                width            = slot.w,
                height           = slot.h,
            })
            if ok and img then
                slot.container[slot.idx] = is_quad and img or FrameContainer:new{
                    bordersize = SUIStyle.BADGE_BORDER_SZ, color = SUIStyle.COLOR.text_primary,
                    padding    = 0, margin = 0,
                    img,
                }
            end
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end

-- ---------------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------------

-- Long-press sheet of a group: choose its cover (single style only), the
-- actions of the group and the settings of the owner module.
local function showGroupDialog(group, style, owner_id, ctx)
    local ActionSheet = require("engines/sui_action_sheet")

    local sheet
    local items = {}
    if style == STYLE_SINGLE and group.cover_key and group.books then
        items[#items + 1] = {
            text      = group.set_cover_text or _("Set cover"),
            sui_icon  = "cover",
            keep_open = true,
            chevron   = true,
            callback  = function()
                GroupActions.openCoverPicker{
                    parent        = sheet,
                    title         = string.format(_("Cover for \"%s\""), group.name),
                    override_key  = group.cover_key,
                    items         = group.books(),
                    on_change     = ctx.refresh_fn,
                    empty_message = _("No books found."),
                }
            end,
        }
    end
    for _i, action in ipairs(group.extra_actions and group.extra_actions() or {}) do
        items[#items + 1] = {
            text      = action.text,
            sui_icon  = action.sui_icon,
            keep_open = true,
            chevron   = true,
            callback  = function() action.callback(sheet) end,
        }
    end
    items[#items + 1] = {
        text     = _("Open Module Settings"),
        sui_icon = "settings",
        callback = function()
            if ctx.open_settings_fn then ctx.open_settings_fn(owner_id) end
        end,
    }

    sheet = ActionSheet.show{
        name       = "sui_win_group_actions",
        title      = group.name,
        icon       = "folder",
        flow       = true,
        auto_close = true,
        sections   = { ActionSheet.list(items) },
    }
end

-- Wraps `content` in a widget reacting to tap and, when the owner module
-- opens a dialog on long press, to hold. The tap event id is one of the
-- gestures the navigation bar overrides. With ctx.kbStops it is also a D-pad
-- focus stop.
local function makeTappable(content, group, style, owner_id, ctx, cell_w, cell_h)
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = cell_w, h = cell_h },
        [1]   = content,
    }
    local function range() return tappable.dimen end

    tappable.ges_events = { TapColl = { GestureRange:new{ ges = "tap", range = range } } }
    function tappable:onTapColl()
        group.open()
        return true
    end
    if ctx.kbStops then UI.makeFocusable(tappable, tappable.onTapColl) end

    if Config.getCoverHoldMode(owner_id, ctx.pfx) == "book_dialog" then
        tappable.ges_events.HoldColl = { GestureRange:new{ ges = "hold", range = range } }
        tappable.ges_events.HoldCollRelease = { GestureRange:new{ ges = "hold_release", range = range } }
        function tappable:onHoldColl() return true end
        function tappable:onHoldCollRelease()
            showGroupDialog(group, style, owner_id, ctx)
            return true
        end
    end
    return tappable
end

-- ---------------------------------------------------------------------------
-- Cell presenter
-- ---------------------------------------------------------------------------

function GroupCell.new(opts)
    local owner_id, settings, describe = opts.owner_id, opts.settings, opts.describe

    local cell = { updateCovers = GroupCell.updateCovers }

    -- Height of a cell for a column `cw` wide. Must match renderCell: it
    -- does not depend on the cover style, only on settings shared by
    -- every cell of the grid.
    function cell.getCellHeight(cw, pfx)
        local scale, thumb_scale, label_style = ownerScales(owner_id, pfx, currentLandscapeFactor())
        local d = getDims(scale, thumb_scale, label_style, cw, settings.hidePile(pfx), 1)
        return fullHeight(d, settings.label(pfx))
    end

    function cell.hasTextBelow(pfx)
        return settings.label(pfx).place ~= PLACE_INSIDE
    end

    function cell.renderCell(item, cw, cell_h, ctx)
        local pfx   = ctx.pfx
        local group = describe(item, ctx)
        local scale, thumb_scale, label_style =
            ownerScales(owner_id, pfx, ctx.landscape_factor or 1)
        local d = getDims(scale, thumb_scale, label_style, cw,
            settings.hidePile(pfx), settings.badgeScale(pfx))

        local name_label = settings.label(pfx)
        local inner      = buildInnerLabel(group, d, name_label, scale, label_style)
        local style      = GroupCell.resolveStyle(settings.coverStyle(pfx), group.count)
        local cover, slots
        if style == STYLE_QUAD then
            cover, slots = buildQuadCell(group, d, settings, pfx, inner)
        else
            cover, slots = buildSingleCell(group, d, settings, pfx, inner)
        end

        local content = cover
        if name_label.place ~= PLACE_INSIDE then
            local label_face, label_bold = SUIStyle.getTextFace(label_style, d.label_fs)
            local label = UI.makeColoredText{
                text                   = group.name,
                face                   = label_face,
                bold                   = label_bold,
                fgcolor                = (ctx.ink or Chrome.PLAIN_INK).sub,
                max_width              = d.cover_w,
                truncate_with_ellipsis = true,
                alignment              = "center",
            }
            -- Centred under the cover, not under the cell, which also
            -- holds the backing.
            local label_row = HorizontalGroup:new{
                HorizontalSpan:new{ width = d.backing.left },
                label,
                HorizontalSpan:new{ width = d.backing.right },
            }
            content = VerticalGroup:new{
                align = "center",
                cover,
                VerticalSpan:new{ width = d.label_gap },
                label_row,
            }
        end
        return makeTappable(content, group, style, owner_id, ctx, d.cell_w, cell_h), slots
    end

    return cell
end

return GroupCell
