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
    return body
end

--- Sends one chat request. Returns answer, reasoning, or nil and an error.
function M.chat(cfg, messages, opts)
    opts = opts or {}
    if not Config.ready(cfg) then return nil, "AI is not set up" end
    os.execute("mkdir -p " .. shell(Config.DIR))
    local headers = 'header = "Content-Type: application/json"\n'
    if cfg.key and cfg.key ~= "" then headers = headers .. 'header = "Authorization: Bearer ' .. cfg.key .. '"\n' end
    local conf = privateFile("curl", headers)
    local data = privateFile("body", JSON.encode(M.body(cfg, messages, opts)))
    local cmd = M.CURL .. " --silent --ipv4 --connect-timeout 8 --max-time " .. (opts.timeout or 90)
        .. " --max-filesize 4194304 -K " .. shell(conf) .. " --data-binary @" .. shell(data)
        .. " --write-out '\\n%{http_code}' " .. shell(cfg.base .. "/chat/completions")
        .. " 2>/dev/null; printf '\\n%s' \"$?\""
    local pipe = io.popen(cmd, "r")
    local out = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    os.remove(conf); os.remove(data)
    local raw, status, code = out:match("^(.*)\n(%d%d%d)\n(%d+)$")
    if not raw then return nil, "Network request failed" end
    if code ~= "0" then return nil, "Network error (" .. code .. ")" end
    local ok, payload = pcall(JSON.decode, raw)
    if tonumber(status) ~= 200 then
        local message = ok and type(payload) == "table" and type(payload.error) == "table" and payload.error.message
        return nil, "HTTP " .. status .. (type(message) == "string" and (": " .. message:sub(1, 200)) or "")
    end
    local choice = ok and type(payload) == "table" and type(payload.choices) == "table" and payload.choices[1]
    local message = type(choice) == "table" and choice.message
    local answer = type(message) == "table" and message.content
    if type(answer) ~= "string" then return nil, "Unexpected response" end
    return answer, type(message.reasoning_content) == "string" and message.reasoning_content or nil
end

--- Sends a minimal message containing no reading content.
function M.test(cfg)
    local started = os.time()
    local answer, err = M.chat(cfg, { { role = "user", content = "Reply with OK." } }, { test = true, timeout = 30 })
    if not answer then return nil, err end
    return { answer = answer:sub(1, 40), seconds = os.time() - started }
end

return M
