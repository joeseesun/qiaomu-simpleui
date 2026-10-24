-- module_recent.lua — Simple UI
-- "Cover row" module for Recent Books, built on top of
-- GridRenderer.makeModule (engines/sui_book_grid.lua). Not instantiable.
--
-- Split from module_book_rows.lua (which held Recent Books + New Books + TBR
-- in a single file) — see moduleregistry.lua for the require_mod.

local _ = require("infra/sui_i18n").translate

local SUISettings  = require("infra/sui_store")
local GridRenderer = require("engines/sui_book_grid")
local Sources      = require("engines/sui_book_sources")

-- Maps this module's setting onto the "recent" source params. The Currently
-- Reading book is left out according to the screen-wide setting, which the
-- source reads itself.
local source = Sources.bind("recent", function(ctx)
    return { show_finished = SUISettings:readSetting((ctx.pfx or "") .. "recent_show_finished") == true }
end)

local recent_module = GridRenderer.makeModule{
    id          = "recent",
    name        = _("Recent Books"),
    label       = Sources.label("recent"),
    default_on  = false,
    is_book_mod = true,   -- suppresses empty-state when active
    max_items   = 5,
    -- Lets the user pick 4 or 5 visible covers (see GridRenderer.makeModule's
    -- doc comment). The prefetch requested through `needs` is well above
    -- either choice.
    cols_choice = true,

    needs       = Sources.get("recent").needs,

    -- Finished books are filtered unless "Show finished books" is on, and
    -- so is the Currently Reading book (unless the screen-wide setting says
    -- otherwise).
    getFileList = source.getFileList,
    filterItem  = source.filterItem,

    progress_style = { default = "bar_text" },

    -- Off by default (unchanged look for existing users) — see
    -- GridRenderer.applyBadges' doc comment. All three available for the
    -- user to turn on, same as Flat Library/Featured Collection.
    badges = { pages = "off", series = "off", new = "off" },

    extra_settings = {
        { key = "show_finished", label = _("Show finished books"), default = false },
    },

    -- Only listed when Currently Reading is enabled on this screen.
    extra_menu_items_after = Sources.get("recent").menu_items,

    reset = function() GridRenderer.reset() end,
}

return recent_module
