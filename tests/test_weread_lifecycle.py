"""Run actual startup registration/sanitization in source order across restarts."""
from pathlib import Path
import re
from lupa.lua54 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]
plugin=ROOT/'simpleui.koplugin'
main=(plugin/'main.lua').read_text()
qa=(plugin/'features/sui_quickactions.lua').read_text()
config=(plugin/'infra/sui_config.lua').read_text()
# Execute the actual initialization block through sanitization, not just install().
start=main.index('        Config.applyFirstRunDefaults()')
end=main.index('        -- Apply the saved UI font',start)
startup=main[start:end]
sanitize=re.search(r'function QA.sanitizeQASlots\(\)(.*?)\nend\n',qa,re.S).group(0)
load_tabs=re.search(r'function M.loadTabConfig\(\)(.*?)\nend\n',config,re.S).group(0)
lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().plugin_root=str(plugin)
lua.globals().startup_source=startup
lua.globals().sanitize_source=sanitize
lua.globals().load_tabs_source=load_tabs
lua.execute('''
package.path=plugin_root.."/?.lua;"..package.path
persisted={simpleui_enabled=true,simpleui_qiaomu_defaults_v1=true,
 simpleui_qiaomu_weread_tab_added=true,
 simpleui_bar_tabs={"homescreen","home","favorites","history","qiaomu_weread","sui_settings"}}
local store={
 get=function(_,k,d) if persisted[k]==nil then return d end return persisted[k] end,
 set=function(_,k,v) persisted[k]=v end,
 isTrue=function(_,k) return persisted[k]==true end,
 nilOrTrue=function(_,k) return persisted[k]~=false end,
}
package.loaded["infra/sui_store"]=store
package.loaded["infra/sui_i18n"]={translate=function(t) return t end}
local installed=true
package.loaded["libs/libkoreader-lfs"]={attributes=function() if installed then return "file" end end}
package.loaded["infra/sui_paths"]={getPluginDir=function() return "/plugins/simpleui.koplugin/" end}
package.loaded["ui/uimanager"]={scheduleIn=function() end}
package.loaded["logger"]={warn=function() end}
local disabled={}
G_reader_settings={readSetting=function() return disabled end}
local actions={}
local QA={
 register=function(d) actions[d.id]=d end,
 unregister=function(id) actions[id]=nil end,
 isRegistered=function(id) return actions[id]~=nil end,
 getCustomQAList=function() return {} end,
}
package.loaded["features/sui_quickactions"]=QA
local Config={ICON={library="book"},ACTION_BY_ID={homescreen=true,home=true,favorites=true,history=true,sui_settings=true},
 effectiveMaxTabs=function() return 6 end,
 isNavpagerEnabled=function() return false end,
 _ensureHomePresent=function() end,
 DEFAULT_NUM_TABS=5,DEFAULT_TABS={"homescreen","home","favorites","history","sui_settings"},
 ALL_ACTIONS={{id="homescreen"},{id="home"}},
 applyFirstRunDefaults=function() end,migrateOldCustomSlots=function() end,
}
local env=setmetatable({M=Config,SUISettings=store,QA=QA,Config=Config,
 logger=package.loaded["logger"],_QA_lazy=function() return QA end}, {__index=_G})
assert(load(load_tabs_source,"tabs","t",env))()
assert(load(sanitize_source,"sanitize","t",env))()
Config.sanitizeQASlots=QA.sanitizeQASlots
Config.invalidateTabsCache=function() env._tabs_cache=nil end
Config.saveTabConfig=function(t) Config.invalidateTabsCache(); persisted.simpleui_bar_tabs=t end
package.loaded["infra/sui_config"]=Config
local Q=require("features/sui_qiaomu")
local self={ui={}}
local function boot()
 actions={}
 Config.invalidateTabsCache()
 -- Startup really empties the in-memory external registry every launch.
 assert(load(startup_source,"startup","t",setmetatable({Config=Config,SUISettings=store,self=self},{__index=_G})))()
end
local function has_tab()
 local n=0
 for _,id in ipairs(persisted.simpleui_bar_tabs) do if id=="qiaomu_weread" then n=n+1 end end
 return n
end
boot()
assert(has_tab()==1,"restart sanitizer removed the WeRead tab before registration")
local news_count=0
for _,id in ipairs(persisted.simpleui_bar_tabs) do
 if id=="qiaomu_news" then news_count=news_count+1 end
 assert(id~="favorites","move book favorites out of the default navbar")
end
assert(news_count==1,"register News before the same startup sanitizer")
boot()
assert(has_tab()==1,"entry must survive a second cold start without duplication")
-- Existing .1/.2 installations may already have lost the persisted entry.
persisted.simpleui_qiaomu_weread_tab_migrated_v2=nil
persisted.simpleui_bar_tabs={"homescreen","home","favorites","history","sui_settings"}
boot()
assert(has_tab()==1,"repair the already-pruned entry once on upgrade")
-- After repair, a deliberate manual removal remains respected.
persisted.simpleui_bar_tabs={"homescreen","home","favorites","history","sui_settings"}
boot()
assert(has_tab()==0,"do not undo user customization on every launch")
-- Unavailable plugin is not offered; a previously present tab can return.
persisted.simpleui_bar_tabs={"homescreen","home","favorites","history","qiaomu_weread","sui_settings"}
disabled.weread=true
boot()
assert(has_tab()==0 and actions.qiaomu_weread==nil)
disabled.weread=nil
boot()
assert(has_tab()==1,"restore a tab suspended by plugin unavailability")
installed=false
boot()
assert(has_tab()==0)
installed=true
boot()
assert(has_tab()==1)
-- Do not replace the user's six selected tabs when there is no room.
persisted.simpleui_qiaomu_weread_tab_added=nil
persisted.simpleui_qiaomu_weread_tab_migrated_v2=nil
Config.ACTION_BY_ID.extra=true
persisted.simpleui_bar_tabs={"homescreen","home","favorites","history","extra","sui_settings"}
boot()
assert(has_tab()==0 and #persisted.simpleui_bar_tabs==6)
persisted.simpleui_bar_tabs={"homescreen","home","favorites","history","sui_settings"}
boot()
assert(has_tab()==1,"retry first insertion once space becomes available")
''')
print('PASS: actual startup ordering, two cold starts, upgrade repair, manual removal, disabled/missing plugin, full bar.')
