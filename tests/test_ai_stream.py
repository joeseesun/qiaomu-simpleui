"""Streaming AI answers: SSE parsing, [DONE], mid-stream drops, 4xx fallback
to a plain request, bounded retries and error classification. A fake curl
script serves one recorded reply per invocation."""
from pathlib import Path
import json, tempfile
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / 'simpleui.koplugin'
with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp) / 'curlwork'
    work.mkdir()
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('os.setlocale("C")')
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
    # Fake curl: counts invocations, records argv/body per call, prints the
    # recorded reply for this call (reply.N, falling back to reply.1) and exits
    # with the recorded exit code (exit.N / exit.1, default 0).
    fake = Path(tmp) / 'curl'
    fake.write_text('''#!/bin/sh
n=0; [ -f "$CURL_DIR/count" ] && n=$(cat "$CURL_DIR/count")
n=$((n+1)); printf '%s' "$n" > "$CURL_DIR/count"
printf "%s\\n" "$@" > "$CURL_DIR/args.$n"
while [ $# -gt 0 ]; do case "$1" in --data-binary) cp "${2#@}" "$CURL_DIR/body.$n";; esac; shift; done
if [ -f "$CURL_DIR/reply.$n" ]; then cat "$CURL_DIR/reply.$n"; else cat "$CURL_DIR/reply.1"; fi
e=0
if [ -f "$CURL_DIR/exit.$n" ]; then e=$(cat "$CURL_DIR/exit.$n"); elif [ -f "$CURL_DIR/exit.1" ]; then e=$(cat "$CURL_DIR/exit.1"); fi
exit $e
''')
    fake.chmod(0o755)
    import subprocess
    lua.globals().run_shell = lambda cmd: subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout
    lua.globals().curl_path = str(fake)
    import os
    os.environ['CURL_DIR'] = str(work)
    lua.execute(r'''
package.path=plugin_root.."/?.lua;"..package.path
package.loaded["json"]={encode=py_encode,decode=py_decode}
package.loaded["logger"]={info=function() end,warn=function() end}
-- io.popen returns the fake curl output; "*l" hands out one line per call so
-- requestStream's line loop runs exactly as on device.
io.popen=function(cmd)
  local out=run_shell(cmd)
  local pos=1
  return {
    read=function(_, fmt)
      if fmt=="*a" then local o=out; out=nil; return o end
      if out==nil then return nil end
      local s,e=out:find("\n",pos,true)
      if not s then
        if pos<=#out then local l=out:sub(pos); pos=#out+1; return l end
        return nil
      end
      local l=out:sub(pos,s-1); pos=e+1; return l
    end,
    close=function() return true end,
  }
end
-- Keep real mkdir/chmod but skip the backoff sleep between retries.
local real_execute=os.execute
os.execute=function(c) if type(c)=="string" and c:match("^sleep ") then return true end return real_execute(c) end
local Config=require("features/sui_ai_config")
Config.DIR=tmp.."/var-local"
cfg_file=assert(Config.merge(Config.load(),{provider="deepseek",key="sk-stream-test"}))
Client=require("features/sui_ai_client")
Client.CURL=curl_path
''')

    def reply(n, text):
        (work / f'reply.{n}').write_text(text)

    def exit_code(n, c):
        (work / f'exit.{n}').write_text(str(c))

    def calls():
        f = work / 'count'
        return int(f.read_text()) if f.exists() else 0

    def reset():
        for p in work.iterdir(): p.unlink()

    def lua_chat(stream=True):
        lua.globals().stream_path = str(Path(tmp) / 'stream.out') if stream else None
        return lua.execute(r'''
local sf=stream_path
local a,r=Client.chat(cfg_file,{{role="user",content="hi"}},{stream_file=sf})
return {answer=a,err=r}''')

    # A reply file holds the body plus the trailing http status line; the fake
    # curl's own exit code supplies the final line, as the real wrapper does.
    def sse(*parts, status='200'):
        return ''.join(parts) + f'\n{status}'

    def delta(text):
        return 'data: ' + json.dumps({'choices': [{'delta': {'content': text}}]}) + '\n'

    # 1. Clean SSE: deltas, a heartbeat comment and blank lines, then [DONE].
    reset()
    reply(1, sse(': heartbeat\n\n', delta('Hello'), delta('，'), delta('world'), 'data: [DONE]\n'))
    r = lua_chat()
    assert r['answer'] == 'Hello，world', r
    body = (work / 'body.1').read_text()
    assert '"stream"' in body, 'streaming asks for stream=true'
    assert calls() == 1

    # 2. A data line with extra whitespace still parses.
    reset()
    reply(1, sse('data:   ' + json.dumps({'choices': [{'delta': {'content': 'spaced'}}]}) + '  \n', 'data: [DONE]\n'))
    assert lua_chat()['answer'] == 'spaced'

    # 3. Mid-stream drop: content arrived but no [DONE] -> retry, then succeed.
    reset()
    reply(1, sse(delta('truncated')))
    reply(2, sse(delta('full answer'), 'data: [DONE]\n'))
    r = lua_chat()
    assert r['answer'] == 'full answer' and calls() == 2, (r, calls())

    # 4. Persistent drop reports an error instead of the truncated text.
    reset()
    reply(1, sse(delta('half')))
    r = lua_chat()
    assert r['answer'] is None and 'mid-stream' in r['err'] and calls() == 2, (r, calls())

    # 5. Server answers one JSON document (ignores stream=true): no [DONE]
    #    needed, parsed via the non-streaming fallback inside requestStream.
    reset()
    reply(1, json.dumps({'choices': [{'message': {'content': 'plain'}}]}) + '\n200')
    assert lua_chat()['answer'] == 'plain' and calls() == 1

    # 6. Server rejects streaming with 4xx: degrade to a plain request once.
    reset()
    reply(1, json.dumps({'error': {'message': 'stream unsupported'}}) + '\n422')
    reply(2, json.dumps({'choices': [{'message': {'content': 'degraded'}}]}) + '\n200')
    r = lua_chat()
    assert r['answer'] == 'degraded' and calls() == 2, (r, calls())
    assert '"stream"' not in (work / 'body.2').read_text(), 'the degraded retry is not streaming'

    # 7. 429 is retried once, then succeeds.
    reset()
    reply(1, json.dumps({'error': {'message': 'slow down'}}) + '\n429')
    reply(2, sse(delta('after retry'), 'data: [DONE]\n'))
    r = lua_chat()
    assert r['answer'] == 'after retry' and calls() == 2

    # 8. Persistent 500 fails with the status in the message; bounded retries.
    reset()
    reply(1, json.dumps({'error': {'message': 'boom'}}) + '\n500')
    r = lua_chat()
    assert r['answer'] is None and 'HTTP 500' in r['err'] and calls() == 2, (r, calls())

    # 9. Transport timeout (curl 28) is not retried.
    reset()
    reply(1, '\n000')
    exit_code(1, 28)
    r = lua_chat()
    assert r['answer'] is None and '28' in r['err'] and calls() == 1, (r, calls())

    # 10. Other transport errors are retried once.
    reset()
    reply(1, '\n000')
    exit_code(1, 7)
    r = lua_chat()
    assert r['answer'] is None and '(7)' in r['err'] and calls() == 2, (r, calls())

    # 11. A 200 with an unexpected shape is not retried and not confused.
    reset()
    reply(1, json.dumps({'unexpected': True}) + '\n200')
    r = lua_chat(stream=False)
    assert r['answer'] is None and r['err'] == 'Unexpected response' and calls() == 1, (r, calls())

    # 12. The final stream file holds the complete answer.
    reset()
    reply(1, sse(delta('on '), delta('disk'), 'data: [DONE]\n'))
    sp = Path(tmp) / 'stream.out'
    r = lua_chat()
    assert r['answer'] == 'on disk' and sp.read_text() == 'on disk'

    print('PASS: SSE deltas/heartbeat/[DONE], whitespace tolerance, mid-stream drop detection + bounded retry, '
          'non-streaming document fallback, 4xx degrade-to-plain (no stream flag on retry), 429/500 retries, '
          'timeout no-retry, transport retry, unexpected shape, final stream file content.')
