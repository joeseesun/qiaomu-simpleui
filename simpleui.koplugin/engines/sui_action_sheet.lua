-- sui_action_sheet.lua — Simple UI
-- Modal sheet of actions built on SUIWindow: a header with a centred title,
-- an optional icon and a separator below it, followed by sections of actions.
--
--   ActionSheet.show{
--       name     = "sui_win_example",   -- window name (optional)
--       title    = "Title",
--       icon     = "book_open",         -- SUIStyle.icon key (optional)
--       message  = "Longer text",       -- wrapped text below the separator (optional);
--                                       -- without a title it is the sheet's content and
--                                       -- is drawn as body text
--       message_end = function(ctx) return widget end,
--                                       -- optional; widget at the end of the message line
--                                       -- (e.g. a pager), the text wraps in the rest
--       on_close = function() end,      -- optional; whenever the sheet closes
--       on_dismiss = function() end,    -- optional; only when the user dismisses it
--       dismissable = true,             -- false: tap outside and Back do nothing
--       footer   = { item, ... },       -- optional; segments pinned below the sections
--       on_enter = function() end,      -- optional; Enter pressed in the last `field`
--       auto_close = false,             -- close the sheet before any callback runs, except that of an
--                                       -- item with `keep_open` (one that shows a page)
--       fit_width  = false,             -- narrow the sheet to its widest row (rows sections only)
--       flow       = false,             -- true: the sheet can show pages (see below); it keeps one
--                                       -- width and fits its height to every page
--       width      = nil,               -- explicit width, in portrait pixels (overrides fit_width)
--                                       -- without either, a sheet over another window is narrower than it
--       sections = {
--           { type = "tiles",    items = { item, ... } },
--           { type = "segments", items = { item, ... } },
--           { type = "swatches", items = { { color = c, selected = bool, pill = bool, label = s, callback = fn }, ... } },
--           { type = "rows",     rows = { { item, item }, { item } } },
--           { type = "stepper",  value = 50, min = 0, max = 100, ... },
--           { type = "field",    id = "name", value = "", hint = "..." },
--           { type = "note",     text = "..." },
--           { type = "note",     columns = 4, labels = { { text = "...", from = 1 }, ... } },
--           { type = "preview",  icon = "nerd:E001", title = "...", subtitle = "..." },
--           { type = "widget",   build = function(ctx) return widget end },
--       },
--   }
--
-- Section types
--   tiles     One row of equal-width cells, each with the icon above the
--             label.
--   segments  One row of equal-width buttons. An item flagged `selected` is
--             drawn inverted, in bold, and its label ends with a tick. One
--             flagged `primary` (the affirmative action of a confirmation row)
--             is drawn the same way without the tick; a disabled one is dimmed.
--             The label size is the body size, reduced for the whole row until
--             the longest label fits its button.
--   rows      Rows of icon + label cells. The icon slot is only reserved when
--             an item of the section has an icon, so sections without icons
--             keep their labels flush left. Consecutive `rows` sections are
--             regrouped by shape, so every group is one of:
--               list  one item per row; rows are divided by horizontal lines.
--               grid  several items per row, in equal-width columns; no lines.
--
--   stepper   A slider with a minus and a plus control, for picking a number.
--             Fields:
--               label      string    bold caption above the slider (optional)
--               value      number    current value; the sheet keeps it up to
--                                    date as the slider moves
--               min, max   number    range
--               step       number    value change of a tap on a control or of a
--                                    drag position (default 1)
--               hold_step  number    value change of a long press (default `step`)
--               unit       string    appended to the value above the knob
--               on_change  function  called with the new value whenever it
--                                    changes; the slider repaints itself, so
--                                    the callback need not repaint the sheet
--               on_commit  function  called with the value once a change settles:
--                                    a tap, a step or the end of a drag, not
--                                    every position a drag passes
--             Without a touch screen the minus and plus controls take their
--             turn in the focus ring; Press steps the value.
--
--   field     A text input, with the on-screen keyboard shown below the sheet
--             (the sheet is placed in the area above it). Fields:
--               id          any       key of the field (required, unique in the
--                                     sheet)
--               label       string    bold caption above the input (optional)
--               value       string    initial text
--               hint        string    shown while the input is empty
--               input_type  string    "text" (default), "number", ...: the
--                                     InputText input type
--             The inputs are created once per sheet and survive a repaint, so
--             `update` can rebuild the sections while the user types. A tap on
--             a field focuses it and opens the keyboard; without a touch
--             screen the first field starts focused, keyboard up. Enter moves
--             to the next field. In the last one it calls `on_enter` and hides
--             the keyboard, unless that closed the sheet or showed a page. With a D-pad, the fields take
--             their turn in the focus ring with the rows and buttons: Up/Down
--             moves between them, focusing a field raises the keyboard and
--             leaving it hides the keyboard, and Press activates the focused
--             stop (on a field it is Enter). While the keyboard is up, a tap
--             off the keyboard and the inputs only hides it, whatever is under
--             the finger; a tap outside the sheet dismisses it once it is hidden.
--   note      A line of bold supporting text, e.g. an inline error. With
--             `columns` and `labels` it is a caption row for a segments
--             section of that many items: each label starts above the item
--             `from` and runs to the next label or the end of the row.
--   widget    A widget built by the caller, drawn as is. `build(ctx)` runs on
--             every repaint, with the sheet's content width in ctx.inner_w and
--             the size scale in ctx.SZ; it returns the widget, or nil for none.
--
--   preview   A large framed preview of an icon (image file or `nerd:` symbol)
--             `icon`, beside a bold `title` and, under it, a dim `subtitle`
--             (optional). Not interactive.
--
-- Where a list meets a grid, the same line divides them as divides the rows of
-- a list. Any other pair of sections is separated by the same spacing.
--
-- Item
--   text           string
--   sui_icon       string    SUIStyle.icon key (optional)
--   icon_slot      string    SUIStyle slot id (optional); shows the icon of
--                            that slot, override included, and wins over
--                            `sui_icon`
--   preview        string    image file or `nerd:` symbol (optional); rows
--                            only. Drawn as a framed preview, larger than
--                            an icon, and wins over `icon_slot`
--   callback       function  called on tap; the sheet closes itself first only
--                            when `auto_close` is set
--   hold_callback  function  called on long press (optional)
--   enabled        bool      false draws the item dimmed and ignores taps
--   selected       bool      segments only
--   primary        bool      segments only; the affirmative action (see segments)
--   checked        bool      rows only; draws a tick after the label
--   value_preview  string    image file or `nerd:` symbol (optional); rows
--                            only. Drawn as a framed preview at the end of the
--                            row, before the chevron, to show the current value
--                            of an item that shows a page
--   toggle         bool      rows only; draws a check box at the end of the row, as
--                            the rows of the settings windows do: ticked when
--                            true, empty when false. nil draws none
--   chevron        bool      rows only; draws a chevron at the end of the row,
--                            for an item that shows a page; not drawn when the
--                            item is disabled
--
-- ActionSheet.pick(opts) shows a one-column chooser: `title`, `icon`, `name`,
-- `fit_width` as in show, plus `items` and `on_cancel`. Tapping an item closes
-- the sheet and then runs its callback; dismissing the sheet (tap outside,
-- Back key) runs `on_cancel`, so a chooser needs no Cancel item.
-- With `parent`, a sheet created with `flow`, the chooser is a page of it
-- instead (`name`, `fit_width` and `on_cancel` do not apply): tapping an item
-- goes back to the parent (leaving `levels` pages, default 1), or closes it
-- when `close_parent` is set, and then runs the callback.
--
-- ActionSheet.list(items) builds a `rows` section with one item per row.
--
-- Items follow the button format of ButtonDialog, so button generators can be
-- passed through unchanged.
--
-- ActionSheet.show returns the SUIWindow; close it with window:close().
-- window:update(fields) replaces any of `title`, `message`, `message_end`, `icon`,
-- `footer` and `sections` of what the sheet shows (its current page, if any) and
-- redraws it; the width stays as it was. The height follows the content: the
-- sheet grows, up to the screen, and shrinks back, never paginating a single
-- screen that fits.
-- A sheet with `field` sections also has
--   window:getFieldText(id)       the raw text of a field
--   window:setFieldText(id, text) replaces the text of a field
--   window:focusField(id)         moves the focus, and the keyboard, to a field
--
-- Pages. A sheet created with `flow` can show further screens over itself
-- instead of closing to open another sheet:
--   window:showPage(spec)   `spec` takes `title`, `icon`, `message`, `sections`,
--                           `footer`, `on_enter`, `on_edit` and `auto_close` as
--                           show does. The page has a header with a back
--                           button; the Back key and a tap on it return to the
--                           screen below, and a tap outside the sheet
--                           dismisses the whole sheet. The sheet fits its
--                           height to each page.
--   window:closePage(n)     returns to the screen below the current page, or
--                           leaves `n` pages at once, with one repaint.
-- The `field` sections of a page keep their text while it is shown and are
-- released when it is left; the ones of the screen below keep theirs.

local CenterContainer = require("ui/widget/container/centercontainer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local RoundedFrame    = require("infra/sui_backdrop").RoundedFrame
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputText       = require("ui/widget/inputtext")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UI              = require("infra/sui_core")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Device          = require("device")
local Screen          = Device.screen

local SUIStyle  = require("features/sui_style")
local SUISlider = require("engines/sui_slider")
local SUIWindow = require("engines/sui_window")
local TextFit  = require("infra/sui_text_fit")

local COLOR = SUIStyle.COLOR

local ActionSheet = {}

-- Metrics in base pixels; scaled by px() when a screen is built.
local METRICS = {
    header_pad_top    = 14,
    header_pad_bottom = 12,
    segment_h         = 44,
    segment_gap       = 10,
    segment_radius    = 10,
    swatch_h          = 40,
    swatch_gap        = 8,
    row_h             = 46,
    cell_pad          = 10,
    cell_gap          = 12,
    cell_icon         = 24,
    cell_preview      = 32,
    preview_card      = 64,
    cell_tick         = 18,
    cell_chevron      = 18,
    cell_toggle       = 24,
    section_gap       = 8,
    tile_h            = 76,
    tile_gap          = 6,
    stepper_gap       = 14,
    caption_gap       = 2,
    field_gap         = 10,
}

-- Scales a base-pixel metric with the window's landscape-aware factor.
local function px(ctx, base)
    return ctx.SZ(Screen:scaleBySize(base))
end

local function isEnabled(item)
    return item.enabled ~= false
end

-- Wraps `widget` so a tap runs the item's callback and a long press its hold
-- callback. Items that are disabled or have neither are returned as they are.
local function makeTappable(widget, item, w, h)
    if not isEnabled(item) or not (item.callback or item.hold_callback) then
        return widget
    end
    return SUIWindow.Input.tapable(widget,
        { on_tap = item.callback, on_hold = item.hold_callback },
        Geom:new{ w = w, h = h })
end

local function buildLine(width, height, color)
    return LineWidget:new{
        dimen      = Geom:new{ w = width, h = height },
        background = color,
    }
end

-- Width of one of `count` equal columns.
local function columnWidth(ctx, count)
    return math.floor(ctx.inner_w / count)
end

-- Horizontal group of `count` columns of `cell_w`: `cells`, then empty space
-- for the missing ones.
local function buildColumns(cells, count, cell_w)
    local group = HorizontalGroup:new{ align = "center" }
    for i = 1, count do
        group[#group + 1] = cells[i] or HorizontalSpan:new{ width = cell_w }
    end
    return group
end

-- ---------------------------------------------------------------------------
-- Header
-- ---------------------------------------------------------------------------

-- Under a title the message is supporting text in a smaller size; alone it is
-- the content of the sheet and is drawn as body text.
local function buildMessage(ctx, text, has_title, width)
    return TextBoxWidget:new{
        text      = text,
        face      = Font:getFace(SUIStyle.FACE_REGULAR,
                        ctx.SZ(has_title and SUIStyle.FS_DETAIL or SUIStyle.FS_BODY)),
        fgcolor   = COLOR.text_primary,
        width     = width or ctx.inner_w,
        alignment = "left",
    }
end

-- Message line: the text, and `trailing` (optional) at its far end.
local function buildMessageLine(ctx, text, has_title, trailing)
    if not trailing then return buildMessage(ctx, text, has_title) end
    local trailing_size = trailing:getSize()
    local message = buildMessage(ctx, text, has_title, ctx.inner_w - trailing_size.w)
    local h = math.max(message:getSize().h, trailing_size.h)
    return HorizontalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = message:getSize().w, h = h }, message },
        RightContainer:new{ dimen = Geom:new{ w = trailing_size.w, h = h }, trailing },
    }
end

-- Centred title row above a separator, and message, each optional, between the
-- header padding. Without either, the header is only the window's own bottom
-- padding, so the content sits evenly between top and bottom.
local function buildHeader(ctx, opts, window, has_back)
    local has_title   = opts.title and opts.title ~= ""
    local has_message = opts.message and opts.message ~= ""
    if not has_title and not has_message then
        return VerticalSpan:new{ width = ctx.SZ(Size.padding.large) }
    end

    local header = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = px(ctx, METRICS.header_pad_top) },
    }
    if has_title then
        -- The same width is reserved on both sides of the heading, so it stays
        -- centred whether or not the back button is shown.
        local back = has_back and window:titleButton("chevron_left", "left",
            function() window:closePage() end, false,
            px(ctx, METRICS.header_pad_top), px(ctx, METRICS.header_pad_bottom))
        local side_w  = back and back:getSize().w or 0
        local heading = SUIWindow.TitleRow{
            width = ctx.inner_w - 2 * side_w,
            title = opts.title,
            icon  = opts.icon,
        }
        local dimen = Geom:new{
            w = ctx.inner_w,
            h = math.max(heading:getSize().h, back and back:getSize().h or 0),
        }
        local row = OverlapGroup:new{
            dimen = dimen,
            CenterContainer:new{ dimen = dimen, heading },
        }
        if back then row[#row + 1] = LeftContainer:new{ dimen = dimen, back } end
        header[#header + 1] = row
        header[#header + 1] = VerticalSpan:new{ width = px(ctx, METRICS.header_pad_bottom) }
        header[#header + 1] = buildLine(ctx.inner_w, Size.line.medium, COLOR.text_primary)
    end
    if has_message then
        if has_title then
            header[#header + 1] = VerticalSpan:new{ width = px(ctx, METRICS.header_pad_bottom) }
        end
        header[#header + 1] = buildMessageLine(ctx, opts.message, has_title,
            opts.message_end and opts.message_end(ctx))
    end
    header[#header + 1] = VerticalSpan:new{ width = px(ctx, METRICS.header_pad_bottom) }
    return header
end

-- ---------------------------------------------------------------------------
-- Segments section
-- ---------------------------------------------------------------------------

local SEGMENT_TICK = "\u{2713}"

-- Label of a segment. A selected segment ends with a tick; a tick already in
-- the text is replaced, never doubled.
local function segmentLabel(item, selected)
    local label = (item.text or ""):gsub("%s*" .. SEGMENT_TICK .. "%s*$", "")
    if selected then label = label .. "  " .. SEGMENT_TICK end
    return label
end

local function buildSegment(ctx, item, w, h, face)
    local selected = item.selected == true
    local filled   = selected or (item.primary == true and isEnabled(item))
    local fgcolor
    if filled then
        fgcolor = SUIStyle.accentFg(COLOR.surface)
    else
        fgcolor = isEnabled(item) and COLOR.text_primary or COLOR.text_dim
    end

    local frame = RoundedFrame:new{
        bordersize = 0,
        padding    = 0,
        radius     = px(ctx, METRICS.segment_radius),
        background = filled and SUIStyle.accent(COLOR.text_primary) or COLOR.surface_flat,
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text                   = segmentLabel(item, selected),
                face                   = face,
                fgcolor                = fgcolor,
                bold                   = filled,
                padding                = 0,
                max_width              = math.max(1, w - 2 * px(ctx, METRICS.cell_pad)),
                truncate_with_ellipsis = true,
            },
        },
    }
    return makeTappable(frame, item, w, h)
end

-- Size of the segment labels: the body size, or the smallest readable one,
-- whichever lets the longest label (ticked and bold, its widest form) fit.
local function segmentFontSize(ctx, items, max_w)
    local function fits(size)
        local face = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(size))
        for _i, item in ipairs(items) do
            local probe = TextWidget:new{ text = segmentLabel(item, true), face = face, bold = true, padding = 0 }
            local w = probe:getSize().w
            probe:free()
            if w > max_w then return false end
        end
        return true
    end
    return TextFit.largest(SUIStyle.FS_BODY, SUIStyle.FS_CAPTION, fits)
end

-- Gap and width of each of `count` equal-width segments of a row.
local function segmentGrid(ctx, count)
    local gap = px(ctx, METRICS.segment_gap)
    return gap, math.floor((ctx.inner_w - gap * (count - 1)) / count)
end

local function buildSegments(ctx, section)
    local items = section.items
    local count = #items
    if count == 0 then return {} end
    local gap, w = segmentGrid(ctx, count)
    local h     = px(ctx, METRICS.segment_h)
    local size  = segmentFontSize(ctx, items, w - 2 * px(ctx, METRICS.cell_pad))
    local face  = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(size))

    local group = HorizontalGroup:new{ align = "center" }
    for i, item in ipairs(items) do
        if i > 1 then group[#group + 1] = HorizontalSpan:new{ width = gap } end
        group[#group + 1] = buildSegment(ctx, item, w, h, face)
    end
    return { group }
end

-- ---------------------------------------------------------------------------
-- Swatches section
-- ---------------------------------------------------------------------------

-- One colour swatch in a cell of `w` x `h`: a circle centred in the cell, or,
-- with `pill`, a pill filling it. The selected one has a heavier frame. Without
-- a colour it is an empty outline, which may carry a `label`.
local function buildSwatch(ctx, item, w, h)
    local d = item.pill and w or math.min(w, h)
    local label
    if item.label then
        label = TextWidget:new{
            text                   = item.label,
            face                   = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY)),
            fgcolor                = COLOR.text_primary,
            padding                = 0,
            max_width              = math.max(1, d - 2 * px(ctx, METRICS.cell_pad)),
            truncate_with_ellipsis = true,
        }
    end
    local chip = SUIStyle.buildColorChip(d, item.pill and h or d, item.color, item.selected, label)
    return makeTappable(CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, chip }, item, w, h)
end

-- One row of equal-width colour swatches. An item has `color` (a Blitbuffer
-- colour, nil for an empty outline), `selected`, `pill`, `label` and
-- `callback`; without a callback it is a plain preview.
local function buildSwatches(ctx, section)
    local items = section.items
    local count = #items
    if count == 0 then return {} end
    local gap   = px(ctx, METRICS.swatch_gap)
    local h     = px(ctx, METRICS.swatch_h)
    local w     = math.floor((ctx.inner_w - gap * (count - 1)) / count)

    local group = HorizontalGroup:new{ align = "center" }
    for i, item in ipairs(items) do
        if i > 1 then group[#group + 1] = HorizontalSpan:new{ width = gap } end
        group[#group + 1] = buildSwatch(ctx, item, w, h)
    end
    return { group }
end

-- ---------------------------------------------------------------------------
-- Tiles section
-- ---------------------------------------------------------------------------

-- Icon widget of `item` at `size` px: its preview, slot icon or symbol glyph.
-- nil when the item has none.
local function buildIcon(item, size, fgcolor)
    if item.preview then
        return SUIStyle.buildIconPreview(size, { icon = item.preview, label = item.text })
    elseif item.icon_slot then
        return SUIStyle.slotIconWidget(item.icon_slot, size, fgcolor)
    elseif item.sui_icon then
        local fields = {
            text    = SUIStyle.icon(item.sui_icon),
            face    = SUIStyle.glyphFace(size),
            padding = 0,
        }
        -- An enabled item's glyph takes the accent colour; a disabled one stays dim.
        if isEnabled(item) then return UI.makeAccentText(fields, fgcolor) end
        fields.fgcolor = fgcolor
        return TextWidget:new(fields)
    end
end

local function hasIcon(item)
    return item.preview ~= nil or item.icon_slot ~= nil or item.sui_icon ~= nil
end

-- Whether the row of `item` ends with a chevron.
local function hasChevron(item)
    return item.chevron == true and isEnabled(item)
end

local function hasToggle(item)
    return item.toggle ~= nil
end

-- Width of what ends the row of `item` (value preview, chevron and check box,
-- each after a gap), after passing the base-pixel metrics through `scale`.
local function trailingWidth(item, scale)
    local base = 0
    if hasToggle(item) then base = base + METRICS.cell_gap + METRICS.cell_toggle end
    if item.value_preview then base = base + METRICS.cell_gap + METRICS.cell_preview end
    if hasChevron(item) then base = base + METRICS.cell_gap + METRICS.cell_chevron end
    return scale(base)
end

-- Icon above the label, centred in a cell of `w` x `h`.
local function buildTile(ctx, item, w, h)
    local fgcolor = isEnabled(item) and COLOR.text_primary or COLOR.text_dim

    local content = VerticalGroup:new{ align = "center" }
    local icon    = buildIcon(item, px(ctx, METRICS.cell_icon), fgcolor)
    if icon then
        content[#content + 1] = icon
        content[#content + 1] = VerticalSpan:new{ width = px(ctx, METRICS.tile_gap) }
    end
    content[#content + 1] = TextWidget:new{
        text                   = item.text or "",
        face                   = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY)),
        fgcolor                = fgcolor,
        padding                = 0,
        max_width              = math.max(1, w - 2 * px(ctx, METRICS.cell_pad)),
        truncate_with_ellipsis = true,
    }

    return makeTappable(CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        content,
    }, item, w, h)
end

local function buildTiles(ctx, section)
    local count = #section.items
    if count == 0 then return {} end
    local w = columnWidth(ctx, count)
    local h = px(ctx, METRICS.tile_h)

    local tiles = {}
    for i, item in ipairs(section.items) do tiles[i] = buildTile(ctx, item, w, h) end
    return { buildColumns(tiles, count, w) }
end

-- ---------------------------------------------------------------------------
-- Rows section
-- ---------------------------------------------------------------------------

-- Optional icon slot, the label and, for a checked item, a tick. `slot` is the
-- slot width in base pixels; it is left empty for items without an icon, so
-- labels stay aligned across the rows of a section.
local function buildCellContent(ctx, item, cell_w, row_h, fgcolor, slot)
    local pad      = px(ctx, METRICS.cell_pad)
    local gap      = px(ctx, METRICS.cell_gap)
    local icon_w   = slot and px(ctx, slot) or 0
    local tick_w   = item.checked and px(ctx, METRICS.cell_tick) or 0
    local content  = HorizontalGroup:new{ align = "center" }
    local used     = 2 * pad + tick_w
    used = used + trailingWidth(item, function(base) return px(ctx, base) end)

    if slot then
        local icon = buildIcon(item,
            item.preview and icon_w or px(ctx, METRICS.cell_icon), fgcolor)
        content[#content + 1] = icon and CenterContainer:new{
            dimen = Geom:new{ w = icon_w, h = row_h },
            icon,
        } or HorizontalSpan:new{ width = icon_w }
        content[#content + 1] = HorizontalSpan:new{ width = gap }
        used = used + icon_w + gap
    end

    content[#content + 1] = TextWidget:new{
        text                   = item.text or "",
        face                   = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY)),
        fgcolor                = fgcolor,
        padding                = 0,
        max_width              = math.max(1, cell_w - used - (item.checked and gap or 0)),
        truncate_with_ellipsis = true,
    }

    if item.checked then
        content[#content + 1] = HorizontalSpan:new{ width = gap }
        content[#content + 1] = UI.makeAccentText({
            text    = SUIStyle.icon("tick"),
            face    = SUIStyle.glyphFace(tick_w),
            padding = 0,
        }, fgcolor)
    end

    return HorizontalGroup:new{
        HorizontalSpan:new{ width = pad },
        content,
    }
end

-- Value preview and chevron of `item` pinned to the end of a cell of
-- `cell_w` x `row_h`, inside the cell padding.
local function buildTrailing(ctx, item, cell_w, row_h, fgcolor)
    local group = HorizontalGroup:new{ align = "center" }
    if item.value_preview then
        group[#group + 1] = SUIStyle.buildIconPreview(px(ctx, METRICS.cell_preview),
            { icon = item.value_preview, label = item.text })
        group[#group + 1] = HorizontalSpan:new{ width = px(ctx, METRICS.cell_gap) }
    end
    if hasChevron(item) then
        group[#group + 1] = UI.makeAccentText({
            text    = SUIStyle.icon("chevron"),
            face    = SUIStyle.glyphFace(px(ctx, METRICS.cell_chevron)),
            padding = 0,
        }, fgcolor)
    end
    if hasToggle(item) then
        if hasChevron(item) then
            group[#group + 1] = HorizontalSpan:new{ width = px(ctx, METRICS.cell_gap) }
        end
        local toggle_fields = {
            text    = SUIStyle.icon(item.toggle and "check" or "uncheck"),
            face    = SUIStyle.glyphFace(px(ctx, METRICS.cell_toggle)),
            padding = 0,
        }
        -- Both states take the accent colour; a disabled item stays dim.
        if isEnabled(item) then
            group[#group + 1] = UI.makeAccentText(toggle_fields, fgcolor)
        else
            toggle_fields.fgcolor = fgcolor
            group[#group + 1] = TextWidget:new(toggle_fields)
        end
    end
    group[#group + 1] = HorizontalSpan:new{ width = px(ctx, METRICS.cell_pad) }
    return RightContainer:new{ dimen = Geom:new{ w = cell_w, h = row_h }, group }
end

local function buildCell(ctx, item, cell_w, row_h, slot)
    local fgcolor = isEnabled(item) and COLOR.text_primary or COLOR.text_dim
    local cell = LeftContainer:new{
        dimen = Geom:new{ w = cell_w, h = row_h },
        buildCellContent(ctx, item, cell_w, row_h, fgcolor, slot),
    }
    if item.value_preview or hasChevron(item) or hasToggle(item) then
        cell = OverlapGroup:new{
            dimen = Geom:new{ w = cell_w, h = row_h },
            cell,
            buildTrailing(ctx, item, cell_w, row_h, fgcolor),
        }
    end
    return makeTappable(cell, item, cell_w, row_h)
end

-- One row of a section with `columns` columns.
local function buildRow(ctx, items, slot, columns)
    local row_h  = px(ctx, METRICS.row_h)
    local cell_w = columnWidth(ctx, columns)
    local cells  = {}
    for i, item in ipairs(items) do
        cells[i] = buildCell(ctx, item, cell_w, row_h, slot)
    end
    return buildColumns(cells, columns, cell_w)
end

-- A row followed by a separator line. The window drops that line when the
-- row ends up last on a page.
local function withSeparator(ctx, row)
    local group = VerticalGroup:new{
        align = "left",
        row,
        buildLine(ctx.inner_w, Size.line.thin, COLOR.gray_strong),
    }
    group.is_list_row_with_sep = true
    return group
end

-- Number of columns of a section: the item count of its widest row.
local function columnCount(rows)
    local count = 1
    for _i, items in ipairs(rows) do count = math.max(count, #items) end
    return count
end

-- Width in base pixels of the icon slot of the rows: nil when no item has an
-- icon, wider when one has a preview.
local function iconSlot(rows)
    local slot
    for _i, items in ipairs(rows) do
        for _j, item in ipairs(items) do
            if item.preview then return METRICS.cell_preview end
            if hasIcon(item) then slot = METRICS.cell_icon end
        end
    end
    return slot
end

local function buildRows(ctx, section)
    local filled = {}
    for _i, items in ipairs(section.rows) do
        if #items > 0 then filled[#filled + 1] = items end
    end

    local slot    = iconSlot(filled)
    local columns = columnCount(filled)
    local widgets = {}
    for i, items in ipairs(filled) do
        local row = buildRow(ctx, items, slot, columns)
        if columns == 1 and i < #filled then row = withSeparator(ctx, row) end
        widgets[#widgets + 1] = row
    end
    return widgets
end

-- ---------------------------------------------------------------------------
-- Stepper section
-- ---------------------------------------------------------------------------

-- Caption, when the section has a label, above the slider row.
local function buildStepper(ctx, section)
    local step      = section.step or 1
    local hold_step = section.hold_step or step
    local unit      = section.unit or ""
    local slider

    -- Moves the slider by `delta` and reports the value when it changed.
    local function changed(value, dragging)
        section.value = value
        if section.on_change then section.on_change(value) end
        if not dragging and section.on_commit then section.on_commit(value) end
    end

    local function move(delta)
        local before = slider:getValue()
        slider:moveTo(before + delta)
        local after = slider:getValue()
        if after ~= before then changed(after) end
    end

    local controls = SUISlider.stepControls({
        minus      = function() move(-step) end,
        plus       = function() move(step) end,
        minus_hold = function() move(-hold_step) end,
        plus_hold  = function() move(hold_step) end,
    }, function(dp) return px(ctx, dp) end)

    slider = SUISlider:new{
        width     = SUISlider.barWidth(ctx.inner_w, controls),
        height    = controls.height,
        min       = section.min,
        max       = section.max,
        value     = section.value,
        step      = step,
        format    = function(value) return value .. unit end,
        face      = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY)),
        on_change = changed,
        on_release = function()
            if section.on_commit then section.on_commit(section.value) end
        end,
    }

    for _i, control in ipairs({ controls.minus, controls.plus }) do
        local _, focused = SUIWindow.Input.focusStop(control, {
            on_select = function() control:activate() end,
        })
        control.focused = focused
    end

    local group = VerticalGroup:new{ align = "left" }
    if section.label and section.label ~= "" then
        group[#group + 1] = SUISlider.Caption:new{
            name      = section.label,
            width     = ctx.inner_w,
            name_face = Font:getFace(SUIStyle.FACE_BOLD, ctx.SZ(SUIStyle.FS_BODY)),
        }
        group[#group + 1] = VerticalSpan:new{ width = px(ctx, METRICS.caption_gap) }
    end
    group[#group + 1] = SUISlider.row(controls, slider)
    return { group }
end

-- ---------------------------------------------------------------------------
-- Field and note sections
-- ---------------------------------------------------------------------------

-- Caption, when the section has a label, above the shared input of the field.
local function buildField(ctx, section, inputs)
    local group = VerticalGroup:new{ align = "left" }
    if section.label and section.label ~= "" then
        group[#group + 1] = TextWidget:new{
            text                   = section.label,
            face                   = Font:getFace(SUIStyle.FACE_BOLD, ctx.SZ(SUIStyle.FS_BODY)),
            fgcolor                = COLOR.text_primary,
            padding                = 0,
            max_width              = ctx.inner_w,
            truncate_with_ellipsis = true,
        }
        group[#group + 1] = VerticalSpan:new{ width = px(ctx, METRICS.caption_gap) }
    end
    local input = inputs.byId[section.id]
    group[#group + 1] = SUIWindow.Input.focusStop(input, {
        input     = input,
        on_select = function() inputs:focus(input) end,
        on_focus  = function() inputs:focus(input) end,
        on_blur   = function(next_stop) inputs:blur(input, next_stop) end,
    })
    return { group }
end

local function noteText(ctx, text, width)
    return TextBoxWidget:new{
        text      = text,
        face      = Font:getFace(SUIStyle.FACE_BOLD, ctx.SZ(SUIStyle.FS_DETAIL)),
        fgcolor   = COLOR.text_primary,
        width     = width,
        alignment = "left",
    }
end

-- Captions over the columns of a segments row of `section.columns` items.
local function buildColumnLabels(ctx, section)
    local gap, w = segmentGrid(ctx, section.columns)
    local group = HorizontalGroup:new{ align = "top" }
    for i, label in ipairs(section.labels) do
        local last = section.labels[i + 1] and section.labels[i + 1].from - 1 or section.columns
        local span = last - label.from + 1
        local label_w = span * w + (span - 1) * gap
        if i > 1 then group[#group + 1] = HorizontalSpan:new{ width = gap } end
        group[#group + 1] = noteText(ctx, label.text, label_w)
    end
    return { group }
end

local function buildNote(ctx, section)
    if section.labels then return buildColumnLabels(ctx, section) end
    if not section.text or section.text == "" then return {} end
    return { noteText(ctx, section.text, ctx.inner_w) }
end

-- A widget built by the caller.
local function buildWidget(ctx, section)
    local widget = section.build(ctx)
    return widget and { widget } or {}
end

-- Framed icon preview beside a bold title and a dim subtitle.
local function buildPreviewCard(ctx, section)
    local size   = px(ctx, METRICS.preview_card)
    local gap    = px(ctx, METRICS.cell_gap)
    local text_w = ctx.inner_w - size - gap

    local text = VerticalGroup:new{ align = "left" }
    text[#text + 1] = TextWidget:new{
        text                   = section.title or "",
        face                   = Font:getFace(SUIStyle.FACE_BOLD, ctx.SZ(SUIStyle.FS_BODY)),
        fgcolor                = COLOR.text_primary,
        padding                = 0,
        max_width              = text_w,
        truncate_with_ellipsis = true,
    }
    if section.subtitle and section.subtitle ~= "" then
        text[#text + 1] = VerticalSpan:new{ width = px(ctx, METRICS.caption_gap) }
        text[#text + 1] = TextBoxWidget:new{
            text    = section.subtitle,
            face    = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_DETAIL)),
            fgcolor = COLOR.text_primary,
            width   = text_w,
        }
    end

    return { HorizontalGroup:new{
        align = "center",
        SUIStyle.buildIconPreview(size, { icon = section.icon, label = section.title }),
        HorizontalSpan:new{ width = gap },
        text,
    } }
end

-- ---------------------------------------------------------------------------
-- Text inputs
-- ---------------------------------------------------------------------------

-- Height in px of the keyboard `input` shows, 0 when it has none.
local function keyboardHeight(input)
    local dimen = input:getKeyboardDimen()
    return dimen and dimen.h or 0
end

-- The text inputs of a sheet, one per `field` section. They are created once,
-- before the window is shown, and every build of the screen reuses them, so the
-- text, the cursor and the keyboard survive a repaint. Returns nil when the
-- sheet has no `field` sections.
--   inputs.byId[id]   the InputText of a field
--   inputs.list       the InputTexts, in section order
--   inputs.current    the InputText that has the focus
local function createInputs(window, opts)
    local list, byId = {}, {}
    -- Without a touch screen no tap can focus a field: the first one starts
    -- focused, keyboard up.
    local focus_first = not Device:isTouchDevice()
    local inputs = { list = list, byId = byId, heights = {}, inset = 0,
                     focus_first = focus_first }
    local face   = Font:getFace(SUIStyle.FACE_REGULAR,
                       math.floor(SUIStyle.FS_BODY * window:getScale()))
    -- InputText needs a parent before the window has a widget; see adopt().
    local placeholder = {}

    local fields = {}
    for _i, section in ipairs(opts.sections) do
        if section.type == "field" then fields[#fields + 1] = section end
    end
    if #fields == 0 then return nil end

    -- The methods exist before the first InputText is built: it reports its
    -- initial text through edit_callback while it is being created.
    -- Enter moves to the next field. In the last one it submits the sheet, as
    -- the default button does, and hides the keyboard if the sheet is still
    -- showing these inputs afterwards.
    function inputs:enter(input)
        for i, candidate in ipairs(list) do
            if candidate == input and list[i + 1] then
                self:focus(list[i + 1])
                return
            end
        end
        if opts.on_enter then opts.on_enter() end
        if self.shown then self:closeKeyboard() end
    end

    -- A change of the text: lets the caller react and refits the sheet when
    -- the text wrapped onto another line.
    function inputs:edited(input)
        if not self.shown then return end
        if opts.on_edit then opts.on_edit() end
        local height = input:getSize().h
        if height ~= self.heights[input] then
            self.heights[input] = height
            window:repaint()
        end
    end

    -- Reserves `height` px at the bottom of the screen for the keyboard, and
    -- repaints a shown sheet only when its placement changes.
    function inputs:setInset(height)
        if height == self.inset then return end
        self.inset = height
        window:setBottomInset(height)
        if self.shown then window:repaint() end
    end

    -- Moves the focus, and the keyboard, to `input`. Nothing to do when it
    -- already has both.
    function inputs:focus(input)
        local current = self.current
        if input == current and input:isKeyboardVisible() then return end
        current:unfocus()
        current:onCloseKeyboard()
        self.current = input
        input:focus()
        self:setInset(keyboardHeight(input))
        input:onShowKeyboard()
    end

    -- Hides the keyboard and gives its area back to the sheet.
    function inputs:closeKeyboard()
        self.current:onCloseKeyboard()
        self:setInset(0)
    end

    -- The D-pad focus leaves `input`: it stops taking the keys, so Press
    -- reaches the stop that has the focus, and the keyboard goes away unless
    -- the focus moves to another input.
    function inputs:blur(input, next_stop)
        input:unfocus()
        if not (next_stop and next_stop.input) then self:closeKeyboard() end
    end

    -- Hides the keyboard and releases every input with its keyboard.
    function inputs:free()
        self.shown = false
        self.current:onCloseKeyboard()
        for _i, input in ipairs(list) do input:onCloseWidget() end
    end

    -- Hides the keyboard and stops repainting for the inputs while a page
    -- covers them; adopt() hands them back.
    function inputs:detach()
        self.shown = false
        self:closeKeyboard()
    end

    -- Hands the inputs to the shown window: from now on it is their parent,
    -- the widget they ask to repaint and to switch the focus.
    function inputs:adopt()
        local wrapper = window:getWidget()
        function wrapper.onSwitchFocus(_, input) inputs:focus(input) end
        -- The window drives its own D-pad focus: InputText finds no focusable
        -- widget to move to after a tap, and moving the focus is a no-op.
        function wrapper.getFocusableWidgetXY() return nil, nil end
        function wrapper.moveFocusTo() end
        for _i, input in ipairs(list) do input.parent = wrapper end
        -- Before `shown`, so that reserving the keyboard's area repaints nothing.
        if self.focus_first then self:setInset(keyboardHeight(self.current)) end
        self.shown = true
        if self.focus_first then self.current:onShowKeyboard() end
    end

    -- InputText's width is the text area: the box adds its padding and border
    -- around it, so subtract them to make the whole box as wide as the sheet.
    local width = window:getInnerWidth() - 2 * (InputText.bordersize + InputText.padding)

    for i, section in ipairs(fields) do
        local input
        input = InputText:new{
            text           = section.value or "",
            hint           = section.hint or "",
            input_type     = section.input_type,
            face           = face,
            width          = width,
            margin         = 0,
            scroll         = false,
            focused        = focus_first and i == 1,
            parent         = placeholder,
            enter_callback = function() inputs:enter(input) end,
            edit_callback  = function() inputs:edited(input) end,
        }
        -- The keyboard can be closed with its own Back key: its area goes back
        -- to the sheet.
        local keyboard = input.keyboard
        if keyboard and keyboard.onCloseWidget then
            -- While its keyboard is up the sheet is always active, so taps the
            -- keyboard does not take reach it (see ActionSheet.show).
            local function setActive(active)
                local wrapper = window:getWidget()
                if wrapper then wrapper.is_always_active = active or nil end
            end
            local show, close = keyboard.onShow, keyboard.onCloseWidget
            function keyboard:onShow()
                local handled = show(self)
                setActive(true)
                return handled
            end
            function keyboard:onCloseWidget()
                close(self)
                setActive(false)
                if inputs.shown and inputs.current == input then inputs:setInset(0) end
            end
        end
        list[i]             = input
        byId[section.id]    = input
        inputs.heights[input] = input:getSize().h
    end
    inputs.current = list[1]

    -- A sheet whose keyboard opens with it is placed above it from the start.
    if focus_first then inputs:setInset(keyboardHeight(list[1])) end
    return inputs
end

-- ---------------------------------------------------------------------------
-- Screen
-- ---------------------------------------------------------------------------

local SECTION_BUILDERS = {
    tiles    = buildTiles,
    segments = buildSegments,
    swatches = buildSwatches,
    rows     = buildRows,
    stepper  = buildStepper,
    field    = buildField,
    note     = buildNote,
    preview  = buildPreviewCard,
    widget   = buildWidget,
}

-- The sections with consecutive `rows` sections regrouped by shape: each
-- list or grid is one section, whatever sections its rows came from.
local function regroupRows(sections)
    local result, run = {}, nil
    for _i, section in ipairs(sections) do
        if section.type == "rows" then
            for _j, items in ipairs(section.rows) do
                if #items > 0 then
                    local multi = #items > 1
                    if not run or run.multi ~= multi then
                        run = { multi = multi, section = { type = "rows", rows = {} } }
                        result[#result + 1] = run.section
                    end
                    run.section.rows[#run.section.rows + 1] = items
                end
            end
        else
            result[#result + 1] = section
            run = nil
        end
    end
    return result
end

-- Spacing between two consecutive sections of the same type, where it differs
-- from the standard section gap.
local SAME_TYPE_GAP = {
    stepper = METRICS.stepper_gap,
    field   = METRICS.field_gap,
}

local function buildScreen(ctx, sections, inputs)
    local widgets = {}
    local previous
    for _i, section in ipairs(regroupRows(sections)) do
        local build = SECTION_BUILDERS[section.type]
        local built = build and build(ctx, section, inputs) or {}
        if #built > 0 then
            if previous == "rows" and section.type == "rows" then
                widgets[#widgets] = withSeparator(ctx, widgets[#widgets])
            elseif previous then
                local gap = METRICS.section_gap
                if previous == section.type then
                    gap = SAME_TYPE_GAP[previous] or gap
                end
                widgets[#widgets + 1] = VerticalSpan:new{ width = px(ctx, gap) }
            end
            previous = section.type
            for _j, widget in ipairs(built) do
                widgets[#widgets + 1] = widget
            end
        end
    end
    return widgets
end

-- Makes every item close the sheet before running its callback, but those
-- that ask to stay open.
local function closeBeforeCallbacks(sections, close)
    for _i, section in ipairs(sections) do
        local rows = section.rows or { section.items or {} }
        for _j, items in ipairs(rows) do
            for _k, item in ipairs(items) do
                local callback = item.callback
                if callback and not item.keep_open then
                    item.callback = function()
                        close()
                        callback()
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Width fitting
-- ---------------------------------------------------------------------------

local FIT_MAX_ITEMS = 12    -- longer lists keep the default width, unmeasured
local FIT_MIN_RATIO = 0.4   -- narrowest sheet, as a fraction of the portrait width
local FIT_MAX_RATIO = 5 / 6 -- widest sheet: the window's default width

-- Width in portrait pixels of the sheet that just holds the title and the
-- `sections` of `opts`, or nil when they are not all `rows` sections or hold
-- more than FIT_MAX_ITEMS items (measuring a long list costs more than it
-- saves: such a sheet is wide anyway). Mirrors the metrics of buildCell:
-- the widest cell of a section sets the width of every column.
local function fitWidth(opts)
    local count = 0
    for _i, section in ipairs(opts.sections) do
        if section.type ~= "rows" then return nil end
        for _j, items in ipairs(section.rows) do count = count + #items end
    end
    if count > FIT_MAX_ITEMS then return nil end

    local face     = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
    local pad      = Screen:scaleBySize(METRICS.cell_pad)
    local gap      = Screen:scaleBySize(METRICS.cell_gap)
    local tick_w   = Screen:scaleBySize(METRICS.cell_tick)
    local widest   = 0

    for _i, section in ipairs(opts.sections) do
        local slot = iconSlot(section.rows)
        local cell_w, columns = 0, 1
        for _j, items in ipairs(section.rows) do
            columns = math.max(columns, #items)
            for _k, item in ipairs(items) do
                local label = TextWidget:new{ text = item.text or "", face = face, padding = 0 }
                local w = 2 * pad + label:getWidth()
                label:free()
                if slot then w = w + Screen:scaleBySize(slot) + gap end
                if item.checked then w = w + gap + tick_w end
                w = w + trailingWidth(item, function(base) return Screen:scaleBySize(base) end)
                cell_w = math.max(cell_w, w)
            end
        end
        widest = math.max(widest, cell_w * columns)
    end

    -- The centred title, with its optional icon (mirrors SUIWindow.TitleRow).
    if opts.title and opts.title ~= "" then
        local heading = TextWidget:new{
            text    = opts.title,
            face    = Font:getFace(SUIStyle.FACE_BOLD, SUIStyle.FS_TITLE),
            padding = 0,
        }
        local title_w = heading:getWidth()
        heading:free()
        if opts.icon then title_w = title_w + Screen:scaleBySize(26 + 12) end
        widest = math.max(widest, title_w)
    end

    local portrait_w = require("infra/sui_core").getPortraitDims()
    local width = widest + 2 * Screen:scaleBySize(20)   -- the window's horizontal padding
    return math.min(math.max(width, math.floor(portrait_w * FIT_MIN_RATIO)),
                    math.floor(portrait_w * FIT_MAX_RATIO))
end

-- Segments pinned under the sections, so they stay visible on every page.
local function buildFooter(ctx, items)
    local gap = px(ctx, METRICS.section_gap)
    local footer = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = gap } }
    for _i, widget in ipairs(buildSegments(ctx, { items = items })) do
        footer[#footer + 1] = widget
    end
    footer[#footer + 1] = VerticalSpan:new{ width = gap }
    return footer
end

--- A `rows` section with one item per row.
function ActionSheet.list(items)
    local rows = {}
    for _i, item in ipairs(items) do rows[#rows + 1] = { item } end
    return { type = "rows", rows = rows }
end

function ActionSheet.show(opts)
    local window
    -- Pages shown over the sheet, innermost last: { spec, inputs }.
    local pages = {}
    local root_inputs

    -- What the sheet shows now: the innermost page, else the sheet itself.
    local function current()
        local page = pages[#pages]
        if page then return page.spec, page.inputs end
        return opts, root_inputs
    end

    local function arm(sections, spec)
        if spec.auto_close then
            closeBeforeCallbacks(sections, function() window:close() end)
        end
    end
    arm(opts.sections, opts)

    local function buildContent(ctx)
        local spec, inputs = current()
        return buildScreen(ctx, spec.sections, inputs)
    end
    local function buildTop(ctx)
        return buildHeader(ctx, current(), window, #pages > 0)
    end
    local function buildBottom(ctx)
        local spec = current()
        return spec.footer and buildFooter(ctx, spec.footer) or nil
    end

    window = SUIWindow:new{
        name           = opts.name or "sui_win_action_sheet",
        no_titlebar    = true,
        auto_height    = true,
        -- The height is fitted again on every repaint: notes come and go,
        -- caller updates change the content, a flow shows pages.
        auto_height_per_page   = true,
        auto_height_per_screen = opts.flow or nil,
        width          = opts.width or (opts.fit_width and fitWidth(opts)) or SUIWindow.stackedWidth(),
        position       = "center",
        navpager_mode  = require("infra/sui_config").isNavpagerEnabled(),
        on_close       = function()
            if root_inputs then root_inputs:free() end
            if opts.on_close then opts.on_close() end
        end,
        on_dismiss     = opts.on_dismiss,
        dismissable    = opts.dismissable,
        screens        = { __root__ = buildContent, __page__ = buildContent },
        screen_headers = { __root__ = buildTop, __page__ = buildTop },
        screen_footers = { __root__ = buildBottom, __page__ = buildBottom },
    }
    root_inputs = createInputs(window, opts)

    function window:update(fields)
        local spec = current()
        if fields.sections then arm(fields.sections, spec) end
        for key, value in pairs(fields) do spec[key] = value end
        self:repaint()
    end

    -- Runs whenever a page is left, by going back or by closing the sheet.
    local function leave(page)
        pages[#pages] = nil
        if page.inputs then page.inputs:free() end
        local _spec, revealed = current()
        if revealed and window:isOpen() then revealed:adopt() end
    end

    function window:showPage(spec)
        local _spec, covered = current()
        if covered then covered:detach() end
        arm(spec.sections, spec)
        local page = { spec = spec, inputs = createInputs(self, spec) }
        pages[#pages + 1] = page
        self:push("__page__", { on_close = function() leave(page) end })
        if page.inputs then page.inputs:adopt() end
    end

    function window:closePage(levels)
        self:pop{ levels = levels }
    end

    function window:getFieldText(id)
        local _spec, inputs = current()
        return inputs.byId[id]:getText()
    end
    function window:setFieldText(id, text)
        local _spec, inputs = current()
        inputs.byId[id]:setText(text)
    end
    function window:focusField(id)
        local _spec, inputs = current()
        inputs:focus(inputs.byId[id])
    end

    window:show()
    if root_inputs then root_inputs:adopt() end

    -- While the keyboard is up, a tap that lands neither on it nor on an input
    -- only hides it, whatever lies under the finger: a button or row of the sheet
    -- is reached by the next tap. Once the keyboard is hidden, a tap outside the
    -- sheet dismisses it.
    local wrapper = window:getWidget()
    local handle  = wrapper.handleEvent
    function wrapper:handleEvent(event)
        local ges = event.handler == "onGesture" and event.args[1]
        if ges and ges.ges == "tap" then
            local _spec, inputs = current()
            local keyboard = inputs and inputs.current.keyboard
            if keyboard and keyboard:isVisible() and keyboard.dimen
                and ges.pos:notIntersectWith(keyboard.dimen) then
                local on_input = false
                for _i, input in ipairs(inputs.list) do
                    if input.dimen and ges.pos:intersectWith(input.dimen) then
                        on_input = true
                        break
                    end
                end
                if not on_input then
                    inputs:closeKeyboard()
                    return true
                end
            end
        end
        return handle(self, event)
    end
    return window
end

--- Shows `opts.items` as a chooser (see the header). Returns the SUIWindow.
function ActionSheet.pick(opts)
    local window
    local parent = opts.parent
    -- Leaves the chooser: closes the sheet, or its page and the `levels - 1`
    -- below it; `close_parent` closes the sheet that holds the page.
    local function leave()
        if not parent then
            window:close()
        elseif opts.close_parent then
            parent:close()
        else
            parent:closePage(opts.levels)
        end
    end
    -- Copies, so the caller's items keep their own callbacks.
    local items = {}
    for i, source in ipairs(opts.items) do
        local item, callback = {}, source.callback
        for key, value in pairs(source) do item[key] = value end
        item.callback = function()
            leave()
            if callback then callback() end
        end
        items[i] = item
    end
    if parent then
        parent:showPage{
            title    = opts.title,
            icon     = opts.icon,
            sections = { ActionSheet.list(items) },
        }
        return parent
    end
    window = ActionSheet.show{
        name      = opts.name,
        title     = opts.title,
        icon      = opts.icon,
        fit_width = opts.fit_width ~= false,
        on_dismiss = opts.on_cancel,
        sections  = { ActionSheet.list(items) },
    }
    return window
end

return ActionSheet
