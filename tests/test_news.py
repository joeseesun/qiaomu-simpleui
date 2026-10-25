"""Exercise news persistence, offline reading and UI actions using shipped Lua."""
from pathlib import Path
import json, tempfile
from lupa.lua54 import LuaRuntime, lua_type

ROOT = Path(__file__).resolve().parents[1] / 'simpleui.koplugin'
with tempfile.TemporaryDirectory() as tmp:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('native_null=function() return native_null end')
    is_null=lua.eval('function(v) return v==native_null end')
    def to_lua(value):
        if value is None:
            return lua.globals().native_null
        if isinstance(value, dict):
            return lua.table_from({k: to_lua(v) for k, v in value.items()})
        if isinstance(value, list):
            return lua.table_from([to_lua(v) for v in value])
        return value
    def from_lua(value):
        if lua_type(value) == 'function' and is_null(value):
            return None
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
package.loaded["features/sui_news_cache"]={touch=function() end,makeRoom=function() return true end,
 root=function() return tmp.."/simpleui/news" end,reserve=function() return function() end end}
package.loaded["features/sui_news_images"]={html=function(a) return a.body end,urls=function() return {} end}
package.loaded["ui/size"]={padding={buttontable=6}}
package.loaded["features/sui_style"]={restoreDefaultIcon=function() end}
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
-- Use the existing origin's DNS name, retaining the public API's TLS/Host.
-- The CDN remains one bounded fallback; do not retry real HTTP errors.
local commands,attempts={},0
package.loaded["socket"].dns.getaddrinfo=function()
 return {{family="inet",addr="172.67.1.1"},{family="inet",addr="104.21.1.1"}}
end
package.loaded["device"].isKindle=function() return true end
local real_popen=io.popen
local real_open=io.open
io.open=function(path,...)
 if path=="/usr/bin/curl" then return {close=function() return true end} end
 return real_open(path,...)
end
io.popen=function(command)
 attempts=attempts+1;commands[#commands+1]=command
 local result=(attempts==1 and 'partial' or '{"entries":[]}')..string.char(10).."200"..string.char(10)..(attempts==1 and "28" or "0")
 local done=false
 return {read=function() if done then return end;done=true;return result end,close=function() end}
end
assert(N.request("/api/entries").entries and attempts==2)
assert(commands[1]:find("--connect-to 'rss.qiaomu.ai:443:vps2.qiaomu.ai:443'",1,true),
 "Kindle must avoid the failing CDN TLS path using the existing origin")
assert(not commands[2]:find("--connect-to",1,true), "fallback uses the public API's DNS")
assert(not commands[1]:find("--resolve",1,true), "do not pin deployment IPs")
assert(commands[1]:find("https://rss.qiaomu.ai/api/entries",1,true))
assert(commands[1]:find("--proto '=https'",1,true) and not commands[1]:find("--insecure",1,true))
attempts=0
io.popen=function()
 attempts=attempts+1;local done=false
 return {read=function() if done then return end;done=true;return string.char(10).."403"..string.char(10).."22" end,close=function() end}
end
local response,error_message=N.request("/api/entries")
assert(response==nil and attempts==1 and error_message=="HTTP 403")
io.popen=real_popen
io.open=real_open
package.loaded["device"].isKindle=function() return false end
-- Empty/stale AI assets fall back to the full original, never a summary.
local real_request=N.request
N.request=function(path)
 if path:match("/rewrite$") then return {rewrite={body="old",stale=true}} end
 return {entry={id="a",content='<p>Full text</p><script>bad()</script><img src="https://x/p.png">'}}
end
local original=N.fetchArticle("a")
assert(original.format=="html" and original.body=='<p>Full text</p><img src="https://x/p.png">')
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
 onSwipe=function(self) self.paged="native" end,onNextPage=function(self) self.paged=1 end,
 onPrevPage=function(self) self.paged=-1 end,onCloseWidget=function() end}
package.loaded["ui/widget/menu"]=Menu
package.loaded["ui/widget/buttondialog"]={new=function(_,o) return o end}
package.loaded["ui/widget/infomessage"]={new=function(_,o) return o end}
package.loaded["ui/widget/textviewer"]={new=function(_,o)
 o.box_widget={page_number=1,page_count=6}
 o.scroll_widget={scrollToRatio=function(_,r) o.box_widget.page_number=1+math.floor(r*6) end,
 scrollText=function(_,d) o.box_widget.page_number=o.box_widget.page_number+d end}
 o.button_table={getButtonById=function() return {width=250,setIcon=function(_,_,width)
  assert(width==250,"bookmark changes must preserve the native button width")
 end} end}
 o.onClose=function() o.close_callback() end
 return o
end}
package.loaded["ui/network/manager"]={isOnline=function() return false end,
 runWhenOnline=function() error("offline article must not enable networking") end}
package.loaded["libs/libkoreader-lfs"]={attributes=function() end,dir=function() return function() end end}
package.loaded["logger"]=package.loaded["logger"] or {warn=function() end,info=function() end}
local R=require("screens/sui_news_reader")
R.open()
local list=shown[#shown]
list:onSwipe(nil,{direction="north"});assert(list.paged==1,"swipe up pages forward")
list:onSwipe(nil,{direction="south"});assert(list.paged==-1,"swipe down pages back instead of closing")
list:onSwipe(nil,{direction="west"});assert(list.paged=="native")
local entry={id="a",title="Original",titleZh="中文标题",sourceName="来源",sourceId="s",published="2026-10-25"}
R.openArticle(entry)
local viewer=shown[#shown]
assert(viewer.title=="中文标题" and viewer.box_widget.page_number==3)
assert(N.flag("a").read==true)
viewer.buttons_table[1][2].callback()
assert(#viewer.buttons_table==1 and #viewer.buttons_table[1]==4,"article tools occupy one icon row")
for _,button in ipairs(viewer.buttons_table[1]) do assert(button.icon and not button.text) end
viewer.buttons_table[1][3].callback()
assert(N.flag("a").starred==false)
viewer:onClose()
assert(N.flag("a").page==4 and list.item_table)
-- A rendering error in a tapped article must not terminate KOReader.
package.loaded["logger"]={warn=function() end}
local TV=package.loaded["ui/widget/textviewer"];local tv_new=TV.new
TV.new=function() error("fixture render failure") end
R.openArticle(entry)
assert(shown[#shown].text:find("fixture render failure",1,true),"article failure is reported in place")
TV.new=tv_new
R.actions(entry)
shown[#shown].buttons[1][1].callback()
assert(not N.flag("a").read)
assert(not package.loaded["apps/reader/readerui"] and not package.loaded["readhistory"])
-- LuaJSON represents JSON null with a function. Native Trapper cannot
-- serialize it as a Lua object; exercise the real job through string IPC.
local online=true
local requests=0
package.loaded["ui/network/manager"]={
 isOnline=function() return online end,
 runWhenOnline=function(_,callback) callback() end,
}
package.loaded["ui/trapper"]={
 wrap=function(_,callback) callback() end,
 dismissableRunInSubprocess=function(_,task,_,simple)
  assert(simple==true,"news tasks must use native Trapper's string return mode")
  local result=task();assert(type(result)=="string")
  -- The boundary only carries bytes, so LuaJSON's null function stays local.
  return true,result
 end,
}
N.fetchIndex=function()
 requests=requests+1
 return {entries={{id="fresh",title="Fresh",sourceId="s",publishedTs=999,nullable=native_null}}}
end
R.update()
assert(N.state().entries[1].id=="fresh" and requests==1)
list:onCloseWidget()
R.open();assert(requests==2,"entering News refreshes even with a cached list")
shown[#shown]:onCloseWidget()
online=false
R.open();assert(requests==2,"offline visits retain cached content without enabling Wi-Fi")
online=true
N.fetchIndex=function() return nil,"HTTP 503" end
R.update();assert(shown[#shown].text:find("HTTP 503",1,true),"IPC retains the useful error")
assert(N.state().entries[1].id=="fresh","a failed refresh keeps the cached list")
N.fetchIndex=function() error("fixture task exception") end
R.update();assert(shown[#shown].text:find("fixture task exception",1,true))
package.loaded["ui/trapper"].dismissableRunInSubprocess=function() return false end
local count=#shown
R.update();assert(#shown==count,"cancelled refresh shows no failure notice")
-- Background media tasks attach to the article rather than creating a modal.
local I=package.loaded["features/sui_news_images"]
local C=package.loaded["features/sui_news_cache"]
local releases,reinitializations=0,0
C.reserve=function() return function() releases=releases+1 end end
I.ARTICLE_BUDGET=8*1024*1024
I.urls=function() return {"https://images.example/photo.png"} end
I.path=function() return nil end
I.download=function() return {count=1,bytes=100} end
local cancelled=false
N.cache("a",{body="Cached article with images",format="html",media_version=1})
package.loaded["ui/trapper"].dismissableRunInSubprocess=function(_,task,owner,simple)
 assert(type(owner)=="table" and owner.text and simple,"background task uses the existing viewer")
 owner.reinit=function() reinitializations=reinitializations+1 end
 owner.dismiss_callback=function() cancelled=true end
 return true,task()
end
R.openArticle(entry)
assert(releases==1 and reinitializations==1,"completion updates local images and releases its budget")
assert(shown[#shown].dismiss_callback==nil,"completed job clears its cancellation hook")
package.loaded["ui/trapper"].dismissableRunInSubprocess=function(_,task,owner)
 owner.reinit=function() reinitializations=reinitializations+1 end
 owner.dismiss_callback=function() cancelled=true end
 owner:onCloseWidget()
 return true,task()
end
R.openArticle(entry)
assert(cancelled and releases==2 and reinitializations==1,"closing cancels and prevents late image redraw")
-- Thumbnails never enter KOReader's shared 8 MiB ImageCache (its assert
-- aborted KOReader on device) and a decode failure only drops the image.
local made={}
local function widget(o) o=o or {};o.getSize=o.getSize or function() return {w=10,h=10} end;o.free=function() end;return o end
local function ctor() return {new=function(_,o) return widget(o) end} end
package.loaded["device"].screen.scaleBySize=function(_,n) return n end
package.loaded["ui/font"]={getFace=function() return {} end}
package.loaded["ffi/blitbuffer"]={COLOR_DARK_GRAY=1}
package.loaded["ui/geometry"]={new=function(_,o) return o end}
for _,m in ipairs{"ui/widget/textwidget","ui/widget/textboxwidget","ui/widget/verticalgroup","ui/widget/horizontalgroup",
 "ui/widget/verticalspan","ui/widget/horizontalspan","ui/widget/container/leftcontainer",
 "ui/widget/container/centercontainer","ui/widget/container/framecontainer",
 "ui/widget/container/rightcontainer","ui/widget/overlapgroup"} do package.loaded[m]=ctor() end
package.loaded["ui/widget/imagewidget"]={new=function(_,o)
 made[#made+1]=o
 o.getSize=function() if o.file=="bad.jpg" then error("not enough storage for cache") end;return {w=64,h=64} end
 return widget(o)
end}
I.path=function(url) return url end
local function row(image)
 return {entry={news_entry={id="a",title="T",sourceName="S",sourceId="s",published="2026-10-25",image=image}},
  dimen={w=1000,h=180},content_width=968,_underline_container={}}
end
local good,bad=row("good.jpg"),row("bad.jpg")
package.loaded["features/sui_news_rows"]=nil
require("features/sui_news_rows").apply({item_group={good,bad}})
assert(#made==2 and made[1].file_do_cache==false and made[2].file_do_cache==false,"thumbnails bypass the shared image cache")
assert(good._underline_container[1] and bad._underline_container[1],"a failed thumbnail keeps the text row")
-- Channels follow Qiaomu AI RSS: groups from the bundled catalog, per-channel memory.
local C=require("features/sui_news_channels")
local f=io.open(plugin_root.."/data/qiaomu_sources.json","rb");local catalog=py_decode(f:read("*a")).sources;f:close()
local counts={}
for _,src in ipairs(C.channels(catalog)) do counts[C.group(src)]=(counts[C.group(src)] or 0)+1 end
assert(counts.wechat==10 and counts.podcast==16 and counts.newsletter==18 and counts.blogs==15,"bundled catalog groups match the Obsidian plugin")
assert(#C.community(catalog)==1)
assert(C.group({id="x",siteUrl="https://foo.substack.com/feed"})=="newsletter" and C.group({id="wechat-a"})=="wechat")
-- Sources saved by older builds lacked categories: reload the bundled catalog.
N.state().sources={{id="qiaomu-blog",name="乔木博客"}};N.save()
package.loaded["features/sui_news"]=nil;N=require("features/sui_news")
assert(N.state().sources[1].category,"uncategorized sources are upgraded")
N.merge({},{{id="s1",name="S",category="podcast",siteUrl="https://x.qiaomu.ai"}})
assert(N.state().sources[1].category=="podcast" and N.state().sources[1].siteUrl=="https://x.qiaomu.ai","merge keeps channel fields")
N.state().sources=catalog
package.loaded["screens/sui_news_reader"]=nil;R=require("screens/sui_news_reader")
online=false
R.open();local list2=shown[#shown]
list2:onLeftButtonTap()
local hub=shown[#shown]
local texts={};for _,row in ipairs(hub.item_table) do texts[#texts+1]=row.text end
local joined=table.concat(texts,"|")
assert(joined:find("WeChat",1,true) and joined:find("Podcasts",1,true) and joined:find("Reader community",1,true),"channel hub lists groups and community")
local group_row;for _,row in ipairs(hub.item_table) do if row.text=="WeChat" then group_row=row end end
assert(group_row.mandatory:find("10 sources",1,true))
group_row.callback()
local gp=shown[#shown];assert(gp.title=="WeChat" and #gp.item_table==11,"group page: all-in-group plus 10 sources")
-- Choosing a channel switches the list, refreshes it online and remembers its filter.
online=true
package.loaded["ui/trapper"].dismissableRunInSubprocess=function(_,task) return true,task() end
local fetched
N.fetchGroup=function(ids) fetched=ids;return {entries={{id="g1",title="Group article",sourceId=ids[1],publishedTs=5}}} end
gp.item_table[1].callback()
assert(fetched and #fetched==10 and list2.title=="WeChat","group channel fetches its sources and titles the list")
R.channelPage();for _,row in ipairs(shown[#shown].item_table) do if row.text=="Unread" then row.callback() end end
R.channelPage();for _,row in ipairs(shown[#shown].item_table) do if row.text=="All picks" then row.callback() end end
assert(list2.title=="All picks" and list2.subtitle=="All articles","each channel restores its own filter")
R.channelPage();R.groupPage("wechat");shown[#shown].item_table[1].callback()
assert(list2.subtitle=="Unread","returning to a channel restores the filter it had")
''')
print('PASS: persisted offline content/read/star/progress, bounded rolling index, saved retention, ID/size/HTTP validation, original fallback, real article/menu callbacks, book-history isolation and Obsidian-matching channels with per-channel memory.')
