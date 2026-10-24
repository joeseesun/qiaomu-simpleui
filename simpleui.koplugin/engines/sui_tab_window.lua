-- sui_tab_window.lua — Simple UI
-- Pure arithmetic of a sliding window over a tab list: which tabs are visible
-- and how wide their cells are. No UI dependencies.
--
-- A window is described by `first`, the 1-based index of its leftmost tab.
-- It shows `visible` tabs out of `total`; when `visible >= total` the only
-- valid position is 1.
--
--   TabWindow.maxFirst(total, visible)            -> last valid `first`
--   TabWindow.clamp(first, total, visible)        -> `first` moved into range
--   TabWindow.shift(first, delta, total, visible) -> window moved by `delta`
--   TabWindow.reveal(first, index, total, visible)
--       -> window moved by the least amount that shows tab `index`
--   TabWindow.cellWidths(total_w, count)          -> { w, ... }
--       `total_w` split into `count` whole-pixel widths that sum to it

local M = {}

function M.maxFirst(total, visible)
    return math.max(1, total - visible + 1)
end

function M.clamp(first, total, visible)
    return math.min(math.max(first, 1), M.maxFirst(total, visible))
end

function M.shift(first, delta, total, visible)
    return M.clamp(first + delta, total, visible)
end

function M.reveal(first, index, total, visible)
    if index < first then
        first = index
    elseif index > first + visible - 1 then
        first = index - visible + 1
    end
    return M.clamp(first, total, visible)
end

function M.cellWidths(total_w, count)
    local widths = {}
    if count < 1 then return widths end
    local base      = math.floor(total_w / count)
    local remainder = total_w - base * count
    for i = 1, count do
        widths[i] = base + (i <= remainder and 1 or 0)
    end
    return widths
end

return M
