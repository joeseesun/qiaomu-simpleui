"""AI selection translation and word lookup (Qiaomu Reader rules) and their KOReader hooks."""
from pathlib import Path
import json
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / 'simpleui.koplugin'
# Expected values produced by Qiaomu Reader 4.9's isLookupTerm (src/lookup.js).
CASES = ["bandwidth", "machine learning model", "four words here now", "带宽", "内存带宽瓶颈", "你好。", "Hello, world",
         "“bandwidth.”", "don't", "state-of-the-art", "line one\nline two", "  spaced  ", "(Caucus-Race)", "上下文窗口",
         "AI", "GPT-4", "42", "すごい", "데이터", "a b c d", "Mr. Smith", "e.g.", "好，的", "「词」"]
EXPECTED = [True, True, False, True, False, True, False, True, True, True, False, True, True, False, True, True,
            False, True, True, False, False, False, False, True]

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('os.setlocale("C")')  # KOReader's LuaJIT runs in the C locale
def to_lua(v):
    if isinstance(v, dict): return lua.table_from({k: to_lua(x) for k, x in v.items()})
    if isinstance(v, list): return lua.table_from([to_lua(x) for x in v])
    return v
lua.globals().py_decode = lambda s: to_lua(json.loads(s))
lua.globals().plugin_root = str(ROOT)
lua.execute('package.path=plugin_root.."/?.lua;"..package.path')
L = lua.eval('(require("features/sui_ai_lookup"))')
assert [bool(L.isTerm(c)) for c in CASES] == EXPECTED, 'term detection matches Qiaomu Reader'
lua.execute(r'''
package.loaded["json"]={decode=py_decode,encode=function() return "{}" end}
package.loaded["logger"]={info=function() end,warn=function() end}
package.loaded["infra/sui_i18n"]={translate=function(s) return s end}
local L=require("features/sui_ai_lookup")
assert(L.fallbackTarget("zh-CN")=="en" and L.fallbackTarget("zh-TW")=="en" and L.fallbackTarget("en")=="zh-CN")
assert(L.trimTerm("“bandwidth.”")=="bandwidth")
local t=L.translateMessages{text="Hello",context="Say Hello now",book="Alice",target="zh-CN"}[1].content
assert(t:find("翻译成简体中文",1,true) and t:find("改为翻译成English",1,true) and t:find("书：《Alice》",1,true)
  and t:find("上下文（仅供理解，不要翻译）：Say Hello now",1,true) and t:find("待翻译：\nHello",1,true))
assert(not L.translateMessages{text="Hi",context="Hi"}[1].content:find("上下文（仅供理解",1,true),"context equal to the text is omitted")
local k=L.lookupMessages{term="bandwidth",sentence="The bandwidth is low.",book="",target="zh-CN"}[1].content
assert(k:find("查询：bandwidth",1,true) and k:find("句子：The bandwidth is low.",1,true) and not k:find("书：",1,true))
local JSON=package.loaded["json"]
local card=L.parseLookup('Sure!\n```json\n{"lemma":"bandwidth","phonetic":"/ˈbændwɪdθ/","meaning":"带宽","senses":[{"pos":"n.","def":"带宽"},{"pos":"n.","def":"精力"},{"pos":"n.","def":"x"},{"pos":"n.","def":"4"}],"note":"","example":"No bandwidth.","exampleTranslation":"没精力。"}\n```',JSON)
assert(card.lemma=="bandwidth" and #card.senses==3 and card.meaning=="带宽","fenced JSON is parsed, senses capped at 3")
local text=L.cardText("bandwidth",card)
assert(text:find("bandwidth  /ˈbændwɪdθ/",1,true) and text:find("n. 精力",1,true) and text:find("No bandwidth.\n没精力。",1,true))
local raw=L.parseLookup("这不是 JSON",JSON);assert(raw.meaning=="这不是 JSON" and #raw.senses==0,"non-JSON answers still show")

-- KOReader integration.
local ready=false
package.loaded["features/sui_ai_config"]={ready=function() return ready end,
  load=function() return {translate_model="deepseek-flash",translate_to="zh-CN"} end}
package.loaded["ui/uimanager"]={show=function() end,close=function() end}
local events={}
package.loaded["ui/event"]={new=function(_,name,a,b,c) return {name=name,args={a,b,c}} end}
package.loaded["device"]={hasClipboard=function() return false end}
package.loaded["apps/reader/readerui"]={}
local A=require("features/sui_ai_actions")
local asked={}
A.ask=function(title,messages,model,done) asked[#asked+1]={title=title,messages=messages,model=model};A.last_done=done end
local native_called=false
local hl={_highlight_buttons={["07_translate"]=function() native_called=true;return {text="Translate"} end},
  selected_text={text="bandwidth",pos0=1,pos1=2},getSelectedWordContext=function() return "The ","  is low." end,
  addToHighlightDialog=function(self,idx,fn) self._highlight_buttons[idx]=fn end}
local note
function hl:addNote(t) note=t end
local dict_spec
local ui={highlight=hl,doc_props={display_title="Alice"},rolling=true,
  document={extendXPointersToSentenceSegment=function() return {text="The whole sentence."} end},
  dictionary={addToDictButtons=function(_,spec) dict_spec=spec end},
  handleEvent=function(_,ev) events[#events+1]=ev end}
hl.ui=ui
A.attach(ui);A.attach(ui)
local btn=hl._highlight_buttons["07_translate"](hl,1)
assert(native_called and btn.text=="Translate","without AI settings the native Translate button stays")
ready=true
btn=hl._highlight_buttons["07_translate"](hl,1)
assert(btn.text=="AI translate","with AI settings Translate becomes AI translate")
assert(hl._highlight_buttons["08_qiaomu_ask"](hl).text=="Ask AI","highlight dialog gets Ask AI")
assert(type(package.loaded["apps/reader/readerui"].onQiaomuAiPage)=="function","page gesture handler installed")
assert(dict_spec.id=="qiaomu_ai_meaning" and dict_spec.conditional and dict_spec.show_func(),"dictionary popup gets AI meaning")
ready=false;assert(not dict_spec.show_func());ready=true
-- A word gets a lookup card with sentence context and the fast model.
btn.callback()
assert(#asked==1 and asked[1].title=="bandwidth" and asked[1].model=="deepseek-flash")
assert(asked[1].messages[1].content:find("句子：The bandwidth  is low.",1,true) and asked[1].messages[1].content:find("书：《Alice》",1,true))
-- Result buttons: save as note, add to vocabulary.
local shown
package.loaded["screens/sui_ai_card"]={show=function(opts) shown=opts;return {finish=function() end,dismiss=function() end} end}
package.loaded["ui/widget/notification"]={notify=function() end}
A.last_done('{"lemma":"bandwidth","meaning":"带宽","senses":[]}')
assert(shown.title=="bandwidth" and shown.text:find("带宽",1,true))
local labels={};for _,b in ipairs(shown.buttons[1]) do labels[b.text]=b end
assert(labels["Save as note"] and labels["Add to vocabulary"] and labels["Close"] and not labels["Copy"])
labels["Add to vocabulary"].callback()
assert(events[1].name=="WordLookedUp" and events[1].args[1]=="bandwidth" and events[1].args[2]=="Alice" and events[1].args[3]==true)
labels["Save as note"].callback();assert(note:find("bandwidth",1,true) and note:find("带宽",1,true),"note contains the card text")
-- A passage is extended to whole sentences and translated.
hl.selected_text={text="whole sentence here and more",pos0=1,pos1=2}
btn.callback()
assert(asked[2].title=="Translation" and asked[2].messages[1].content:find("待翻译：\nThe whole sentence.",1,true))
A.last_done("整句话。")
assert(shown.title=="Translation" and shown.text=="整句话。")
labels={};for _,b in ipairs(shown.buttons[1]) do labels[b.text]=b end
assert(labels["Save as note"] and not labels["Add to vocabulary"],"passages cannot go to the vocabulary builder")
-- Card text is plain and the subtitle names the language actually produced.
assert(A.plain("**Bold** and *Madness in Civilization*\n## Head\n> quote")=="Bold and Madness in Civilization\nHead\nquote")
assert(A.translatedInto("历史学家研究这段历史四十多年","zh-CN")=="en" and A.translatedInto("Historians study","zh-CN")=="zh-CN")
-- Dictionary popup lookup uses the popup word.
dict_spec.callback({lookupword="ephemeral",ui=ui})
assert(asked[3].title=="ephemeral")
''')
print('PASS: term detection identical to Qiaomu Reader on 24 cases, prompts, fenced/raw answer parsing, native Translate kept until AI is set up, AI translate/meaning buttons, word vs passage, note and vocabulary actions.')
