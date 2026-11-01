"""Phone book upload: multipart parsing, safe file names, library target and
the shared web-server skeleton (token, body size limit)."""
from pathlib import Path
import json, tempfile
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / 'simpleui.koplugin'

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().plugin_root = str(ROOT)

lua.execute(r'''
package.path = plugin_root.."/?.lua;"..package.path
package.loaded["logger"] = { info=function() end, warn=function() end, dbg=function() end, err=function() end }
package.loaded["json"] = { encode=function() return "{}" end, decode=function(s) return py_decode(s) end }
package.loaded["util"] = { trim=function(s) return (s:gsub("^%s+",""):gsub("%s+$","")) end }
package.loaded["infra/sui_paths"] = { getPluginDirNoSlash=function() return "/mnt/us/plugins/simpleui.koplugin" end,
                                    getPluginDir=function() return "/mnt/us/plugins/simpleui.koplugin/" end }
package.loaded["infra/sui_text"] = { truncate=function(s,n) return s:sub(1,n) end }
package.loaded["infra/sui_core"] = { Notify = { toast=function() end } }
package.loaded["features/dialogs/sui_dialogs"] = {}
package.loaded["ui/uimanager"] = { scheduleIn=function() end, show=function() end, close=function() end,
                                   insertZMQ=function() return 1 end, removeZMQ=function() end }
package.loaded["ui/trapper"] = { wrap=function(_,fn) fn() end }
package.loaded["socket/http"] = { request=function() return nil end }
package.loaded["socket"] = { skip=function(...) return nil, nil, nil end, udp=function() error("no network") end }
package.loaded["ltn12"] = { sink={ table=function() return function() end end, file=function() return function() end end } }
package.loaded["socketutil"] = { set_timeout=function() end, reset_timeout=function() end }
package.loaded["device"] = { isKindle=false, home_dir="/mnt/us" }
package.loaded["libs/libkoreader-lfs"] = {
  attributes=function(path,what) if what=="modification" then return 0 end return { mode="file", modification=0, size=0 } end,
  dir=function() return function() end end,
}
''')

def _from_lua(value):
    if hasattr(value, 'keys'):
        keys = list(value.keys())
        if keys and all(isinstance(k, int) for k in keys):
            return [_from_lua(value[k]) for k in sorted(keys)]
        return {k: _from_lua(v) for k, v in value.items()}
    return value


def _to_lua(value):
    if isinstance(value, dict):
        return lua.table_from({k: _to_lua(v) for k, v in value.items()})
    if isinstance(value, list):
        return lua.table_from([_to_lua(v) for v in value])
    return value


lua.globals().py_decode = lambda s: _to_lua(json.loads(s))

# --- multipart parsing ------------------------------------------------------
lua.execute(r'''
local Multipart = require("features/sui_upload_multipart")

-- Boundary is taken from the Content-Type header, with or without quotes.
assert(Multipart.boundary("multipart/form-data; boundary=----X1")=="----X1")
assert(Multipart.boundary('multipart/form-data; boundary="----X1"')=="----X1")
assert(Multipart.boundary("multipart/form-data")==nil)

-- A form with one text field and one file part.
local body = table.concat({
  "--B\r\n",
  'Content-Disposition: form-data; name="subdir"\r\n',
  "\r\n",
  "小说\r\n",
  "--B\r\n",
  'Content-Disposition: form-data; name="file"; filename="我的书.epub"\r\n',
  "Content-Type: application/epub+zip\r\n",
  "\r\n",
  "PK\x03\x04binary\x00content\r\n",
  "--B--\r\n",
})
local parts = assert(Multipart.parse(body, "B"))
assert(#parts==2,"two parts are found")
assert(parts[1].name=="subdir" and parts[1].content=="小说","the text field is parsed")
assert(parts[2].name=="file" and parts[2].filename=="我的书.epub","the file name is parsed")
assert(parts[2].content:find("binary",1,true) and parts[2].content:find("\0",1,true),"binary payloads survive")
assert(Multipart.field(parts,"file")==parts[2],"field() finds a part by name")

-- Garbage in, an error out — never a crash.
assert(not Multipart.parse("no boundaries here","B"))
assert(not Multipart.parse(nil,"B"))
assert(not Multipart.parse(body,nil))
''')

# --- upload target and file names -----------------------------------------
lua.execute(r'''
local Upload = require("features/sui_upload_web")

-- The library folder is the one the reader shows.
local dir = Upload._libraryDir()
assert(dir:find("documents",1,true),"books land in the documents folder: "..tostring(dir))

-- File names must not escape the library.
assert(Upload._safeName("a.epub")=="a.epub")
assert(Upload._safeName("../../etc/passwd")==".._.._etc_passwd" or Upload._safeName("../../etc/passwd"):find("/")==nil,
  "path separators are removed")
assert(Upload._safeName("")==nil)
assert(Upload._safeName("a/b.epub"):find("/")==nil)

-- Sub-folders stay inside the library.
local base = Upload._libraryDir()
assert(Upload._destinationDir("")==base,"no subfolder means the library root")
assert(Upload._destinationDir("小说")==base.."/小说","a subfolder is appended")
assert(Upload._destinationDir("../etc")==nil,"a parent folder is refused")
assert(Upload._destinationDir("/etc")==nil,"an absolute path is refused")
''')

# --- the shared web server: token and body size ---------------------------
lua.execute(r'''
local Web = require("infra/sui_webserver")

-- The token is hex so the request matcher can read it.
local token = Web.randomToken()
assert(#token==24 and token:match("^[%x]+$"),"the token is 24 hex characters")

-- The body reader refuses anything above the caller's limit and reads the
-- rest in chunks (books are megabytes, the old limit was 64 KB).
-- The fake client hands out the body in 64 KB pieces and then stops.
local sent = {}
local client = {
  settimeout=function() end,
  receive=function(_,n) local s = sent[1]; if not s then return nil end
    local part = s:sub(1,n); sent[1] = s:sub(#part+1)
    if sent[1]=="" then sent[1]=nil end
    return part end,
}
local function makeBody(size)
  sent = { string.rep("a", size) }
end

makeBody(100)
local ok, err = Web.requestBody(client, "Content-Length: 100", 65536)
assert(ok and #ok==100,"a body within the limit is read")
assert(err==nil)

makeBody(100 * 1024)
local too_big, err2 = Web.requestBody(client, "Content-Length: 102400", 65536)
assert(too_big==nil and err2=="too large","the 64 KB limit still applies to the AI page")

makeBody(3 * 1024 * 1024)
local big = assert(Web.requestBody(client, "Content-Length: 3145728", 10 * 1024 * 1024))
assert(#big==3145728,"a multi-megabyte body is read, so books can be uploaded")

local none, err3 = Web.requestBody(client, "no length header", 65536)
assert(none==nil and err3=="no length","a missing length is reported")
''')

print('PASS: multipart parsing with binary payloads, safe file names, library '
      'target, token, and body reading beyond the old 64 KB limit.')
