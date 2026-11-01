"""Run article conversion with the actual Markdown parser from KOReader 2026.07.1."""
from pathlib import Path
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().plugin_root = str(ROOT / 'simpleui.koplugin')
lua.globals().parser_path = str(ROOT / 'tests/fixtures/koreader_md.lua')
lua.execute(r'''
package.path=plugin_root.."/?.lua;"..package.path
package.loaded["ffi/util"]={orderedPairs=function(t)
 local keys={};for k in pairs(t) do keys[#keys+1]=k end;table.sort(keys)
 local i=0;return function() i=i+1;local k=keys[i];if k then return k,t[k] end end
end}
local md=dofile(parser_path)
package.loaded["apps/filemanager/filemanagerconverter"]={mdToHtml=function(_,s) return md(s) end}
package.loaded["features/sui_news_cache"]={root=function() return "/cache" end,touch=function() end}
package.loaded["libs/libkoreader-lfs"]={attributes=function() end}
local Images=require("features/sui_news_images")
Images.path=function(url) if url:find("images.example",1,true) then return "/cache/"..string.rep("a",64)..".png" end end
local article={format="md",base_url="https://source.example/post",body=
 '重点推荐：[第一篇](https://first.example/a?x=1&amp;y=2)、[第二篇](https://second.example/b)、[第三篇](https://third.example/c)。\n\n'..
 '![图片](https://images.example/chart_(large).png "Chart title")\n\n'..
 '[**加粗链接**](https://first.example/wiki/Example_(test))\n\n'..
 '`[代码](https://code.example/)`\n\n'..
 '```\n![代码图片](https://code.example/image.png)\n```'}
local html=Images.html(article)
assert(html:find('<a href="https://first.example/a?x=1&amp;y=2">第一篇</a>',1,true),"multiple links must not collapse into one raw URL")
assert(html:find('<a href="https://second.example/b">第二篇</a>',1,true))
assert(html:find('<a href="https://third.example/c">第三篇</a>',1,true))
assert(html:find('<a href="https://first.example/wiki/Example_(test)"><strong>加粗链接</strong></a>',1,true))
assert(html:find('src="'..string.rep("a",64)..'.png"',1,true),"parenthesized image URL and title must embed")
assert(html:find('[代码](https://code.example/)',1,true),"code stays literal")
local urls=Images.urls(article)
assert(#urls==1 and urls[1]=='https://images.example/chart_(large).png',"download and render must use the same parsed URL, excluding code")
local lazy={format="html",body='<p><a href="https://first.example/a">原文</a></p><img src="placeholder.gif" data-src="https://images.example/full.png" alt="图">'}
assert(Images.urls(lazy)[1]=='https://images.example/full.png',"prefer lazy image source over placeholder")
assert(Images.html(lazy):find(string.rep("a",64)..'.png',1,true))
-- Execute the shipped cached-article branch: retry missing images once online,
-- without holding offline text behind a network request.
local f=assert(io.open(plugin_root.."/screens/sui_news_reader.lua"));local source=f:read("*a");f:close()
source=assert(source:match('(function M.read%(entry, from_reader%).-\nend)'))
local downloads,opened=0,0
local online=true
local news={state=function() return {} end,cached=function() return article end,
 flag=function() return {} end,save=function() end}
local session={open=function() opened=opened+1 end}
local env=setmetatable({M={},News=news,Images={urls=function() return {"https://images.example/missing.png"} end,
 path=function() end,download=function() downloads=downloads+1 end},image_attempts={},
 UIManager={},readerPath=function() return "/article.epub" end,
 job=function(_,task,done) done(task()) end,_=function(s) return s end,
 require=function(name)
  if name=="features/sui_news_session" then return session end
  if name=="ui/network/manager" then return {isOnline=function() return online end} end
  return require(name)
 end},{__index=_G})
assert(load(source,"reader","t",env))()
env.M.read({id="cached"},true);assert(downloads==1 and opened==1)
env.M.read({id="cached"},true);assert(downloads==1 and opened==2,"bound retry per article/session")
online=false
env.M.read({id="offline"},true);assert(downloads==1 and opened==3,"offline text opens without network")
print('PASS: real KOReader Markdown parser; multiple links, balanced destinations, titles, inline formatting, literal code, image URL parity and lazy images.')
''')
