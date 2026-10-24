-- width_sheet.lua — Simple UI (Reading Stats)
-- Action sheet that edits a card of a stat grid: how many columns it spans, by
-- name (Small, Medium, Large and Full row), its place along the grid and whether
-- it is highlighted. A
-- strip at the top shows the row the card sits in as it will render; tapping
-- another card of the strip selects it, and so do the chevrons at the end of
-- the message line and a swipe on the strip, which walk the cards of the grid
-- in order. A change that makes a neighbour widen
-- or narrow is named under it. The sheet grows to fit and never paginates.
--
--   StatWidthSheet.show{
--       stat_id    any        id of the card in the grid (required)
--       max        number     widest span a card can store, at most 4 (required)
--       state      function   () -> { ids = {id, ...}, spans = {id -> span}, cols = n },
--                             read on every repaint (required)
--       set        function   (id, span) stores the span of a card (required)
--       move       function   (id, delta) moves a card by `delta` places (required)
--       label_for  function   (id) -> card name for the title, strip and captions
--       icon_for   function?  (id) -> SUIStyle.icon key of the card
--       highlight_get function? (id) -> bool | nil, whether the card is highlighted
--                             (nil: the grid has no highlight, the row is left out)
--       highlight_set function? (id, on) stores whether the card is highlighted
--       on_changed function?  after each stored change, to repaint the screen behind
--   }
--   -> window
--
--   StatWidthSheet.options(cols, max) -> { { value=, label=, enabled=, full= }, ... }
--   StatWidthSheet.selected(options, span, cols) -> the option standing for `span`
--   StatWidthSheet.summary(span, cols, max) -> "Medium  ·  2/3"
--
-- Buttons and the summary show the width the card is drawn with, which a row
-- can stretch; a width the row hides moves the card to the nearest place that
-- shows it. A name is a label of a span (1, 2, 3 and `max`); an option that would
-- give the same result as a smaller one on this grid is disabled, and Full row
-- always stands for the whole row.

local ActionSheet     = require("engines/sui_action_sheet")
local BentoPreview    = require("engines/sui_bento_preview")
local Device          = require("device")
local GestureRange    = require("ui/gesturerange")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local PageNav         = require("engines/sui_page_nav")
local SUIWindow       = require("engines/sui_window")
local UI              = require("infra/sui_core")
local VerticalSpan    = require("ui/widget/verticalspan")
local SpanGrid        = require("infra/sui_span_grid")
local _               = require("infra/sui_i18n").translate
local N_              = require("infra/sui_i18n").ngettext
local T               = require("ffi/util").template
local Screen          = Device.screen

-- Space between the two chevrons (base pixels).
local PAGER_GAP = 8

-- Space under the last section, so the bottom margin matches the top (base pixels).
local BOTTOM_PAD = 6

local StatWidthSheet = {}

function StatWidthSheet.options(cols, max)
    local names = { _("Small"), _("Medium"), _("Large") }
    local options = {}
    for span = 1, max - 1 do
        options[span] = { value = span, label = names[span], enabled = span < cols }
    end
    options[max] = { value = max, label = _("Full row"), enabled = cols > 1, full = true }
    return options
end

-- `span` is the span a card takes on this grid (already limited to `cols`).
function StatWidthSheet.selected(options, span, cols)
    if cols > 1 and span >= cols then return options[#options] end
    return options[span]
end

-- Share of the row a card takes, e.g. "2/3".
local function columnsOf(span, cols)
    return string.format("%d/%d", span, cols)
end

-- Name and size of a card spanning `span` columns on a grid of `cols`.
function StatWidthSheet.summary(span, cols, max)
    local current = StatWidthSheet.selected(StatWidthSheet.options(cols, max), span, cols)
    return current.label .. "  ·  " .. columnsOf(span, cols)
end

-- Effective span of every card of `ids`, after the packing.
local function cellSpans(state)
    local spans = {}
    for _r, row in ipairs(SpanGrid.pack(state.ids, state.spans, state.cols)) do
        for _c, cell in ipairs(row.cells) do spans[cell.id] = cell.span end
    end
    return spans
end

local function spanLabel(span)
    return T(N_("%1 column", "%1 columns", span), span)
end

-- Positions a card can move to, from its place in the order of `ids`.
local function canMove(ids, stat_id)
    return {
        left  = SpanGrid.shift(ids, stat_id, -1) ~= nil,
        right = SpanGrid.shift(ids, stat_id, 1) ~= nil,
    }
end

-- Position of `stat_id` in `ids`.
local function indexOf(ids, stat_id)
    for i, id in ipairs(ids) do
        if id == stat_id then return i end
    end
end

-- Chevron pair at the end of the message line, the same proportions as the
-- pager under a paged grid. A chevron with no card to go to is dimmed and
-- inert; an active one is a D-pad focus stop.
local function navPager(index, count, go)
    local row_h = PageNav.rowHeight(PageNav.indicatorFace(1))
    local prev_btn, next_btn = PageNav.buildButtons(index, count, row_h, go)
    for _i, button in ipairs({ prev_btn, next_btn }) do
        if button.onTapPageNav then
            UI.makeFocusable(button, button.onTapPageNav)
            local _, focused = SUIWindow.Input.focusStop(button, { on_select = button.onTapPageNav })
            button._kb_focused = focused
        end
    end
    local gap = Screen:scaleBySize(PAGER_GAP)
    return HorizontalGroup:new{
        align = "center",
        prev_btn,
        HorizontalSpan:new{ width = gap },
        next_btn,
    }
end

function StatWidthSheet.show(opts)
    local stat_id = opts.stat_id
    local win, message
    local buildSections, walk

    -- Which other cards changed width between two packings.
    local function describe(state, before, after)
        local changed = {}
        for _i, id in ipairs(state.ids) do
            if id ~= stat_id and before[id] ~= after[id] then changed[#changed + 1] = id end
        end
        if #changed == 1 then
            return T(_("%1 adjusted to %2"), opts.label_for(changed[1]), spanLabel(after[changed[1]]))
        elseif #changed > 1 then
            return _("Neighbouring stats adjusted")
        end
    end

    -- Title, subtitle and sections of the sheet for the selected card.
    local function content()
        local state = opts.state()
        local cols  = state.cols
        return {
            title    = opts.label_for(stat_id),
            icon     = opts.icon_for and opts.icon_for(stat_id),
            message  = _("Row preview") .. " · "
                       .. StatWidthSheet.summary(cellSpans(state)[stat_id] or 1, cols, opts.max),
            sections = buildSections(),
            message_end = function() return navPager(indexOf(state.ids, stat_id), #state.ids, walk) end,
        }
    end

    -- Row number of `id` in the packing of `state`.
    local function rowOf(state, id)
        for r, row in ipairs(SpanGrid.pack(state.ids, state.spans, state.cols)) do
            for _c, cell in ipairs(row.cells) do
                if cell.id == id then return r end
            end
        end
    end

    -- A row stretches its last card, so the width asked for can differ from the
    -- one shown. The card then moves to the nearest place that shows it (the end
    -- of the grid always does).
    local function setWidth(value)
        local before = cellSpans(opts.state())
        opts.set(stat_id, value)
        local state = opts.state()
        local delta = SpanGrid.fitShift(state.ids, state.spans, state.cols, stat_id)
        if delta then
            opts.move(stat_id, delta)
            state = opts.state()
            message = T(_("Moved to row %1 to keep its width"), rowOf(state, stat_id))
        else
            message = describe(state, before, cellSpans(state))
        end
        if opts.on_changed then opts.on_changed() end
        win:update(content())
    end

    local function move(delta)
        opts.move(stat_id, delta)
        if opts.on_changed then opts.on_changed() end
        message = nil
        win:update(content())
    end

    local function toggleHighlight()
        opts.highlight_set(stat_id, not opts.highlight_get(stat_id))
        if opts.on_changed then opts.on_changed() end
        win:update(content())
    end

    local function select(id)
        stat_id = id
        message = nil
        win:update(content())
    end

    -- Selects the card `delta` places along the grid.
    function walk(delta)
        local ids = opts.state().ids
        local target = ids[indexOf(ids, stat_id) + delta]
        if target then select(target) end
    end

    function buildSections()
        local state = opts.state()
        local cols  = state.cols
        local rows  = SpanGrid.pack(state.ids, state.spans, cols)

        local row_no, own_row
        for r, row in ipairs(rows) do
            for _c, cell in ipairs(row.cells) do
                if cell.id == stat_id then row_no, own_row = r, row end
            end
        end

        local span    = cellSpans(state)[stat_id] or 1
        local choices = StatWidthSheet.options(cols, opts.max)
        local current = StatWidthSheet.selected(choices, span, cols)
        local can = canMove(state.ids, stat_id)
        local moves = {
            { text = "←", enabled = can.left,  callback = function() move(-1) end },
            { text = "→", enabled = can.right, callback = function() move(1) end },
        }
        local buttons = {}
        for _i, option in ipairs(choices) do
            buttons[#buttons + 1] = {
                text     = option.label,
                selected = option == current,
                enabled  = option.enabled,
                callback = function() setWidth(option.value) end,
            }
        end

        -- The row of the card, then what the last change did to its neighbours.
        local function preview(ctx)
            local ids, spans = {}, {}
            for _c, cell in ipairs(own_row.cells) do
                ids[#ids + 1] = cell.id
                spans[cell.id] = cell.span
            end
            local strip = BentoPreview.build(ctx, {
                ids        = ids,
                spans      = spans,
                row_total  = cols,
                label_for  = opts.label_for,
                span_label = spanLabel,
                highlight  = stat_id,
                on_tap     = select,
            }, T(_("Row %1 of %2"), row_no, #rows), message)

            -- A swipe on the strip walks the cards like the chevrons.
            local size = strip:getSize()
            local swipe = InputContainer:new{ dimen = Geom:new{ w = size.w, h = size.h }, strip }
            swipe.ges_events = {
                Swipe = { GestureRange:new{ ges = "swipe", range = function() return swipe.dimen end } },
            }
            function swipe:onSwipe(_, ges)
                local delta = PageNav.swipeDelta(ges)
                if not delta then return false end
                walk(delta)
                return true
            end
            return swipe
        end

        local sections = {
            { type = "widget",   build = preview },
        }
        local highlighted = opts.highlight_get and opts.highlight_get(stat_id)
        if highlighted ~= nil then
            sections[#sections + 1] = ActionSheet.list({
                { text = _("Highlight card"), sui_icon = "highlights", toggle = highlighted, callback = toggleHighlight },
            })
        end
        local rest = {
            { type = "note",     text = _("Width") },
            { type = "segments", items = buttons },
            { type = "note",     text = _("Position") },
            { type = "segments", items = moves },
            { type = "widget",   build = function(ctx)
                return VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(BOTTOM_PAD)) }
            end },
        }
        for _i, section in ipairs(rest) do sections[#sections + 1] = section end
        return sections
    end

    local first = content()
    first.name     = "sui_win_stat_width_sheet"
    win = ActionSheet.show(first)
    return win
end

return StatWidthSheet
