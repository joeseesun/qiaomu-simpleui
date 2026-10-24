-- recommend.lua — Simple UI
-- Book the Critter suggests in the conversation: one of the library that the
-- user has not opened yet. The pick is pure (Recommend.pick); nextBook reads the
-- library and the sidecars, so it is only called when the user asks for a book,
-- never while painting.

local lfs = require("libs/libkoreader-lfs")

local Recommend = {}

Recommend.TRIES = 25   -- most sidecars read for one suggestion

--- A file of `files` for which `is_unopened(fp)` holds, taken in random order
--- (`rand(n)` gives an integer from 1 to n) without testing any file twice, or
--- nil. `skip` is passed over; at most `tries` files are tested.
function Recommend.pick(files, is_unopened, rand, tries, skip)
    local swapped, remaining, tested = {}, #files, 0
    while remaining > 0 and tested < tries do
        local at = rand(remaining)
        local fp = swapped[at] or files[at]
        swapped[at] = swapped[remaining] or files[remaining]
        remaining = remaining - 1
        if fp ~= skip then
            tested = tested + 1
            if is_unopened(fp) then return fp end
        end
    end
    return nil
end

--- Whether a book with the sidecar record `data` (nil: no sidecar) was never
--- opened: no progress, no status and no reading time.
function Recommend.isUnopened(data)
    if not data then return true end
    if (data.percent or 0) >= 0.01 then return false end
    if type(data.summary) == "table" and data.summary.status then return false end
    return (data.stat_total_time or 0) == 0
end

--- Whether the book file `fp` is still there.
function Recommend.exists(fp)
    return lfs.attributes(fp, "mode") == "file"
end

--- An unopened book of the library, { fp, title, authors }, or nil when there is
--- none. The one in `skip_fp` is offered again only when no other is found.
function Recommend.nextBook(skip_fp)
    local LibraryScan = require("engines/sui_library_scan")
    local SH          = require("modules/module_books_shared")
    local files = LibraryScan.getFileList(LibraryScan.resolveHomeDir())
    local function unopened(fp) return Recommend.isUnopened(SH.sidecarData(fp)) end
    local fp = Recommend.pick(files, unopened, math.random, Recommend.TRIES, skip_fp)
    -- The book offered before was unopened, so it stands in when nothing else is found.
    if not fp and skip_fp and Recommend.exists(skip_fp) then fp = skip_fp end
    if not fp then return nil end
    local book = SH.getBookData(fp)
    return { fp = fp, title = book.title, authors = book.authors }
end

return Recommend
