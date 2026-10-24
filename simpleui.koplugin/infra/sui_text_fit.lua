-- sui_text_fit.lua — Simple UI
-- Picks the font size at which a set of texts fits a width.
--
--   TextFit.largest(max_size, min_size, fits) -> size
--     Biggest size in [min_size, max_size] for which fits(size) is true;
--     min_size when none fits. fits must be monotonic: once a size fits,
--     every smaller one does.

local TextFit = {}

function TextFit.largest(max_size, min_size, fits)
    local lo, hi = min_size, max_size
    while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        if fits(mid) then lo = mid else hi = mid - 1 end
    end
    return lo
end

return TextFit
