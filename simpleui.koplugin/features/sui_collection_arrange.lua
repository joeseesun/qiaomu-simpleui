-- sui_collection_arrange.lua — Simple UI
-- "Arrange" menu row for modules backed by an ordered book collection: the
-- generic Arrange row (features/sui_arrange.lua) over the books of a
-- collection.
--
-- Usage:
--   CollectionArrange.makeMenuItem{
--       ctx_menu       = ctx_menu,
--       labels         = { action = ..., header = ..., empty = ... },
--       getCollName    = function() → collection name | nil end,
--       getList        = function() → { fp, ... } end,
--       removeBook     = function(fp) end,
--       isMember       = function(fp) → bool end,        -- optional
--       onOrderChanged = function(list) end,             -- optional
--   }
--
--   labels (already translated): see features/sui_arrange.lua
--   getCollName  the row is disabled while this returns nil
--   onOrderChanged  runs after a new order has been persisted

local Arrange      = require("features/sui_arrange")
local GridRenderer = require("engines/sui_book_grid")

local M = {}

function M.makeMenuItem(opts)
    local _lc = opts.ctx_menu._

    return Arrange.makeMenuItem{
        ctx_menu = opts.ctx_menu,
        labels   = {
            action  = opts.labels.action,
            header  = opts.labels.header,
            empty   = opts.labels.empty,
            too_few = _lc("Add at least 2 books to arrange."),
        },
        isEnabled  = function() return opts.getCollName() ~= nil end,
        getEntries = function()
            local entries = {}
            for _i, fp in ipairs(opts.getList()) do
                entries[#entries + 1] = { value = fp, title = GridRenderer.getBookTitle(fp) }
            end
            return entries
        end,
        saveOrder = function(list)
            local name = opts.getCollName()
            if name then GridRenderer.setCollectionOrder(name, list) end
            if opts.onOrderChanged then opts.onOrderChanged(list) end
        end,
        removeEntry = opts.removeBook,
        isMember    = opts.isMember,
    }
end

return M
