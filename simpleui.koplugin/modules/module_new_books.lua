-- module_new_books.lua — Simple UI
-- "Cover row" module for New Books — recently added to the library
-- (by file date), built on top of GridRenderer.makeModule
-- (engines/sui_book_grid.lua). Not instantiable.
--
-- The book list comes from the "new_books" source (engines/sui_book_sources.lua).

local _ = require("infra/sui_i18n").translate

local GridRenderer = require("engines/sui_book_grid")
local Sources      = require("engines/sui_book_sources")

local source = Sources.bind("new_books")

local new_books_module = GridRenderer.makeModule{
    id          = "new_books",
    name        = _("New Books"),
    label       = Sources.label("new_books"),
    default_on  = false,  -- opt-in; users enable via Arrange Modules
    max_items   = 5,
    -- Lets the user pick 4 or 5 visible covers (see GridRenderer.makeModule's
    -- doc comment). The source provides more candidates than either choice.
    cols_choice = true,

    getFileList  = source.getFileList,
    filterItem   = source.filterItem,
    labelForItem = source.labelForItem,

    -- Same defaults as Recent Books/Library/TBR: progress bar + "% Read"
    -- label by default, user-editable via the "Progress Style" picker
    -- (see engines/sui_book_grid.lua's getMenuItems).
    progress_style = { default = "bar_text" },

    -- All three off by default. "New" stays user-editable even though every
    -- cover here is a new book: some users want the marker on the cover
    -- itself in addition to the under-cover text.
    badges = { pages = "off", series = "off", new = "off" },

    reset = function()
        GridRenderer.reset()
        Sources.invalidate("new_books")
    end,
}

--- Forces the next build to re-rank the library.
function new_books_module.invalidateCache()
    Sources.invalidate("new_books")
end

return new_books_module
