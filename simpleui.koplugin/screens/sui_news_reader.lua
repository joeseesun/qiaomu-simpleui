-- Separate article navigation; never opens ReaderUI or writes book history.
local News = require("features/sui_news")
local JSON = require("json")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local _ = require("infra/sui_i18n").translate
local M = {}
local menu, mode, source = nil, "all", nil
local Cache = require("features/sui_news_cache")
local Images = require("features/sui_news_images")

local function notice(message)
    UIManager:show(require("ui/widget/infomessage"):new{ text = message })
end

local function job(label, task, done, owner, finish)
    local function run()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            -- LuaJSON's null marker is a function; native LuaJIT serialization
            -- rejects it. Transfer JSON bytes, not decoded API objects.
            local completed, payload = Trapper:dismissableRunInSubprocess(function()
                local ok, value, err = pcall(task)
                local envelope = ok and { result = value, error = err } or { error = tostring(value) }
                local encoded, result = pcall(JSON.encode, envelope)
                if encoded then return result end
                return JSON.encode{ error = tostring(result) }
            end, owner or label, true)
            if owner then owner.dismiss_callback=nil end
            if finish then finish() end
            if not completed or (owner and owner._news_closed) then return end
            local decoded, response = pcall(JSON.decode, payload or "")
            local result = decoded and type(response) == "table" and response.result
            local err = decoded and type(response) == "table" and response.error or "Invalid response"
            if not result then
                if not owner then notice(_("Could not update. Saved articles are still available.") .. "\n" .. tostring(err or "")) end
                return
            end
            local ok, why = pcall(done, result)
            if not ok then notice(_("Could not save news.") .. "\n" .. tostring(why)) end
        end)
    end
    local network=require("ui/network/manager")
    if owner then
        if network:isOnline() then run() elseif finish then finish() end
    else network:runWhenOnline(run) end
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
        local function closeArticle()
            if viewer._news_closed then return end
            viewer._news_closed=true
            if viewer.dismiss_callback then viewer.dismiss_callback() end
            savePosition(); M.redraw()
        end
        local function starIcon() return News.flag(entry.id).starred and "star.full" or "star.empty" end
        local Size=require("ui/size")
        local button_h=math.max(Screen:scaleBySize(20),Screen:scaleBySize(44)-2*Size.padding.buttontable)
        local function icon(id, glyph, label, callback)
            return {id=id,icon=glyph,height=button_h,icon_width=Screen:scaleBySize(20),icon_height=Screen:scaleBySize(20),
                callback=callback,hold_callback=function() notice(type(label)=="function" and label() or label) end}
        end
        viewer = require("ui/widget/textviewer"):new{
            title = News.title(entry), title_multilines = false, title_shrink_font_to_fit = true,
            width = Screen:getWidth(), height = Screen:getHeight(),
            text = Images.html(article), text_format = "html",
            -- Supplies the native HTML resource root, without opening ReaderUI.
            file = Cache.root() .. "/images/news-article.html",
            text_type = "general", show_menu = true,
            buttons_table = {
                {
                    icon("top","chevron.left",_("Previous page"),function() viewer.scroll_widget:scrollText(-1) end),
                    icon("bottom","chevron.right",_("Next page"),function() viewer.scroll_widget:scrollText(1) end),
                    icon("news_star",starIcon(),starText,function()
                        local flag = News.flag(entry.id)
                        flag.starred = not flag.starred
                        News.save()
                        local button=viewer.button_table:getButtonById("news_star")
                        button:setIcon(starIcon(),button.width)
                        UIManager:setDirty(viewer, "ui")
                    end),
                    icon("news_back","appbar.filebrowser",_("Back to articles"),function() viewer:onClose() end),
                },
            },
            close_callback = closeArticle,
        }
        local native_close=viewer.onCloseWidget
        function viewer:onCloseWidget()
            closeArticle()
            if native_close then return native_close(self) end
        end
        local function decorate()
            require("features/sui_style").restoreDefaultIcon(viewer.button_table:getButtonById("news_back"),nil,
                require("infra/sui_paths").getPluginDir().."icons/qiaomu_list.svg")
        end
        local native_init=viewer.init
        function viewer:init(reinit) native_init(self,reinit);decorate() end
        decorate()
        local flag = News.flag(entry.id)
        -- A ratio survives font and orientation changes better than a page number.
        if flag.page and flag.pages and flag.pages > 0 then
            viewer.scroll_widget:scrollToRatio((flag.page - 1) / flag.pages)
        end
        flag.read = true
        News.save()
        UIManager:show(viewer)
        local function downloadImages(manual)
            if viewer._image_job then return end
            local urls={}
            for _,url in ipairs(Images.urls(article)) do if not Images.path(url) then urls[#urls+1]=url end end
            if #urls==0 then return end
            if not require("ui/network/manager"):isOnline() then
                if manual then notice(_("Connect to Wi-Fi to download images.")) end
                return
            end
            local release=Cache.reserve(Images.ARTICLE_BUDGET,News.state())
            News.save()
            if not release then
                if manual then notice(_("Not enough cache space. Clear unstarred cache and retry.")) end
                return
            end
            viewer._image_job=true
            job(nil,function() return Images.download(urls,Images.ARTICLE_BUDGET) end,function(result)
                if result.count>0 then viewer.text=Images.html(article);viewer:reinit()
                elseif manual then notice(_("Images could not be downloaded. Use the menu to retry.")) end
            end,viewer,function() viewer._image_job=false;release() end)
        end
        local native_menu=viewer.onShowMenu
        function viewer:onShowMenu()
            local dialog
            local function action(fn) return function() UIManager:close(dialog);fn() end end
            dialog=require("ui/widget/buttondialog"):new{title=_("News"),buttons={
                {{text=_("Download missing images"),callback=action(function() downloadImages(true) end)}},
                {{text=_("Font settings"),callback=action(function() native_menu(self) end)}},
                {{text=_("Cancel"),callback=action(function() end)}},
            }}
            UIManager:show(dialog)
        end
        if article.version=="original" and not article.media_version
                and require("ui/network/manager"):isOnline() then
            -- Older text-only caches had removed img tags. Keep their text
            -- readable while restoring the complete article once in background.
            job(nil,function() return News.fetchArticle(entry.id) end,function(fresh)
                News.cache(entry.id,fresh);article=fresh
                viewer.text=Images.html(article);viewer:reinit();downloadImages()
            end,viewer)
        else downloadImages() end
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
            rows[#rows + 1] = {
                text = News.title(entry),
                bold = not flag.read, news_entry = entry,
                callback = function() M.openArticle(entry) end,
            }
        end
    end
    if #rows == 0 then rows[1] = { text = _("No articles here. Use the menu to update or change the filter."), select_enabled = false } end
    return rows
end

local function thumbnails()
    if not menu or menu._thumb_job then return end
    local owner,urls=menu,{}
    owner._thumb_attempts=owner._thumb_attempts or {}
    for _,row in ipairs(owner.item_group or {}) do
        local entry=row.entry and row.entry.news_entry
        local url=entry and Images.safeUrl(entry.image)
        if url and not Images.path(url) and not owner._thumb_attempts[url] then
            urls[#urls+1]=url;owner._thumb_attempts[url]=true
        end
    end
    if #urls==0 then return end
    local release=Cache.reserve(Images.THUMB_BUDGET,News.state());News.save()
    if not release then return end
    owner._thumb_job=true
    job(nil,function() return Images.download(urls,Images.THUMB_BUDGET) end,function(result)
        if result.count>0 and menu==owner then M.redraw() end
    end,owner,function() owner._thumb_job=false;release() end)
end

function M.redraw(reset_page)
    if not menu then return end
    local filter = mode == "unread" and _("Unread") or mode == "starred" and _("Saved articles") or _("All articles")
    if source then
        for _i, item in ipairs(News.state().sources) do
            if item.id == source then filter = filter .. " · " .. item.name; break end
        end
    end
    local rows=items()
    menu:switchItemTable(_("Qiaomu picks"), rows, reset_page and 1 or -1, nil, filter)
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
        { text = _("All sources"), callback = function() source = nil; M.redraw(true) end },
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
            M.redraw(true)
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
            {{ text = _("Unread"), callback = action(function() mode = "unread"; M.redraw(true) end) },
             { text = _("All articles"), callback = action(function() mode = "all"; M.redraw(true) end) }},
            {{ text = _("Saved articles"), callback = action(function() mode = "starred"; M.redraw(true) end) }},
            {{ text = _("Sources"), callback = action(M.sourceMenu) }},
            {{ text = _("News cache"), callback = action(M.cacheMenu) }},
        }
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = action(function() end) }}
    dialog = require("ui/widget/buttondialog"):new{ title = entry and News.title(entry) or _("News"), buttons = buttons }
    UIManager:show(dialog)
end

function M.cacheMenu()
    local info=Cache.stats()
    local title=string.format("%s: %.1f / 512 MiB",_("News cache"),info.bytes/1048576)
    if info.free then title=title..string.format("\n%s: %.2f GiB",_("Free space"),info.free/1073741824) end
    local dialog
    dialog=require("ui/widget/buttondialog"):new{title=title,buttons={
        {{text=_("Clear unstarred cache"),callback=function()
            if menu and menu.dismiss_callback then menu.dismiss_callback() end
            Cache.makeRoom(0,News.state(),true);News.save();UIManager:close(dialog);M.redraw()
        end}},
        {{text=_("Cancel"),callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end

function M.open()
    if menu then
        UIManager:show(menu)
        if require("ui/network/manager"):isOnline() then M.update() end
        return
    end
    menu = require("ui/widget/menu"):new{
        title = _("Qiaomu picks"), item_table = items(),
        width = Screen:getWidth(), height = Screen:getHeight(),
        is_borderless = true, items_per_page = 7, multilines_forced = true,
        items_font_size = 18,
        title_bar_left_icon = "appbar.menu",
    }
    local native_update=menu.updateItems
    if native_update then
        function menu:updateItems(...)
            native_update(self,...)
            require("features/sui_news_rows").apply(self)
            UIManager:scheduleIn(0,thumbnails)
        end
    end
    function menu:onLeftButtonTap() M.actions() end
    function menu:onMenuHold(item)
        if item.news_entry then M.actions(item.news_entry) end
        return true
    end
    function menu:onCloseWidget()
        self._news_closed=true
        if self.dismiss_callback then self.dismiss_callback() end
        require("ui/widget/menu").onCloseWidget(self)
        menu = nil
    end
    M.redraw()
    UIManager:show(menu)
    -- Show cached entries immediately, refresh on every online visit, and
    -- retain offline reading without asking to enable Wi-Fi for a cached list.
    if require("ui/network/manager"):isOnline() or #News.state().entries == 0 then M.update() end
end

return M
