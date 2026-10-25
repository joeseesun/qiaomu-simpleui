-- Opens news EPUBs in KOReader's reader and keeps them out of book state:
-- reading history, lastfile, statistics and the file browser location.
-- Every hook is a no-op for documents outside the hidden news cache.
local Epub = require("features/sui_news_epub")
local logger = require("logger")
local M = {}
local installed, swept = false, false
local native_show_config
-- Receives the typography each news article closed with.
M.profile_sink = nil
local session -- { file, entry, prev_lastfile, on_close, on_end }

local function restoreBookState(file)
    local ReadHistory = require("readhistory")
    pcall(function() ReadHistory:removeItemByPath(Epub.absolute(file)) end)
    local prev = session and session.prev_lastfile
    if prev and not Epub.isNewsDoc(prev) and require("libs/libkoreader-lfs").attributes(prev, "mode") == "file" then
        G_reader_settings:saveSetting("lastfile", prev)
    else
        pcall(function() ReadHistory:ensureLastFile() end)
    end
end

local function dropStatistics(book_id)
    if not book_id then return end
    local ok, err = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(require("datastorage"):getSettingsDir() .. "/statistics.sqlite3")
        local stmt = conn:prepare("DELETE FROM page_stat_data WHERE id_book = ?;")
        stmt:reset():bind(book_id):step(); stmt:close()
        stmt = conn:prepare("DELETE FROM book WHERE id = ?;")
        stmt:reset():bind(book_id):step(); stmt:close()
        conn:close()
    end)
    logger.info("simpleui news-epub: statistics row", book_id, ok and "removed" or ("not removed: " .. tostring(err)))
end

--- Removes leftovers of a session that ended abnormally (crash, power loss).
function M.sweep()
    if swept then return end
    swept = true
    pcall(function()
        local ReadHistory = require("readhistory")
        local stale = {}
        for _, item in ipairs(ReadHistory.hist or {}) do
            if Epub.isNewsDoc(item.file) then stale[#stale + 1] = item.file end
        end
        for _, file in ipairs(stale) do ReadHistory:removeItemByPath(file) end
        if Epub.isNewsDoc(G_reader_settings:readSetting("lastfile")) then ReadHistory:ensureLastFile() end
        if #stale > 0 then logger.info("simpleui news-epub: swept", #stale, "history items") end
    end)
end

function M.install()
    if installed then return end
    installed = true
    local ReaderUI = require("apps/reader/readerui")
    local native_close = ReaderUI.onClose
    function ReaderUI:onClose(...)
        local file = self.document and self.document.file
        if not Epub.isNewsDoc(file) then return native_close(self, ...) end
        local stats = self.statistics
        local book_id = stats and stats.id_curr_book
        -- Stop the statistics module from writing this article on close.
        if stats then stats.is_doc_not_frozen = false; stats.id_curr_book = nil end
        local result = native_close(self, ...)
        local profile = self.doc_settings and Epub.capture(self.doc_settings)
        restoreBookState(file)
        dropStatistics(book_id)
        local current = session
        logger.info("simpleui news-epub: closed", file, "lastfile=", G_reader_settings:readSetting("lastfile"))
        if profile and M.profile_sink then pcall(M.profile_sink, profile) end
        -- Switching to another article has already replaced the session.
        if current and Epub.absolute(current.file) == Epub.absolute(file) then
            session = nil
            if current.on_close then pcall(current.on_close) end
        end
        return result
    end
    local native_fm = ReaderUI.showFileManager
    function ReaderUI:showFileManager(file, ...)
        -- Never browse into the hidden cache; land where the user last was.
        if Epub.isNewsDoc(file) then file = nil end
        return native_fm(self, file, ...)
    end
    local ReaderConfigClass = require("apps/reader/modules/readerconfig")
    native_show_config = ReaderConfigClass.onShowConfigMenu
    local ReaderStatus = require("apps/reader/modules/readerstatus")
    local native_end = ReaderStatus.onEndOfBook
    function ReaderStatus:onEndOfBook(...)
        local file = self.ui and self.ui.document and self.ui.document.file
        if Epub.isNewsDoc(file) and session and session.on_end then
            session.on_end(self.ui)
            return true
        end
        return native_end(self, ...)
    end
    local function newsSession(ui)
        local file = ui and ui.document and ui.document.file
        if Epub.isNewsDoc(file) and session then return session end
    end
    -- Bottom tap / swipe up: the news reading bar instead of the native panel.
    local ReaderConfig = require("apps/reader/modules/readerconfig")
    for _, name in ipairs{ "onTapShowConfigMenu", "onSwipeShowConfigMenu" } do
        local native = ReaderConfig[name]
        ReaderConfig[name] = function(self, ges, ...)
            local current = newsSession(self.ui)
            if current and current.on_bar and (name == "onTapShowConfigMenu" or (ges and ges.direction == "north")) then
                current.on_bar(self.ui, function() return native_show_config(self) end)
                return true
            end
            return native(self, ges, ...)
        end
    end
    -- The in-text "next article" link uses a private URI.
    local ReaderLink = require("apps/reader/modules/readerlink")
    local native_link = ReaderLink.onGotoLink
    function ReaderLink:onGotoLink(link, ...)
        local target = type(link) == "table" and (link.xpointer or link.uri) or ""
        local current = newsSession(self.ui)
        if current and type(target) == "string" and target:find(M.NEXT_URI, 1, true) then
            if current.on_next then current.on_next() end
            return true
        end
        return native_link(self, link, ...)
    end
    -- Gesture actions registered by registerActions().
    for event, key in pairs{ QiaomuNewsNext = "on_next", QiaomuNewsPrevious = "on_prev", QiaomuNewsList = "on_list" } do
        ReaderUI["on" .. event] = function(self)
            local current = newsSession(self)
            if current and current[key] then current[key](); return true end
        end
    end
end

M.NEXT_URI = "qiaomu-next:"

--- Lets users bind article navigation to KOReader gestures.
function M.registerActions()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok then return end
    local _ = require("infra/sui_i18n").translate
    Dispatcher:registerAction("qiaomu_news_next", { category = "none", event = "QiaomuNewsNext", title = _("Qiaomu picks: next article"), reader = true })
    Dispatcher:registerAction("qiaomu_news_previous", { category = "none", event = "QiaomuNewsPrevious", title = _("Qiaomu picks: previous article"), reader = true })
    Dispatcher:registerAction("qiaomu_news_list", { category = "none", event = "QiaomuNewsList", title = _("Qiaomu picks: back to list"), reader = true })
end

--- Opens `path` (an EPUB in the news cache), replacing an open article.
--- `opts`: on_close() back to the list, on_end(ui), on_bar(ui, more), on_next(), on_prev(), on_list().
function M.open(path, entry, opts)
    M.install()
    local ReaderUI = require("apps/reader/readerui")
    local prev = session and session.prev_lastfile or G_reader_settings:readSetting("lastfile")
    local started = os.clock()
    local wall = os.time()
    session = { file = path, entry = entry, prev_lastfile = prev, on_close = opts.on_close, on_end = opts.on_end,
        on_bar = opts.on_bar, on_next = opts.on_next, on_prev = opts.on_prev, on_list = opts.on_list }
    local function ready()
        logger.info("simpleui news-epub: opened", entry.id, string.format("cpu=%.2fs wall=%ds", os.clock() - started, os.time() - wall))
    end
    if ReaderUI.instance then
        ReaderUI.instance:switchDocument(path, true, ready)
    else
        ReaderUI:showReader(path, nil, true, nil, ready)
    end
end

return M
