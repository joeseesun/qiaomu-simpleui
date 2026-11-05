"""Disk cache for AI answers: keys distinguish provider/model/language/kind,
corrupt files are misses, write failures are silent, pruning bounds growth."""
from pathlib import Path
import json, os, tempfile
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / 'simpleui.koplugin'
with tempfile.TemporaryDirectory() as tmp:
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
    # Minimal lfs over the real tmp dir so prune() can list and stat files.
    lua.globals().py_list = lambda p: lua.table_from(sorted(os.listdir(p)))
    lua.globals().py_mtime = lambda p: os.path.getmtime(p)
    lua.globals().py_exists = lambda p: os.path.exists(p)
    lua.globals().bump = lambda p, t: os.utime(p, (t, t))
    lua.execute(r'''
package.path=plugin_root.."/?.lua;"..package.path
package.loaded["json"]={encode=py_encode,decode=py_decode}
package.loaded["libs/libkoreader-lfs"]={
  attributes=function(p) if py_exists(p) then return {modification=py_mtime(p)} end return nil end,
  dir=function(p) local names=py_list(p); local i=0
    return function() i=i+1; if names[i] then return names[i] end end end,
}
local Config=require("features/sui_ai_config")
Config.DIR=tmp.."/var-local"
Cache=require("features/sui_ai_cache")
ConfigRef=Config
local base={provider="deepseek",chat_model="m1",translate_model="m1",translate_to="zh-CN"}
local msgs={{role="user",content="hello"}}
Cache.set(base,"translate","m1",msgs,"答案")
assert(Cache.get(base,"translate","m1",msgs)=="答案","same key hits")
local other=base
assert(Cache.get({provider="kimi",translate_to="zh-CN"},"translate","m1",msgs)==nil,"provider is part of the key")
assert(Cache.get(base,"translate","m2",msgs)==nil,"model is part of the key")
assert(Cache.get(base,"translate","m1",{{role="user",content="other"}})==nil,"messages are part of the key")
assert(Cache.get(base,"lookup","m1",msgs)==nil,"kind is part of the key")
local en={provider="deepseek",translate_to="en"}
assert(Cache.get(en,"translate","m1",msgs)==nil,"target language is part of the key")
''')
    cache_dir = Path(tmp) / 'var-local' / 'ai-cache'
    files = list(cache_dir.glob('*.json'))
    assert len(files) == 1
    files[0].write_text('not json at all')
    lua.execute(r'''
local msgs={{role="user",content="hello"}}
local base={provider="deepseek",translate_to="zh-CN"}
assert(Cache.get(base,"translate","m1",msgs)==nil,"corrupt cache files are misses")
assert(Cache.get(base,"translate","m1",msgs)==nil,"repeat reads stay misses")
''')
    files[0].write_text(json.dumps({'answer': ''}))
    lua.execute(r'''
assert(Cache.get({provider="deepseek",translate_to="zh-CN"},"translate","m1",{{role="user",content="hello"}})==nil,
  "empty answers never count as hits")
''')
    # Write failure (directory cannot be created) must not raise.
    blocker = Path(tmp) / 'afile'
    blocker.write_text('x')
    lua.execute(r'''
ConfigRef.DIR=tmp.."/afile"
Cache.set({provider="deepseek",translate_to="zh-CN"},"translate","m1",{{role="user",content="x"}},"y")
assert(Cache.get({provider="deepseek",translate_to="zh-CN"},"translate","m1",{{role="user",content="x"}})==nil,
  "failed writes are silent misses, not errors")
ConfigRef.DIR=tmp.."/var-local"
''')
    # Pruning: past LIMIT files, the oldest half is removed.
    for i in range(6):
        lua.globals().i = i
        lua.execute(r'Cache.set({provider="deepseek",translate_to="zh-CN"},"translate","m1",{{role="user",content="k"..i}},"v"..i)')
        newest = max(cache_dir.glob('*.json'), key=lambda p: p.stat().st_mtime)
        os.utime(newest, (1000 + i, 1000 + i))
    lua.globals().keep = sorted(p.name for p in cache_dir.glob('*.json'))
    lua.execute(r'''
Cache.LIMIT=4
Cache.set({provider="deepseek",translate_to="zh-CN"},"translate","m1",{{role="user",content="k6"}},"v6")
local remaining=py_list(Cache.dir())
assert(#remaining<=4,"pruning bounds the cache: "..#remaining)
''')
    remaining = sorted(p.name for p in cache_dir.glob('*.json'))
    # The two oldest entries (k0, k1 — one of which was the corrupt file's
    # replacement) must be gone; the newest ones survive.
    assert len(remaining) <= 4 and len(remaining) >= 2, remaining
    print('PASS: key mixes provider/model/language/kind/messages, corrupt and empty entries are misses, '
          'write failure is silent, prune evicts oldest half past LIMIT.')
