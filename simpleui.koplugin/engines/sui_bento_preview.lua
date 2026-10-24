-- sui_bento_preview.lua — Simple UI
-- Row preview of the placement sheets: the row of cards as it will render,
-- and under it one line with the row position at the reading start and the
-- last adjustment at the far end (cut with an ellipsis, mirrored in RTL).
--
--   BentoPreview.build(ctx, row, row_text, notice) -> widget
--       ctx        the `build` context of an ActionSheet "widget" section
--       row        table     options of SUIWindow.BentoRow, without `inner_w`
--       row_text   string    e.g. "Row 1 of 2"
--       notice     string?   what the last change adjusted

local BD              = require("ui/bidi")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local SUIWindow       = require("engines/sui_window")
local SUIStyle        = require("features/sui_style")
local Screen          = Device.screen

local BentoPreview = {}

function BentoPreview.build(ctx, row, row_text, notice)
    row.inner_w = ctx.inner_w
    local strip, strip_h = SUIWindow.BentoRow(row)
    local face = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_CAPTION))
    local function caption(text, max_width)
        return TextWidget:new{
            text      = text,
            face      = face,
            fgcolor   = SUIStyle.COLOR.text,
            max_width = max_width,
        }
    end
    local row_label = caption(row_text, ctx.inner_w)
    local row_w = row_label:getSize().w
    local gap = ctx.SZ(Screen:scaleBySize(12))
    local notice_label, notice_w
    if notice and ctx.inner_w - row_w - gap > 0 then
        notice_label = caption(notice, ctx.inner_w - row_w - gap)
        notice_w = notice_label:getSize().w
    end
    local start_w = notice_label and (ctx.inner_w - row_w - notice_w) or (ctx.inner_w - row_w)
    local labels = HorizontalGroup:new{ align = "center" }
    if BD.mirroredUILayout() then
        labels[1] = HorizontalSpan:new{ width = start_w }
        labels[2] = row_label
        if notice_label then labels[1], labels[2], labels[3] = notice_label, labels[1], row_label end
    else
        labels[1] = row_label
        if notice_label then labels[2], labels[3] = HorizontalSpan:new{ width = start_w }, notice_label end
    end
    return VerticalGroup:new{
        align = "left",
        CenterContainer:new{ dimen = Geom:new{ w = ctx.inner_w, h = strip_h }, strip },
        VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(6)) },
        labels,
    }
end

return BentoPreview
