"""Behavioral regression tests against the shipped Lua modules.
Run: python3 -m pip install lupa && python3 tests/test_customizations.py
"""
from pathlib import Path
import sys, re
from lupa.lua54 import LuaRuntime
ROOT = Path(__file__).resolve().parents[1] / 'simpleui.koplugin'
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().plugin_root = str(ROOT)
lua.execute('''
package.path = plugin_root .. "/?.lua;" .. package.path
persisted = {}
local store = {
 get=function(_,k,d) local v=persisted[k]; if v==nil then return d end; return v end,
 set=function(_,k,v) persisted[k]=v end,
 isTrue=function(_,k) return persisted[k]==true end,
 readSetting=function(self,k,d) return self:get(k,d) end,
 saveSetting=function(self,k,v) return self:set(k,v) end,
}
package.loaded["infra/sui_store"] = store
package.loaded["infra/sui_i18n"] = { translate=function(t) return t end }
existing = { ["/mnt/us/documents/a/同名.epub"]=true,
             ["/mnt/us/documents/b/同名.epub"]=true,
             ["/mnt/us/documents/笔记.txt"]=true,
             ["/plugins/weread.koplugin/main.lua"]=true }
package.loaded["libs/libkoreader-lfs"] = {
 attributes=function(path,what) if existing[path] then return "file" end end
}
Hidden = require("features/library/sui_hidden_books")
local a="/mnt/us/documents/a/同名.epub"
local b="/mnt/us/documents/b/同名.epub"
assert(not Hidden.isHidden(a))
assert(Hidden.hide(a))
assert(Hidden.isHidden("/mnt/base-us/documents/a/同名.epub"))
assert(Hidden.isHidden("/mnt/us/documents/a/../a//同名.epub"))
assert(not Hidden.isHidden(b))
assert(existing[a] and existing[b], "visibility must preserve files")
assert(not Hidden.hide("/missing.epub"))
assert(not Hidden.hide("relative.epub"))
assert(not Hidden.hide("/mnt/us/documents"), "folders are not silently hidden")
assert(#Hidden.filterPaths({a,b})==1)
local state={current_fp=a,recent_fps={a,b},prefetched_data={}}
local clean=Hidden.filterState(state)
assert(clean.current_fp==nil and #clean.recent_fps==1)
assert(state.current_fp==a and #state.recent_fps==2, "history input must not be mutated")
package.loaded["features/library/sui_hidden_books"]=nil
Hidden=require("features/library/sui_hidden_books")
assert(Hidden.isHidden(a), "hidden state survives module reload")
existing[a]=nil
assert(Hidden.restore(a), "a missing source file must not trap its hidden record")
assert(#Hidden.list()==0)
existing[a]=true
assert(Hidden.hide(a))
-- Exercise the actual shared book-hold registration and its callback.
local row
local fm={addFileDialogButtons=function(_,id,f) assert(id=="sui_hide_book"); row=f end}
Hidden.registerHoldAction(fm)
assert(row(a,false)==nil)
local closed=0
local refreshed=0
Hidden.refresh=function(close) refreshed=refreshed+1; if close then close() end end
package.loaded["infra/sui_core"]={Notify={toast=function() end}}
local buttons=row(b,true,nil,function() closed=closed+1 end)
buttons[1].callback()
assert(Hidden.isHidden(b) and closed==1 and refreshed==1)
local manager=Hidden.makeMenuItem()
local entries=manager.sub_item_table_func()
assert(#entries==2)
entries[1].sub_item_table[1].callback()
assert(#Hidden.list()==1)
Hidden.restore(b)
assert(manager.sub_item_table_func()[1].enabled==false)
-- The actual native file-browser gate, preserving existing format/status filters.
package.loaded["ui/widget/booklist"]={getBookStatus=function() return "reading" end}
local FC={show_file=function(_,name) return name~="unsupported.bin" end}
package.loaded["ui/widget/filechooser"]=FC
local config={readChoice=function() return "show" end}
package.loaded["infra/sui_config"]=config
local Finished=require("features/library/sui_finished_books")
Finished.install()
assert(Hidden.hide(a))
assert(not FC.show_file({name="filemanager"},"同名.epub",a))
assert(FC.show_file({name="filemanager"},"同名.epub",b))
assert(FC.show_file({name="filechooser"},"同名.epub",a), "generic file picker remains usable")
assert(not FC.show_file({name="filemanager"},"unsupported.bin","/unsupported.bin"))
Hidden.restore(a)
assert(FC.show_file({name="filemanager"},"同名.epub",a))
Finished.uninstall()
''')
# Run the real shared grid filter in isolation from the e-ink drawing backend.
grid=(ROOT/'engines/sui_book_grid.lua').read_text()
body=re.search(r'local function _filterFileList\(fps, opts, ctx\)(.*?)\nend\n',grid,re.S).group(1)
lua.globals().filter_grid=lua.execute('return function(fps,opts,ctx)'+body+'\nend')
lua.execute('''
local a="/mnt/us/documents/a/同名.epub"
local b="/mnt/us/documents/b/同名.epub"
Hidden.hide(a)
assert(#filter_grid({a,b},{},{})==1)
assert(#filter_grid({a,b},{filterItem=function() return false end},{})==0)
Hidden.restore(a)
assert(#filter_grid({a,b},{},{})==2)
''')
# WeRead: installed/enabled detection, one entry, execution dispatch, removal.
lua.execute('''
local store=package.loaded["infra/sui_store"]
persisted.simpleui_bar_tabs={"homescreen","home","favorites","history","sui_settings"}
local actions={}
package.loaded["features/sui_quickactions"]={
 register=function(d) actions[d.id]=d end, unregister=function(id) actions[id]=nil end
}
local config=package.loaded["infra/sui_config"]
config.ICON={library="book"}
config.loadTabConfig=function() return persisted.simpleui_bar_tabs end
config.saveTabConfig=function(t) persisted.simpleui_bar_tabs=t end
config.effectiveMaxTabs=function() return 6 end
config.invalidateTabsCache=function() end
package.loaded["infra/sui_paths"]={getPluginDir=function() return "/plugins/simpleui.koplugin/" end}
local queue={}
package.loaded["ui/uimanager"]={scheduleIn=function(_,_,fn) queue[#queue+1]=fn end}
local disabled={}
G_reader_settings={readSetting=function() return disabled end}
local launched=0
local plugin={ui={weread={openBookshelf=function() launched=launched+1 end}}}
local Q=require("features/sui_qiaomu")
Q.install(plugin)
Q.install(plugin)
assert(#persisted.simpleui_bar_tabs==6)
assert(actions.qiaomu_weread)
actions.qiaomu_weread.execute()
assert(launched==1)
disabled.weread=true
Q.install(plugin)
assert(actions.qiaomu_weread==nil and #persisted.simpleui_bar_tabs==5)
disabled.weread=nil
existing["/plugins/weread.koplugin/main.lua"]=nil
Q.install(plugin)
assert(actions.qiaomu_weread==nil)
''')
# Parse every shipped Lua file; this is syntax validation, not a device launch.
check=lua.eval('function(s,n) local f,e=load(s,n); assert(f,e) end')
count=0
for path in ROOT.rglob('*.lua'):
    check(path.read_text(),str(path.relative_to(ROOT))); count+=1
print(f'PASS: visibility persistence/restoration, same-name paths, file preservation, shared hold action, native browser gate, grid filter, WeRead detection/launch/deduplication; {count} Lua files parsed.')
