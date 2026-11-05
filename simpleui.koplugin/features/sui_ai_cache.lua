-- Disk cache for idempotent AI answers (translation, word lookup): one JSON
-- file per request under /var/local/qiaomu/ai-cache. Keys mix provider,
-- model, target language and a hash of the messages, so cached answers
-- survive reboots and work offline. Past LIMIT files the oldest half goes.
local JSON = require("json")
local Config = require("features/sui_ai_config")
local M = { LIMIT = 200 }

function M.dir() return Config.DIR .. "/ai-cache" end

local sha2
local function hash(text)
    if sha2 == nil then
        local ok, mod = pcall(require, "ffi/sha2")
        sha2 = (ok and type(mod) == "table") and mod or false
    end
    if sha2 and type(sha2.sha1) == "function" then
        local ok, digest = pcall(sha2.sha1, text)
        if ok and type(digest) == "string" then
            if #digest == 40 and digest:match("^[0-9a-f]+$") then return digest end
            return (digest:gsub(".", function(c) return string.format("%02x", c:byte()) end))
        end
    end
    -- Portable fallback (desktop tests): djb2 over the bytes plus the length.
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
    return string.format("%08x-%d", h, #text)
end

local function key(cfg, kind, model, messages)
    local ok, encoded = pcall(JSON.encode, { provider = cfg.provider, model = model,
        lang = cfg.translate_to, kind = kind, messages = messages })
    return hash(ok and encoded or (tostring(kind) .. tostring(model) .. tostring(messages)))
end

local function path(k) return M.dir() .. "/" .. k .. ".json" end

--- Cached answer string, or nil on a miss.
function M.get(cfg, kind, model, messages)
    local f = io.open(path(key(cfg, kind, model, messages)), "rb")
    if not f then return nil end
    local ok, data = pcall(JSON.decode, f:read("*a") or "")
    f:close()
    if ok and type(data) == "table" and type(data.answer) == "string" and data.answer ~= "" then
        return data.answer
    end
end

local function shell(p) return "'" .. p:gsub("'", "'\\''") .. "'" end

--- Drops the oldest half once past LIMIT files; never fatal.
local function prune()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or type(lfs) ~= "table" or not lfs.attributes(M.dir()) then return end
    local files = {}
    for entry in lfs.dir(M.dir()) do
        if entry:match("%.json$") then
            local p = M.dir() .. "/" .. entry
            local attr = lfs.attributes(p)
            if attr then files[#files + 1] = { path = p, mtime = attr.modification } end
        end
    end
    if #files <= M.LIMIT then return end
    table.sort(files, function(a, b) return a.mtime < b.mtime end)
    for i = 1, math.floor(#files / 2) do os.remove(files[i].path) end
end

function M.set(cfg, kind, model, messages, answer)
    os.execute("mkdir -p " .. shell(M.dir()))
    local f = io.open(path(key(cfg, kind, model, messages)), "wb")
    if not f then return end
    f:write(JSON.encode({ answer = answer, time = os.time() }))
    f:close()
    prune()
end

return M
