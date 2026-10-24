-- sui_bento.lua — Simple UI
-- Pure bento-grid model: no UI, no settings. Widths are spans in sixths of a
-- row (1/3 = 2, 1/2 = 3, 2/3 = 4, full = 6). Modules keep their order; a row
-- is a run of consecutive modules whose spans fit in 6, and a full-width
-- module always sits alone. Shared by the screen engine and the layout editor
-- so the editor preview always matches the rendered screen.
--
--   Bento.pack(ids, spans)                  -> rows { {ids=, sum=}, ... }
--   Bento.setSpan(ids, spans, x, span, adjust) -> spans', changed_ids
--   Bento.move(ids, spans, x, dir)          -> ids', spans', changed_ids
--   Bento.canMove(ids, spans, x)            -> { left, right, up, down }
--   Bento.pctToSpan(pct) / Bento.spanToPct(span)
--
-- `ids` is an ordered array and `spans` a map id -> span (missing = full).
-- Inputs are never mutated.

local Bento = {}

local ROW   = 6
local FULL  = 6
Bento.SPANS = { 2, 3, 4, 6 }
Bento.ROW   = ROW
Bento.FULL  = FULL

local SPAN_PCT = { [2] = 33, [3] = 50, [4] = 67, [6] = 100 }

function Bento.pctToSpan(pct)
    pct = tonumber(pct)
    if not pct then return FULL end
    if pct <= 41 then return 2 end
    if pct <= 58 then return 3 end
    if pct <= 83 then return 4 end
    return FULL
end

function Bento.spanToPct(span)
    return SPAN_PCT[span] or 100
end

local function isValidSpan(s)
    return SPAN_PCT[s] ~= nil
end

local function spanOf(spans, id)
    local s = spans and spans[id]
    return isValidSpan(s) and s or FULL
end

local function copyMap(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

function Bento.pack(ids, spans)
    local rows, cur = {}, nil
    for _, id in ipairs(ids) do
        local s = spanOf(spans, id)
        if cur and s < FULL and cur.sum + s <= ROW then
            cur.ids[#cur.ids + 1] = id
            cur.sum = cur.sum + s
        else
            cur = { ids = { id }, sum = s }
            rows[#rows + 1] = cur
        end
    end
    return rows
end

-- Row index and position of `x`, or nil.
local function locate(rows, x)
    for r, row in ipairs(rows) do
        for i, id in ipairs(row.ids) do
            if id == x then return r, i end
        end
    end
end

-- Spans that make `members` fill a row on their own.
local function closeSpans(members, out)
    local n = #members
    local each = (n >= 3) and 2 or (n == 2) and 3 or FULL
    for _, id in ipairs(members) do out[id] = each end
end

local function slice(list, from, to)
    local out = {}
    for i = from, to do out[#out + 1] = list[i] end
    return out
end

local function diff(old, new, ids)
    local changed = {}
    for _, id in ipairs(ids) do
        if spanOf(old, id) ~= spanOf(new, id) then changed[#changed + 1] = id end
    end
    return changed
end

-- Gives `x` the span `s` and closes its row with one neighbour: the next
-- module of the row, else the previous one, else (when alone) the first
-- module of the next row, else the last of the previous row. Modules left
-- without a row fill their own; nothing is touched beyond those rows.
-- With `adjust == false` only `x` changes.
function Bento.setSpan(ids, spans, x, s, adjust)
    if not isValidSpan(s) then return copyMap(spans), {} end
    local rows = Bento.pack(ids, spans)
    local r, i = locate(rows, x)
    if not r then return copyMap(spans), {} end

    local out = copyMap(spans)
    for _, id in ipairs(ids) do out[id] = spanOf(spans, id) end
    out[x] = s
    if adjust == false then return out, diff(spans, out, ids) end

    if s == FULL then
        closeSpans(slice(rows[r].ids, 1, i - 1), out)
        closeSpans(slice(rows[r].ids, i + 1, #rows[r].ids), out)
        return out, diff(spans, out, ids)
    end

    local row, nb = rows[r].ids, nil
    if i < #row then
        nb = row[i + 1]
        -- Members before x and after the neighbour fill their own rows.
        closeSpans(slice(row, 1, i - 1), out)
        closeSpans(slice(row, i + 2, #row), out)
    elseif i > 1 then
        nb = row[i - 1]
        closeSpans(slice(row, 1, i - 2), out)
    elseif rows[r + 1] then
        local nrow = rows[r + 1].ids
        nb = nrow[1]
        closeSpans(slice(nrow, 2, #nrow), out)
    elseif rows[r - 1] then
        local prow = rows[r - 1].ids
        nb = prow[#prow]
        closeSpans(slice(prow, 1, #prow - 1), out)
    end
    if nb then out[nb] = ROW - s end
    return out, diff(spans, out, ids)
end

function Bento.canMove(ids, spans, x)
    local rows = Bento.pack(ids, spans)
    local r = locate(rows, x)
    local k
    for idx, id in ipairs(ids) do if id == x then k = idx; break end end
    if not r or not k then return { left = false, right = false, up = false, down = false } end
    return {
        left  = k > 1,
        right = k < #ids,
        up    = r > 1,
        down  = r < #rows,
    }
end

-- Moves `x` one step. left/right swap it with the previous/next module; when
-- that module sits in another row the two exchange spans (slots), so every row
-- keeps its sum. up/down swap the whole row of `x` with the adjacent row.
function Bento.move(ids, spans, x, dir)
    local can = Bento.canMove(ids, spans, x)
    local nids, nspans = slice(ids, 1, #ids), copyMap(spans)
    for _, id in ipairs(ids) do nspans[id] = spanOf(spans, id) end
    if not can[dir] then return nids, nspans, {} end

    local rows = Bento.pack(ids, spans)
    local r = locate(rows, x)

    if dir == "up" or dir == "down" then
        local a, b = r, (dir == "up") and r - 1 or r + 1
        if a > b then a, b = b, a end
        local order = {}
        for idx, row in ipairs(rows) do
            local src = (idx == a) and rows[b] or (idx == b) and rows[a] or row
            for _, id in ipairs(src.ids) do order[#order + 1] = id end
        end
        return order, nspans, {}
    end

    local k
    for idx, id in ipairs(ids) do if id == x then k = idx; break end end
    local j = (dir == "left") and k - 1 or k + 1
    local y = ids[j]
    nids[k], nids[j] = nids[j], nids[k]
    local ry = locate(rows, y)
    if ry ~= r then
        nspans[x], nspans[y] = spanOf(spans, y), spanOf(spans, x)
    end
    return nids, nspans, diff(spans, nspans, ids)
end

return Bento
