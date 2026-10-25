"""Real scanner plus shelf ordering: newly transferred files are immediately found."""
from pathlib import Path
import os, re, tempfile
from lupa.lua54 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]/'simpleui.koplugin'
with tempfile.TemporaryDirectory() as tmp:
    home=Path(tmp)/'books';home.mkdir()
    (home/'nested').mkdir()
    for name,stamp in [('z.epub',100),('a.epub',99),('same-a.epub',98),('same-b.epub',98)]:
        p=home/name;p.write_text(name);os.utime(p,(stamp,stamp))
    lua=LuaRuntime(unpack_returned_tuples=True)
    def attrs(path,key=None):
        try:
            p=Path(path);st=p.stat()
            d={'mode':'directory' if p.is_dir() else 'file','modification':st.st_mtime,'size':st.st_size}
            return d.get(key) if key else lua.table_from(d)
        except FileNotFoundError:return None
    lua.globals().py_attrs=attrs
    lua.globals().py_entries=lambda path:lua.table_from(['.','..']+os.listdir(path))
    lua.globals().home=str(home);lua.globals().plugin_root=str(ROOT)
    lua.execute('''
package.path=plugin_root.."/?.lua;"..package.path
package.loaded["libs/libkoreader-lfs"]={attributes=py_attrs,dir=function(path)
 local entries=py_entries(path);local i=0;return function() i=i+1;return entries[i] end
end}
package.loaded["logger"]={dbg=function() end}
package.loaded["device"]={home_dir=home}
package.loaded["features/library/sui_bim_stamp"]={get=function() return nil end}
G_reader_settings={readSetting=function() return home end}
local settings={}
package.loaded["infra/sui_store"]={readSetting=function(_,k) return settings[k] end,saveSetting=function(_,k,v) settings[k]=v end}
package.loaded["infra/sui_config"]={readChoice=function(k,_,default) return settings[k] or default end}
package.loaded["infra/sui_i18n"]={translate=function(s) return s end}
package.loaded["engines/sui_book_grid"]={makeModule=function(spec) return spec end,getBookTitle=function(fp) return fp end}
package.loaded["features/library/sui_finished_books"]={isHidden=function() return false end}
package.loaded["modules/module_books_shared"]={}
local hidden={}
package.loaded["features/library/sui_hidden_books"]={isHidden=function(fp) return hidden[fp] end}
package.loaded["engines/sui_section_label"]={PageState={setPage=function(ctx,_,page) ctx.page=page end}}
Shelf=require("modules/module_library")
Ctx={pfx="simpleui_hs_"}
assert(Shelf.label_fn(Ctx.pfx)=="Recently added")
local first=Shelf.getFileList(Ctx)
assert(#first==4 and first[1]==home.."/z.epub")
assert(first[3]==home.."/same-a.epub" and first[4]==home.."/same-b.epub")
Ctx.page=3
assert(Shelf.getFileList(Ctx)[1]==first[1] and Ctx.page==3,"ordinary pagination must not reset")
''')
    new=home/'nested'/'刚传入.epub';new.write_text('new book');os.utime(new,(999,999))
    # Ensure the tracked directory's mtime advances even on coarse filesystems.
    os.utime(home/'nested',(2000,2000))
    lua.execute('''
local newest=Shelf.getFileList(Ctx)
assert(#newest==5 and newest[1]==home.."/nested/刚传入.epub")
assert(Ctx.page==1,"new arrivals must surface on the first page")
assert(Shelf.badges.new=="on")
Ctx.page=3
''')
    tied=home/'nested'/'最后.epub';tied.write_text('same transfer timestamp');os.utime(tied,(999,999))
    os.utime(home/'nested',(3000,3000))
    lua.execute('''
assert(#Shelf.getFileList(Ctx)==6 and Ctx.page==1,
 "a same-timestamp batch arrival also returns to page 1")
local settings=package.loaded["infra/sui_store"]
settings:saveSetting(Ctx.pfx.."flat_library_sort_mode","title_asc")
assert(Shelf.label_fn(Ctx.pfx)=="Books" and Shelf.getFileList(Ctx)[1]==home.."/a.epub")
''')
print('PASS: actual nested-directory scanner sees an arrival without a TTL wait, latest-first order, deterministic ties, pagination reset only on change, explicit sorting preserved.')
