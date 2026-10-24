-- sui_insights_charts.lua — Simple UI
-- Chart sections of the Reading Insights window, each the title, icon and content
-- of a card: this week against last week, the days of the month, the calendar of
-- reading days and, as separate sections, the hour of the day, the day of the
-- week and the part of the day of the reading.
-- Built from the chart data of the stats provider (SP.getChartData) with the
-- shared bar, heatmap and share-bar charts.
--
-- Usage:
--   local sections = InsightsCharts.sections{
--       inner_w = w, avail_h = h, SZ = ctx.SZ, charts = SP.getChartData(conn),
--       fmt_time = function(secs) return "1h 20m" end,
--   }
--   -- sections.week / .month / .activity / .hours / .weekdays / .dayparts:
--   -- { title =, icon =, content = } or nil; `inner_w` is the width of a card's content

local CenterContainer = require("ui/widget/container/centercontainer")
local Charts          = require("engines/sui_stats_charts")
local DateNames       = require("infra/sui_datenames")
local Device          = require("device")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local HD              = require("engines/sui_heatmap_data")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local SUIStyle        = require("features/sui_style")
local UI              = require("infra/sui_core")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _               = require("infra/sui_i18n").translate
local N_              = require("infra/sui_i18n").ngettext

local InsightsCharts = {}

local BAR_H_PCT   = 0.16  -- height of a bar chart, relative to the content height
local HEAT_H_PCT  = 0.32  -- height of the calendar, relative to the content height

-- Short weekday names, Monday first.
local function weekdayLabels()
    local names, labels = DateNames.weekdayShort(), {}
    for i = 1, 7 do labels[i] = names[i % 7 + 1] end
    return labels
end

function InsightsCharts.sections(opts)
    local charts, inner_w, avail_h, SZ = opts.charts, opts.inner_w, opts.avail_h, opts.SZ
    if not (charts and charts.days and charts.week) then return {} end

    local color    = SUIStyle.COLOR.text_primary
    local ink      = SUIStyle.accent(color)  -- bars, calendar and share bar
    local face_lbl = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_CAPTION - 2))
    local face_cap = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_DETAIL))
    local lbl_h    = face_lbl.size + SZ(Screen:scaleBySize(2))
    local bar_h    = math.max(SZ(Screen:scaleBySize(40)),
                         math.min(SZ(Screen:scaleBySize(90)), math.floor(avail_h * BAR_H_PCT)))
    local now      = os.time()
    local today    = os.date("*t", now)

    local function space(px)
        return VerticalSpan:new{ width = SZ(Screen:scaleBySize(px)) }
    end

    local function caption(text, bold)
        return UI.makeColoredText{
            text = text, face = face_cap, fgcolor = UI.CLR_TEXT_SUB, bold = bold,
            max_width = inner_w, truncate_with_ellipsis = true,
        }
    end

    local function centered(widget)
        return CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = widget:getSize().h }, widget }
    end

    -- A bar chart centred in the content width, or nil when it does not fit.
    -- `o` holds what Charts.bars takes besides the sizes; `max_bar_w` caps the width of a bar.
    local function barChart(o, max_bar_w)
        local bar_w, gap = Charts.fitBars(#o.values, inner_w, SZ(Screen:scaleBySize(max_bar_w)), o.ghost ~= nil)
        if not bar_w then return nil end
        o.bar_w, o.gap, o.color = bar_w, gap, ink
        o.max_h, o.avail_h = bar_h, bar_h + 2 * lbl_h
        o.label_face, o.label_color = face_lbl, color
        local chart = Charts.bars(o)
        return chart and centered(chart)
    end

    local result = {}

    -- This week's days, each beside the same day of the week before.
    do
        local cur, prev = HD.weekValues(charts.days, now, 0), HD.weekValues(charts.days, now, -1)
        local chart = barChart({ values = cur, ghost = prev, labels = weekdayLabels() }, 30)
        if chart then
            local delta = HD.weekDelta(cur, prev, charts.week.today)
            local text
            if delta then
                text = string.format(_("%s against the same days last week"),
                    delta == 0 and "0%" or string.format("%+d%%", delta))
            else
                text = _("No reading on the same days last week")
            end
            result.week = {
                title = _("This week vs last week"), icon = "chart",
                content = VerticalGroup:new{ align = "left", chart, space(6), caption(text) },
            }
        end
    end

    -- The days of this month, today highlighted.
    do
        local month = HD.monthDays(charts.days, today.year, today.month)
        local labels, total = {}, 0
        for day, secs in ipairs(month) do
            labels[day] = (day == 1 or day % 5 == 0) and tostring(day) or ""
            if day <= today.day then total = total + secs end
        end
        local chart = barChart({ values = month, highlight = today.day, labels = labels }, 20)
        if chart then
            result.month = {
                title = _("This month by day"), icon = "calendar_select",
                content = VerticalGroup:new{ align = "left", chart, space(6),
                    caption(string.format(_("%s a day on average"), opts.fmt_time(math.floor(total / today.day)))) },
            }
        end
    end

    -- Calendar of the days read over the last weeks.
    do
        local max_size = SZ(Screen:scaleBySize(24))
        local size, gap, cols, gap_x = Charts.fitGrid(7, HD.HEAT_WEEKS, inner_w,
            math.floor(avail_h * HEAT_H_PCT), max_size, HD.HEAT_WEEKS)
        if size then
            local grid = HD.heatGrid(charts.days, cols, now)
            local heat = Charts.heatmap{
                levels = grid.levels, size = size, gap = gap, gap_x = gap_x, color = ink,
                today = { grid.today_col, grid.today_row },
            }
            result.activity = {
                title = _("Activity"), icon = "calendar_select",
                content = VerticalGroup:new{ align = "left", centered(heat), space(6),
                    caption(string.format(_("Last %d weeks"), cols) .. " · "
                        .. string.format(N_("%d day read", "%d days read", grid.days_read), grid.days_read)) },
            }
        end
    end

    -- Hour of the day.
    do
        local hour_labels = {}
        for h = 0, 23 do hour_labels[h + 1] = h % 6 == 0 and tostring(h) or "" end
        local hours = barChart({
            values = charts.hours, highlight = charts.peak_hour and charts.peak_hour + 1, labels = hour_labels,
        }, 20)
        if hours then result.hours = { title = _("By hour of the day"), icon = "clock", content = hours } end
    end

    -- Day of the week.
    do
        local weekdays = barChart({
            values = charts.weekdays, highlight = charts.peak_weekday, labels = weekdayLabels(),
        }, 30)
        if weekdays then result.weekdays = { title = _("By day of the week"), icon = "calendar_select", content = weekdays } end
    end

    -- Part of the day.
    do
        local parts, peak = HD.dayPartTotals(charts.hours)
        local share = Charts.share{
            values = parts, w = inner_w, avail_h = SZ(Screen:scaleBySize(20)),
            bar_h = SZ(Screen:scaleBySize(14)), color = ink, highlight = peak,
        }
        if share then
            local total = 0
            for _i, secs in ipairs(parts) do total = total + secs end
            local cell_w = math.floor(inner_w / #parts)
            local legend = HorizontalGroup:new{ align = "center" }
            for i, name in ipairs(DateNames.dayParts()) do
                local text = UI.makeColoredText{
                    text = string.format("%s %d%%", name, math.floor(parts[i] / total * 100 + 0.5)),
                    face = face_lbl, fgcolor = color, bold = i == peak,
                    max_width = cell_w, truncate_with_ellipsis = true,
                }
                legend[#legend + 1] = CenterContainer:new{
                    dimen = Geom:new{ w = cell_w, h = text:getSize().h }, text,
                }
            end
            result.dayparts = {
                title = _("By time of day"), icon = "clock",
                content = VerticalGroup:new{ align = "left", share, space(4), legend },
            }
        end
    end

    return result
end

return InsightsCharts
