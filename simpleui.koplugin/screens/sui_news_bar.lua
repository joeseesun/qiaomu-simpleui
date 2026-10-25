-- Bottom reading bar for news articles in KOReader's reader: previous/next
-- article, list, typography card and save. Books keep the native panel.
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local _ = require("infra/sui_i18n").translate
local M = {}

-- Line spacing applies on top of the EPUB's CJK line-height baseline.
M.LINE_SPACING = { { _("Tight"), 90 }, { _("Standard"), 100 }, { _("Relaxed"), 115 }, { _("Spacious"), 130 } }
M.MARGINS = { { _("Narrow"), 10 }, { _("Medium"), 25 }, { _("Wide"), 50 } }
-- The open-source CJK fonts installed with Qiaomu SimpleUI, by their real names.
local FONTS = { { _("Zhuque Fangsong"), "Zhuque" }, { _("LXGW WenKai"), "WenKai" },
    { _("Source Han Serif"), "Serif CJK" }, { _("Source Han Sans"), "Sans CJK" } }

--- Typography faces available on this device, in display order.
function M.fonts()
    local ok, faces = pcall(function() return require("document/credocument"):engineInit().getFontFaces() end)
    local result = {}
    for _, font in ipairs(FONTS) do
        for _, face in ipairs(ok and faces or {}) do
            if face:find(font[2], 1, true) then result[#result + 1] = { label = font[1], face = face }; break end
        end
    end
    return result
end

--- Applies one typography change through KOReader's own reader events.
function M.apply(ui, kind, value)
    require("logger").info("simpleui news-bar: apply", kind, value)
    local configurable = ui.document.configurable
    if kind == "font" then
        ui:handleEvent(Event:new("SetFont", value))
    elseif kind == "size" then
        ui:handleEvent(Event:new("SetFontSize", value))
    elseif kind == "line" then
        ui:handleEvent(Event:new("SetLineSpace", value))
    elseif kind == "margin" then
        -- The margin event does not record itself in the document options.
        configurable.h_page_margins = { value, value }
        ui:handleEvent(Event:new("SetPageHorizMargins", { value, value }))
    end
end

--- `ctx`: title(entry), prev, next, starred(), toggleStar(), open(entry), back(), more()
function M.show(ui, ctx, expanded)
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
    local ButtonTable = require("ui/widget/buttontable")
    local TextWidget = require("ui/widget/textwidget")

    local width = Screen:getWidth()
    local bar = InputContainer:new{ covers_footer = true,
        dimen = Geom:new{ x = 0, y = 0, w = width, h = Screen:getHeight() } }
    local inner = width - 2 * Size.padding.large
    local function close() UIManager:close(bar) end
    local function go(fn) return function() close(); fn() end end
    local function reshow() close(); M.show(ui, ctx, true) end
    local function set(kind, value) return function() M.apply(ui, kind, value); reshow() end end

    local rows = {}
    -- A disabled leading cell labels each typography row.
    local function label(text) return { text = text, enabled = false } end
    if expanded then
        local configurable = ui.document.configurable
        local fonts = { label(_("Font")) }
        for _, font in ipairs(M.fonts()) do
            fonts[#fonts + 1] = { text = font.label, callback = set("font", font.face),
                checked_func = function() return ui.font and ui.font.font_face == font.face end }
        end
        if #fonts > 1 then rows[#rows + 1] = fonts end
        local size = tonumber(configurable.font_size) or 22
        rows[#rows + 1] = {
            label(_("Font size")),
            { text = "A−", callback = set("size", size - 1) },
            { text = string.format("%g", size), enabled = false },
            { text = "A+", callback = set("size", size + 1) },
        }
        local line = { label(_("Line spacing")) }
        for _, item in ipairs(M.LINE_SPACING) do
            line[#line + 1] = { text = item[1], callback = set("line", item[2]),
                checked_func = function() return configurable.line_spacing == item[2] end }
        end
        rows[#rows + 1] = line
        local margins = { label(_("Margins")) }
        for _, item in ipairs(M.MARGINS) do
            margins[#margins + 1] = { text = item[1], callback = set("margin", item[2]),
                checked_func = function()
                    -- Mark the preset nearest to the current margin.
                    local m = type(configurable.h_page_margins) == "table" and configurable.h_page_margins[1]
                    if not m then return false end
                    local best, gap = nil, math.huge
                    for _, preset in ipairs(M.MARGINS) do
                        if math.abs(preset[2] - m) < gap then best, gap = preset[2], math.abs(preset[2] - m) end
                    end
                    return best == item[2]
                end }
        end
        rows[#rows + 1] = margins
        rows[#rows + 1] = {{ text = _("More settings…"), callback = go(ctx.more) }}
    end
    rows[#rows + 1] = {
        { text = "‹ " .. _("Previous article"), enabled = ctx.prev ~= nil, callback = go(function() ctx.open(ctx.prev) end),
          hold_callback = ctx.prev and function() ctx.notify(ctx.title(ctx.prev)) end },
        { text = _("List"), callback = go(ctx.back) },
        { text = "Aa", font_bold = expanded, callback = expanded and close or reshow },
        { text = "AI", callback = go(ctx.ai) },
        { text = ctx.starred() and "★" or "☆", callback = function() ctx.toggleStar(); close(); M.show(ui, ctx, expanded) end },
        { text = _("Next article") .. " ›", enabled = ctx.next ~= nil, callback = go(function() ctx.open(ctx.next) end),
          hold_callback = ctx.next and function() ctx.notify(ctx.title(ctx.next)) end },
    }

    local content = VerticalGroup:new{ align = "left" }
    if ctx.next then
        content[#content + 1] = LeftContainer:new{
            dimen = Geom:new{ w = inner, h = Screen:scaleBySize(28) },
            TextWidget:new{ text = _("Next article") .. "：" .. ctx.title(ctx.next),
                face = Font:getFace("smallinfofont", 15), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = inner },
        }
        content[#content + 1] = VerticalSpan:new{ width = Size.padding.small }
    end
    content[#content + 1] = ButtonTable:new{ width = inner, buttons = rows, zero_sep = true, show_parent = bar }
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window, radius = 0,
        padding = Size.padding.large, padding_bottom = Size.padding.large,
        content,
    }
    bar[1] = BottomContainer:new{ dimen = Geom:new{ w = width, h = Screen:getHeight() }, frame }
    bar.ges_events = { TapClose = { GestureRange:new{ ges = "tap", range = bar.dimen } } }
    function bar:onTapClose(_, ges)
        if frame.dimen and ges.pos:notIntersectWith(frame.dimen) then close() end
        return true
    end
    -- E-ink only updates regions that are explicitly refreshed: refresh the
    -- whole card when shown, and flash its area away when closed.
    function bar:onShow()
        UIManager:setDirty(self, function() return "ui", frame.dimen end)
    end
    function bar:onCloseWidget()
        UIManager:setDirty(nil, function() return "flashui", frame.dimen end)
    end
    require("logger").info("simpleui news-bar: shown", expanded and "typography" or "bar", "rows=", #rows)
    UIManager:show(bar)
    return bar
end

return M
