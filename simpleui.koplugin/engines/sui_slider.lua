-- sui_slider.lua — Simple UI
-- Horizontal slider with a hollow round knob and the value above it, drawn with
-- anti-aliased shapes, plus a caption line that can repaint itself without
-- redrawing its parent and the controls that sit beside the slider.
--
-- Usage:
--   local slider = SUISlider:new{
--       width      = px,
--       height     = px,        -- height of the bar row; the knob and the bars are sized from it
--       min        = number,
--       max        = number,
--       value      = number,
--       step       = number,    -- optional; a tap or drag picks values min + k * step
--       format     = function(value) -> string,   -- optional; text shown above the knob
--       face       = face,      -- font of the value shown above the knob
--       bold       = bool,      -- emboldens a face without a bold file
--       on_change  = function(value, dragging) end,  -- a tap, drag or flick picked a new value
--       on_release = function() end,                 -- a drag ended
--   }
--   slider:setValue(v)   -- clamps and rounds; does not fire on_change
--   slider:moveTo(v)     -- as setValue, then repaints the slider on screen
--   slider:getValue()
--
-- The slider handles its own tap, drag and flick gestures. While a drag is in
-- progress it paints itself straight onto the screen buffer and queues a fast
-- refresh of the strip the knob crossed, so no parent widget is redrawn per
-- move. A drag starts on the slider and moves horizontally; any other gesture
-- is left to the parent.
--
--   local caption = SUISlider.Caption:new{
--       name = "", value = "", width = px, gap = px,   -- the value follows the name, left-aligned
--       name_face = face,  name_bold = bool,
--       value_face = face, value_bold = bool,          -- omitted: the caption is the name only
--   }
--   caption:setValue(text)
--   caption:refresh(refresh_type)   -- repaint the caption on its own (a name-only caption stays as is)
--
-- A control sits beside the slider, for example a step button. Its content is
-- a drawn symbol:
--
--   local control = SUISlider.Control:new{
--       symbol   = "minus" | "plus",
--       height   = px,                  -- height of the tap area; the symbol is sized from it
--       inset    = px,                  -- tap area added around the content, on the sides facing the slider
--       edge     = "left" | "right",    -- row end the content is flush with; omitted between two widgets
--       radius   = px,                  -- corner radius of the focus frame
--       callback = function() end,
--       hold_callback = function() end,  -- optional; a long press
--   }
--   control:activate()   -- runs the callback after the press feedback
--
-- A control takes part in a focus manager's layout: it shows a frame around
-- its symbol while it has the focus (the Focus and Unfocus events), and a
-- Press on it is a tap at the centre of its tap area. A host with its own
-- focus ring sets `control.focused` when it builds the control.
--
-- A slider row is a minus control, the slider and a plus control side by side:
--
--   local controls = SUISlider.stepControls({ minus = fn, plus = fn,
--                        minus_hold = fn, plus_hold = fn }, scale)  -- scale(dp) -> px, optional
--   local bar_w = SUISlider.barWidth(width, controls)
--   local row   = SUISlider.row(controls, slider)

local Device         = require("device")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local InputContainer   = require("ui/widget/container/inputcontainer")
local Math           = require("optmath")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local Widget         = require("ui/widget/widget")
local AAPaint        = require("infra/sui_aa_paint")
local SUIStyle       = require("features/sui_style")
local UI             = require("infra/sui_core")
local Screen         = Device.screen

local KNOB_PCT  = 0.7    -- knob diameter, relative to the slider height
local TRACK_PCT = 0.1    -- track thickness, relative to the slider height
local FILL_PCT  = 0.2    -- filled part thickness, relative to the slider height
local DIAGONAL  = 0.7071 -- horizontal share of a diagonal gesture

-- Horizontal share of each gesture direction. Vertical directions are absent:
-- they never start a drag or a flick.
local DIRECTION_DX = {
    east      = 1,
    west      = -1,
    northeast = DIAGONAL,
    southeast = DIAGONAL,
    northwest = -DIAGONAL,
    southwest = -DIAGONAL,
}

-- Fills a pill of thickness `h` whose left end is at `x` and whose vertical
-- centre is `cy`.
local function fillPill(bb, x, cy, w, h, color)
    AAPaint.fillPill(bb, x, cy - math.floor(h / 2), w, h, color, 255)
end

local function fillCircle(bb, cx, cy, r, color)
    AAPaint.fillPill(bb, cx - r, cy - r, r * 2, r * 2, color, 255)
end

-- ---------------------------------------------------------------------------
-- Slider
-- ---------------------------------------------------------------------------

local SUISlider = InputContainer:extend{
    width  = 0,
    height = 0,
    min    = 0,
    max    = 100,
    value  = 0,
    format = tostring,
}

function SUISlider:init()
    self.knob_r  = math.max(2, math.floor(self.height * KNOB_PCT / 2))
    self.ring    = math.max(1, Screen:scaleBySize(1))
    self.track_h = math.max(2, math.floor(self.height * TRACK_PCT))
    self.fill_h  = math.max(self.track_h, math.floor(self.height * FILL_PCT))
    self._value  = self:_clamp(self.value)
    self:_initValueLabel()
    self.dimen   = Geom:new{ w = self.width, h = self.bar_top + self.height }

    -- Drags can leave the slider's own area, so the gestures that continue
    -- or end one are matched on the whole screen.
    local screen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events.TapSlider = {
        GestureRange:new{ ges = "tap", range = function() return self.dimen end },
    }
    self.ges_events.PanSlider = { GestureRange:new{ ges = "pan", range = screen } }
    self.ges_events.PanReleaseSlider = { GestureRange:new{ ges = "pan_release", range = screen } }
    self.ges_events.SwipeSlider = { GestureRange:new{ ges = "swipe", range = screen } }
    self.ges_events.MultiSwipeSlider = { GestureRange:new{ ges = "multiswipe", range = screen } }
end

-- Sets up the value shown above the knob. `bar_top` is the room it takes above
-- the bar; the knob travels in the row below it.
function SUISlider:_initValueLabel()
    -- The longest value fixes the room reserved and the margin to repaint.
    local longest = self.format(self.max)
    local shortest = self.format(self.min)
    if #shortest > #longest then longest = shortest end
    self.label = TextWidget:new{ text = longest, face = self.face, bold = self.bold }
    local size = self.label:getSize()
    self.label_w = size.w
    self.bar_top = size.h + math.max(1, Screen:scaleBySize(2))
end

function SUISlider:_clamp(value)
    return math.max(self.min, math.min(self.max, Math.round(value)))
end

function SUISlider:getValue()
    return self._value
end

function SUISlider:setValue(value)
    self._value = self:_clamp(value)
end

-- Sets the value and repaints the strip between the previous and the new knob
-- position. Does not fire on_change.
function SUISlider:moveTo(value)
    value = self:_clamp(value)
    if value == self._value then return end
    local prev_knob_x = self.dimen.x + self:_knobOffset()
    self._value = value
    self:_repaint(prev_knob_x, "ui")
end

function SUISlider:getSize()
    return self.dimen
end

-- ---------------------------------------------------------------------------
-- Geometry
-- The knob centre travels between one knob radius from each end.
-- ---------------------------------------------------------------------------

-- Distance of the knob centre from the left edge.
function SUISlider:_knobOffset()
    local range = self.max - self.min
    local frac  = range > 0 and (self._value - self.min) / range or 0
    return self.knob_r + math.floor(frac * (self.width - 2 * self.knob_r) + 0.5)
end

-- Value under the screen position `abs_x`, on the step grid when there is one.
function SUISlider:_valueAt(abs_x)
    local span = self.width - 2 * self.knob_r
    local frac = span > 0 and (abs_x - self.dimen.x - self.knob_r) / span or 0
    local value = self.min + math.max(0, math.min(1, frac)) * (self.max - self.min)
    if self.step and self.step > 1 then
        value = self.min + Math.round((value - self.min) / self.step) * self.step
    end
    return self:_clamp(value)
end

-- ---------------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------------

-- Hollow knob centred on (cx, cy): a ring around the surface, which hides the
-- track beneath it.
function SUISlider:_paintKnob(bb, cx, cy)
    fillCircle(bb, cx, cy, self.knob_r, SUIStyle.accent())
    fillCircle(bb, cx, cy, self.knob_r - self.ring, SUIStyle.COLOR.surface)
end

-- Value above the knob at `knob_x`, kept within the slider's width.
function SUISlider:_paintValue(bb, x, y, knob_x)
    local text = self.format(self._value)
    if self.label.text ~= text then self.label:setText(text) end
    local w = self.label:getSize().w
    self.label:paintTo(bb, math.max(x, math.min(x + self.width - w, knob_x - math.floor(w / 2))), y)
end

function SUISlider:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local cy     = y + self.bar_top + math.floor(self.height / 2)
    local knob_x = x + self:_knobOffset()

    bb:paintRect(x, y, self.width, self.dimen.h, SUIStyle.COLOR.surface)
    fillPill(bb, x, cy, self.width, self.track_h, SUIStyle.COLOR.track)
    fillPill(bb, x, cy, knob_x - x, self.fill_h, SUIStyle.accent())
    self:_paintKnob(bb, knob_x, cy)
    self:_paintValue(bb, x, y, knob_x)
end

function SUISlider:free()
    self.label:free()
end

-- Paints the slider onto the screen buffer and queues a `refresh_type`
-- refresh of the strip between the previous and the current knob position.
function SUISlider:_repaint(prev_knob_x, refresh_type)
    self:paintTo(Screen.bb, self.dimen.x, self.dimen.y)
    local cur_knob_x = self.dimen.x + self:_knobOffset()
    local pad = math.max(self.knob_r, math.ceil(self.label_w / 2)) + 1
    local x0 = math.max(self.dimen.x, math.min(prev_knob_x, cur_knob_x) - pad)
    local x1 = math.min(self.dimen.x + self.width, math.max(prev_knob_x, cur_knob_x) + pad)
    UIManager:setDirty(nil, refresh_type, Geom:new{
        x = x0, y = self.dimen.y, w = x1 - x0, h = self.dimen.h,
    })
end

-- ---------------------------------------------------------------------------
-- Gestures
-- Each handler returns true when it consumed the gesture.
-- ---------------------------------------------------------------------------

-- Moves the knob to the value under `abs_x` and fires on_change when the
-- value differs. Drag moves refresh fast; any other pick refreshes normally.
function SUISlider:_pick(abs_x, dragging)
    local value = self:_valueAt(abs_x)
    if value == self._value then return end
    local prev_knob_x = self.dimen.x + self:_knobOffset()
    self._value = value
    self:_repaint(prev_knob_x, dragging and "fast" or "ui")
    if self.on_change then self.on_change(value, dragging) end
end

-- Ends a drag in progress. Returns true when there was one.
function SUISlider:_endDrag()
    if not self.dragging then return false end
    self.dragging = false
    UIManager:setDirty(nil, "ui", self.dimen)
    if self.on_release then self.on_release() end
    return true
end

-- True when a gesture of `direction` starting at `pos` begins on the slider
-- and moves horizontally.
function SUISlider:_startsOnSlider(pos, direction)
    return DIRECTION_DX[direction] ~= nil and pos:intersectWith(self.dimen)
end

function SUISlider:onTapSlider(_arg, ges)
    self:_pick(ges.pos.x, false)
    return true
end

function SUISlider:onPanSlider(_arg, ges)
    if not self.dragging then
        if not self:_startsOnSlider(ges.pos, ges.direction) then return false end
        self.dragging = true
    end
    self:_pick(ges.pos.x, true)
    return true
end

function SUISlider:onPanReleaseSlider(_arg, ges)
    if not self.dragging then return false end
    self:_pick(ges.pos.x, true)
    return self:_endDrag()
end

-- A flick ends a drag in progress, or, when no drag preceded it, picks the
-- value under its end point. A swipe reports its start and its length.
function SUISlider:onSwipeSlider(_arg, ges)
    if self.dragging then return self:_endDrag() end
    if not self:_startsOnSlider(ges.pos, ges.direction) then return false end
    self:_pick(ges.pos.x + DIRECTION_DX[ges.direction] * (ges.distance or 0), false)
    return true
end

function SUISlider:onMultiSwipeSlider()
    return self:_endDrag()
end

-- ---------------------------------------------------------------------------
-- Control
-- A tappable symbol, centred on the slider's axis and flush with the
-- row end named by `edge`; the tap area extends by `inset` on the other sides,
-- so the control is easy to hit without moving its content off the edge.
-- ---------------------------------------------------------------------------

local SYMBOL_PCT = 0.32  -- symbol length, relative to the control height
local STROKE_PCT = 0.08  -- symbol stroke, relative to the control height

-- Symbols, drawn with their left end at `x` and centred on `cy`.
local SYMBOLS = {
    minus = function(bb, x, cy, len, stroke, color)
        fillPill(bb, x, cy, len, stroke, color)
    end,
    plus = function(bb, x, cy, len, stroke, color)
        fillPill(bb, x, cy, len, stroke, color)
        AAPaint.fillPill(bb, x + math.floor(len / 2) - math.floor(stroke / 2), cy - math.floor(len / 2),
            stroke, len, color, 255)
    end,
}

-- Odd sizes keep a symbol centred on one pixel row and column.
local function odd(n)
    return n % 2 == 0 and n + 1 or n
end

-- Content of a control: its width and a `paint(bb, x, y)` of the content in a
-- row `height` tall whose top is `y`.
local function symbolContent(symbol, height)
    local len    = odd(Math.round(height * SYMBOL_PCT))
    local stroke = odd(math.max(1, Math.round(height * STROKE_PCT)))
    return {
        w     = len,
        paint = function(bb, x, y)
            SYMBOLS[symbol](bb, x, y + math.floor(height / 2), len, stroke, SUIStyle.COLOR.text_primary)
        end,
    }
end

local Control = InputContainer:extend{
    height  = 0,
    inset   = 0,
    radius  = 0,
    focused = false,
}

function Control:init()
    self.content = symbolContent(self.symbol, self.height)
    self.content_x = self.edge == "left" and 0 or self.inset
    local trailing = self.edge == "right" and 0 or self.inset
    self.dimen = Geom:new{ w = self.content_x + self.content.w + trailing, h = self.height }
    -- Press feedback: a square centred on the symbol, whatever the tap area.
    local side = 2 * self.content.w + 1
    self.flash = { dimen = Geom:new{ w = side, h = side } }
    self.ges_events.TapControl = {
        GestureRange:new{ ges = "tap", range = function() return self.dimen end },
    }
    if self.hold_callback then
        self.ges_events.HoldControl = {
            GestureRange:new{ ges = "hold", range = function() return self.dimen end },
        }
    end
end

function Control:getSize()
    return self.dimen
end

function Control:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local reach = self.content.w
    self.flash.dimen.x = x + self.content_x + math.floor(reach / 2) - reach
    self.flash.dimen.y = y + math.floor(self.height / 2) - reach
    self.content.paint(bb, x + self.content_x, y)
    if self.focused then
        local box = self.flash.dimen
        AAPaint.strokeRoundedRect(bb, box.x, box.y, box.w, box.h, self.radius,
            SUIStyle.BORDER_SZ * 2, SUIStyle.COLOR.text_primary)
    end
end

function Control:onFocus()
    self.focused = true
    return true
end

function Control:onUnfocus()
    self.focused = false
    return true
end

-- Inverts the area around the symbol for one refresh, then runs the callback.
function Control:activate()
    UI.runWithTapFeedback(self.flash, self.callback)
end

function Control:onTapControl()
    self:activate()
    return true
end

function Control:onHoldControl()
    UI.runWithTapFeedback(self.flash, self.hold_callback)
    return true
end

SUISlider.Control = Control

-- ---------------------------------------------------------------------------
-- Row
-- Drawn symbols flush with the ends of the row, around the slider. The tap
-- areas of the controls fill the spaces between the visible items, which are
-- all twice ROW_SPACE_DP.
-- ---------------------------------------------------------------------------

local ROW_HEIGHT_DP = 36  -- height of the slider row
local ROW_SPACE_DP  = 10  -- tap area a control adds beside its content, and gap before the slider
local FOCUS_RADIUS_DP = 6 -- corner radius of the frame around a focused control

--- The minus and plus controls of a slider row, with the `gap` kept between
--- them and the slider, the `height` of the row and `value_on_bar`, as the
--- slider carries its value above it. `actions` holds `minus`
--- and `plus`, and optionally `minus_hold` and `plus_hold` for a long press.
--- `scale(dp)` converts the base metrics to pixels (default: Screen:scaleBySize).
function SUISlider.stepControls(actions, scale)
    scale = scale or function(dp) return Screen:scaleBySize(dp) end
    local space  = scale(ROW_SPACE_DP)
    local height = scale(ROW_HEIGHT_DP)
    local radius = scale(FOCUS_RADIUS_DP)
    local function control(symbol, edge, callback, hold_callback)
        return Control:new{
            symbol        = symbol,
            edge          = edge,
            height        = height,
            inset         = space,
            radius        = radius,
            callback      = callback,
            hold_callback = hold_callback,
        }
    end
    return {
        minus   = control("minus", "left", actions.minus, actions.minus_hold),
        plus    = control("plus", "right", actions.plus, actions.plus_hold),
        gap          = space,
        top_gap      = 0,
        height       = height,
        value_on_bar = true,
    }
end

--- Width left for the slider in a row `width` wide with `controls`: the
--- minus and plus controls and, when present, a `top` control.
function SUISlider.barWidth(width, controls)
    local bar_w = width - 2 * controls.gap
        - controls.minus:getSize().w - controls.plus:getSize().w
    if controls.top then bar_w = bar_w - controls.top_gap - controls.top:getSize().w end
    return bar_w
end

--- The row: minus, `bar`, plus and, when present, the top control. A bar that
--- carries its value above it (`controls.value_on_bar`) is taller than the
--- controls, which sit on its bottom line.
function SUISlider.row(controls, bar)
    local function span(w) return HorizontalSpan:new{ width = w } end
    local row = HorizontalGroup:new{
        align = controls.value_on_bar and "bottom" or "center",
        controls.minus,
        span(controls.gap),
        bar,
        span(controls.gap),
        controls.plus,
    }
    if controls.top then
        table.insert(row, span(controls.top_gap))
        table.insert(row, controls.top)
    end
    return row
end

-- ---------------------------------------------------------------------------
-- Caption
-- A name followed by its value, left-aligned. The value is the part that
-- changes while the slider moves.
-- ---------------------------------------------------------------------------

local Caption = Widget:extend{
    name  = "",
    value = "",
    width = 0,
    gap   = 0,
}

function Caption:init()
    self.name_label = TextWidget:new{
        text      = self.name,
        face      = self.name_face,
        bold      = self.name_bold,
        max_width = self.width,
    }
    local height = self.name_label:getSize().h
    if self.value_face then
        self.value_label = TextWidget:new{
            text    = self.value,
            face    = self.value_face,
            bold    = self.value_bold,
        }
        height = math.max(height, self.value_label:getSize().h)
    end
    self.dimen = Geom:new{ w = self.width, h = height }
end

function Caption:getSize()
    return self.dimen
end

function Caption:setValue(value)
    if self.value_label then self.value_label:setText(value) end
end

function Caption:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.name_label:paintTo(bb, x, y)
    if self.value_label then
        self.value_label:paintTo(bb, x + self.name_label:getSize().w + self.gap, y)
    end
end

-- Repaints the caption onto the screen buffer and queues a `refresh_type`
-- refresh of its area (normal when omitted). A caption without a value never
-- changes, so it is left alone.
function Caption:refresh(refresh_type)
    if not self.value_label then return end
    local d = self.dimen
    Screen.bb:paintRect(d.x, d.y, d.w, d.h, SUIStyle.COLOR.surface)
    self:paintTo(Screen.bb, d.x, d.y)
    UIManager:setDirty(nil, refresh_type or "ui", d)
end

function Caption:free()
    self.name_label:free()
    if self.value_label then self.value_label:free() end
end

SUISlider.Caption = Caption

return SUISlider
