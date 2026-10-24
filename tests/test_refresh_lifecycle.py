"""A visibility mutation must repaint through one owner, after invalidation."""
from pathlib import Path
from lupa.lua54 import LuaRuntime
root=Path(__file__).resolve().parents[1]/'simpleui.koplugin'
lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().plugin_root=str(root)
lua.execute('''
package.path=plugin_root.."/?.lua;"..package.path
local settings={}
package.loaded["infra/sui_store"]={get=function(_,k) return settings[k] end,set=function(_,k,v) settings[k]=v end}
package.loaded["infra/sui_i18n"]={translate=function(s) return s end}
package.loaded["libs/libkoreader-lfs"]={attributes=function() return "file" end}
local events={}
local function record(e) events[#events+1]=e end
package.loaded["engines/sui_library_scan"]={invalidate=function() record("invalidate_scan") end}
local screen_live=true
package.loaded["engines/sui_screen_engine"]={
 markAllStale=function() record("mark_stale") end,
 invalidateAllCfgAndRefresh=function() record("extra_home_repaint") end,
 liveScreenIds=function() return screen_live and {"hs"} or {} end,
 refreshAllLiveImmediate=function() record("restore_home_repaint") end,
}
local fm={file_chooser={refreshPath=function()
 record(fm and "unused" or "background_repaint")
end}}
-- Lua local initializers do not capture their own binding: use assignment.
fm.file_chooser.refreshPath=function() record(fm._navbar_suppress_path_change and "browser_repaint" or "background_repaint") end
package.loaded["apps/filemanager/filemanager"]={instance=fm}
package.loaded["infra/sui_core"]={Notify={toast=function() record("overlay") end}}
local tasks={}
package.loaded["ui/uimanager"]={nextTick=function(_,fn) tasks[#tasks+1]=fn end}
local Hidden=require("features/library/sui_hidden_books")
local row
fm.addFileDialogButtons=function(_,_,fn) row=fn end
Hidden.registerHoldAction(fm)
row("/mnt/us/documents/a.epub",true,nil,function()
 record("close_sheet")
 record("caller_repaint")
end)[1].callback()
local order=table.concat(events,",")
assert(order=="invalidate_scan,mark_stale,close_sheet,caller_repaint", "hide lifecycle: "..order)
assert(#tasks==0,"the host already owns the hide repaint")
-- Restoring from settings has no book-dialog callback: schedule exactly one
-- visible owner. Never repaint the file manager underneath a live homepage.
events={}
Hidden.refresh()
assert(table.concat(events,",")=="invalidate_scan,mark_stale")
assert(#tasks==1)
table.remove(tasks,1)()
assert(events[#events]=="restore_home_repaint")
for _,event in ipairs(events) do assert(event~="background_repaint") end
-- If no home screen is live, refresh only the browser with path-change events
-- suppressed, and restore the previous flag even when the refresh errors.
screen_live=false
events={}
Hidden.refresh()
table.remove(tasks,1)()
assert(events[#events]=="browser_repaint")
assert(fm._navbar_suppress_path_change==nil)
fm._navbar_suppress_path_change="previous"
fm.file_chooser.refreshPath=function() error("synthetic paint failure") end
Hidden.refresh()
local ok=pcall(table.remove(tasks,1))
assert(not ok and fm._navbar_suppress_path_change=="previous", "restore suppression after an error")
''')
print('PASS: single-owner hide/restore redraw, invalidation-before-close, no background browser repaint under home.')
