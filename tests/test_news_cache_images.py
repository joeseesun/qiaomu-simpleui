"""Exercise the real bounded news cache and image pipeline on a real temp filesystem."""
from pathlib import Path
import hashlib, os, stat, struct, tempfile, zlib
from lupa.lua54 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]/'simpleui.koplugin'
with tempfile.TemporaryDirectory() as tmp:
    lua=LuaRuntime(unpack_returned_tuples=True)
    def attrs(path, key=None):
        try:
            s=os.lstat(path)
        except FileNotFoundError:
            return None
        data={'mode':'link' if stat.S_ISLNK(s.st_mode) else 'directory' if stat.S_ISDIR(s.st_mode) else 'file',
              'size':s.st_size,'modification':s.st_mtime}
        return data.get(key) if key else lua.table_from(data)
    lua.globals().attrs=attrs
    lua.globals().listing=lambda p:lua.table_from(os.listdir(p))
    lua.globals().mkdir=lambda p:Path(p).mkdir(parents=True,exist_ok=True)
    lua.globals().touch=lambda p:os.utime(p,None)
    lua.globals().digest=lambda u:hashlib.sha256(u.encode()).hexdigest()
    lua.globals().tmp=tmp
    lua.globals().plugin_root=str(ROOT)
    def chunk(name,data):
        return struct.pack('>I',len(data))+name+data+struct.pack('>I',zlib.crc32(name+data)&0xffffffff)
    png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,2,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b'\x00\xff\xff\xff\x00\x00\x00'*2))+chunk(b'IEND',b'')
    lua.globals().png=png
    lua.execute('''
package.path=plugin_root.."/?.lua;"..package.path
package.loaded["datastorage"]={getSettingsDir=function() return tmp end}
package.loaded["util"]={makePath=mkdir}
package.loaded["libs/libkoreader-lfs"]={attributes=attrs,symlinkattributes=attrs,touch=touch,
 dir=function(p) local names=listing(p);local i=0;return function() i=i+1;return names[i] end end}
local free=10*1024*1024*1024
package.loaded["ffi/util"]={df=function() return free*2,free end}
package.loaded["ffi/sha2"]={sha256=digest}
package.loaded["ffi"]={C={getpid=function() return 123 end}}
local C=require("features/sui_news_cache")
assert(C.LIMIT==512*1024*1024 and C.MIN_FREE==256*1024*1024)
local root=C.root()
local function put(p,s) local f=assert(io.open(p,"wb"));assert(f:write(s));f:close() end
local function exists(p) local f=io.open(p,"rb");if f then f:close();return true end end
put(root.."/articles/saved.json",string.rep("s",100))
put(root.."/articles/old.json",string.rep("o",200))
put(root.."/images/abc.txt","not a managed cache asset")
put(tmp.."/book.epub","original book")
local state={flags={saved={starred=true},old={offline=true}}}
C.makeRoom(0,state,true)
assert(exists(root.."/articles/saved.json") and not exists(root.."/articles/old.json"))
assert(not state.flags.old.offline and exists(tmp.."/book.epub") and exists(root.."/images/abc.txt"))
free=C.MIN_FREE-1
assert(C.reserve(1024,state)==nil,"stop downloads before consuming the disk reserve")
put(root.."/images/"..string.rep("a",64)..".png",string.rep("i",2048))
local recovered=assert(C.reserve(1024,state),"reclaim expendable images even when quota is below 512 MiB")
recovered()
assert(not exists(root.."/images/"..string.rep("a",64)..".png"))
assert(exists(root.."/articles/saved.json"),"saved text survives low-space eviction")
free=10*1024*1024*1024
C.LIMIT=1024*1024+300
local release=assert(C.reserve(100,state));assert(not C.reserve(150,state),"concurrent reservations count toward the cap")
release();release();assert(C.reserve(150,state))
-- A fresh module resets the reservation fixture, retaining real disk data.
package.loaded["features/sui_news_cache"]=nil
C=require("features/sui_news_cache")
local I=require("features/sui_news_images")
assert(not I.safeUrl("file:///etc/passwd"))
assert(not I.safeUrl("https://user:pass@example.com/a"))
assert(not I.safeUrl("https://example.com/a\\nheader"))
assert(not I.safeUrl("https://router.local/a"))
local w,h,ext=I.dimensions(png);assert(w==2 and h==2 and ext=="png")
local commands={}
package.loaded["socket"]={dns={getaddrinfo=function(host)
 if host=="private.example" then return {{family="inet",addr="192.168.1.1"}} end
 return {{family="inet",addr="203.0.113.1"}}
end}}
local original=io.popen
local response=png..string.char(10).."200"..string.char(10).."0"
io.popen=function(command)
 commands[#commands+1]=command
 local done=false
 return {read=function() if not done then done=true;return response end end,close=function() end}
end
assert(not I.fetch("https://private.example/a.png",10000))
assert(#commands==0,"never request private-network image targets")
local path,bytes=I.fetch("https://images.example/a.png",10000)
assert(path and bytes==#png and exists(path))
assert(I.path("https://images.example/a.png")==path)
assert(commands[1]:find("--resolve 'images.example:443:203.0.113.1'",1,true))
assert(not commands[1]:find("--insecure",1,true) and not commands[1]:find("--location",1,true))
response=string.rep("x",1001)..string.char(10).."200"..string.char(10).."0"
assert(not I.fetch("https://images.example/large.png",1000))
response="<html>error</html>"..string.char(10).."200"..string.char(10).."0"
assert(not I.fetch("https://images.example/not-image.png",10000))
response=png..string.char(10).."200"..string.char(10).."28"
assert(not I.fetch("https://images.example/partial.png",10000))
package.loaded["apps/filemanager/filemanagerconverter"]={mdToHtml=function(_,body) return body end}
local html=I.html{body='<p>Text</p><img src="https://images.example/a.png"><img src="file:///etc/passwd">',format="html"}
assert(html:find(path:match("([^/]+)$"),1,true))
assert(not html:find("file:///",1,true) and not html:find("https://",1,true))
package.loaded["apps/filemanager/filemanagerconverter"]={mdToHtml=function() return nil end}
package.loaded["util"].htmlEscape=function(s) return (s:gsub("&","&amp;"):gsub("<","&lt;")) end
local fallback=I.html{body="第一段 <b>"..string.char(10,10).."第二段",format="md"}
assert(fallback=="<p>第一段 &lt;b></p><p>第二段</p>","failed Markdown parsing falls back to escaped text")
assert(#I.urls{format="md",body="![one](https://images.example/a.png) ![two](https://images.example/a.png)"}==1)
assert(C.stats().bytes<C.LIMIT)
io.popen=original
''')
print('PASS: 512 MiB quota, low-space reserve, concurrent budgets, saved-text retention, book/file isolation, safe bounded raster downloads and local-only offline HTML.')
