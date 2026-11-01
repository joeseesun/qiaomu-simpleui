"""The OTA updater must reach a prerelease-only repo, throttle after a failed
check and back off; the library scan must not list formats KOReader cannot
open."""
from pathlib import Path
import json
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / 'simpleui.koplugin'

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().plugin_root = str(ROOT)
def _from_lua(value):
    if hasattr(value, 'keys'):
        keys = list(value.keys())
        if keys and all(isinstance(k, int) for k in keys):
            return [_from_lua(value[k]) for k in sorted(keys)]
        return {k: _from_lua(v) for k, v in value.items()}
    return value


def _to_lua(value):
    if isinstance(value, dict):
        return lua.table_from({k: _to_lua(v) for k, v in value.items()})
    if isinstance(value, list):
        return lua.table_from([_to_lua(v) for v in value])
    return value


lua.globals().py_decode = lambda s: _to_lua(json.loads(s))
lua.globals().py_encode = lambda v: json.dumps(_from_lua(v), ensure_ascii=False)

lua.execute(r'''
package.path = plugin_root.."/?.lua;"..package.path
package.loaded["logger"] = { info=function() end, warn=function() end, dbg=function() end, err=function() end }
package.loaded["infra/sui_paths"] = { getPluginDirNoSlash=function() return "/mnt/us/plugins/simpleui.koplugin" end,
                                    getPluginDir=function() return "/mnt/us/plugins/simpleui.koplugin/" end }
package.loaded["infra/sui_text"] = { truncate=function(s,n) return s:sub(1,n) end }
package.loaded["infra/sui_core"] = { Notify = { toast=function() end } }
package.loaded["features/dialogs/sui_dialogs"] = {}
package.loaded["ui/uimanager"] = { scheduleIn=function() end, show=function() end, close=function() end }
package.loaded["ui/trapper"] = { wrap=function(_,fn) fn() end }
package.loaded["json"] = { encode=function() return "{}" end, decode=function(s) return py_decode(s) end }
package.loaded["util"] = { trim=function(s) return (s:gsub("^%s+",""):gsub("%s+$","")) end }
-- No network in the test environment: the request returns no headers,
-- which the updater reports as a network error (its normal failure path).
package.loaded["socket/http"] = { request=function() return nil end }
package.loaded["socket"] = { skip=function(...) return nil, nil, nil end }
package.loaded["ltn12"] = { sink={ table=function() return function() end end, file=function() return function() end end } }
package.loaded["socketutil"] = { set_timeout=function() end, reset_timeout=function() end }
''')

# --- Release-list parsing ---------------------------------------------------
# The repo publishes only prereleases, so "releases/latest" always 404s. The
# updater must parse the release list and pick the newest published entry.
lua.execute(r'''
local Updater = require("infra/sui_updater")
local parse = Updater._parseRelease
assert(type(parse)=="function","the release parser must be reachable")

local list = py_encode({
  { tag_name="v3.0.0-qiaomu.17", prerelease=true, draft=false,
    body="## What is new\n- faster",
    html_url="https://example.invalid/17",
    assets={ { name="simpleui.koplugin.zip",
               browser_download_url="https://example.invalid/17/simpleui.koplugin.zip" },
             { name="SHA256SUMS", browser_download_url="https://example.invalid/17/SHA256SUMS" } } },
  { tag_name="v3.0.0-qiaomu.16", prerelease=true, draft=false, assets={} },
})
local r = assert(parse(list))
assert(r.version=="3.0.0-qiaomu.17","the newest release wins")
assert(r.download_url=="https://example.invalid/17/simpleui.koplugin.zip","the plugin ZIP is picked out of the assets")
assert(r.notes and r.notes:find("faster",1,true),"release notes are kept")

-- A draft is skipped.
local with_draft = py_encode({
  { tag_name="v9.9.9-draft", draft=true, assets={} },
  { tag_name="v3.0.0-qiaomu.17", draft=false, assets={} },
})
assert(assert(parse(with_draft)).version=="3.0.0-qiaomu.17","drafts are ignored")

-- A single release object still parses (older payload shape).
local single = py_encode({ tag_name="v3.0.0-qiaomu.16", assets={} })
assert(assert(parse(single)).version=="3.0.0-qiaomu.16","a single release object is accepted")

-- Garbage in, a clear error out — never a crash.
local bad, err = parse("not json at all")
assert(bad==nil and err~=nil,"unparsable payloads report an error")
''')

# --- Throttle and backoff ---------------------------------------------------
# A failed check must still record the attempt, otherwise the 24 h window
# never opens and every boot repeats the request.
lua.execute(r'''
local Updater = require("infra/sui_updater")

local stored = {}
local gs = {
  readSetting=function(_,k,d) local v=stored[k]; if v==nil then return d end; return v end,
  saveSetting=function(_,k,v) stored[k]=v end,
  flush=function() end,
}
G_reader_settings = gs

-- No network: the check fails, but the attempt is recorded.
stored["sui_upd_last_check"] = nil
stored["sui_upd_fail_count"] = nil
local failed, message = Updater._doNetworkCheck()
assert(failed==false,"a failing check reports failure")
assert(message~=nil,"a failing check reports why")
assert(type(stored["sui_upd_last_check"])=="number" and stored["sui_upd_last_check"]>0,
  "a failed check still records the timestamp — otherwise every boot repeats it")
assert(stored["sui_upd_fail_count"]==1,"the failure counter advances")
''')

# --- Library scan: no KFX --------------------------------------------------
# KOReader cannot open KFX at all, so listing it produced books that appeared
# on the shelf and failed with "format not supported".
lua.execute(r'''
package.loaded["logger"] = { info=function() end, warn=function() end, dbg=function() end }
package.loaded["device"] = { home_dir="/mnt/us/documents" }
package.loaded["features/library/sui_bim_stamp"] = {}
package.loaded["features/library/sui_hidden_books"] = { isHidden=function() return false end }
package.loaded["libs/libkoreader-lfs"] = {
  attributes=function(path,what)
    if what=="modification" then return 0 end
    return { mode="file", modification=0, size=0 }
  end,
  dir=function() return function() end end,
}
local Scan = require("engines/sui_library_scan")
local exts = Scan.BOOK_EXTS
assert(exts.epub and exts.mobi and exts.azw3 and exts.azw and exts.pdf,"openable formats stay listed")
assert(exts.kfx==nil,"KFX is not listed — KOReader cannot open it")
''')

print('PASS: updater parses the prerelease release list, a failed check still '
      'throttles, the library scan no longer lists KFX.')
