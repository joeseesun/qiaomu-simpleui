-- sui_webserver.lua — Simple UI
-- Shared skeleton for the temporary LAN web pages (AI settings, book upload).
--
-- Both pages need the same things: a one-shot random token in the URL, a
-- temporary firewall hole on the Kindle, a 5-minute idle timeout, and a
-- request handler that can read a request body of arbitrary size.
--
-- Why this module exists
--   The AI settings page was the first such server and carried its own
--   copy of the token/firewall/idle logic. The book upload page needs the
--   same, plus a body reader that does not impose the 64 KB limit the AI
--   page had (books are megabytes). Rather than copy the skeleton, both
--   now live here.
--
-- Public API
--   WebServer.start{ port, token, title, idle, routes, on_event } -> url, err
--   WebServer.stop()
--   WebServer.running()                -> boolean
--   WebServer.address()                -> LAN IP or nil
--   WebServer.requestBody(client, headers, max) -> string or nil, err
--   WebServer.respond(client, code, ctype, body)
--   WebServer.json(client, code, value)
--
-- `routes` is a table keyed by "<METHOD> <path>" whose values are
-- functions(handler) where handler is:
--   handler(client, request)  -> handled (truthy) or nil to fall through
-- `request` is a table:
--   method, path, query, headers (raw header block), token (extracted)

local JSON = require("json")
local logger = require("logger")

local M = {}

local server, queue, token, last_seen, idle_task, on_event, state, port

M.PORT = 8686
M.IDLE = 300

-- ---------------------------------------------------------------------------
-- Token
-- ---------------------------------------------------------------------------

--- 24 hex characters from the kernel RNG. The URL is only valid while the
--- page is open, and the token is checked on every request.
function M.randomToken()
    local f = io.open("/dev/urandom", "rb")
    local bytes = f and f:read(12) or tostring(os.time() + math.random(1, 1e9))
    if f then f:close() end
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- The request token must be hex — the handler matches it with [%x]+.
function M.validToken(t)
    return type(t) == "string" and t:match("^[%x]+$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Firewall
-- ---------------------------------------------------------------------------

--- Opens (action "A") or closes (action "D") the Kindle firewall hole the
--- page needs. No-op on non-Kindle platforms, where no firewall exists.
function M.firewall(action, port)
    local Device = require("device")
    if not (Device.isKindle and Device:isKindle()) then return end
    os.execute(string.format("iptables -%s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", action, port))
    os.execute(string.format("iptables -%s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", action, port))
end

-- ---------------------------------------------------------------------------
-- Address
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Responses
-- ---------------------------------------------------------------------------

function M.respond(client, code, ctype, body)
    local reason = ({ [200] = "OK", [201] = "Created", [400] = "Bad Request",
        [403] = "Forbidden", [404] = "Not Found", [413] = "Payload Too Large",
        [500] = "Internal Server Error" })[code] or "OK"
    client:send(table.concat({
        "HTTP/1.0 " .. code .. " " .. reason,
        "Content-Type: " .. ctype,
        "Content-Length: " .. #body,
        "Cache-Control: no-store",
        "X-Content-Type-Options: nosniff",
        "Referrer-Policy: no-referrer",
        "Connection: close", "", body }, "\r\n"))
end

function M.json(client, code, value)
    M.respond(client, code, "application/json; charset=utf-8", JSON.encode(value))
end

-- ---------------------------------------------------------------------------
-- Request body
-- ---------------------------------------------------------------------------

--- Reads a request body of up to `max` bytes.
---
--- The AI settings page only ever posts a few hundred bytes; the upload
--- page posts whole books. The old reader refused anything above 64 KB,
--- which made uploads impossible, so the limit is now a parameter and
--- the caller decides.
---
--- Returns body, nil on success; nil, "too large" / "no length" / err on
--- failure. The body is read in chunks so a large transfer does not need
--- the whole thing in one socket read.
--- The declared body length, or nil when the header is absent.
--- The header block may or may not start with a CRLF, so both shapes are
--- accepted.
function M.contentLength(headers)
    if type(headers) ~= "string" then return nil end
    return tonumber(headers:match("\r\n[Cc]ontent%-[Ll]ength:%s*(%d+)"))
        or tonumber(headers:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)"))
end

function M.requestBody(client, headers, max)
    max = max or 65536
    local length = M.contentLength(headers)
    if not length then return nil, "no length" end
    if length > max then return nil, "too large" end
    client:settimeout(30, "t")
    local parts, got = {}, 0
    while got < length do
        local chunk = client:receive(math.min(65536, length - got))
        if not chunk or chunk == "" then break end
        got = got + #chunk
        parts[#parts + 1] = chunk
    end
    if got < length then return nil, "truncated" end
    return table.concat(parts), nil
end

-- ---------------------------------------------------------------------------
-- Request dispatch
-- ---------------------------------------------------------------------------

--- Splits a raw request block into method, path, query and headers.
local function parse(data)
    local method, target = data:match("^(%u+) (%S+) HTTP/1%.[01]")
    if not method then return nil end
    local path, query = target:match("^([^?]*)%??(.*)$")
    return {
        method = method,
        path = path,
        query = query or "",
        headers = data,
        token = (query or ""):match("t=([%x]+)"),
    }
end

local function handle(data, client)
    last_seen = os.time()
    local request = parse(data)
    if not request then return M.json(client, 400, { error = "Bad request" }) end
    -- Every request needs the session token; without it the page is closed.
    if request.token ~= token then
        return M.respond(client, 403, "text/plain", "Forbidden")
    end
    local handler = state and state.routes and state.routes[request.method .. " " .. request.path]
    if handler then
        local ok, err = pcall(handler, client, request)
        if not ok then
            logger.warn("simpleui web: handler failed", err)
            pcall(function() M.respond(client, 500, "text/plain", "Server error") end)
        end
        return
    end
    M.respond(client, 404, "text/plain", "Not found")
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Starts the page. Returns the URL, or nil and an error.
---
--- opts:
---   port    -- TCP port (default 8686)
---   token   -- session token (default: freshly generated)
---   idle    -- seconds before the page closes itself (default 300)
---   routes  -- table keyed by "<METHOD> <path>"
---   on_event -- callback(kind, value) for "stopped"
function M.start(opts)
    opts = opts or {}
    if server then M.stop() end
    local address = M.address()
    if not address then return nil, "Connect to Wi-Fi first" end
    port = opts.port or M.PORT
    token = opts.token or M.randomToken()
    last_seen = os.time()
    on_event = opts.on_event
    state = { routes = opts.routes or {} }

    local Server = require("ui/message/simpletcpserver")
    server = Server:new{ host = "*", port = port, receiveCallback = function(data, client)
        local ok, err = pcall(handle, data, client)
        if not ok then
            logger.warn("simpleui web: request failed", err)
            pcall(client.close, client)
        end
    end }
    local ok, err = server:start()
    if not ok then server = nil; return nil, err end
    M.firewall("A", port)
    queue = require("ui/uimanager"):insertZMQ(server)

    local idle = opts.idle or M.IDLE
    local function watch()
        if not server then return end
        if os.time() - last_seen >= idle then M.stop(); return end
        idle_task = watch
        require("ui/uimanager"):scheduleIn(15, watch)
    end
    watch()
    logger.info("simpleui web: listening on", address, port)
    return string.format("http://%s:%d/?t=%s", address, port, token), nil
end

function M.stop()
    if not server then return end
    local UIManager = require("ui/uimanager")
    if idle_task then UIManager:unschedule(idle_task); idle_task = nil end
    if queue then UIManager:removeZMQ(queue); queue = nil end
    pcall(server.stop, server)
    server, token = nil, nil
    state = nil
    M.firewall("D", port or M.PORT)
    logger.info("simpleui web: stopped")
    local callback = on_event
    on_event = nil
    if callback then callback("stopped") end
end

function M.running() return server ~= nil end

function M.currentToken() return token end

-- Test helper: the request handler without a socket. `routes` is optional;
-- without it the last started server's routes are used.
M._handle = function(data, client, srv, tok, routes)
    server, token = srv, tok
    if routes then state = { routes = routes } end
    return handle(data, client)
end

return M
