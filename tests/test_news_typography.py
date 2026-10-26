"""Publish rich HTML through the actual EPUB builder; exercise old-cache upgrade."""
from pathlib import Path
from html.parser import HTMLParser
import hashlib, html, os, tempfile, zipfile
from lupa.lua54 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]/'simpleui.koplugin'
with tempfile.TemporaryDirectory() as tmp:
    lua=LuaRuntime(unpack_returned_tuples=True)
    lua.globals().tmp=tmp;lua.globals().plugin_root=str(ROOT)
    lua.globals().mkdir=lambda p:Path(p).mkdir(parents=True,exist_ok=True)
    lua.globals().exists=lambda p:Path(p).is_file()
    lua.globals().listing=lambda p:lua.table_from(sorted(os.listdir(p)))
    lua.globals().unescape=html.unescape
    lua.globals().sha256=lambda s:hashlib.sha256(s.encode()).hexdigest()
    def archive(path,files):
        with zipfile.ZipFile(path,'w') as z:
            for name,data in files.items():z.writestr(name,data)
    lua.globals().write_zip=archive
    lua.execute(r'''
package.path=plugin_root.."/?.lua;"..package.path
package.loaded['util']={makePath=mkdir,htmlEntitiesToUtf8=unescape}
package.loaded['ffi/sha2']={sha256=sha256}
package.loaded['ffi/util']={realpath=function(p) return p end}
package.loaded['libs/libkoreader-lfs']={
 attributes=function(p,k) if not exists(p) then return end;return ({mode='file',modification=0})[k] end,
 dir=function(p) local names=listing(p);local i=0;return function() i=i+1;return names[i] end end,
}
package.loaded['features/sui_news_cache']={root=function() return tmp..'/news' end}
package.loaded['features/sui_news_images']={html=function(a) return a.body end}
package.loaded['features/sui_news_session']={NEXT_URI='qiaomu-next:'}
package.loaded['ffi/archiver']={Writer={new=function()
 local w={files={}}
 function w:open(path) self.path=path;return true end
 function w:setZipCompression() end
 function w:addFileFromMemory(name,data) self.files[name]=data end
 function w:close() write_zip(self.path,self.files) end
 return w end}}
package.loaded['docsettings']={hasSidecarFile=function() return true end,open=function() error('must preserve existing sidecar') end}
E=require('features/sui_news_epub')
N={title=function(e) return e.title end}
entry={id='rich',title='Rich article',sourceName='Source',published='2026-10-26'}
function build(body) return assert(E.build(entry,{body=body,format='html',version='original'},N)) end
''')
    fixture='''<html><body><h2>Section</h2>
<p id="p" style="font-size:12px; line-height:14px; font-family:'fixed;family'; font-weight:bold; text-align:center; color:#333">正文</p>
<span id="upper" STYLE='FONT-SIZE:14px; FONT-FAMILY:Serif; font-style:italic'>Uppercase</span>
<p id="bare" data-note="x > y" style=font-size:10px>Unquoted</p>
<span id="hidden" style="display:none;font-size:1px">Hidden</span>
<font id="legacy" SIZE="2" FACE='Serif'>Legacy</font>
<span id="shorthand" style="font:italic 11px/12px serif; text-decoration:underline">Short</span>
<span id="encoded" style="font&#45;size:12px; font-weight:600">Entity</span>
<span id="escaped" style="f\\6f nt-size:12px; font-weight:600">CSS escape</span>
<p id="comments" style="/* source:theme; */font-size:12px; font-weight:bold">Comment</p>
<p id="quoted" data-note="a style=font-size:2px > b" style="line-height:12px">Quoted</p>
<pre><code>code</code></pre><img src="photo.png" style="max-width:100%;height:auto"/>
<p data-style="font-size:4px">Data</p><!-- <span style="font-size:3px">comment</span> -->
</body></html>'''
    path=Path(lua.globals().build(fixture))
    with zipfile.ZipFile(path) as z: content=z.read('OEBPS/content.html').decode();css=z.read('OEBPS/stylesheet.css').decode()
    class Tags(HTMLParser):
        def __init__(self):super().__init__();self.ids={};self.images=[]
        def handle_starttag(self,tag,attrs):
            a=dict(attrs)
            if 'id' in a:self.ids[a['id']]=a
            if tag=='img':self.images.append(a)
    parsed=Tags();parsed.feed(content)
    for name in ['p','upper','bare','hidden','legacy','shorthand','encoded','escaped','comments','quoted']:
        a=parsed.ids[name];style=a.get('style','').lower()
        assert 'font-size' not in style and 'font-family' not in style and 'line-height' not in style,(name,a)
    assert 'font-weight:bold' in parsed.ids['p']['style'].replace(' ','')
    assert 'text-align:center' in parsed.ids['p']['style'].replace(' ','')
    assert 'display:none' in parsed.ids['hidden']['style'].replace(' ','')
    assert 'font-style:italic' in parsed.ids['upper']['style'].replace(' ','')
    assert 'text-decoration:underline' in parsed.ids['shorthand']['style'].replace(' ','')
    assert 'font:' not in parsed.ids['shorthand'].get('style','')
    assert 'size' not in parsed.ids['legacy'] and 'face' not in parsed.ids['legacy']
    assert parsed.ids['quoted']['data-note']=='a style=font-size:2px > b'
    assert parsed.ids['bare']['data-note']=='x > y'
    assert parsed.images[0]['style']=='max-width:100%;height:auto'
    assert 'data-style="font-size:4px"' in content and '<pre><code>code</code></pre>' in content
    assert 'h1.qm-title { font-size: 1.4em' in css and 'p.qm-meta { font-size: 0.8em' in css
    # A pre-upgrade EPUB/stamp must rebuild at the same path; user sidecars survive.
    old=Path(str(path)+'.version');old.write_text('original:'+str(len(fixture.encode()))+':')
    path.write_bytes(b'old epub')
    sidecar=path.with_suffix('.sdr');sidecar.mkdir();notes=sidecar/'metadata.epub.lua'
    notes.write_text('return {copt_font_size=31,last_xpointer="/body/p",annotations={"saved"}}')
    original_notes=notes.read_bytes()
    assert Path(lua.globals().build(fixture))==path
    with zipfile.ZipFile(path) as z:assert 'font-size:12px' not in z.read('OEBPS/content.html').decode()
    assert notes.read_bytes()==original_notes,'upgrade must preserve typography/progress/annotations'
    # Also upgrade the external PR's revision-2 stamp, not only the .15 stamp.
    old.write_text('2:original:'+str(len(fixture.encode()))+':')
    path.write_bytes(b'old revision 2 epub')
    lua.globals().build(fixture)
    with zipfile.ZipFile(path) as z:assert 'font-size:12px' not in z.read('OEBPS/content.html').decode()
    stat=path.stat().st_mtime_ns;stamp=old.read_bytes()
    lua.globals().build(fixture)
    assert path.stat().st_mtime_ns==stat and old.read_bytes()==stamp,'same input must reuse EPUB'
    # Equal-length text changes and title/source/CSS changes must invalidate old output.
    changed=fixture.replace('正文','新文');assert len(changed.encode())==len(fixture.encode())
    lua.globals().build(changed)
    with zipfile.ZipFile(path) as z:assert '新文' in z.read('OEBPS/content.html').decode()
    lua.execute("entry.title='New title';entry.sourceName='New source'")
    lua.globals().build(changed)
    with zipfile.ZipFile(path) as z:
        assert 'New title' in z.read('OEBPS/content.html').decode() and 'New source' in z.read('OEBPS/content.opf').decode()
    lua.execute(r"E.CSS=E.CSS..'\np { letter-spacing:0; }'")
    lua.globals().build(changed)
    with zipfile.ZipFile(path) as z:assert 'letter-spacing:0' in z.read('OEBPS/stylesheet.css').decode()
    assert notes.read_bytes()==original_notes
print('PASS: rich HTML typography cleanup, preserved emphasis/hiding/images/attributes, legacy/equal-length/CSS EPUB invalidation, stable reuse and intact sidecars.')
