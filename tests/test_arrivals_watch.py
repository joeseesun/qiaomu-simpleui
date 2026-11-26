"""[INPUT]: 首页配置、书库扫描与收书刷新事件。
[OUTPUT]: 默认布局迁移、文件扫描和刷新时序的回归结果。
[POS]: 首页显示近期收书的行为测试。
[PROTOCOL]: Update this header on change, then check AGENTS.md
"""
from pathlib import Path
import os, tempfile
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / 'simpleui.koplugin'

with tempfile.TemporaryDirectory() as tmp:
    home = Path(tmp) / 'documents'; home.mkdir()
    (home / 'old.epub').write_text('old')
    lua = LuaRuntime(unpack_returned_tuples=True)
    stats = {'attr': 0, 'dir': 0}

    def attrs(path, key=None):
        stats['attr'] += 1
        try:
            p = Path(path); st = p.stat()
            d = {'mode': 'directory' if p.is_dir() else 'file',
                 'modification': st.st_mtime_ns, 'size': st.st_size}
            return d.get(key) if key else lua.table_from(d)
        except FileNotFoundError:
            return None

    def entries(path):
        stats['dir'] += 1
        return lua.table_from(['.', '..'] + os.listdir(path))

    g = lua.globals()
    g.py_attrs = attrs; g.py_entries = entries
    g.home = str(home); g.plugin_root = str(ROOT)
    g.py_stats = lambda: lua.table_from(stats)
    lua.execute('''
package.path=plugin_root.."/?.lua;"..package.path
package.loaded["libs/libkoreader-lfs"]={attributes=py_attrs,dir=function(path)
 local list=py_entries(path);local i=0;return function() i=i+1;return list[i] end
end}
Logs={}
package.loaded["logger"]={dbg=function() end,info=function(...) Logs[#Logs+1]=table.concat({...}," ") end,warn=function() end}
package.loaded["device"]={home_dir=home}
package.loaded["features/library/sui_bim_stamp"]={get=function() return nil end}
G_reader_settings={readSetting=function() return home end}
Settings={}
package.loaded["infra/sui_store"]={
 get=function(_,k) return Settings[k] end, readSetting=function(_,k) return Settings[k] end,
 set=function(_,k,v) Settings[k]=v end, saveSetting=function(_,k,v) Settings[k]=v end,
 nilOrTrue=function(_,k) return Settings[k]~=false end,
}
package.loaded["infra/sui_i18n"]={translate=function(s) return s end}
package.loaded["features/library/sui_hidden_books"]={isHidden=function() return false end}
-- Timer queue standing in for UIManager:scheduleIn.
Timers={}
package.loaded["ui/uimanager"]={
 _window_stack={},
 scheduleIn=function(_,secs,fn) Timers[#Timers+1]={secs=secs,fn=fn} end,
 unschedule=function(_,fn) for i=#Timers,1,-1 do if Timers[i].fn==fn then table.remove(Timers,i) end end end,
}
UI=package.loaded["ui/uimanager"]
Enabled={flat_library=true}
package.loaded["modules/moduleregistry"]={
 get=function(id) return {id=id} end,
 isEnabled=function(mod) return Enabled[mod.id]==true end,
}
function runTimers()
 local due=Timers;Timers={}
 for _,t in ipairs(due) do
  assert(t.secs>=10 and t.secs<=15,"poll interval must be 10-15 s, got "..t.secs)
  t.fn()
 end
 return #due
end
Arrivals=require("features/library/sui_arrivals")
Scan=require("engines/sui_library_scan")
local invalidations=0
local real_invalidate=Scan.invalidate
Scan.invalidate=function(...) invalidations=invalidations+1; return real_invalidate(...) end
function Invalidations() return invalidations end
-- What the shelf sees: the real recursive scan of the library home.
function Listed(path)
 for _,r in ipairs(Scan.getRaw(home)) do if r.fp==path then return true end end
 return false
end

Screen={_id="hs",_pfx="simpleui_hs_",refreshes=0,_ctx_cache={}}
function Screen:isActive() return self._ctx_cache~=nil and not (self._parked or self._suspended) end
function Screen:_refreshImmediate(keep) assert(keep==true); self.refreshes=self.refreshes+1 end
UI._window_stack={{widget={}},{widget=Screen}}
Arrivals.watch(Screen)
assert(#Timers==1 and Screen._arrivals_state,"showing the home screen arms one timer with a baseline")
''')

    def tick():
        return lua.eval('runTimers()')

    # Idle ticks: a handful of stats, no directory listing, no repaint.
    before = dict(stats)
    for _ in range(3):
        assert tick() == 1
    assert stats['dir'] == before['dir'], 'an idle tick must not list directories'
    assert stats['attr'] - before['attr'] <= 3 * 5, 'an idle tick costs only a few stat calls'
    assert lua.eval('Screen.refreshes') == 0

    # First transfer creates the folder: the home root changes.
    inbox = home / '我的文章'; inbox.mkdir()
    tick()
    assert lua.eval('Screen.refreshes') == 1, 'creating the delivery folder refreshes once'

    # The receiver writes a hidden temp file first: nothing visible changes.
    temp = inbox / '.receiving-4242'
    temp.write_bytes(b'x' * 2048)
    # Some senders keep the extension on their temp name.
    temp_ext = inbox / '.receiving-4243.epub'
    temp_ext.write_bytes(b'y' * 1024)
    os.utime(inbox, ns=(inbox.stat().st_mtime_ns + 10**9,) * 2)
    tick()
    assert lua.eval('Screen.refreshes') == 1, 'an in-flight .receiving-* file must not repaint'
    assert not lua.eval(f'Listed({str(temp)!r})') and not lua.eval(f'Listed({str(temp_ext)!r})'), 'an in-flight transfer is never listed'

    # Verified, renamed into place: the row lists it within one tick.
    final = inbox / '刚传来.epub'
    temp_ext.unlink()
    temp.rename(final)
    os.utime(inbox, ns=(inbox.stat().st_mtime_ns + 2 * 10**9,) * 2)
    os.utime(final, (5000, 5000))
    inv = lua.eval('Invalidations()')
    tick()
    assert lua.eval('Screen.refreshes') == 2, 'the renamed book repaints the home screen'
    assert lua.eval('Invalidations()') > inv, 'the library scan cache is dropped before the repaint'
    assert lua.eval(f'Listed({str(final)!r})'), 'the delivered book reaches the shelf scan'

    # Covered by a menu: no I/O, no repaint; caught up once it closes.
    lua.execute('UI._window_stack[3]={widget={}}')
    (inbox / '第二本.epub').write_text('b')
    os.utime(inbox, ns=(inbox.stat().st_mtime_ns + 3 * 10**9,) * 2)
    refreshes = lua.eval('Screen.refreshes')
    before = dict(stats)
    tick()
    assert lua.eval('Screen.refreshes') == refreshes and stats == before, 'covered: skip the tick'
    lua.execute('UI._window_stack[3]={widget={toast=true}}')
    tick()
    assert lua.eval('Screen.refreshes') == refreshes + 1, 'a toast above the screen does not block it'
    lua.execute('UI._window_stack[3]=nil')

    # Suspend stops the timer; a book arriving meanwhile shows on resume.
    lua.execute('Screen._suspended=true; Arrivals.stop(Screen)')
    assert lua.eval('#Timers') == 0, 'no timer while asleep'
    (inbox / '睡眠时到.epub').write_text('c')
    os.utime(inbox, ns=(inbox.stat().st_mtime_ns + 4 * 10**9,) * 2)
    refreshes = lua.eval('Screen.refreshes')
    lua.execute('Arrivals.watch(Screen)')
    assert lua.eval('#Timers') == 0 and lua.eval('Screen.refreshes') == refreshes, 'not re-armed while suspended'
    lua.execute('Screen._suspended=false; Arrivals.watch(Screen)')
    assert lua.eval('Screen.refreshes') == refreshes + 1, 'resume checks immediately'
    assert lua.eval('#Timers') == 1

    # A queued repaint is not cancelled; the change waits for the next tick.
    (inbox / '排队.epub').write_text('d')
    os.utime(inbox, ns=(inbox.stat().st_mtime_ns + 5 * 10**9,) * 2)
    lua.execute('Screen._refresh_scheduled=true')
    refreshes = lua.eval('Screen.refreshes')
    tick()
    assert lua.eval('Screen.refreshes') == refreshes
    lua.execute('Screen._refresh_scheduled=false')
    tick()
    assert lua.eval('Screen.refreshes') == refreshes + 1

    # Parked under the reader: the timer ends itself.
    lua.execute('Screen._parked=true')
    assert tick() == 1 and lua.eval('#Timers') == 0, 'parked: polling stops'
    lua.execute('Screen._parked=false')

    # Setting off, or no library module on the screen: never polled.
    lua.execute('Settings.simpleui_arrivals_autorefresh=false; Arrivals.watch(Screen)')
    assert lua.eval('#Timers') == 0
    lua.execute('Settings.simpleui_arrivals_autorefresh=nil; Enabled={}; Arrivals.watch(Screen)')
    assert lua.eval('#Timers') == 0
    lua.execute('Enabled={flat_library=true}; Arrivals.watch(Screen)')
    assert lua.eval('#Timers') == 1, 'the Recently added shelf alone also gets live arrivals'

    # The pre-release row leaves saved layouts once; nothing else moves.
    lua.execute('''
local Config={}
-- Load just the helper from sui_config.lua without its dependencies.
local src=io.open(plugin_root.."/infra/sui_config.lua"):read("a")
local a=src:find("function M.removeArrivalsModule",1,true)
local b=src:find("-- First-run defaults. Idempotent:",a,true)
local chunk=load("local M, SUISettings = ...\\n"..src:sub(a,b-1))
local store=package.loaded["infra/sui_store"]
store.del=function(_,k) Settings[k]=nil end
chunk(Config,store)
Settings={
 simpleui_layout={pages={{id=1,modules={"currently","arrivals","flat_library"}},{id=2,modules={{id="arrivals"},"tbr"}}}},
 simpleui_hs_module_order={"currently","arrivals","flat_library"},
 simpleui_hs_arrivals_enabled=true, simpleui_arrivals_placed_v1=true,
 simpleui_hs_flat_library_grid_rows=2,
}
Config.removeArrivalsModule()
assert(table.concat(Settings.simpleui_layout.pages[1].modules,",")=="currently,flat_library")
assert(table.concat(Settings.simpleui_layout.pages[2].modules,",")=="tbr")
assert(table.concat(Settings.simpleui_hs_module_order,",")=="currently,flat_library")
assert(Settings.simpleui_hs_arrivals_enabled==nil and Settings.simpleui_arrivals_placed_v1==nil)
assert(Settings.simpleui_hs_flat_library_grid_rows==2,"the shelf keeps its own settings")
Config.removeArrivalsModule()
assert(table.concat(Settings.simpleui_layout.pages[1].modules,",")=="currently,flat_library","idempotent")
Settings={}
Config.removeArrivalsModule()
assert(Settings.simpleui_layout==nil and Settings.simpleui_hs_module_order==nil,"no saved layout: defaults apply")
''')

    # 复现设备原有的默认布局，并验证定制布局与显式关闭。
    lua.execute('''
local Config={}
local src=io.open(plugin_root.."/infra/sui_config.lua"):read("a")
local a=assert(src:find("    local default_order = {",src:find("function M.applyFirstRunDefaults()",1,true),true))
local b=assert(src:find("    -- Keeps a Homescreen",a,true))
local apply=assert(load("local SUISettings=...;local PFX='simpleui_hs_';local function def(k,v) if SUISettings:get(k)==nil then SUISettings:set(k,v) end end\\n"..src:sub(a,b-1)))
local store=package.loaded["infra/sui_store"]
store.isTrue=function(_,k) return Settings[k]==true end
local function oldStock()
 return {"quote","currently","recent","clock","coverdeck","new_books","tbr","collections","reading_goals","reading_stats","quick_actions_row_000001","quick_actions_row_000002","quick_actions_row_000003","action_list"}
end
local function legacy(extra)
 Settings=extra or {}
 Settings.simpleui_hs_module_order=oldStock()
 apply(store)
end
legacy({simpleui_hs_new_books_enabled=false})
assert(Settings.simpleui_hs_flat_library_enabled==true)
assert(Settings.simpleui_hs_module_order[3]=="flat_library")
assert(Settings.simpleui_hs_module_order[4]=="recent")
Settings.simpleui_hs_flat_library_enabled=false
apply(store)
assert(Settings.simpleui_hs_flat_library_enabled==false)
legacy({simpleui_hs_flat_library_enabled=false})
assert(Settings.simpleui_hs_module_order[3]=="recent")
legacy({simpleui_hs_new_books_enabled=true})
assert(Settings.simpleui_hs_module_order[3]=="recent")
legacy({simpleui_layout={pages={{modules={"recent"}}}}})
assert(Settings.simpleui_hs_flat_library_enabled==nil)
assert(Settings.simpleui_hs_module_order[3]=="recent")
Settings={simpleui_hs_module_order={"recent","currently"}}
apply(store)
assert(Settings.simpleui_hs_flat_library_enabled==nil)
Settings={}
apply(store)
assert(Settings.simpleui_hs_flat_library_enabled==true and Settings.simpleui_hs_module_order[3]=="flat_library")
''')

    src = (ROOT / 'infra/sui_config.lua').read_text()
    assert '"currently", "flat_library", "recent"' in src, 'fresh installs get the shelf after Currently Reading'
    assert 'arrivals_enabled' not in src.replace('simpleui_hs_arrivals_enabled', ''), 'no duplicate row is enabled'
    reg = (ROOT / 'modules/moduleregistry.lua').read_text()
    assert 'module_arrivals' not in reg and not (ROOT / 'modules/module_arrivals.lua').exists()
    eng = (ROOT / 'engines/sui_screen_engine.lua').read_text()
    for hook in ('function ScreenWidget:_pauseBackgroundWork()\n    self:_stopArrivalsWatch()',):
        assert hook in eng
    assert eng.count('self:_armArrivalsWatch()') == 2, 'armed on show and on resume'
    assert 'inst:_armArrivalsWatch()' in (ROOT / 'infra/sui_patches.lua').read_text(), 'armed on unpark'
    recent = (ROOT / 'modules/module_recent.lua').read_text()
    for field in ('always_label = true', 'label_lines  = 2', 'progress_style = { default = "badge" }'):
        assert field in recent, 'Recent Books matches the shelf: ' + field
    grid = (ROOT / 'engines/sui_book_grid.lua').read_text()
    assert grid.count('progressDrawsText(progress_style) or opts.always_label') == 2, 'build and getHeight must reserve the same caption'
    assert grid.count('labelBlockHeight(') == 3 and grid.count('gridRowGap(') == 3, 'one caption height and row gap for build and getHeight'

print('PASS: Wi-Fi deliveries appear on an open Homescreen within one 12 s tick; .receiving-* temp files never show; idle ticks only stat; paused when covered, suspended or parked; resume catches up; the duplicate row leaves saved layouts once.')
