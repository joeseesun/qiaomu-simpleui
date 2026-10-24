-- talk_window.lua — Simple UI
-- The conversation window of the Critter module: a bubble with the critter's
-- opening line, which takes the place of the module's bubble, and under it
-- (above it when there is no room below) a separate panel with the answers to
-- pick from. A "?" stands next to the critter's head while the window is open.
--
-- The window is a popup over the screen, anchored to the rectangle of the
-- module's bubble, and draws in the bubble's style: stepped blocks of one `unit`
-- (pixel_shapes.lua) or anti-aliased rounded boxes (smooth). A tap on an answer
-- picks it; a tap outside, the Back key, a suspend and a change of the screen
-- size close it. Without a touch screen the Up and Down keys move an inverted
-- bar with an arrow over the answers and Press picks the one it is on; with a
-- touch screen no answer is marked.
--
--   TalkWindow.open{
--       opener       = "Line of the critter", -- nil leaves the module's bubble as it is
--       options      = { { text = "...", on_pick = function() end }, ... },
--       other        = { text = "...", on_pick = function() end },  -- last row
--       anchor       = Geom,                  -- rectangle of the module's bubble
--       side         = "left" | "right",      -- where the critter stands
--       critter_rect = Geom,                  -- rectangle of the critter
--       style        = "pixel" | "smooth",    -- style of the bubble
--       unit         = 4,                     -- pixel size, in px
--       scale        = 1,                     -- size factor of the module
--       faces        = { message, message_bold,
--                        answer },             -- answer: face of the answers, else message
--   }
-- Returns the window; window:close() closes it.

local Device         = require("device")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local UIManager      = require("ui/uimanager")
local InputContainer = require("ui/widget/container/inputcontainer")

local AAPaint  = require("infra/sui_aa_paint")
local Bubble   = require("modules/critter/bubble")
local Shapes   = require("modules/critter/pixel_shapes")
local SUIStyle = require("features/sui_style")
local UI       = require("infra/sui_core")

local Screen = Device.screen

-- Metrics at 100% scale, in dp.
local ROW_PAD_DP  = 10   -- above and below the text of an answer
local ROW_MIN_DP  = 52   -- shortest answer row
local MARGIN_DP   = 8    -- kept free at the edges of the screen

-- Most lines the opening line and an answer take; longer text is cut with an ellipsis.
local OPENER_LINES = 3
local ANSWER_LINES = 3

local TalkWindow = {}

local function ceilTo(value, unit)
    return math.ceil(value / unit) * unit
end

-- Paints `rects` (relative to x, y) in `color`.
local function paintRects(bb, rects, x, y, color)
    for _i, r in ipairs(rects) do bb:paintRect(x + r.x, y + r.y, r.w, r.h, color) end
end

-- Paints the frame of the w x h box at x, y: in the pixel style the stepped
-- `shape` (nil for a box too small for its unit: a plain framed rectangle), in
-- the smooth style a rounded box.
local function paintFrame(bb, l, shape, x, y, w, h)
    local COLOR = SUIStyle.COLOR
    if not l.pixel then
        if not AAPaint.fillRoundedRect(bb, x, y, w, h, l.radius, COLOR.surface, 255) then
            bb:paintRect(x, y, w, h, COLOR.surface)
        end
        if not AAPaint.strokeRoundedRect(bb, x, y, w, h, l.radius, l.border, COLOR.text_primary) then
            bb:paintBorder(x, y, w, h, l.border, COLOR.text_primary)
        end
    elseif shape then
        local sx, sy = x + math.floor((w - shape.w) / 2), y + math.floor((h - shape.h) / 2)
        paintRects(bb, shape.fill, sx, sy, COLOR.surface)
        paintRects(bb, shape.border, sx, sy, COLOR.text_primary)
    else
        bb:paintRect(x, y, w, h, COLOR.surface)
        bb:paintBorder(x, y, w, h, l.border, COLOR.text_primary)
    end
end

-- Rectangle covering the rectangles `list`.
local function union(list)
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for _i, r in ipairs(list) do
        x1, y1 = math.min(x1, r.x), math.min(y1, r.y)
        x2, y2 = math.max(x2, r.x + r.w), math.max(y2, r.y + r.h)
    end
    return Geom:new{ x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

-- Text box for the conversation, drawn without a background so it reads over a
-- light or a dark row; text that needs more than `lines` lines is cut with an
-- ellipsis.
local function textBox(text, face, bold, width, color, lines)
    local args = { text = text, face = face, bold = bold, width = width, fgcolor = color, alignment = "left" }
    local box = UI.makeTextBox(args, true)
    local probe = UI.makeTextBox({ text = "Xg", face = face, bold = bold, width = width, fgcolor = color }, true)
    local max_h = lines * probe:getSize().h
    probe:free()
    if box:getSize().h <= max_h then return box end
    box:free()
    args.height = max_h
    args.height_overflow_show_ellipsis = true
    return UI.makeTextBox(args, true)
end

-- Function that paints the tail of the bubble, nil when it has none. The tail
-- stands where the module's own bubble has it, so it covers that one. `left` and
-- `right` are the x of the edges of the bubble frame.
local function tailPainter(l, o, reach, left, right)
    local COLOR = SUIStyle.COLOR
    if not o.side or reach == 0 then return nil end
    local anchor = o.anchor
    if not l.pixel then
        local tail = Bubble.smoothTail(anchor.h, reach, l.border, l.radius, o.side)
        if not tail then return nil end
        local x = o.side == "left" and left - reach or right - l.border
        return function(bb) tail:paintTo(bb, x, anchor.y) end
    end
    local unit = l.unit
    local steps, top = Shapes.tailRows(anchor.h, reach, unit)
    if not steps or not l.bubble_shape then return nil end
    local shape = Shapes.tail(steps, unit, o.side)
    local x = o.side == "left" and left - (steps - 1) * unit or right - unit
    return function(bb)
        paintRects(bb, shape.border, x, anchor.y + top, COLOR.text_primary)
        paintRects(bb, shape.fill, x, anchor.y + top, COLOR.surface)
    end
end

-- Everything the window paints, laid out for `opts` in screen coordinates.
local function layout(opts)
    local COLOR = SUIStyle.COLOR
    local unit, scale, faces = math.max(1, opts.unit or 1), opts.scale or 1, opts.faces
    local pixel = opts.style == "pixel"
    local border, pad, reach = Bubble.metrics(scale, opts.side ~= nil, opts.style, unit)
    local row_pad  = math.floor(Screen:scaleBySize(ROW_PAD_DP) * scale)
    local row_min  = math.floor(Screen:scaleBySize(ROW_MIN_DP) * scale)
    local margin   = Screen:scaleBySize(MARGIN_DP)
    local sep_h    = math.max(1, math.floor((pixel and unit or border) / 2))
    local box_x    = opts.anchor.x + (opts.side == "left" and reach or 0)
    local box_w    = opts.anchor.w - reach
    local inset    = border + pad                       -- from a box edge to its text
    local text_w   = box_w - 2 * inset
    local function fit(height) return pixel and ceilTo(height, unit) or height end

    local l = {
        pixel = pixel, unit = unit, border = border, pad = pad, inset = inset, faces = faces,
        radius = Bubble.radius(scale), sep_h = sep_h, box_x = box_x, box_w = box_w,
    }

    -- Bubble: the opening line, as the module's bubble shows its text. Without
    -- one the module's bubble stays and the window does not draw its own.
    l.opener    = opts.opener and textBox(opts.opener, faces.message, faces.message_bold, text_w,
                                          COLOR.text_primary, OPENER_LINES)
    l.content_h = l.opener and l.opener:getSize().h or 0
    l.bubble_y  = opts.anchor.y
    l.bubble_h  = l.opener and fit(math.max(opts.anchor.h, l.content_h + 2 * inset)) or opts.anchor.h
    l.bubble_shape = pixel and l.opener and Shapes.box(box_w, l.bubble_h, unit) or nil

    -- Panel: a row per answer, the last one the way to another phrase.
    local items = {}
    for _i, option in ipairs(opts.options) do items[#items + 1] = option end
    items[#items + 1] = opts.other
    local answer_face = faces.answer or faces.message
    l.answer_face = answer_face
    l.arrow = Shapes.glyph("arrow", math.max(1, math.floor(SUIStyle.faceHeight(answer_face) / 5)))
    l.row_w = text_w - l.arrow.w - pad
    l.rows = {}
    local rows_h = 0
    for i, item in ipairs(items) do
        local text = textBox(item.text, answer_face, false, l.row_w, COLOR.text_primary, ANSWER_LINES)
        local h = math.max(row_min, text:getSize().h + 2 * row_pad)
        l.rows[i] = { item = item, text = text, h = h, offset = rows_h }
        rows_h = rows_h + h + (i < #items and sep_h or 0)
    end
    l.panel_h = fit(rows_h + 2 * border)
    l.panel_shape = pixel and Shapes.box(box_w, l.panel_h, unit) or nil

    -- The panel stands apart from the bubble.
    local gap = math.max(2 * unit, pad)
    l.panel_y = Shapes.stack(l.bubble_y, l.bubble_h, l.panel_h, Screen:getHeight(), margin, gap)
    local rows_y = l.panel_y + border + math.floor((l.panel_h - 2 * border - rows_h) / 2)
    for _i, row in ipairs(l.rows) do
        row.rect = Geom:new{ x = box_x + border, y = rows_y + row.offset, w = box_w - 2 * border, h = row.h }
    end

    l.bubble_rect = Geom:new{ x = opts.anchor.x, y = l.bubble_y, w = opts.anchor.w, h = l.bubble_h }
    l.panel_rect  = Geom:new{ x = box_x, y = l.panel_y, w = box_w, h = l.panel_h }
    local covered = { l.panel_rect }
    if l.opener then covered[#covered + 1] = l.bubble_rect end

    -- Bubble tail, pointing at the critter. In the pixel style the shape is
    -- centred in the box, so the tail follows its edge.
    local shape_w = l.bubble_shape and l.bubble_shape.w or box_w
    local left = box_x + math.floor((box_w - shape_w) / 2)
    l.paint_tail = l.opener and tailPainter(l, opts, reach, left, left + shape_w) or nil

    -- "?" at the top right of the critter.
    if opts.critter_rect and opts.critter_rect.y >= 0 then
        local glyph = Shapes.glyph("question", math.max(1, unit))
        l.mark = { glyph = glyph, x = opts.critter_rect.x + opts.critter_rect.w - glyph.w, y = opts.critter_rect.y }
        covered[#covered + 1] = Geom:new{ x = l.mark.x, y = l.mark.y, w = glyph.w, h = glyph.h }
    end
    l.region = union(covered)
    return l
end

function TalkWindow.open(opts)
    local lay = layout(opts)
    local screen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local popup = InputContainer:new{ dimen = screen }
    popup.lay    = lay
    popup.focus  = Device:hasDPad() and 1 or nil
    popup.closed = false

    popup.ges_events = {
        TalkTap = { GestureRange:new{ ges = "tap", range = screen } },
    }

    function popup:close()
        if self.closed then return end
        self.closed = true
        UIManager:close(self)
    end

    local function pick(self, row)
        if self.closed then return end
        self:close()
        row.item.on_pick()
    end

    -- Picks the answer tapped; a tap on the bubble or the panel does nothing and
    -- one anywhere else closes the window.
    function popup:onTalkTap(_args, ges)
        for _i, row in ipairs(self.lay.rows) do
            if ges.pos:intersectWith(row.rect) then
                pick(self, row)
                return true
            end
        end
        if not (ges.pos:intersectWith(self.lay.bubble_rect) or ges.pos:intersectWith(self.lay.panel_rect)) then
            self:close()
        end
        return true
    end

    if Device:hasKeys() then
        popup.key_events = { Close = { { "Back" } } }
        if Device:hasDPad() then
            popup.key_events.TalkUp    = { { "Up" } }
            popup.key_events.TalkDown  = { { "Down" } }
            popup.key_events.TalkPress = { { "Press" } }
        end
    end

    function popup:onClose()
        self:close()
        return true
    end

    -- Moves the marked answer by `step`, repainting the panel.
    local function moveFocus(self, step)
        local row = self.lay.rows[self.focus]
        if row.inverted then row.inverted:free(); row.inverted = nil end
        self.focus = (self.focus - 1 + step) % #self.lay.rows + 1
        -- The smooth outline is translucent: repaint what lies under it first.
        UIManager:setDirty(self.lay.pixel and self or "all", function() return "ui", self.lay.panel_rect end)
    end

    function popup:onTalkUp()
        if self.focus then moveFocus(self, -1) end
        return true
    end

    function popup:onTalkDown()
        if self.focus then moveFocus(self, 1) end
        return true
    end

    function popup:onTalkPress()
        local row = self.focus and self.lay.rows[self.focus]
        if row then pick(self, row) end
        return true
    end

    -- A suspend or a change of the screen size leave the conversation behind.
    function popup:onSuspend() self:close() end
    function popup:onSetRotationMode() self:close() end
    function popup:onScreenResize() self:close() end

    function popup:paintTo(bb)
        local COLOR, l = SUIStyle.COLOR, self.lay

        -- Bubble: frame, tail and opening line.
        local text_x = l.box_x + l.inset
        if l.opener then
            paintFrame(bb, l, l.bubble_shape, l.box_x, l.bubble_y, l.box_w, l.bubble_h)
            if l.paint_tail then l.paint_tail(bb) end
            l.opener:paintTo(bb, text_x, l.bubble_y + math.floor((l.bubble_h - l.content_h) / 2))
        end

        -- Panel: the answers, the marked one inverted.
        paintFrame(bb, l, l.panel_shape, l.box_x, l.panel_y, l.box_w, l.panel_h)
        local answer_x = text_x + l.arrow.w + l.pad
        local bar_inset = math.floor(l.pad / 2)   -- of the marked bar and the lines, from the frame
        for i, row in ipairs(l.rows) do
            local rect, text = row.rect, row.text
            if self.focus == i then
                bb:paintRect(rect.x + bar_inset, rect.y, rect.w - 2 * bar_inset, rect.h, COLOR.text_primary)
                row.inverted = row.inverted
                    or textBox(row.item.text, l.answer_face, false, l.row_w, COLOR.surface, ANSWER_LINES)
                text = row.inverted
                paintRects(bb, l.arrow.rects, text_x, rect.y + math.floor((rect.h - l.arrow.h) / 2), COLOR.surface)
            end
            text:paintTo(bb, answer_x, rect.y + math.floor((rect.h - text:getSize().h) / 2))
            if i < #l.rows then
                bb:paintRect(rect.x + bar_inset, rect.y + rect.h, rect.w - 2 * bar_inset, l.sep_h, COLOR.text_dim)
            end
        end

        if l.mark then paintRects(bb, l.mark.glyph.rects, l.mark.x, l.mark.y, COLOR.text_primary) end
    end

    function popup:onCloseWidget()
        local l = self.lay
        if l.opener then l.opener:free() end
        for _i, row in ipairs(l.rows) do
            row.text:free()
            if row.inverted then row.inverted:free() end
        end
        UIManager:setDirty(nil, function() return "ui", l.region end)
    end

    UIManager:show(popup, "ui", lay.region)
    return popup
end

return TalkWindow
