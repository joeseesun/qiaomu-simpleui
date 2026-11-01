-- sui_upload_page.lua — Simple UI
-- Phone page for sending books to the Kindle. Self-contained HTML: no
-- external scripts, fonts or images.
local M = {}

M.HTML = [==[<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>传书到 Kindle</title>
<style>
:root{--bg:#f6f5f2;--card:#fff;--text:#1d1d1b;--muted:#6b6a66;--line:#e2e0da;--accent:#1d1d1b;--ok:#2f6b3a;--err:#a3322b;--tint:#efeee9}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--card:#22221f;--text:#ecebe6;--muted:#a3a19b;--line:#3a3935;--accent:#ecebe6;--ok:#8fc79a;--err:#f0a39c;--tint:#2c2b28}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.55 -apple-system,"PingFang SC","Noto Sans CJK SC",sans-serif}
main{max-width:560px;margin:0 auto;padding:16px 16px 96px}
h1{font-size:22px;margin:8px 0 2px}p.lead{color:var(--muted);margin:0 0 16px;font-size:14px}
section{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;margin:12px 0}
h2{font-size:15px;margin:0 0 10px}label{display:block;font-size:13px;color:var(--muted);margin:10px 0 4px}
input,select{width:100%;font:inherit;color:var(--text);background:var(--bg);border:1px solid var(--line);border-radius:10px;padding:10px 12px}
input[type=file]{padding:8px}
.small{font-size:12px;color:var(--muted)}
button{font:inherit;border-radius:12px;padding:12px;border:1px solid var(--line);background:var(--card);color:var(--text)}
button.primary{background:var(--accent);color:var(--bg);border-color:var(--accent);font-weight:600}
.bar{position:fixed;left:0;right:0;bottom:0;background:var(--card);border-top:1px solid var(--line);padding:12px 16px}
.bar .row{max-width:560px;margin:0 auto}
#status{min-height:22px;font-size:14px;margin:6px 0 0}.ok{color:var(--ok)}.err{color:var(--err)}
.note{font-size:12px;color:var(--muted);background:var(--tint);border-radius:10px;padding:10px;margin-top:12px}
#list{margin:0;padding-left:20px;font-size:14px}
#list li{margin:2px 0}
</style></head><body><main>
<h1>传书到 Kindle</h1>
<p class="lead">选一本书，它会存进 Kindle 的 documents 文件夹，在书库里就能看到。</p>
<section><h2>选择文件</h2>
<input type="file" id="file" accept=".epub,.mobi,.azw3,.azw,.pdf,.txt,.fb2,.djvu,.cbz,.cbr,.doc,.docx,.rtf">
<label for="subdir">保存到子文件夹（可留空）</label>
<input id="subdir" placeholder="例如：小说" autocomplete="off">
<p class="small">文件名会保留原样。Kindle 支持的格式：EPUB、MOBI、AZW3、PDF、TXT 等。</p>
</section>
<section><h2>将上传</h2><ul id="list"><li class="small">还没有选择文件</li></ul></section>
<p class="note">页面只在 Kindle 显示二维码时可用，上传完成后自动关闭。家里的局域网内是普通 HTTP，请只在你信任的 Wi-Fi 下使用。</p>
</main>
<div class="bar"><div class="row"><button type="button" class="primary" id="send">上传到 Kindle</button></div><p id="status"></p></div>
<script>
const T=new URLSearchParams(location.search).get('t');const $=id=>document.getElementById(id);
function status(text,cls){const s=$('status');s.textContent=text;s.className=cls||''}
function api(path,body){return fetch(path+'?t='+T,body?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}:{}).then(r=>r.json().then(j=>{if(!r.ok)throw new Error(j.error||('HTTP '+r.status));return j}))}
function showFiles(){const f=$('file').files;const box=$('list');box.innerHTML='';
 if(!f||!f.length){const li=document.createElement('li');li.className='small';li.textContent='还没有选择文件';box.appendChild(li);return}
 Array.from(f).forEach(file=>{const li=document.createElement('li');
 li.textContent=file.name+'  ('+Math.round(file.size/1024)+' KB)';box.appendChild(li)})}
$('file').onchange=showFiles;
$('send').onclick=()=>{
 const f=$('file').files;if(!f||!f.length){status('请先选择要上传的文件','err');return}
 const subdir=$('subdir').value.trim();
 status('正在上传，请保持页面打开…');
 const fd=new FormData();fd.append('subdir',subdir);
 for(const file of Array.from(f))fd.append('file',file,file.name);
 fetch('/api/upload?t='+T,{method:'POST',body:fd}).then(r=>r.json().then(j=>{
  if(!r.ok)throw new Error(j.error||('HTTP '+r.status));
  status('已上传：'+(j.files||[]).join('、'),'ok');
  $('send').disabled=true;$('file').disabled=true;$('subdir').disabled=true;
 })).catch(e=>status('上传失败：'+e.message,'err'));
};
</script></body></html>]==]

return M
