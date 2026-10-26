-- Optional on-device regression, run from the KOReader directory:
-- ./luajit /path/to/news_typography.lua /tmp/unique-test-root /path/to/pre-update-backup
-- The backup must contain simpleui.koplugin/. Uses the installed EPUB builder,
-- native archiver, LuaJIT and crengine; writes only under the supplied test root.
-- Large random filler forces native disk-cache coverage. Does not touch the
-- framebuffer, live reader session, news/book library, user progress or settings.
-- Requires the standard Noto CJK/Serif fonts shipped with this Kindle build.
io.stdout:setvbuf('line')
require('setupkoenv')
package.path='./plugins/simpleui.koplugin/?.lua;'..package.path
local json=require('json')
local tmp=assert(arg[1])
local backup=assert(arg[2])
local util=require('util')
util.makePath(tmp..'/crcache')
package.loaded['features/sui_news_cache']={root=function() return tmp..'/news' end}
package.loaded['features/sui_news_images']={html=function(a) return a.body end}
package.loaded['features/sui_news_session']={NEXT_URI='qiaomu-next:'}
local old=assert(loadfile(backup..'/simpleui.koplugin/features/sui_news_epub.lua'))()
local patched=require('features/sui_news_epub')
local N={title=function(e) return e.title end}
local entry={id='isolated-font-probe',title='字号回归测试',sourceName='本地隔离测试',published='2026-10-26'}
math.randomseed(297)
local chunks={'<p style="font-size:12px;line-height:14px;font-family:serif">QMFONT正文测量：字号应该能够调节。小字与大字要有清楚的区别。</p><p STYLE="font-size:12px; font-weight:bold">QMUPPER大小写样式测试</p><p style="display:none;font-size:1px">QMHIDDEN不能显示的内容</p>'}
for i=1,180 do
 local letters={}
 for j=1,800 do letters[j]=string.char(math.random(97,122)) end
 chunks[#chunks+1]='<p style="font-size:12px;line-height:14px">'..table.concat(letters)..'</p>'
end
local article={body=table.concat(chunks),format='html',version='original'}
local cre=require('libs/libkoreader-cre')
local BB=require('ffi/blitbuffer')
cre.initCache(tmp..'/crcache',16*1024*1024,true,1)
cre.initHyphDict('./data/hyph/')
cre.registerFont('./fonts/noto/NotoSansCJKsc-Regular.otf')
cre.registerFont('./fonts/noto/NotoSerif-Regular.ttf')
local results={}
local function measure(path,label)
 local doc=cre.newDocView(1072,1448,1)
 doc:readDefaults()
 doc:setHeaderInfo(0)
 doc:setStringProperty('font.face.default','Noto Sans CJK SC')
 doc:setIntProperty('crengine.doc.embedded.styles.enabled',1)
 doc:setIntProperty('crengine.cache.filesize.min',65536)
 doc:setStyleSheet('./data/epub.css','')
 doc:setFontSize(22)
 assert(doc:loadDocument(path))
 local result={label=label,sizes={}}
 for _,size in ipairs{22,38} do
  doc:setFontSize(size);doc:renderDocument();doc:gotoPage(1)
  local bb=BB.new(1072,1448,BB.TYPE_BB8)
  doc:drawCurrentPage(bb,false,false,false,false)
  bb:writePNG(tmp..'/'..label..'-'..size..'.png');bb:free()
  local matches=assert(doc:findText('QMFONT',0,false,false,false,10),'sentinel missing')
  local boxes=assert(doc:getWordBoxesFromPositions(matches[1].start,matches[1]['end'],true),'no glyph boxes')
  assert(#boxes>0)
  local upper=assert(doc:findText('QMUPPER',0,false,false,false,10))
  local ub=assert(doc:getWordBoxesFromPositions(upper[1].start,upper[1]['end'],true))
  local item={size=size,body_height=boxes[1].y1-boxes[1].y0,upper_height=ub[1].y1-ub[1].y0,pages=doc:getPages(),cache_path=doc:getCacheFilePath()}
  result.sizes[#result.sizes+1]=item
  print(json.encode(item))
 end
 doc:close()
 results[#results+1]=result
 return result
end
local path=assert(old.build(entry,article,N))
local before=measure(path,'before')
local sidecar=path:gsub('%.epub$','.sdr')
util.makePath(sidecar)
local settings='return {copt_font_size=31,last_xpointer="/body/p",annotations={"saved"}}'
local f=assert(io.open(sidecar..'/metadata.epub.lua','wb'));f:write(settings);f:close()
local after_path=assert(patched.build(entry,article,N));assert(after_path==path)
local after=measure(path,'after')
local reopened=measure(path,'reopened')
f=assert(io.open(sidecar..'/metadata.epub.lua','rb'));assert(f:read('*a')==settings);f:close()
assert(before.sizes[1].body_height==before.sizes[2].body_height,'control unexpectedly follows user font size')
assert(after.sizes[2].body_height>after.sizes[1].body_height*1.4,'patched body does not scale')
assert(after.sizes[2].upper_height>after.sizes[1].upper_height*1.4,'uppercase style does not scale')
assert(reopened.sizes[1].body_height==after.sizes[1].body_height and reopened.sizes[2].body_height==after.sizes[2].body_height,'reopen uses stale layout')
f=assert(io.open(tmp..'/result.json','wb'));f:write(json.encode({ok=true,results=results,sidecar_preserved=true,path=path}));f:close()
print('PASS native typography and cache upgrade')
