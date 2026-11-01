-- Phone settings page served by features/sui_ai_web. Self-contained: no
-- external scripts, fonts or images.
local M = {}

M.HTML = [==[<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AI 设置</title>
<style>
:root{--bg:#f6f5f2;--card:#fff;--text:#1d1d1b;--muted:#6b6a66;--line:#e2e0da;--accent:#1d1d1b;--ok:#2f6b3a;--err:#a3322b;--tint:#efeee9}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--card:#22221f;--text:#ecebe6;--muted:#a3a19b;--line:#3a3935;--accent:#ecebe6;--ok:#8fc79a;--err:#f0a39c;--tint:#2c2b28}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.55 -apple-system,"PingFang SC","Noto Sans CJK SC",sans-serif}
main{max-width:560px;margin:0 auto;padding:16px 16px 96px}
h1{font-size:22px;margin:8px 0 2px}p.lead{color:var(--muted);margin:0 0 16px;font-size:14px}
section{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;margin:12px 0}
h2{font-size:15px;margin:0 0 10px}label{display:block;font-size:13px;color:var(--muted);margin:10px 0 4px}
input,select,textarea{width:100%;font:inherit;color:var(--text);background:var(--bg);border:1px solid var(--line);border-radius:10px;padding:10px 12px}
textarea{min-height:64px;resize:vertical}
.chips{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}
.chip{border:1px solid var(--line);border-radius:10px;padding:10px;text-align:center;background:var(--bg);font-size:15px;cursor:pointer}
.chip.on{background:var(--tint);border-color:var(--accent);font-weight:600}
.small{font-size:12px;color:var(--muted)}a{color:inherit}
.row{display:flex;gap:8px;align-items:center}.row>*{flex:1}
.toggle{display:flex;align-items:center;gap:10px;margin-top:10px}.toggle input{width:auto}
.prompt{border-top:1px solid var(--line);padding-top:10px;margin-top:10px}
button{font:inherit;border-radius:12px;padding:12px;border:1px solid var(--line);background:var(--card);color:var(--text)}
button.primary{background:var(--accent);color:var(--bg);border-color:var(--accent);font-weight:600}
.bar{position:fixed;left:0;right:0;bottom:0;background:var(--card);border-top:1px solid var(--line);padding:12px 16px}
.bar .row{max-width:560px;margin:0 auto}
#status{min-height:22px;font-size:14px;margin:6px 0 0}.ok{color:var(--ok)}.err{color:var(--err)}
.note{font-size:12px;color:var(--muted);background:var(--tint);border-radius:10px;padding:10px;margin-top:12px}
</style></head><body><main>
<h1>AI 设置</h1>
<p class="lead">这里填写的内容只保存在你的 Kindle 上，用于划线翻译和 AI 伴读。</p>
<section><h2>服务</h2><div class="chips" id="providers"></div>
<div><label for="base">接口地址（OpenAI 兼容，例如 https://api.openai.com/v1）</label><input id="base" inputmode="url" autocomplete="off">
<p class="small">留空则使用所选服务的默认地址；可以填自己的中转或局域网地址。</p></div>
<p class="small" id="providerNote"></p></section>
<section><h2>API Key</h2>
<input id="key" type="password" autocomplete="off" placeholder="粘贴 API Key">
<p class="small" id="keyHint"></p></section>
<section><h2>模型</h2>
<label for="chat_model">对话模型（问 AI）</label><select id="chat_model"></select>
<input id="chat_model_custom" autocomplete="off" placeholder="列表里没有？手动填写模型名">
<label for="translate_model">翻译模型（划线翻译和查词，建议用快的模型）</label><select id="translate_model"></select>
<input id="translate_model_custom" autocomplete="off" placeholder="列表里没有？手动填写模型名">
<div class="row" style="margin-top:8px"><button type="button" id="fetchModels">获取模型列表</button><span class="small" id="modelsHint"></span></div>
<div class="toggle" id="thinkingBox" hidden><input type="checkbox" id="thinking"><label for="thinking" style="margin:0;color:var(--text)">对话时开启思考模式（更慢，更深入）</label></div>
<div class="row"><div><label for="answer_lang">回答语言</label><select id="answer_lang"></select></div>
<div><label for="translate_to">翻译成</label><select id="translate_to"></select></div></div></section>
<section><h2>自定义动作（可选）</h2><p class="small">Kindle 上已经内置常用动作：选中文字时有解释、翻译、总结要点、举个例子、补充背景、换个角度看、出题考考我；整篇文章或当前页有总结全文、核心要点、通俗讲讲、对我有什么用、值得追问、出题考考我。这里可以再追加自己的动作，会排在内置动作后面，最多 20 条。</p><div id="prompts"></div>
<button type="button" id="addPrompt" style="margin-top:10px;width:100%">添加一条</button></section>
<p class="note">配置页只在 Kindle 显示二维码时可用，保存后会自动关闭。家里的局域网内是普通 HTTP，请只在你信任的 Wi-Fi 下使用。</p>
</main>
<div class="bar"><div class="row"><button type="button" id="test">测试连接</button><button type="button" class="primary" id="save">保存到 Kindle</button></div><p id="status"></p></div>
<script>
const T=new URLSearchParams(location.search).get('t');const $=id=>document.getElementById(id);
const LANG={'zh-CN':'简体中文','zh-TW':'繁體中文','en':'English','ja':'日本語','ko':'한국어'};
let S=null,provider='deepseek',prompts=[];
const ERR={'Invalid API key':'API Key 格式不对','Invalid service URL':'接口地址格式不对','Invalid model name':'模型名称格式不对','Unknown service':'请选择服务','Fill in the service, model and API key first':'请先填好服务、模型和 API Key','Network request failed':'Kindle 没能连上这个服务','AI is not set up':'请先填好服务、模型和 API Key','Cancelled':'测试被取消','Forbidden':'配置页已过期，请在 Kindle 上重新打开'};
function zh(m){m=String(m||'');return ERR[m]||m}
function status(text,cls){const s=$('status');s.textContent=text;s.className=cls||''}
function api(path,body){return fetch(path+'?t='+T,body?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}:{}).then(r=>r.json().then(j=>{if(!r.ok)throw new Error(j.error||('HTTP '+r.status));return j}))}
function current(){return S.providers.find(p=>p.id===provider)}
function renderProviders(){const box=$('providers');box.innerHTML='';S.providers.forEach(p=>{const b=document.createElement('button');b.type='button';b.className='chip'+(p.id===provider?' on':'');b.textContent=p.custom?'自定义接口':p.label;b.onclick=()=>selectProvider(p.id,true);box.appendChild(b)})}
function selectProvider(id,changed){provider=id;const p=current();renderProviders();
 $('thinkingBox').hidden=!p.thinking;fillModelSelect('chat_model',p.models||[]);fillModelSelect('translate_model',p.models||[]);
 if(changed){setModel('chat_model',p.model||'');setModel('translate_model',p.model||'');$('base').value=p.base||'';setModelsHint('')}
 const notes=[];if(p.key_url)notes.push('<a href="'+p.key_url+'" target="_blank" rel="noreferrer">去获取 API Key</a>');if(p.slow)notes.push('这台 Kindle 连接它较慢');if(p.model_hint==='endpoint')notes.push('模型处填写在火山方舟创建的推理接入点 ID');
 $('providerNote').innerHTML=notes.join(' · ');
 const same=S.config.provider===id&&S.config.key_hint;$('keyHint').textContent=same?('已保存 '+S.config.key_hint+'，留空则保持不变'):(S.config.key_hint?'切换服务后需要填写该服务的 Key':(p.custom?'本地服务可以不填':'还没有保存 Key'))}
function setModelsHint(text,cls){const h=$('modelsHint');if(!h)return;h.textContent=text||'';h.style.color=cls==='err'?'#a3322b':''}
// A model is either one of the offered ones or a name typed by hand.
function fillModelSelect(id,list){const sel=$(id);const prev=readModel(id);sel.innerHTML='';
 const blank=document.createElement('option');blank.value='';blank.textContent='— 选择模型 —';sel.appendChild(blank);
 list.forEach(m=>{const o=document.createElement('option');o.value=m;o.textContent=m;sel.appendChild(o)});
 if(prev&&list.indexOf(prev)<0){const o=document.createElement('option');o.value=prev;o.textContent=prev;sel.appendChild(o)}
 sel.value=list.indexOf(prev)>=0?prev:'';}
function readModel(id){const manual=$(id+'_custom');if(manual&&manual.value.trim())return manual.value.trim();
 const sel=$(id);return sel&&sel.value?sel.value:''}
function setModel(id,value){const manual=$(id+'_custom');if(manual)manual.value='';
 const sel=$(id);if(!sel)return;const hit=[...sel.options].find(o=>o.value===value);
 sel.value=hit?value:'';
 if(!hit&&value){const o=document.createElement('option');o.value=value;o.textContent=value;sel.appendChild(o);sel.value=value}}
function fillModels(list){fillModelSelect('chat_model',list);fillModelSelect('translate_model',list);
 setModelsHint('已获取 '+list.length+' 个模型');}
function pollModels(){api('/api/state').then(s=>{const t=s.models;if(!t||t.status==='idle')return;
 if(t.status==='running'){setTimeout(pollModels,1500);return}
 if(t.status==='ok'){fillModels(t.models||[]);status('已获取模型列表','ok')}
 else status('获取模型失败：'+zh(t.message),'err')}).catch(e=>status(e.message,'err'))}
function renderPrompts(){const box=$('prompts');box.innerHTML='';prompts.forEach((p,i)=>{const d=document.createElement('div');d.className='prompt';
 d.innerHTML='<div class="row"><input aria-label="按钮名称" maxlength="20"><button type="button" style="flex:0 0 auto">删除</button></div><textarea aria-label="发给 AI 的提示词" maxlength="500"></textarea>';
 const [n,del]=[d.querySelector('input'),d.querySelector('button')],t=d.querySelector('textarea');n.value=p.name;t.value=p.prompt;
 n.oninput=()=>p.name=n.value;t.oninput=()=>p.prompt=t.value;del.onclick=()=>{prompts.splice(i,1);renderPrompts()};box.appendChild(d)});$('addPrompt').hidden=prompts.length>=20}
function form(){return{provider,base:$('base').value.trim(),key:$('key').value.trim(),chat_model:readModel('chat_model'),translate_model:readModel('translate_model'),
 thinking:$('thinking').checked,answer_lang:$('answer_lang').value,translate_to:$('translate_to').value,quick_prompts:prompts.filter(p=>p.name.trim()&&p.prompt.trim())}}
function poll(){api('/api/state').then(s=>{const t=s.test;if(t.status==='running'){setTimeout(poll,1500);return}
 if(t.status==='ok')status('连接成功，Kindle 用时约 '+t.seconds+' 秒','ok');else status('连接失败：'+zh(t.message),'err')}).catch(e=>status(e.message,'err'))}
$('test').onclick=()=>{status('Kindle 正在测试连接…');api('/api/test',form()).then(()=>setTimeout(poll,1500)).catch(e=>status(zh(e.message),'err'))};
$('save').onclick=()=>{status('正在保存…');api('/api/save',form()).then(r=>{status('已保存到 Kindle（'+r.config.key_hint+'）。配置页已关闭，可以回到 Kindle 了。','ok');$('save').disabled=true;$('test').disabled=true}).catch(e=>status(zh(e.message),'err'))};
$('addPrompt').onclick=()=>{prompts.push({name:'',prompt:''});renderPrompts()};
$('fetchModels').onclick=()=>{const base=$('base').value.trim();if(!base){setModelsHint('请先填写接口地址','err');return}
 status('Kindle 正在获取模型列表…');setModelsHint('正在获取…');
 api('/api/models',form()).then(()=>setTimeout(pollModels,1500)).catch(e=>{status(zh(e.message),'err');setModelsHint(zh(e.message),'err')})};
api('/api/state').then(s=>{S=s;const c=s.config;provider=c.provider||'deepseek';
 ['answer_lang','translate_to'].forEach(id=>{const sel=$(id);s.languages.forEach(l=>{const o=document.createElement('option');o.value=l;o.textContent=LANG[l]||l;sel.appendChild(o)});sel.value=c[id]});
 $('base').value=c.base||'';$('thinking').checked=!!c.thinking;
 selectProvider(provider,false);setModel('chat_model',c.chat_model||'');setModel('translate_model',c.translate_model||'');
 prompts=Array.isArray(c.quick_prompts)?c.quick_prompts.filter(p=>p&&p.name&&p.prompt).map(p=>({name:p.name,prompt:p.prompt})):[];
 renderPrompts()}).catch(e=>status('无法读取设置：'+e.message,'err'));
</script></body></html>]==]

return M
