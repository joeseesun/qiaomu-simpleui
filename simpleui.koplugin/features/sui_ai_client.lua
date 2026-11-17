-- OpenAI-compatible chat requests through the system curl. Runs inside a
-- cancellable subprocess; the key travels in a private curl config file,
-- never on the command line or in logs.
local JSON = require("json")
local Config = require("features/sui_ai_config")
local M = { CURL = "/usr/bin/curl" }

local function shell(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function privateFile(name, content)
    local path = string.format("%s/.%s-%d-%d", Config.DIR, name, os.time(), math.random(1, 1e9))
    local f = assert(io.open(path, "wb"))
    os.execute("chmod 600 " .. shell(path))
    f:write(content); f:close()
    return path
end

--- Request body (Qiaomu Reader buildAiRequestBody). DeepSeek thinking is
--- explicit; connection tests always disable it and cap tokens.
function M.body(cfg, messages, opts)
    opts = opts or {}
    local body = { model = opts.model or cfg.chat_model, messages = messages, temperature = 0.2 }
    -- Thinking is for conversations only; translation and lookup stay fast.
    local thinking = cfg.provider == "deepseek" and not opts.test and opts.thinking == true and cfg.thinking == true
    if not thinking then body.max_tokens = opts.test and 16 or (opts.max_tokens or 2400) end
    if cfg.provider == "deepseek" then body.thinking = { type = thinking and "enabled" or "disabled" } end
    if opts.stream_file then body.stream = true end
    return body
end

local function curlCmd(opts, conf, data, url, stream)
    return M.CURL .. " --silent " .. (stream and "-N " or "") .. "--ipv4 --connect-timeout 8 --max-time "
        .. (opts.timeout or 90) .. " --max-filesize 4194304 -K " .. shell(conf) .. " --data-binary @"
        .. shell(data) .. " --write-out '\\n%{http_code}' " .. shell(url) .. " 2>/dev/null; printf '\\n%s' \"$?\""
end

-- Network errors and 429/5xx are worth one retry; timeouts (curl 28) are not.
local function retryable(status, code)
    if code and code ~= "0" then return code ~= "28" end
    local s = tonumber(status)
    return s == 429 or (s ~= nil and s >= 500)
end

local function httpError(status, raw)
    local ok, payload = pcall(JSON.decode, raw)
    local message = ok and type(payload) == "table" and type(payload.error) == "table" and payload.error.message
    return "HTTP " .. status .. (type(message) == "string" and (": " .. message:sub(1, 200)) or "")
end

--- One non-streaming attempt: a single JSON response.
--- Returns answer, reasoning, error, retryable.
local function requestOnce(cfg, opts, conf, data)
    local pipe = io.popen(curlCmd(opts, conf, data, cfg.base .. "/chat/completions", false), "r")
    local out = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    local raw, status, code = out:match("^(.*)\n(%d%d%d)\n(%d+)$")
    if not raw then return nil, nil, "Network request failed", true end
    if code ~= "0" then return nil, nil, "Network error (" .. code .. ")", retryable(nil, code) end
    if tonumber(status) ~= 200 then return nil, nil, httpError(status, raw), retryable(status) end
    local ok, payload = pcall(JSON.decode, raw)
    local choice = ok and type(payload) == "table" and type(payload.choices) == "table" and payload.choices[1]
    local message = type(choice) == "table" and choice.message
    local answer = type(message) == "table" and message.content
    if type(answer) ~= "string" then return nil, nil, "Unexpected response", false end
    return answer, type(message.reasoning_content) == "string" and message.reasoning_content or nil
end

--- One streaming attempt: SSE deltas are appended to opts.stream_file as they
--- arrive, so the UI process can poll and render the partial answer.
--- Returns answer, error, retryable.
local function requestStream(cfg, opts, conf, data)
    local pipe = io.popen(curlCmd(opts, conf, data, cfg.base .. "/chat/completions", true), "r")
    if not pipe then return nil, "Network request failed", true end
    local chunks, rest = {}, {}
    local last_write = 0
    local done_seen = false
    local function writeFile()
        local f = io.open(opts.stream_file, "wb")
        if f then f:write(table.concat(chunks)); f:close() end
    end
    while true do
        local line = pipe:read("*l")
        if not line then break end
        if line:sub(1, 5) == "data:" then
            local payload = line:sub(6):gsub("^%s+", ""):gsub("%s+$", "")
            if payload == "[DONE]" then
                done_seen = true
            elseif payload ~= "" then
                local ok, obj = pcall(JSON.decode, payload)
                local choice = ok and type(obj) == "table" and type(obj.choices) == "table" and obj.choices[1]
                local delta = type(choice) == "table" and choice.delta
                -- Reasoning deltas stay invisible; only the answer streams.
                if type(delta) == "table" and type(delta.content) == "string" and delta.content ~= "" then
                    chunks[#chunks + 1] = delta.content
                    -- Rewrite at most once a second; the UI polls on its own schedule.
                    if os.time() ~= last_write then last_write = os.time(); writeFile() end
                end
            end
        elseif line ~= "" and line:sub(1, 1) ~= ":" then
            rest[#rest + 1] = line -- status and exit code lines, or an error body
        end
    end
    pipe:close()
    local status, code = rest[#rest - 1], rest[#rest]
    if not (status and status:match("^%d%d%d$") and code and code:match("^%d+$")) then
        return nil, "Network request failed", true
    end
    if code ~= "0" then return nil, "Network error (" .. code .. ")", retryable(nil, code) end
    if tonumber(status) ~= 200 then
        return nil, httpError(status, table.concat(rest, "\n", 1, #rest - 2)), retryable(status)
    end
    if #chunks > 0 and not done_seen then
        -- The stream ended without [DONE]: what we have is truncated, and
        -- showing it as a finished answer would be misleading.
        return nil, "Connection dropped mid-stream", true
    end
    if #chunks == 0 then
        -- The server ignored stream=true and answered one JSON document.
        local ok, payload = pcall(JSON.decode, table.concat(rest, "\n", 1, #rest - 2))
        local choice = ok and type(payload) == "table" and type(payload.choices) == "table" and payload.choices[1]
        local message = type(choice) == "table" and choice.message
        local answer = type(message) == "table" and message.content
        if type(answer) ~= "string" then return nil, "Unexpected response", false end
        chunks[1] = answer
    end
    writeFile()
    return table.concat(chunks), nil, false
end

--- Sends one chat request, with one retry on flaky connections.
--- Returns answer, reasoning, or nil and an error.
function M.chat(cfg, messages, opts)
    opts = opts or {}
    if not Config.ready(cfg) then return nil, "AI is not set up" end
    os.execute("mkdir -p " .. shell(Config.DIR))
    local headers = 'header = "Content-Type: application/json"\n'
    if cfg.key and cfg.key ~= "" then headers = headers .. 'header = "Authorization: Bearer ' .. cfg.key .. '"\n' end
    local conf = privateFile("curl", headers)
    local data = privateFile("body", JSON.encode(M.body(cfg, messages, opts)))
    local answer, err, again
    local reasoning
    for attempt = 1, 2 do
        if opts.stream_file then
            answer, err, again = requestStream(cfg, opts, conf, data)
            if not answer and not again and type(err) == "string" and err:match("^HTTP 4%d%d") then
                -- A 4xx against a streaming request usually means this server
                -- rejects stream=true; degrade once to a plain request instead
                -- of failing the feature.
                local plain = {}
                for k, v in pairs(opts) do plain[k] = v end
                plain.stream_file = nil
                local pdata = privateFile("body", JSON.encode(M.body(cfg, messages, plain)))
                answer, reasoning, err, again = requestOnce(cfg, plain, conf, pdata)
                os.remove(pdata)
            end
        else
            answer, reasoning, err, again = requestOnce(cfg, opts, conf, data)
        end
        if answer or not again or attempt == 2 then break end
        -- The sleep runs inside the cancellable subprocess, so the UI stays
        -- responsive and the retry can still be dismissed.
        os.execute("sleep 2")
    end
    os.remove(conf); os.remove(data)
    if not answer then return nil, err end
    return answer, reasoning
end

--- Sends a minimal message containing no reading content.
function M.test(cfg)
    local started = os.time()
    local answer, err = M.chat(cfg, { { role = "user", content = "Reply with OK." } }, { test = true, timeout = 30 })
    if not answer then return nil, err end
    return { answer = answer:sub(1, 40), seconds = os.time() - started }
end

return M
