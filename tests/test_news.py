"""Exercise news persistence, offline reading and UI actions using shipped Lua."""
from pathlib import Path
import json, tempfile
from lupa.lua54 import LuaRuntime, lua_type

ROOT = Path(__file__).resolve().parents[1] / 'simpleui.koplugin'
with tempfile.TemporaryDirectory() as tmp:
    lua = LuaRuntime(unpack_returned_tuples=True)
    def to_lua(value):
        if isinstance(value, dict):
            return lua.table_from({k: to_lua(v) for k, v in value.items()})
        if isinstance(value, list):
            return lua.table_from([to_lua(v) for v in value])
        return value
    def from_lua(value):
        if lua_type(value) == 'table':
            keys = list(value.keys())
            if keys and all(isinstance(k, int) for k in keys):
                return [from_lua(value[k]) for k in sorted(keys)]
            return {k: from_lua(v) for k, v in value.items()}
        return value
    lua.globals().py_encode = lambda value: json.dumps(from_lua(value), ensure_ascii=False)
    lua.globals().py_decode = lambda value: to_lua(json.loads(value))
    lua.globals().mkdir = lambda path: Path(path).mkdir(parents=True, exist_ok=True)
    lua.globals().tmp = tmp
    lua.globals().plugin_root = str(ROOT)
    lua.execute('''
package.path=plugin_root.."/?.lua;"..package.path
package.loaded["json"]={encode=py_encode,decode=py_decode}
package.loaded["datastorage"]={getSettingsDir=function() return tmp end}
package.loaded["util"]={makePath=mkdir}
package.loaded["infra/sui_paths"]={getPluginDir=function() return plugin_root.."/" end}
package.loaded["infra/sui_i18n"]={translate=function(s) return s end}
local N=require("features/sui_news")
assert(not N.validId("../escape")); assert(not N.validId("x/y")); assert(N.validId("abc-123"))
N.merge({{id="a",title="Original",titleZh="中文标题",sourceId="s",publishedTs=1},
 {id="a",title="duplicate"}, {id="../escape",title="bad"}, false}, {{id="s",name="来源"}})
assert(#N.state().entries==1 and N.title(N.state().entries[1])=="中文标题")
assert(N.state().entries[1].sourceName=="来源")
N.cache("a",{body="# 正文",format="md"})
N.cache("index",{body="not an index",format="html"})
assert(#N.state().entries==1, "article IDs cannot overwrite the list index")
N.flag("a").starred=true;N.flag("a").page=3;N.flag("a").pages=6;N.save()
package.loaded["features/sui_news"]=nil
N=require("features/sui_news")
assert(N.cached("a").body=="# 正文" and N.flag("a").page==3)
local many={}
for i=1,205 do many[i]={id="id"..i,title="Article "..i,publishedTs=i} end
N.merge(many)
assert(#N.state().entries==201, "retain an old starred article beyond the rolling 200")
assert(N.flag("a").starred and N.cached("a"))
local f=assert(io.open(tmp.."/simpleui/news/index.json","rb"));assert(f:read("*a"):find("中文标题",1,true));f:close()
assert(not pcall(N.cache,"../escape",{body="bad",format="html"}))
assert(not pcall(N.cache,"large",{body=string.rep("x",400001),format="html"}))
-- Exercise real transport validation, including HTTP errors and malformed JSON.
local timeout_reset=0
package.loaded["socketutil"]={set_timeout=function() end,reset_timeout=function() timeout_reset=timeout_reset+1 end}
package.loaded["device"]={isKindle=function() return false end}
package.loaded["socket"]={dns={getaddrinfo=function() return {} end}}
local payload='{"entries":[]}'
local status=200
package.loaded["socket.http"]={request=function(request)
 assert(request.url:match("^https://rss%.qiaomu%.ai/api/"))
 assert(request.redirect==false)
 request.sink(payload);request.sink(nil)
 return 1,status
end}
assert(N.request("/api/entries").entries)
status=503;assert(N.request("/api/entries")==nil)
status=200;payload="not json";assert(N.request("/api/entries")==nil)
assert(timeout_reset==3)
-- Try at most two DNS-advertised IPv4 endpoints. Keep the original TLS SNI
-- and Host semantics and do not retry real HTTP errors on another address.
local commands,attempts={},0
package.loaded["socket"].dns.getaddrinfo=function()
 return {{family="inet",addr="172.67.1.1"},{family="inet",addr="104.21.1.1"}}
end
package.loaded["device"].isKindle=function() return true end
local real_popen=io.popen
io.popen=function(command)
 attempts=attempts+1;commands[#commands+1]=command
 local result=(attempts==1 and 'partial' or '{"entries":[]}')..string.char(10)..(attempts==1 and "000" or "200")..string.char(10)..(attempts==1 and "28" or "0")
 local done=false
 return {read=function() if done then return end;done=true;return result end,close=function() end}
end
assert(N.request("/api/entries").entries and attempts==2)
assert(commands[1]:find("rss.qiaomu.ai:443:104.21.1.1",1,true))
assert(commands[2]:find("rss.qiaomu.ai:443:172.67.1.1",1,true))
assert(commands[1]:find("https://rss.qiaomu.ai/api/entries",1,true))
assert(commands[1]:find("--proto '=https'",1,true) and not commands[1]:find("--insecure",1,true))
attempts=0
io.popen=function()
 attempts=attempts+1;local done=false
 return {read=function() if done then return end;done=true;return string.char(10).."403"..string.char(10).."22" end,close=function() end}
end
assert(N.request("/api/entries")==nil and attempts==1)
io.popen=real_popen
package.loaded["device"].isKindle=function() return false end
-- Empty/stale AI assets fall back to the full original, never a summary.
local real_request=N.request
N.request=function(path)
 if path:match("/rewrite$") then return {rewrite={body="old",stale=true}} end
 return {entry={id="a",content='<p>Full text</p><script>bad()</script><img src="https://x/p.png">'}}
end
local original=N.fetchArticle("a")
assert(original.format=="html" and original.body=="<p>Full text</p>")
N.request=function() return {rewrite={body="# 中文解读",stale=false}} end
assert(N.fetchArticle("a").format=="md")
N.request=real_request
-- The UI's real callbacks: opening cached news never needs networking or ReaderUI.
local shown={}
local U={show=function(_,w) shown[#shown+1]=w end,close=function() end,setDirty=function() end}
package.loaded["ui/uimanager"]=U
package.loaded["device"]={screen={getWidth=function() return 1072 end,getHeight=function() return 1448 end,scaleBySize=function(_,n) return n end}}
local Menu={new=function(self,o) setmetatable(o,{__index=self});return o end,
 switchItemTable=function(self,title,items,_,_,subtitle) self.title=title;self.item_table=items;self.subtitle=subtitle end,
 onCloseWidget=function() end}
package.loaded["ui/widget/menu"]=Menu
package.loaded["ui/widget/buttondialog"]={new=function(_,o) return o end}
package.loaded["ui/widget/infomessage"]={new=function(_,o) return o end}
package.loaded["ui/widget/textviewer"]={new=function(_,o)
 o.box_widget={page_number=1,page_count=6}
 o.scroll_widget={scrollToRatio=function(_,r) o.box_widget.page_number=1+math.floor(r*6) end,
 scrollText=function(_,d) o.box_widget.page_number=o.box_widget.page_number+d end}
 o.button_table={getButtonById=function() return {setText=function() end} end}
 o.onClose=function() o.close_callback() end
 return o
end}
package.loaded["ui/network/manager"]={runWhenOnline=function() error("offline article must not enable networking") end}
local R=require("screens/sui_news_reader")
R.open()
local list=shown[#shown]
local entry={id="a",title="Original",titleZh="中文标题",sourceName="来源",sourceId="s",published="2026-10-25"}
R.openArticle(entry)
local viewer=shown[#shown]
assert(viewer.title=="中文标题" and viewer.box_widget.page_number==3)
assert(N.flag("a").read==true)
viewer.buttons_table[1][2].callback()
viewer.buttons_table[2][1].callback()
assert(N.flag("a").starred==false)
viewer:onClose()
assert(N.flag("a").page==4 and list.item_table)
R.actions(entry)
shown[#shown].buttons[1][1].callback()
assert(not N.flag("a").read)
assert(not package.loaded["apps/reader/readerui"] and not package.loaded["readhistory"])
''')
print('PASS: persisted offline content/read/star/progress, bounded rolling index, saved retention, ID/size/HTTP validation, original fallback, real article/menu callbacks and book-history isolation.')
