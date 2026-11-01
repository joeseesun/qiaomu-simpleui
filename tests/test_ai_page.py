"""Execute the shipped phone-page JavaScript against real JSON wire shapes."""
from pathlib import Path
import re, subprocess
root = Path(__file__).resolve().parents[1]
page = (root / 'simpleui.koplugin/features/sui_ai_page.lua').read_text()
script = re.search(r'<script>(.*?)</script>', page, re.S).group(1)
subprocess.run(['node', '-e', r'''
const vm=require('node:vm'),assert=require('node:assert/strict');
let source='';process.stdin.setEncoding('utf8');
process.stdin.on('data',s=>source+=s);
process.stdin.on('end',async()=>{
 class Element {
  constructor(){this.children=[];this.value='';this.disabled=false;this.textContent='';this.fields={}}
  appendChild(e){this.children.push(e)}
  querySelector(s){return this.fields[s]??=new Element()}
 }
 const valid={name:'找金句',prompt:'从正文里选择一句话'};
 for(const [value,count] of [[{},0],[[],0],[null,0],[undefined,0],['bad',0],[[null,{},42,{name:2,prompt:'x'},valid],1],[[valid],1]]){
  const elements={};const requests=[];
  const config={provider:'deepseek',chat_model:'deepseek-flash',translate_model:'deepseek-flash',
   base:'https://api.deepseek.com',key_hint:'••••test',answer_lang:'zh-CN',translate_to:'zh-CN'};
  if(value!==undefined)config.quick_prompts=value;
  const state=JSON.parse(JSON.stringify({config,providers:[{id:'deepseek',label:'DeepSeek',models:['deepseek-flash']}],languages:['zh-CN'],test:{status:'idle'}}));
  const context=vm.createContext({URLSearchParams,location:{search:'?t=testtoken'},
   document:{getElementById:id=>elements[id]??=new Element(),createElement:()=>new Element()},
   fetch:async(path,options)=>{requests.push({path,options});return {ok:true,json:async()=>state}},setTimeout:()=>{}});
  vm.runInContext(source,context);
  for(let i=0;i<4;i++)await new Promise(setImmediate);
  assert(!elements.status?.textContent.includes('无法读取设置'),elements.status?.textContent);
  assert.equal(vm.runInContext('prompts.length',context),count);
  assert.equal(elements.save.disabled,false);assert.equal(elements.test.disabled,false);
  assert(elements.keyHint.textContent.includes('test'));
  elements.test.onclick();await new Promise(setImmediate);
  const posted=JSON.parse(requests.find(r=>r.path.startsWith('/api/test')).options.body);
  assert.equal(posted.quick_prompts.length,count);
  if(count)assert.deepEqual(posted.quick_prompts,[valid]);
 }
 // A failed state request must not leave Save enabled on a partial form.
 const elements={};
 const context=vm.createContext({URLSearchParams,location:{search:'?t=testtoken'},
  document:{getElementById:id=>elements[id]??=new Element(),createElement:()=>new Element()},
  fetch:async()=>{throw Error('offline')},setTimeout:()=>{}});
 vm.runInContext(source,context);for(let i=0;i<4;i++)await new Promise(setImmediate);
 assert.equal(elements.save.disabled,true);assert.equal(elements.test.disabled,true);
 console.log('PASS: phone-page initialization with empty Lua object, array, null, missing/malformed prompts, valid custom actions, test payload and failed-load controls.');
}).on('error',e=>{throw e});
'''], input=script, text=True, check=True)
