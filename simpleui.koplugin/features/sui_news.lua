-- Qiaomu's public read API, shared with Qiaomu AI RSS for Obsidian.
-- All news data stays outside the book library and ReadHistory.
local JSON = require("json")
local DataStorage = require("datastorage")
local M = { ORIGIN = "https://rss.qiaomu.ai", LIMIT = 60, MAX_ITEMS = 200 }
local state

local function root()
    local dir = DataStorage:getSettingsDir() .. "/simpleui/news"
    require("util").makePath(dir .. "/articles")
    return dir
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return end
    local s = f:read("*a"); f:close()
    if #s > 4 * 1024 * 1024 then return end
    local ok, value = pcall(JSON.decode, s)
    if ok and type(value) == "table" then return value end
end

local function write(path, value)
    local f, err = io.open(path .. ".tmp", "wb")
    assert(f, err)
    local ok, why = f:write(JSON.encode(value))
    local closed, close_err = f:close()
    assert(ok and closed, why or close_err)
    assert(os.rename(path .. ".tmp", path))
end

function M.validId(id)
    return type(id) == "string" and #id <= 128 and id:match("^[%w_-]+$") ~= nil
end

function M.state()
    if not state then
        state = read(root() .. "/index.json") or {}
        for _, key in ipairs{ "entries", "sources", "flags" } do
            if type(state[key]) ~= "table" then state[key] = {} end
        end
        if #state.sources == 0 then
            local preset = read(require("infra/sui_paths").getPluginDir() .. "data/qiaomu_sources.json")
            state.sources = preset and preset.sources or {}
        end
    end
    return state
end

function M.save() write(root() .. "/index.json", M.state()) end

local function text(value, limit)
    if type(value) ~= "string" then return "" end
    -- Do not split UTF-8 in the middle of a character.
    if #value > limit then return "" end
    return value
end

function M.title(entry)
    return type(entry.titleZh) == "string" and entry.titleZh ~= "" and entry.titleZh or entry.title
end

function M.merge(entries, sources)
    assert(type(entries) == "table", "Invalid article list")
    local s, merged, seen = M.state(), {}, {}
    local names = {}
    if type(sources) == "table" then
        local clean = {}
        for _, source in ipairs(sources) do
            if type(source) == "table" and M.validId(source.id) and type(source.name) == "string" and source.enabled ~= false then
                clean[#clean + 1] = { id = source.id, name = text(source.name, 500) }
                names[source.id] = source.name
            end
        end
        s.sources = clean
    end
    for _, source in ipairs(s.sources) do names[source.id] = source.name end
    for _, raw in ipairs(entries) do
        if type(raw) == "table" and M.validId(raw.id) and type(raw.title) == "string" and not seen[raw.id] then
            seen[raw.id] = true
            merged[#merged + 1] = {
                id = raw.id, title = text(raw.title, 4000), titleZh = text(raw.titleZh, 4000),
                sourceId = text(raw.sourceId, 128), sourceName = names[raw.sourceId] or text(raw.sourceName, 500),
                published = text(raw.published, 100), publishedTs = tonumber(raw.publishedTs) or 0,
                link = text(raw.link, 4000),
            }
        end
        if #merged >= M.MAX_ITEMS then break end
    end
    -- Keep older saved articles and their reading positions across refreshes.
    for _, entry in ipairs(s.entries) do
        if M.validId(entry.id) and not seen[entry.id] then
            if #merged < M.MAX_ITEMS or (s.flags[entry.id] or {}).starred then
                merged[#merged + 1] = entry
                seen[entry.id] = true
            end
        end
    end
    for id in pairs(s.flags) do
        if not seen[id] then
            if M.validId(id) then os.remove(root() .. "/articles/" .. id .. ".json") end
            s.flags[id] = nil
        end
    end
    table.sort(merged, function(a, b)
        if a.publishedTs ~= b.publishedTs then return a.publishedTs > b.publishedTs end
        return a.id < b.id
    end)
    s.entries, s.updated_at = merged, os.time()
    M.save()
end

function M.flag(id)
    assert(M.validId(id), "Invalid article ID")
    local s = M.state()
    s.flags[id] = s.flags[id] or {}
    return s.flags[id]
end

function M.cached(id)
    assert(M.validId(id), "Invalid article ID")
    local article = read(root() .. "/articles/" .. id .. ".json")
    if article and type(article.body) == "string" and #article.body > 0
            and #article.body <= 400000 and (article.format == "html" or article.format == "md") then
        return article
    end
end

function M.cache(id, article)
    assert(M.validId(id), "Invalid article ID")
    assert(type(article.body) == "string" and #article.body > 0 and #article.body <= 400000,
        "Article is empty or too large for this device")
    assert(article.format == "md" or article.format == "html", "Invalid article format")
    write(root() .. "/articles/" .. id .. ".json", article)
    M.flag(id).offline = true
    M.save()
end

-- Requests run in KOReader's cancellable subprocess, never in a new service.
local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function curlRequest(path)
    -- Kindle's built-in curl uses its system TLS/CA stack. LuaSec can stall
    -- on these same CDN handshakes. No external program is installed.
    local last_error
    for i = 1, 2 do
        local command = "/usr/bin/curl --silent --fail --compressed --ipv4 --connect-timeout 8 --max-time 25"
            .. " --max-filesize 4194304 --proto '=https'"
            .. " --header 'Accept: application/json' --header 'X-Rss-List: reader-v1'"
            .. " --user-agent 'Qiaomu-SimpleUI/3.0.0'"
            .. " --write-out '\\n%{http_code}'"
        if i == 1 then
            -- Existing DNS-only origin hostname, not a new service or pinned IP.
            -- --connect-to changes routing only: TLS SNI, certificate validation
            -- and HTTP Host remain rss.qiaomu.ai. The public CDN is the fallback.
            command = command .. " --connect-to " .. shellQuote("rss.qiaomu.ai:443:vps2.qiaomu.ai:443")
        end
        command = command .. " " .. shellQuote(M.ORIGIN .. path)
            .. " 2>/dev/null; qiaomu_news_exit=$?; printf '\\n%s' \"$qiaomu_news_exit\""
        local pipe = io.popen(command, "r")
        if not pipe then return nil, "Could not start network request" end
        local chunks, size, oversized = {}, 0, false
        while true do
            local chunk = pipe:read(65536)
            if not chunk then break end
            size = size + #chunk
            if size > 4 * 1024 * 1024 then oversized = true; break end
            chunks[#chunks + 1] = chunk
        end
        local closed, _, exit_code = pipe:close()
        if oversized then return nil, "Response too large" end
        local body, status, curl_status = table.concat(chunks):match("^(.*)\n(%d%d%d)\n(%d+)$")
        local failed = tonumber(curl_status) ~= 0 or closed == false or (exit_code ~= nil and exit_code ~= 0)
        if tonumber(status) == 200 and not failed then
            local ok, data = pcall(JSON.decode, body)
            if ok and type(data) == "table" then return data end
            return nil, "Invalid response"
        end
        last_error = tonumber(status) and tonumber(status) >= 300 and ("HTTP " .. status)
            or ("Network transfer incomplete (" .. tostring(curl_status) .. ")")
        if tonumber(status) and tonumber(status) >= 300 then break end
    end
    return nil, last_error
end

function M.request(path)
    assert(path:sub(1, 5) == "/api/", "Invalid API path")
    local Device = require("device")
    local curl = Device.isKindle and Device:isKindle() and io.open("/usr/bin/curl", "rb")
    if curl then curl:close(); return curlRequest(path) end
    local http, socketutil = require("socket.http"), require("socketutil")
    local chunks, size, started = {}, 0, os.time()
    socketutil:set_timeout(5, 15)
    local options = {
        url = M.ORIGIN .. path, method = "GET", redirect = false,
        headers = { ["User-Agent"] = "Qiaomu-SimpleUI/3.0.0", Accept = "application/json", ["X-Rss-List"] = "reader-v1" },
        sink = function(chunk)
            if chunk then
                size = size + #chunk
                if size > 4 * 1024 * 1024 then return nil, "Response too large" end
                if os.time() - started > 15 then return nil, "Request timed out" end
                chunks[#chunks + 1] = chunk
            end
            return 1
        end,
    }
    local ok, result, code = pcall(http.request, options)
    socketutil:reset_timeout()
    if not ok or tonumber(code) ~= 200 then
        return nil, "HTTP " .. tostring(code or result or "network error")
    end
    local decoded, data = pcall(JSON.decode, table.concat(chunks))
    if not decoded or type(data) ~= "table" then return nil, "Invalid response" end
    return data
end

function M.fetchIndex(source)
    if source ~= nil then assert(M.validId(source), "Invalid source ID") end
    local path = source and ("/api/sources/" .. source .. "/entries") or "/api/entries"
    local entries, err = M.request(path .. "?limit=" .. M.LIMIT)
    if not entries or type(entries.entries) ~= "table" then return nil, err or "Invalid article list" end
    -- Source names ship with the plugin and can be refreshed separately:
    -- a large or unavailable catalog must not hold up the latest articles.
    return { entries = entries.entries }
end

function M.fetchArticle(id)
    assert(M.validId(id), "Invalid article ID")
    -- Prefer the already published Chinese reading version; do not generate AI content.
    local rewrite = M.request("/api/entry/" .. id .. "/rewrite")
    rewrite = rewrite and rewrite.rewrite
    if type(rewrite) == "table" and rewrite.stale ~= true and type(rewrite.body) == "string"
            and #rewrite.body > 0 and #rewrite.body <= 400000 then
        return { body = rewrite.body, format = "md", version = "rewrite" }
    end
    local data, err = M.request("/api/entry/" .. id)
    local entry = data and data.entry
    if type(entry) ~= "table" or entry.id ~= id then return nil, err or "Article unavailable" end
    local body = entry.content
    if type(body) ~= "string" or #body == 0 then return nil, "Full article unavailable" end
    if #body > 400000 then return nil, "Article too large for this device" end
    -- Text-first offline reading: external images, embeds and scripts are not fetched.
    for _, tag in ipairs{ "script", "style", "iframe", "video", "audio", "svg" } do
        local pattern = tag:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end)
        body = body:gsub("<" .. pattern .. "[%s>].-</" .. pattern .. "%s*>", "")
    end
    body = body:gsub("<[Ii][Mm][Gg][%s/].->", "")
    return { body = body, format = "html", version = "original" }
end

return M
