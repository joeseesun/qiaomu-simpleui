-- sui_span_grid.lua — Simple UI
-- Pure packing model for a grid whose cards span several columns: no UI, no
-- settings. Cards keep their order; one that does not fit in what is left of
-- a row starts the next row, and the last card of the row it leaves widens to
-- the row's edge. The last row of the list is never widened.
--
--   SpanGrid.spanOf(spans, id, max)  -> span of `id`, an integer in [1, max]
--   SpanGrid.pack(ids, spans, cols)  -> rows { {cells=, used=}, ... }
--                                       cell = { id=, index=, col=, span= }
--   SpanGrid.pages(rows, per_page)   -> pages { {rows=, ids=}, ... }
--                                       at most `per_page` rows a page; the rows
--                                       are shared out evenly between the pages
--                                       needed, the first pages taking the extra
--   SpanGrid.cellAt(cells, col)      -> the cell covering column `col`, or nil
--   SpanGrid.shift(ids, id, delta)   -> copy of `ids` with `id` moved `delta`
--                                       places, or nil when it cannot move
--   SpanGrid.fitShift(ids, spans, cols, id) -> places `id` has to move for its row
--                                       to show the span asked for (the nearest
--                                       place; the end always does), or nil when
--                                       it already shows it
--
-- `ids` is an ordered array and `spans` a map id -> span (missing or invalid
-- = 1). Inputs are never mutated.

local SpanGrid = {}

function SpanGrid.spanOf(spans, id, max)
    local s = type(spans) == "table" and spans[id]
    if type(s) ~= "number" or s < 1 or s % 1 ~= 0 then return 1 end
    return math.min(s, max)
end

function SpanGrid.pack(ids, spans, cols)
    local rows, cur = {}, nil
    for i, id in ipairs(ids) do
        local s = SpanGrid.spanOf(spans, id, cols)
        if cur and cur.used + s > cols then
            local last = cur.cells[#cur.cells]
            last.span = last.span + (cols - cur.used)
            cur.used = cols
            cur = nil
        end
        if not cur then
            cur = { cells = {}, used = 0 }
            rows[#rows + 1] = cur
        end
        cur.cells[#cur.cells + 1] = { id = id, index = i, col = cur.used + 1, span = s }
        cur.used = cur.used + s
    end
    return rows
end

function SpanGrid.pages(rows, per_page)
    local count = math.max(1, math.ceil(#rows / per_page))
    local base, extra = math.floor(#rows / count), #rows % count
    local pages, r = {}, 0
    for p = 1, count do
        local page = { rows = {}, ids = {} }
        for _ = 1, base + (p <= extra and 1 or 0) do
            r = r + 1
            page.rows[#page.rows + 1] = rows[r]
            for _, cell in ipairs(rows[r].cells) do page.ids[#page.ids + 1] = cell.id end
        end
        pages[p] = page
    end
    return pages
end

function SpanGrid.cellAt(cells, col)
    for _, cell in ipairs(cells) do
        if col >= cell.col and col < cell.col + cell.span then return cell end
    end
end

function SpanGrid.shift(ids, id, delta)
    local from
    for i, v in ipairs(ids) do
        if v == id then from = i break end
    end
    local to = from and from + delta
    if not to or to < 1 or to > #ids then return nil end
    local out = {}
    for i, v in ipairs(ids) do out[i] = v end
    table.remove(out, from)
    table.insert(out, to, id)
    return out
end

-- Span `id` takes after the packing.
local function effectiveSpan(ids, spans, cols, id)
    for _r, row in ipairs(SpanGrid.pack(ids, spans, cols)) do
        for _c, cell in ipairs(row.cells) do
            if cell.id == id then return cell.span end
        end
    end
end

function SpanGrid.fitShift(ids, spans, cols, id)
    local want = SpanGrid.spanOf(spans, id, cols)
    if effectiveSpan(ids, spans, cols, id) == want then return nil end
    for d = 1, #ids - 1 do
        for _i, delta in ipairs({ d, -d }) do
            local moved = SpanGrid.shift(ids, id, delta)
            if moved and effectiveSpan(moved, spans, cols, id) == want then return delta end
        end
    end
end

return SpanGrid
