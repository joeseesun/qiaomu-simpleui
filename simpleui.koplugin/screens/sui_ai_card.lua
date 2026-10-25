-- Bottom sheet for AI translation and word lookup results. Refreshes its
-- own area on show and flashes it away on close (e-ink).
local UIManager = require("ui/uimanager")
local _ = require("infra/sui_i18n").translate
local M = {}

--- `opts`: title, subtitle, text, buttons (rows of button specs), on_close.
function M.show(opts)
    local Screen = require("device").screen
    local Geom = require("ui/geometry")
    local Size = require("ui/size")
    local Font = require("ui/font")
    local Blitbuffer = require("ffi/blitbuffer")
    local GestureRange = require("ui/gesturerange")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local BottomContainer = require("ui/widget/container/bottomcontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local TextWidget = require("ui/widget/textwidget")
    local ScrollTextWidget = require("ui/widget/scrolltextwidget")
    local ButtonTable = require("ui/widget/buttontable")

    local w, h = Screen:getWidth(), Screen:getHeight()
    local inner = w - 2 * Size.padding.large
    local card = InputContainer:new{ covers_footer = true, dimen = Geom:new{ x = 0, y = 0, w = w, h = h } }
    local closed = false
    function card:dismiss()
        if closed then return end
        closed = true
        UIManager:close(self)
        if self.dismiss_callback then self.dismiss_callback() end
        if opts.on_close then opts.on_close() end
    end
    --- Closes without the cancel/close callbacks (the next card replaces it).
    function card:finish()
        if closed then return end
        closed = true
        UIManager:close(self)
    end

    local content = VerticalGroup:new{ align = "left" }
    local head = HorizontalGroup:new{ align = "center",
        TextWidget:new{ text = opts.title or "", face = Font:getFace("tfont", 22), bold = true, max_width = inner } }
    if opts.subtitle and opts.subtitle ~= "" then
        head[#head + 1] = HorizontalSpan:new{ width = Size.padding.large }
        head[#head + 1] = TextWidget:new{ text = opts.subtitle, face = Font:getFace("infont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = math.floor(inner / 2) }
    end
    content[#content + 1] = LeftContainer:new{ dimen = Geom:new{ w = inner, h = Screen:scaleBySize(36) }, head }
    content[#content + 1] = VerticalSpan:new{ width = Size.padding.default }
    local face = Font:getFace("cfont", 19)
    local probe = require("ui/widget/textboxwidget"):new{ text = opts.text or "", face = face, width = inner }
    local full_h = probe:getSize().h
    local text_h = math.min(full_h, math.floor(h * 0.55))
    probe:free()
    content[#content + 1] = ScrollTextWidget:new{ text = opts.text or "", face = face, width = inner,
        height = math.max(text_h, Screen:scaleBySize(40)), dialog = card }
    if full_h > text_h then
        -- Longer text pages inside the card; say so, since e-ink has no scroll hint.
        content[#content + 1] = TextWidget:new{ text = _("Swipe up for more"), face = Font:getFace("infont", 15),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = inner }
    end
    if opts.buttons and #opts.buttons > 0 then
        content[#content + 1] = VerticalSpan:new{ width = Size.padding.large }
        content[#content + 1] = ButtonTable:new{ width = inner, buttons = opts.buttons, zero_sep = true, show_parent = card }
    end
    local frame = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
        radius = 0, padding = Size.padding.large, content }
    card[1] = BottomContainer:new{ dimen = Geom:new{ w = w, h = h }, frame }
    card.ges_events = { TapClose = { GestureRange:new{ ges = "tap", range = card.dimen } } }
    function card:onTapClose(_, ges)
        if frame.dimen and ges.pos:notIntersectWith(frame.dimen) then self:dismiss() end
        return true
    end
    function card:onClose() self:dismiss(); return true end
    function card:onShow() UIManager:setDirty(self, function() return "ui", frame.dimen end) end
    function card:onCloseWidget() UIManager:setDirty(nil, function() return "flashui", frame.dimen end) end
    UIManager:show(card)
    return card
end

--- A card that only says what is happening; tapping outside cancels.
function M.loading(title, on_cancel)
    return M.show{ title = title, text = _("Asking AI… Tap outside to cancel."), on_close = on_cancel }
end

return M
