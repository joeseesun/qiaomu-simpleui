-- sui_dialog_icons.lua — Simple UI
-- Icons for the actions of the dialogs built by the file manager, the
-- collections and the history.
--
-- Those dialogs describe their actions by text only. This module maps the
-- English source string of an action to a SUIStyle.icon key and resolves it
-- against the active translation, so the lookup works in every language.
--
-- Only actions with a distinctive meaning are listed. Groups of look-alike
-- actions (the "Filter by ..." family, option toggles) stay without icons so
-- an icon always tells actions apart.
--
-- Public API
--   DialogIcons.forText(text) -> string?   SUIStyle.icon key, nil when the
--                                          action has no icon.
--   DialogIcons.forSpec(spec) -> string?   Same for a button spec, from its
--                                          `text` or `text_func`.

local gettext = require("gettext")

local DialogIcons = {}

-- Icon key → source strings. An entry is either a string or { context, string }
-- for strings translated with a context.
local ICON_SOURCES = {
    -- Selection
    select       = { "Select files", "Select" },
    select_all   = { "Select all", "Select all files in folder" },
    deselect     = { "Deselect all" },
    exit         = { "Exit select mode" },
    list         = { "Show selected files list" },

    -- File operations
    new_folder   = { "New folder" },
    paste        = { "Paste", { "File", "Paste" }, "Paste to folder" },
    cut          = { "Move", "Cut", "Move to collection" },
    copy         = { "Copy", { "File", "Copy" }, "Copy to collection" },
    edit         = { "Rename", "Rename collection", "Rename shortcut" },
    delete       = { "Delete", "Remove collection", "Clear history of deleted files" },
    import       = { "Import files here" },
    random       = { "Open random document" },
    storage      = { "Switch to SDCard", "Switch to internal storage" },

    -- Folders
    home         = { "Go to HOME folder" },
    home_set     = { "Set as HOME folder" },
    shortcut     = { "Folder shortcuts", "Add to folder shortcuts" },
    shortcut_off = { "Remove from folder shortcuts", "Remove shortcut" },
    folder       = { "Show folder", "Select in file browser",
                     "Add all books from a folder",
                     "Add all books from a folder and its subfolders" },

    -- Books
    open_with    = { "Open with…" },
    info         = { "Book information" },
    cover        = { "Book cover", "Set folder cover" },
    description  = { "Book description" },
    notes        = { "Bookmark browser", "Bookmarks" },
    export       = { "Export highlights" },
    reset        = { "Reset" },
    hide         = { "Ignore cover", "Ignore metadata" },
    show         = { "Unignore cover", "Unignore metadata" },
    convert      = { "Convert" },
    update       = { "Extract and cache book information",
                     "Refresh cached book information" },

    -- Collections
    collections    = { "Collections", "Collections…", "Create collection" },
    collection_add = { "New collection" },
    add_book       = { "Add a book to collection", "Add current book to collection" },
    remove         = { "Remove from collection", "Remove from history",
                       "Remove current book from collection" },
    link           = { "Connect folders" },
    unlink         = { "Disconnect folder" },

    -- Browsing
    search       = { "Search", "Collections search",
                     "Search in filename and book metadata" },
    filter       = { "Filter new books", "Filter by collections" },
    sort         = { "Sort by" },
    arrange      = { "Arrange books in collection", "Arrange collections",
                     "Manual sorting" },
}

-- Translated string → icon key for `index_lang`. Rebuilt when the active
-- language changes.
local icon_by_text, index_lang

local function translate(source)
    if type(source) == "table" then
        return gettext.pgettext(source[1], source[2])
    end
    return gettext(source)
end

-- When two actions translate to the same text, the icon whose key sorts
-- first wins, so the result never depends on table order.
local function buildIndex()
    local icons = {}
    for icon in pairs(ICON_SOURCES) do icons[#icons + 1] = icon end
    table.sort(icons)

    local index = {}
    for _i, icon in ipairs(icons) do
        for _j, source in ipairs(ICON_SOURCES[icon]) do
            local text = translate(source)
            if index[text] == nil then index[text] = icon end
        end
    end
    return index
end

function DialogIcons.forText(text)
    if type(text) ~= "string" then return nil end
    if not icon_by_text or index_lang ~= gettext.current_lang then
        icon_by_text = buildIndex()
        index_lang   = gettext.current_lang
    end
    return icon_by_text[text]
end

function DialogIcons.forSpec(spec)
    local text = spec.text_func and spec.text_func() or spec.text
    return DialogIcons.forText(text)
end

return DialogIcons
