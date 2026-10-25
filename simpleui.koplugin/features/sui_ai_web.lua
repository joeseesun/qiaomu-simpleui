-- Temporary LAN page for entering AI settings from a phone. Runs only while
-- the Kindle shows its QR code; every request needs the session token.
local JSON = require("json")
local Config = require("features/sui_ai_config")
local logger = require("logger")
local M = { PORT = 8686, IDLE = 300 }
local server, queue, token, last_seen, idle_task, on_event
local test_state = { status = "idle" }

local function firewall(action)
    local Device = require("device")
    if not (Device.isKindle and Device:isKindle()) then return end
    os.execute(string.format("iptables -%s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", action, M.PORT))
    os.execute(string.format("iptables -%s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", action, M.PORT))
end

local function randomToken()
    local f = io.open("/dev/urandom", "rb")
    local bytes = f and f:read(12) or tostring(os.time() + math.random(1, 1e9))
    if f then f:close() end
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- LAN address of this device (no packet is sent by a UDP connect).
function M.address()
    local ok, ip = pcall(function()
        local udp = require("socket").udp()
        udp:setpeername("223.5.5.5", 80)
        local addr = udp:getsockname()
        udp:close()
        return addr
    end)
    return ok and ip and ip ~= "0.0.0.0" and ip or nil
end

local function respond(client, code, ctype, body)
    local reason = ({ [200] = "OK", [400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found" })[code] or "OK"
    server:send(table.concat({
        "HTTP/1.0 " .. code .. " " .. reason,
        "Content-Type: " .. ctype,
        "Content-Length: " .. #body,
        "Cache-Control: no-store",
        "X-Content-Type-Options: nosniff",
        "Referrer-Policy: no-referrer",
        "Connection: close", "", body }, "\r\n"), client)
end

local function json(client, code, value) respond(client, code, "application/json; charset=utf-8", JSON.encode(value)) end

local function state()
    local providers = {}
    for _, p in ipairs(Config.PROVIDERS) do
        providers[#providers + 1] = { id = p.id, label = p.label, base = p.base, model = p.model, models = p.models,
            key_url = p.key_url, thinking = p.thinking == true, custom = p.custom == true, slow = p.slow == true,
            model_hint = p.model_hint }
    end
    return { config = Config.public(), providers = providers, languages = Config.LANGUAGES, test = test_state }
end

local function startTest(cfg)
    test_state = { status = "running" }
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local done, payload = Trapper:dismissableRunInSubprocess(function()
            local ok, result, err = pcall(require("features/sui_ai_client").test, cfg)
            return JSON.encode(ok and { result = result, error = err } or { error = tostring(result) })
        end, false, true)
        local decoded, response = pcall(JSON.decode, payload or "")
        if not done then
            test_state = { status = "error", message = "Cancelled" }
        elseif decoded and type(response) == "table" and type(response.result) == "table" then
            test_state = { status = "ok", seconds = response.result.seconds, answer = response.result.answer }
        else
            test_state = { status = "error", message = decoded and type(response) == "table" and tostring(response.error) or "Invalid response" }
        end
        logger.info("simpleui ai-web: test", test_state.status)
        if on_event then on_event("test", test_state) end
    end)
end

local function body(client, headers)
    local length = tonumber(headers:match("\r\n[Cc]ontent%-[Ll]ength:%s*(%d+)"))
    if not length or length > 65536 then return nil end
    client:settimeout(2, "t")
    return client:receive(length)
end

local function handle(data, client)
    last_seen = os.time()
    local method, target = data:match("^(%u+) (%S+) HTTP/1%.[01]")
    if not method then return json(client, 400, { error = "Bad request" }) end
    local path, query = target:match("^([^?]*)%??(.*)$")
    if query:match("t=([%x]+)") ~= token then return respond(client, 403, "text/plain", "Forbidden") end
    if method == "GET" and path == "/" then
        return respond(client, 200, "text/html; charset=utf-8", require("features/sui_ai_page").HTML)
    elseif method == "GET" and path == "/api/state" then
        return json(client, 200, state())
    elseif method == "POST" and (path == "/api/save" or path == "/api/test") then
        local raw = body(client, data)
        local ok, input = pcall(JSON.decode, raw or "")
        if not ok or type(input) ~= "table" then return json(client, 400, { error = "Invalid request" }) end
        local cfg, err = Config.merge(Config.load(), input)
        if not cfg then return json(client, 400, { error = err }) end
        if path == "/api/test" then
            if not Config.ready(cfg) then return json(client, 400, { error = "Fill in the service, model and API key first" }) end
            startTest(cfg)
            return json(client, 200, { status = "running" })
        end
        Config.save(cfg)
        logger.info("simpleui ai-web: saved", cfg.provider, cfg.chat_model)
        json(client, 200, { ok = true, config = Config.public(cfg) })
        if on_event then on_event("saved", cfg) end
        return
    end
    return respond(client, 404, "text/plain", "Not found")
end

--- Starts the page. Returns the URL, or nil and an error.
--- `callback(kind, value)` receives "saved", "test" and "stopped".
function M.start(callback)
    if server then M.stop() end
    local address = M.address()
    if not address then return nil, "Connect to Wi-Fi first" end
    token, last_seen, on_event, test_state = randomToken(), os.time(), callback, { status = "idle" }
    local Server = require("ui/message/simpletcpserver")
    server = Server:new{ host = "*", port = M.PORT, receiveCallback = function(data, client)
        local ok, err = pcall(handle, data, client)
        if not ok then
            logger.warn("simpleui ai-web: request failed", err)
            pcall(client.close, client)
        end
    end }
    local ok, err = server:start()
    if not ok then server = nil; return nil, err end
    firewall("A")
    queue = require("ui/uimanager"):insertZMQ(server)
    local function watch()
        if not server then return end
        if os.time() - last_seen >= M.IDLE then M.stop(); return end
        idle_task = watch
        require("ui/uimanager"):scheduleIn(15, watch)
    end
    watch()
    logger.info("simpleui ai-web: listening on", address, M.PORT)
    return string.format("http://%s:%d/?t=%s", address, M.PORT, token)
end

function M.stop()
    if not server then return end
    local UIManager = require("ui/uimanager")
    if idle_task then UIManager:unschedule(idle_task); idle_task = nil end
    if queue then UIManager:removeZMQ(queue); queue = nil end
    pcall(server.stop, server)
    server, token = nil, nil
    firewall("D")
    logger.info("simpleui ai-web: stopped")
    local callback = on_event
    on_event = nil
    if callback then callback("stopped") end
end

function M.running() return server ~= nil end

-- Test helper: the request handler without a socket.
M._handle = function(data, client, srv, tok) server, token = srv, tok; return handle(data, client) end

return M
