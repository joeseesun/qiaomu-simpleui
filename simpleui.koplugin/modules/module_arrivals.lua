-- module_arrivals.lua — Simple UI
-- "Just arrived" cover row: the books in the Wi-Fi delivery folder
-- ("我的文章", see features/library/sui_arrivals.lua), newest file first.
-- Books never opened carry the cover "New" badge.
--
-- On by default and placed near the top, but it takes no room at all while
-- that folder holds no books: GridRenderer.build returns nil for an empty
-- list and the screen engine then emits neither label nor cell. Not an
-- is_book_mod for the same reason — the engine would otherwise force a full
-- rebuild on every data refresh to "repair" the missing slot.

local _ = require("infra/sui_i18n").translate

local GridRenderer = require("engines/sui_book_grid")
local LibraryScan  = require("engines/sui_library_scan")
local Arrivals     = require("features/library/sui_arrivals")

local MAX_ITEMS = 5

--- Books under the arrivals folder, newest first; ties by path so a batch
--- delivered within one second keeps a stable order. LibraryScan already
--- skips hidden entries (".receiving-*" temp files) and hidden books.
local function getFileList()
    local dir = Arrivals.resolveDir()
    if not dir then return {} end
    local raw = LibraryScan.getRaw(dir)
    table.sort(raw, function(a, b)
        if a.mtime == b.mtime then return a.fp < b.fp end
        return a.mtime > b.mtime
    end)
    local fps = {}
    for i, r in ipairs(raw) do fps[i] = r.fp end
    return fps
end

local mod = GridRenderer.makeModule{
    id          = "arrivals",
    name        = _("Just arrived"),
    label       = _("Just arrived"),
    default_on  = true,
    max_items   = MAX_ITEMS,
    cols_choice = true,

    getFileList = function() return getFileList() end,

    progress_style = { default = "bar_text" },
    -- "New" until the book is first opened.
    badges = { pages = "off", series = "off", new = "on" },

    reset = function()
        GridRenderer.reset()
        LibraryScan.invalidate()
    end,
}

mod.getFileList = getFileList

return mod
