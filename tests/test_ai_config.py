"""Qiaomu AI settings: storage, validation, curl client and the phone page server."""
from pathlib import Path
import json, os, stat, tempfile
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / 'simpleui.koplugin'
with tempfile.TemporaryDirectory() as tmp:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('os.setlocale("C")')  # KOReader's LuaJIT runs in the C locale
    def from_lua(value):
        if hasattr(value, 'keys'):
            keys = list(value.keys())
            if keys and all(isinstance(k, int) for k in keys):
                return [from_lua(value[k]) for k in sorted(keys)]
            return {k: from_lua(v) for k, v in value.items()}
        return value
    def to_lua(value):
        if isinstance(value, dict):
            return lua.table_from({k: to_lua(v) for k, v in value.items()})
        if isinstance(value, list):
            return lua.table_from([to_lua(v) for v in value])
        return value
    lua.globals().py_encode = lambda v: json.dumps(from_lua(v), ensure_ascii=False)
    lua.globals().py_decode = lambda s: to_lua(json.loads(s))
    lua.globals().tmp = tmp
    lua.globals().plugin_root = str(ROOT)
    lua.globals().file_mode = lambda p: stat.S_IMODE(os.stat(p).st_mode)
    lua.globals().list_dir = lambda p: lua.table_from(sorted(os.listdir(p)))
    # Fake curl: records its arguments and the config it was given.
    fake = Path(tmp) / 'curl'
    fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CURL_ARGS"\n'
                    'while [ $# -gt 0 ]; do case "$1" in -K) cp "$2" "$CURL_ARGS.conf";; --data-binary) cp "${2#@}" "$CURL_ARGS.body";; esac; shift; done\n'
                    'printf \'%s\' "$CURL_REPLY"\n')
    fake.chmod(0o755)
    lua.execute(r'''
package.path=plugin_root.."/?.lua;"..package.path
package.loaded["json"]={encode=py_encode,decode=py_decode}
package.loaded["logger"]={info=function() end,warn=function() end}
local Config=require("features/sui_ai_config")
Config.DIR=tmp.."/var-local"
local cfg=Config.load()
assert(cfg.provider=="deepseek" and cfg.chat_model=="deepseek-flash" and not Config.ready(cfg),"DeepSeek is the default, unset until a key exists")
assert(#cfg.quick_prompts==0 and #Config.SELECTION_ACTIONS==6 and #Config.WHOLE_ACTIONS==6 and Config.SELECTION_ACTIONS[1].name=="解释")
local merged_actions=Config.actions(Config.SELECTION_ACTIONS,{quick_prompts={{name="解释",prompt="dup"},{name="找金句",prompt="p"}}})
assert(#merged_actions==7 and merged_actions[7].name=="找金句" and merged_actions[1].prompt~="dup","user actions append after built-ins, no duplicates")
-- Validation of what the phone page posts.
assert(not Config.merge(cfg,{provider="nope"}))
assert(not Config.merge(cfg,{provider="deepseek",key='sk-abc" -o /tmp/x'}),"keys cannot inject into the curl config")
assert(not Config.merge(cfg,{provider="deepseek",chat_model="bad model;rm"}))
assert(not Config.merge(cfg,{provider="custom",base="file:///etc/passwd",chat_model="m"}))
local merged=assert(Config.merge(cfg,{provider="deepseek",key=" sk-test-1234 ",chat_model="deepseek-v4-pro",thinking=true,translate_model=""}))
assert(merged.key=="sk-test-1234" and merged.translate_model=="deepseek-v4-pro" and merged.thinking==true and merged.base=="https://api.deepseek.com")
assert(Config.ready(merged) and Config.keyHint(merged)=="••••1234")
local kept=assert(Config.merge(merged,{provider="deepseek",key="",chat_model="deepseek-flash"}))
assert(kept.key=="sk-test-1234","an empty key keeps the saved one")
local switched=assert(Config.merge(merged,{provider="kimi",chat_model="kimi-k2.6",thinking=true}))
assert(switched.key=="" and switched.thinking==false and switched.base=="https://api.moonshot.cn/v1","switching service drops the other service's key")
local custom=assert(Config.merge(cfg,{provider="custom",base="http://192.168.1.10:11434/v1/",chat_model="qwen3:8b"}))
assert(custom.base=="http://192.168.1.10:11434/v1" and Config.ready(custom),"local services may run without a key")
local many={};for i=1,25 do many[i]={name="q"..i,prompt="p"} end
assert(#assert(Config.merge(cfg,{provider="deepseek",quick_prompts=many})).quick_prompts==20)
-- Storage: private file, key never in the public view.
Config.save(merged)
assert(file_mode(Config.path())==384,"settings file is 0600")
assert(file_mode(Config.DIR)==448,"settings folder is 0700")
Config.reset();assert(Config.load().key=="sk-test-1234")
local public=Config.public();assert(public.key==nil and public.key_hint=="••••1234")
-- Request body follows Qiaomu Reader: tests disable DeepSeek thinking.
local Client=require("features/sui_ai_client")
local body=Client.body(merged,{{role="user",content="x"}},{test=true})
assert(body.thinking.type=="disabled" and body.max_tokens==16 and body.model=="deepseek-v4-pro")
body=Client.body(merged,{{role="user",content="x"}},{thinking=true})
assert(body.thinking.type=="enabled" and body.max_tokens==nil,"conversations honour thinking mode")
body=Client.body(merged,{{role="user",content="x"}})
assert(body.thinking.type=="disabled" and body.max_tokens==2400,"translation and lookup never think")
body=Client.body(switched,{{role="user",content="x"}});assert(body.thinking==nil and body.max_tokens==2400)
''')
    lua.globals().curl_path = str(fake)
    import subprocess
    lua.globals().run_shell = lambda cmd: subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout
    lua.execute('''io.popen=function(cmd) local out=run_shell(cmd)
      return {read=function(_, fmt) local o=out; out=nil; return o end, close=function() return true end} end''')
    args = Path(tmp) / 'args'
    os.environ['CURL_ARGS'] = str(args)
    os.environ['CURL_REPLY'] = json.dumps({'choices': [{'message': {'content': 'OK', 'reasoning_content': 'r'}}]}) + '\n200'
    lua.execute(r'''
local Client=require("features/sui_ai_client");local Config=require("features/sui_ai_config")
Client.CURL=curl_path
local answer,reasoning=Client.chat(Config.load(),{{role="user",content="你好"}})
assert(answer=="OK" and reasoning=="r")
local ok=Client.test(Config.load());assert(ok and ok.answer=="OK")
for _,name in ipairs(list_dir(Config.DIR)) do assert(name=="ai.json","temporary key and body files are removed: "..name) end
''')
    argv = args.read_text()
    assert 'sk-test-1234' not in argv, 'the key never appears on the command line'
    assert '-K' in argv and 'https://api.deepseek.com/chat/completions' in argv
    assert 'Authorization: Bearer sk-test-1234' in (Path(str(args) + '.conf')).read_text()
    assert '"thinking"' in Path(str(args) + '.body').read_text()
    os.environ['CURL_REPLY'] = json.dumps({'error': {'message': 'Authentication Fails'}}) + '\n401'
    lua.execute(r'''
local Client=require("features/sui_ai_client");local Config=require("features/sui_ai_config")
local answer,err=Client.chat(Config.load(),{{role="user",content="x"}})
assert(answer==nil and err=="HTTP 401: Authentication Fails","service errors are reported")
''')
    # Phone page server: token required, key never returned, input validated.
    lua.execute(r'''
local Config=require("features/sui_ai_config")
package.loaded["features/sui_ai_page"]={HTML="<html>page</html>"}
local Web=require("features/sui_ai_web")
local sent
local srv={send=function(_,data) sent=data end}
local function client(body) return {settimeout=function() end,receive=function(_,n) return body:sub(1,n) end,close=function() end} end
local function req(line,body)
  sent=nil
  local data=line.."\r\nHost: k\r\n"..(body and ("Content-Length: "..#body.."\r\n") or "").."\r\n"
  Web._handle(data,client(body or ""),srv,"abc123")
  return sent
end
assert(req("GET /?t=wrong HTTP/1.1"):match("^HTTP/1.0 403"),"wrong token is refused")
assert(req("GET / HTTP/1.1"):match("^HTTP/1.0 403"),"missing token is refused")
assert(req("GET /?t=abc123 HTTP/1.1"):find("<html>page</html>",1,true))
local state=req("GET /api/state?t=abc123 HTTP/1.1")
assert(state:find("••••1234",1,true) and not state:find("sk-test-1234",1,true),"state never contains the key")
assert(state:find("Cache-Control: no-store",1,true))
assert(req("POST /api/save?t=abc123 HTTP/1.1",'{"provider":"deepseek","key":"bad key\\"x"}'):match("^HTTP/1.0 400"))
assert(req("POST /api/save?t=abc123 HTTP/1.1","not json"):match("^HTTP/1.0 400"))
local saved=req("POST /api/save?t=abc123 HTTP/1.1",'{"provider":"kimi","key":"sk-kimi-9876","chat_model":"kimi-k2.6","translate_to":"en"}')
assert(saved:match("^HTTP/1.0 200") and not saved:find("sk-kimi-9876",1,true))
Config.reset()
local now=Config.load();assert(now.provider=="kimi" and now.key=="sk-kimi-9876" and now.translate_to=="en")
assert(req("POST /api/test?t=abc123 HTTP/1.1",'{"provider":"custom","base":"","chat_model":""}'):match("^HTTP/1.0 400"),"tests need complete settings")
''')
print('PASS: DeepSeek default, input validation (key/model/URL injection), private 0600 storage, key never in page state or curl argv, temp files removed, Qiaomu Reader request body, service errors, token-protected phone page.')
