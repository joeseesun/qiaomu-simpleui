"""News EPUBs open in KOReader's reader without leaking into book state."""
from pathlib import Path
import tempfile
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / 'simpleui.koplugin'
with tempfile.TemporaryDirectory() as tmp:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().tmp = tmp
    lua.globals().plugin_root = str(ROOT)
    lua.globals().mkdir = lambda path: Path(path).mkdir(parents=True, exist_ok=True)
    lua.globals().listdir = lambda path: lua.table_from(sorted(p.name for p in Path(path).iterdir()))
    lua.globals().isfile = lambda path: Path(path).is_file()
    lua.execute(r'''
package.path=plugin_root.."/?.lua;"..package.path
local files={}
package.loaded["util"]={makePath=mkdir}
package.loaded["logger"]={info=function() end,warn=function() end}
-- KOReader opens "./settings/..." but history stores real paths.
package.loaded["ffi/util"]={realpath=function(p) return (p:gsub("/%./","/")) end}
package.loaded["libs/libkoreader-lfs"]={
 attributes=function(path,key) if not isfile(path) then return nil end
  local info={mode="file",modification=0,size=1};return key and info[key] or info end,
 dir=function(path) local names=listdir(path);local i=0
  return function() i=i+1;return names[i] end end,
}
local root=tmp.."/news"
package.loaded["features/sui_news_cache"]={root=function() return root end,touch=function() end}
mkdir(root.."/images")
local img=io.open(root.."/images/"..string.rep("a",64)..".png","wb");img:write("PNGDATA");img:close()
package.loaded["features/sui_news_images"]={html=function(a) return a.body end}
-- In-memory EPUB writer that also creates the file on close.
package.loaded["ffi/archiver"]={Writer={new=function()
 local w={}
 function w:open(path) self.path=path;files[path]={};return true end
 function w:setZipCompression() end
 function w:addFileFromMemory(name,content) files[self.path][name]=content end
 function w:close() local f=io.open(self.path,"wb");f:write("zip");f:close() end
 return w end}}
local sidecars={}
package.loaded["docsettings"]={
 hasSidecarFile=function(_,path) return sidecars[path]~=nil end,
 open=function(_,path) sidecars[path]=sidecars[path] or {}
  local s=sidecars[path]
  return {saveSetting=function(_,k,v) s[k]=v end,readSetting=function(_,k) return s[k] end,
   flush=function() s.flushed=true end,purge=function() sidecars[path]=nil end} end,
}
package.loaded["document/credocument"]={engineInit=function() return {getFontFaces=function()
 return {"Noto Sans CJK SC","LXGW WenKai Screen"} end} end}
local News={title=function(e) return e.titleZh or e.title end}
local Epub=require("features/sui_news_epub")
local entry={id="abc",title="A <b> & C",sourceName="来源",published="2026-10-25T08:00"}
local nextEntry={id="n2",title="Next one"}
package.loaded["features/sui_news_session"]={NEXT_URI="qiaomu-next:"}
local path=Epub.build(entry,{version="rewrite",body='<html><body><h2>第一节</h2><p>正文</p><img src="'..string.rep("a",64)..'.png"/><h3 id="keep">第二节</h3></body></html>'},News,nextEntry)
package.loaded["features/sui_news_session"]=nil
assert(files[path..".tmp"]["OEBPS/content.html"]:find('<a href="qiaomu-next:n2">下一篇：Next one ›</a>',1,true),"article ends with a next link")
assert(path==root.."/epub/abc.epub" and Epub.isNewsDoc(path) and not Epub.isNewsDoc("/mnt/us/documents/book.epub"))
local book=files[path..".tmp"]
assert(book["mimetype"]=="application/epub+zip" and book["OEBPS/stylesheet.css"]:find("line-height: 1.6",1,true))
local content=book["OEBPS/content.html"]
assert(content:find('<h1 class="qm-title">A &lt;b&gt; &amp; C</h1>',1,true),"title is escaped")
assert(content:find('<h2 id="qm-h1">',1,true) and content:find('<h3 id="keep">',1,true),"headings get anchors")
assert(content:find('src="images/'..string.rep("a",64)..'.png"',1,true) and book["OEBPS/images/"..string.rep("a",64)..".png"]=="PNGDATA","cached images are embedded")
assert(book["OEBPS/toc.ncx"]:find("content.html#qm-h1",1,true) and book["OEBPS/toc.ncx"]:find("content.html#keep",1,true),"TOC follows headings")
files={}
assert(Epub.build(entry,{version="rewrite",body='<html><body><h2>第一节</h2><p>正文</p><img src="'..string.rep("a",64)..'.png"/><h3 id="keep">第二节</h3></body></html>'},News,nextEntry)==path and not next(files),"unchanged articles reuse their EPUB")
-- Typography: new articles inherit the last news profile, default to WenKai.
Epub.seed(path,nil)
assert(sidecars[path].font_face=="LXGW WenKai Screen" and sidecars[path].flushed)
local other=root.."/epub/next.epub"
Epub.seed(other,{font_face="Noto Sans CJK SC",copt_line_spacing=120})
assert(sidecars[other].font_face=="Noto Sans CJK SC" and sidecars[other].copt_line_spacing==120)

-- Session hooks: only news documents are isolated from book state.
local settings={lastfile="/mnt/us/documents/book.epub"}
G_reader_settings={readSetting=function(_,k) return settings[k] end,saveSetting=function(_,k,v) settings[k]=v end}
local hist={}
package.loaded["readhistory"]={hist=hist,
 removeItemByPath=function(self,p) for i=#self.hist,1,-1 do if self.hist[i].file==p then table.remove(self.hist,i) end end end,
 ensureLastFile=function(self) settings.lastfile=self.hist[1] and self.hist[1].file end}
local closed,fm_target={},"unset"
local ReaderUI={}
function ReaderUI.onClose(self) closed[#closed+1]=self.document.file;settings.lastfile=self.document.file
 if self.statistics and self.statistics.is_doc_not_frozen then self.statistics.wrote=true end end
function ReaderUI.showFileManager(_,file) fm_target=file end
function ReaderUI.showReader(_,path,_,_,_,ready) ReaderUI.opened=path;ready() end
package.loaded["apps/reader/readerui"]=ReaderUI
local ended=false
package.loaded["apps/reader/modules/readerstatus"]={onEndOfBook=function() ended=true;return true end}
package.loaded["lua-ljsqlite3/init"]={open=function() return {prepare=function() local st={}
 function st:reset() return self end function st:bind() return self end function st:step() end function st:close() end
 return st end,close=function() end} end}
package.loaded["datastorage"]={getSettingsDir=function() return tmp end}
local native_config,native_link={},{}
package.loaded["apps/reader/modules/readerconfig"]={
 onShowConfigMenu=function(self) native_config.shown=true end,
 onTapShowConfigMenu=function(self) native_config.tap=true;return true end,
 onSwipeShowConfigMenu=function(self,ges) native_config.swipe=ges.direction;return true end}
package.loaded["apps/reader/modules/readerlink"]={onGotoLink=function(self,link) native_link.target=link.xpointer;return true end}
local actions={}
package.loaded["dispatcher"]={registerAction=function(_,name,value) actions[name]=value end}
package.loaded["infra/sui_i18n"]={translate=function(s) return s end}
local Session=require("features/sui_news_session")
local profile,returned,end_called
Session.profile_sink=function(p) profile=p end
Session.open(path,entry,{on_close=function() returned=true end,on_end=function() end_called=true end})
assert(ReaderUI.opened==path)
hist[1]={file=path};hist[2]={file="/mnt/us/documents/book.epub"}
local opened_as=path:gsub("/epub/","/./epub/")
local ui={document={file=opened_as},statistics={id_curr_book=7,is_doc_not_frozen=true},
 doc_settings={readSetting=function(_,k) return ({copt_font_size=26})[k] end}}
ReaderUI.onClose(ui)
assert(#hist==1 and hist[1].file=="/mnt/us/documents/book.epub","the article leaves reading history")
assert(settings.lastfile=="/mnt/us/documents/book.epub","lastfile returns to the user's book")
assert(not ui.statistics.wrote and ui.statistics.id_curr_book==nil,"statistics do not record the article")
assert(returned and profile.copt_font_size==26,"closing returns to the list and keeps typography")
ReaderUI:showFileManager(opened_as);assert(fm_target==nil,"the file browser never opens the hidden cache")
ReaderUI:showFileManager("/mnt/us/documents/book.epub");assert(fm_target=="/mnt/us/documents/book.epub")
-- Ordinary books keep native behavior.
local Status=package.loaded["apps/reader/modules/readerstatus"]
Status.onEndOfBook({ui={document={file="/mnt/us/documents/book.epub"}}});assert(ended and not end_called)
returned=false
ReaderUI.onClose({document={file="/mnt/us/documents/book.epub"}})
assert(not returned and settings.lastfile=="/mnt/us/documents/book.epub")
-- End of a news article shows the article end page instead of the book pop-up.
ended=false
Session.open(path,entry,{on_close=function() end,on_end=function() end_called=true end})
Status.onEndOfBook({ui={document={file=opened_as}}});assert(end_called and not ended)
-- Bottom tap / swipe up opens the news bar; the native panel stays reachable.
local bar_more,stepped
Session.open(path,entry,{on_close=function() end,on_bar=function(_,more) bar_more=more end,
 on_next=function() stepped="next" end,on_prev=function() stepped="prev" end,on_list=function() stepped="list" end})
local Config=package.loaded["apps/reader/modules/readerconfig"]
local news_ui={document={file=opened_as}}
assert(Config.onTapShowConfigMenu({ui=news_ui}) and bar_more and not native_config.tap,"bottom tap opens the reading bar")
bar_more();assert(native_config.shown,"More settings opens the native panel")
bar_more=nil;Config.onSwipeShowConfigMenu({ui=news_ui},{direction="north"});assert(bar_more)
Config.onTapShowConfigMenu({ui={document={file="/mnt/us/documents/book.epub"}}});assert(native_config.tap,"books keep the native panel")
local Link=package.loaded["apps/reader/modules/readerlink"]
Link.onGotoLink({ui=news_ui},{xpointer="qiaomu-next:n2"});assert(stepped=="next" and not native_link.target,"the in-text link opens the next article")
Link.onGotoLink({ui=news_ui},{xpointer="#_doc_fragment"});assert(native_link.target=="#_doc_fragment","other links stay native")
ReaderUI.onQiaomuNewsPrevious(news_ui);assert(stepped=="prev")
ReaderUI.onQiaomuNewsList(news_ui);assert(stepped=="list")
stepped=nil;assert(not ReaderUI.onQiaomuNewsNext({document={file="/mnt/us/documents/book.epub"}}) and not stepped,"gestures do nothing in books")
Session.registerActions()
assert(actions.qiaomu_news_next.event=="QiaomuNewsNext" and actions.qiaomu_news_previous.reader and actions.qiaomu_news_list)
-- Typography card changes go through KOReader's own reader events.
package.loaded["ui/uimanager"]={show=function() end,close=function() end,setDirty=function() end}
package.loaded["ui/event"]={new=function(_,name,arg) return {name=name,arg=arg} end}
local Bar=require("screens/sui_news_bar")
local sent={}
local ui={document={configurable={font_size=22}},handleEvent=function(_,ev) sent[#sent+1]=ev end}
Bar.apply(ui,"size",23);Bar.apply(ui,"line",115);Bar.apply(ui,"font","LXGW WenKai Screen");Bar.apply(ui,"margin",25)
assert(sent[1].name=="SetFontSize" and sent[1].arg==23 and sent[2].name=="SetLineSpace" and sent[2].arg==115)
assert(sent[3].name=="SetFont" and sent[4].name=="SetPageHorizMargins" and sent[4].arg[1]==25)
assert(ui.document.configurable.h_page_margins[2]==25,"margins are recorded so the next article inherits them")
local fonts=Bar.fonts();assert(#fonts==2 and fonts[1].label=="LXGW WenKai" and fonts[2].face=="Noto Sans CJK SC","only installed CJK faces are offered")
-- A crashed session leaves no stale history behind on the next visit.
hist[1]={file=path};hist[2]={file="/mnt/us/documents/book.epub"};settings.lastfile=path
Session.sweep()
assert(#hist==1 and settings.lastfile=="/mnt/us/documents/book.epub")
''')
print('PASS: escaped EPUB with heading TOC and embedded images, unchanged reuse, typography carry-over, history/lastfile/statistics isolation, cache-safe file browser, article end page, crash sweep, reading bar/native fallback, in-text next link, gesture actions, typography events.')
