-- Separate article navigation; never opens ReaderUI or writes book history.
local News = require("features/sui_news")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local _ = require("infra/sui_i18n").translate
local M = {}
local menu, mode, source = nil, "all", nil

local function notice(message)
    UIManager:show(require("ui/widget/infomessage"):new{ text = message })
end

local function job(label, task, done)
    require("ui/network/manager"):runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local completed, result, err = Trapper:dismissableRunInSubprocess(task, label)
            if not completed then return end
            if not result then
                notice(_("Could not update. Saved articles are still available.") .. "\n" .. tostring(err or ""))
                return
            end
            local ok, why = pcall(done, result)
            if not ok then notice(_("Could not save news.") .. "\n" .. tostring(why)) end
        end)
    end)
end

function M.openArticle(entry)
    local function show(article)
        local viewer
        local function savePosition()
            local flag = News.flag(entry.id)
            flag.page = viewer.box_widget.page_number or 1
            flag.pages = viewer.box_widget.page_count or 1
            News.save()
        end
        local function starText()
            return News.flag(entry.id).starred and _("Unsave") or _("Save article")
        end
        viewer = require("ui/widget/textviewer"):new{
            title = News.title(entry), title_multilines = true,
            width = Screen:getWidth(), height = Screen:getHeight(),
            text = article.body, text_format = article.format,
            text_type = "general", show_menu = true,
            buttons_table = {
                {
                    { text = _("Previous page"), callback = function() viewer.scroll_widget:scrollText(-1) end },
                    { text = _("Next page"), callback = function() viewer.scroll_widget:scrollText(1) end },
                },
                {
                    { id = "news_star", text = starText(), callback = function()
                        local flag = News.flag(entry.id)
                        flag.starred = not flag.starred
                        News.save()
                        viewer.button_table:getButtonById("news_star"):setText(starText())
                        UIManager:setDirty(viewer, "ui")
                    end },
                    { text = _("Back to articles"), callback = function() viewer:onClose() end },
                },
            },
            close_callback = function() savePosition(); M.redraw() end,
        }
        local flag = News.flag(entry.id)
        -- A ratio survives font and orientation changes better than a page number.
        if flag.page and flag.pages and flag.pages > 0 then
            viewer.scroll_widget:scrollToRatio((flag.page - 1) / flag.pages)
        end
        flag.read = true
        News.save()
        UIManager:show(viewer)
    end
    local cached = News.cached(entry.id)
    if cached then show(cached); return end
    job(_("Loading article… Tap to cancel."), function() return News.fetchArticle(entry.id) end,
        function(article) News.cache(entry.id, article); show(article) end)
end

local function items()
    local rows = {}
    for _i, entry in ipairs(News.state().entries) do
        local flag = News.flag(entry.id)
        if (not source or entry.sourceId == source)
                and (mode ~= "unread" or not flag.read)
                and (mode ~= "starred" or flag.starred) then
            local status = flag.read and _("Read") or _("Unread")
            local date = (entry.published or ""):sub(1, 10)
            rows[#rows + 1] = {
                text = (flag.starred and "★ " or "") .. News.title(entry)
                    .. "\n" .. (entry.sourceName ~= "" and entry.sourceName or entry.sourceId)
                    .. " · " .. date .. " · " .. status
                    .. (flag.offline and " · " .. _("Offline") or ""),
                bold = not flag.read, news_entry = entry,
                callback = function() M.openArticle(entry) end,
            }
        end
    end
    if #rows == 0 then rows[1] = { text = _("No articles here. Use the menu to update or change the filter."), select_enabled = false } end
    return rows
end

function M.redraw()
    if not menu then return end
    local updated = News.state().updated_at
    local subtitle = updated and (_("Updated") .. " " .. os.date("%m-%d %H:%M", updated)) or _("Update to load Qiaomu picks")
    local filter = mode == "unread" and _("Unread") or mode == "starred" and _("Saved articles") or _("All articles")
    if source then
        for _i, item in ipairs(News.state().sources) do
            if item.id == source then filter = filter .. " · " .. item.name; break end
        end
    end
    menu:switchItemTable(_("Qiaomu picks") .. " · " .. filter, items(), nil, nil, subtitle)
end

function M.update()
    local selected = source
    job(_("Updating Qiaomu picks… Tap to cancel."), function() return News.fetchIndex(selected) end, function(result)
        News.merge(result.entries, result.sources)
        M.redraw()
    end)
end

function M.sourceMenu()
    local rows = {
        { text = _("All sources"), callback = function() source = nil; M.redraw() end },
        { text = _("Update sources"), callback = function()
            job(_("Updating sources… Tap to cancel."), function()
                local data, err = News.request("/api/sources")
                if not data or type(data.sources) ~= "table" then return nil, err end
                return data.sources
            end, function(sources)
                News.merge(News.state().entries, sources)
                M.redraw()
                M.sourceMenu()
            end)
        end },
    }
    for _i, item in ipairs(News.state().sources) do
        rows[#rows + 1] = { text = item.name, callback = function()
            source = item.id
            M.redraw()
            local cached = false
            for _j, entry in ipairs(News.state().entries) do
                if entry.sourceId == source then cached = true; break end
            end
            if not cached then M.update() end
        end }
    end
    local picker
    picker = require("ui/widget/menu"):new{
        title = _("Sources"), item_table = rows,
        width = Screen:getWidth(), height = Screen:getHeight(),
    }
    function picker:onMenuChoice(item)
        UIManager:close(self)
        item.callback()
    end
    UIManager:show(picker)
end

function M.actions(entry)
    local dialog
    local function action(fn)
        return function() UIManager:close(dialog); fn() end
    end
    local buttons
    if entry then
        local flag = News.flag(entry.id)
        buttons = {
            {{ text = flag.read and _("Mark unread") or _("Mark read"), callback = action(function()
                flag.read = not flag.read; News.save(); M.redraw()
            end) }},
            {{ text = flag.starred and _("Unsave") or _("Save article"), callback = action(function()
                flag.starred = not flag.starred; News.save(); M.redraw()
            end) }},
        }
    else
        buttons = {
            {{ text = _("Update now"), callback = action(M.update) }},
            {{ text = _("Unread"), callback = action(function() mode = "unread"; M.redraw() end) },
             { text = _("All articles"), callback = action(function() mode = "all"; M.redraw() end) }},
            {{ text = _("Saved articles"), callback = action(function() mode = "starred"; M.redraw() end) }},
            {{ text = _("Sources"), callback = action(M.sourceMenu) }},
        }
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = action(function() end) }}
    dialog = require("ui/widget/buttondialog"):new{ title = entry and News.title(entry) or _("News"), buttons = buttons }
    UIManager:show(dialog)
end

function M.open()
    if menu then UIManager:show(menu); return end
    menu = require("ui/widget/menu"):new{
        title = _("Qiaomu picks"), item_table = items(),
        width = Screen:getWidth(), height = Screen:getHeight(),
        is_borderless = true, items_per_page = 7, items_max_lines = 3,
        items_font_size = Screen:scaleBySize(18),
        title_bar_left_icon = "appbar.menu",
    }
    function menu:onLeftButtonTap() M.actions() end
    function menu:onMenuHold(item)
        if item.news_entry then M.actions(item.news_entry) end
        return true
    end
    function menu:onCloseWidget()
        require("ui/widget/menu").onCloseWidget(self)
        menu = nil
    end
    M.redraw()
    UIManager:show(menu)
    -- First visit is explicit user intent; subsequent visits remain offline.
    if #News.state().entries == 0 then M.update() end
end

return M
