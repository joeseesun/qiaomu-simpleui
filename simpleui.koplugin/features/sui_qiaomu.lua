-- Copyright (c) 2026 向阳乔木. GPL-3.0-or-later.
local Settings = require("infra/sui_store")
local Config = require("infra/sui_config")
local QA = require("features/sui_quickactions")
local _ = require("infra/sui_i18n").translate
local M = {}
local ACTION = "qiaomu_weread"

function M.wereadAvailable()
    local disabled = G_reader_settings:readSetting("plugins_disabled", {})
    if disabled.weread then return false end
    local dir = require("infra/sui_paths").getPluginDir()
    local plugins = dir:gsub("[^/]+/$", "")
    return require("libs/libkoreader-lfs").attributes(
        plugins .. "weread.koplugin/main.lua", "mode") == "file"
end

function M.install(plugin)
    QA.register{
        id = "qiaomu_news", label = _("News"),
        icon = require("infra/sui_paths").getPluginDir() .. "icons/qiaomu_news.svg",
        is_in_place = true, is_async_in_place = true,
        execute = function() require("screens/sui_news_reader").open() end,
    }
    -- Move the less frequent book collection action into the shelf menu.
    -- This runs once, so later manual navbar choices remain respected.
    if not Settings:isTrue("simpleui_qiaomu_news_tab_v1") then
        local tabs, has_news = {}, false
        for _, id in ipairs(Config.loadTabConfig()) do
            if id == "qiaomu_news" then has_news = true end
        end
        for _, id in ipairs(Config.loadTabConfig()) do
            if id == "favorites" then
                if not has_news then tabs[#tabs + 1] = "qiaomu_news"; has_news = true end
            else tabs[#tabs + 1] = id end
        end
        if not has_news and #tabs < Config.effectiveMaxTabs() then
            table.insert(tabs, math.max(2, #tabs), "qiaomu_news")
        end
        Config.saveTabConfig(tabs)
        Settings:set("simpleui_qiaomu_news_tab_v1", true)
    end
    if not Settings:isTrue("simpleui_qiaomu_defaults_v1") then
        Settings:set("simpleui_topbar_swipe_indicator", false)
        Settings:set("simpleui_qiaomu_defaults_v1", true)
    end
    if M.wereadAvailable() then
        QA.register{
            id = ACTION,
            label = _("WeRead"),
            icon = Config.ICON.library,
            is_in_place = true,
            is_async_in_place = true,
            execute = function()
                local FM = package.loaded["apps/filemanager/filemanager"]
                local fm = FM and FM.instance
                local inst = fm and fm.weread or plugin.ui.weread
                if not inst then
                    local ok, Loader = pcall(require, "pluginloader")
                    if ok then inst = Loader:getPluginInstance("weread") end
                end
                if inst and type(inst.openBookshelf) == "function" then
                    inst:openBookshelf()
                elseif inst and type(inst.launch) == "function" then
                    inst:launch()
                else
                    require("infra/sui_core").Notify.toast(_("WeRead is not available. Enable its plugin and restart KOReader."))
                end
            end,
        }
        -- .1/.2 could prune the tab on restart but retain the "added" flag.
        -- Repair that state once; later manual navbar choices stay respected.
        if not Settings:isTrue("simpleui_qiaomu_weread_tab_added")
                or not Settings:isTrue("simpleui_qiaomu_weread_tab_migrated_v2")
                or Settings:isTrue("simpleui_qiaomu_weread_tab_suspended") then
            local tabs = {}
            local found = false
            for _i, id in ipairs(Config.loadTabConfig()) do
                tabs[#tabs + 1] = id
                if id == ACTION then found = true end
            end
            if not found and #tabs < Config.effectiveMaxTabs() then
                table.insert(tabs, math.max(2, #tabs), ACTION)
                Config.saveTabConfig(tabs)
                found = true
            end
            if found then
                Settings:set("simpleui_qiaomu_weread_tab_added", true)
                Settings:set("simpleui_qiaomu_weread_tab_suspended", false)
            end
            Settings:set("simpleui_qiaomu_weread_tab_migrated_v2", true)
        end
    else
        QA.unregister(ACTION)
        local tabs = Settings:get("simpleui_bar_tabs")
        if type(tabs) == "table" then
            local kept = {}
            for _i, id in ipairs(tabs) do if id ~= ACTION then kept[#kept + 1] = id end end
            if #kept ~= #tabs then
                Config.saveTabConfig(kept)
                Settings:set("simpleui_qiaomu_weread_tab_suspended", true)
            end
        end
    end
    Config.invalidateTabsCache()
    require("ui/uimanager"):scheduleIn(0, function()
        local FM = package.loaded["apps/filemanager/filemanager"]
        if FM and FM.instance then
            require("features/library/sui_hidden_books").registerHoldAction(FM.instance)
        end
    end)
end

return M
