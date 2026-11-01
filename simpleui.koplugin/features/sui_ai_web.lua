-- Temporary LAN page for entering AI settings from a phone. Runs only while
-- the Kindle shows its QR code; every request needs the session token.
--
-- The skeleton (token, firewall, idle timeout, request dispatch) lives in
-- infra/sui_webserver and is shared with the book-upload page.
local JSON = require("json")
local Config = require("features/sui_ai_config")
local logger = require("logger")
local Web = require("infra/sui_webserver")
local M = { PORT = 8686, IDLE = 300 }
local server, queue, token, last_seen, idle_task, on_event
local test_state = { status = "idle" }
local models_state = { status = "idle" }

local function state()
    local providers = {}
    for _, p in ipairs(Config.PROVIDERS) do
        providers[#providers + 1] = { id = p.id, label = p.label, base = p.base, model = p.model, models = Config.asArray(p.models),
            key_url = p.key_url, thinking = p.thinking == true, custom = p.custom == true, slow = p.slow == true,
            model_hint = p.model_hint }
    end
    return { config = Config.public(), providers = providers, languages = Config.LANGUAGES,
        test = test_state, models = models_state }
end

--- Runs one check in a cancellable subprocess; result lands in test_state.
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

--- Asks the configured service which models it offers and returns the list.
--- The request is made by the Kindle (never by the phone) so the API key
--- stays on the device.
local function startModels(cfg)
    models_state = { status = "running" }
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local done, payload = Trapper:dismissableRunInSubprocess(function()
            local ok, list, err = pcall(require("features/sui_ai_client").models, cfg)
            return JSON.encode(ok and { models = list, error = err } or { error = tostring(list) })
        end, false, true)
        local decoded, response = pcall(JSON.decode, payload or "")
        if not done then
            models_state = { status = "error", message = "Cancelled" }
        elseif decoded and type(response) == "table" and type(response.models) == "table" then
            models_state = { status = "ok", models = response.models }
        else
            models_state = { status = "error", message = decoded and type(response) == "table" and tostring(response.error) or "Invalid response" }
        end
        logger.info("simpleui ai-web: models", models_state.status)
        if on_event then on_event("models", models_state) end
    end)
end

--- Builds the route table. `routes` is keyed by "<METHOD> <path>".
local function routes()
    local r = {}

    r["GET /"] = function(client)
        Web.respond(client, 200, "text/html; charset=utf-8", require("features/sui_ai_page").HTML)
    end

    r["GET /api/state"] = function(client)
        Web.json(client, 200, state())
    end

    -- Save settings, or start a connection test.
    r["POST /api/save"] = function(client, request)
        local raw, err = Web.requestBody(client, request.headers, 65536)
        if not raw then return Web.json(client, 400, { error = err == "too large" and "Request too large" or "Invalid request" }) end
        local ok, input = pcall(JSON.decode, raw)
        if not ok or type(input) ~= "table" then return Web.json(client, 400, { error = "Invalid request" }) end
        local cfg, merge_err = Config.merge(Config.load(), input)
        if not cfg then return Web.json(client, 400, { error = merge_err }) end
        Config.save(cfg)
        logger.info("simpleui ai-web: saved", cfg.provider, cfg.chat_model)
        Web.json(client, 200, { ok = true, config = Config.public(cfg) })
        if on_event then on_event("saved", cfg) end
    end

    r["POST /api/test"] = function(client, request)
        local raw, err = Web.requestBody(client, request.headers, 65536)
        if not raw then return Web.json(client, 400, { error = err == "too large" and "Request too large" or "Invalid request" }) end
        local ok, input = pcall(JSON.decode, raw)
        if not ok or type(input) ~= "table" then return Web.json(client, 400, { error = "Invalid request" }) end
        local cfg, merge_err = Config.merge(Config.load(), input)
        if not cfg then return Web.json(client, 400, { error = merge_err }) end
        if not Config.ready(cfg) then
            return Web.json(client, 400, { error = "Fill in the service, model and API key first" })
        end
        startTest(cfg)
        Web.json(client, 200, { status = "running" })
    end

    -- Fetch the model's list from the configured endpoint.
    r["POST /api/models"] = function(client, request)
        local raw, err = Web.requestBody(client, request.headers, 65536)
        if not raw then return Web.json(client, 400, { error = err == "too large" and "Request too large" or "Invalid request" }) end
        local ok, input = pcall(JSON.decode, raw)
        if not ok or type(input) ~= "table" then return Web.json(client, 400, { error = "Invalid request" }) end
        local cfg, merge_err = Config.merge(Config.load(), input)
        if not cfg then return Web.json(client, 400, { error = merge_err }) end
        if type(cfg.base) ~= "string" or cfg.base == "" then
            return Web.json(client, 400, { error = "Fill in the service address first" })
        end
        startModels(cfg)
        Web.json(client, 200, { status = "running" })
    end

    return r
end

--- Starts the page. Returns the URL, or nil and an error.
--- `callback(kind, value)` receives "saved", "test", "models" and "stopped".
function M.start(callback)
    if Web.running() then Web.stop() end
    on_event = callback
    local url, err = Web.start{
        port = M.PORT,
        idle = M.IDLE,
        routes = routes(),
        on_event = function(kind, value)
            if kind == "stopped" then
                on_event = nil
                if callback then callback("stopped") end
            end
        end,
    }
    if not url then on_event = nil; return nil, err end
    return url
end

function M.stop()
    Web.stop()
end

function M.running() return Web.running() end

-- Test helper: the request handler without a socket.
M._handle = function(data, client, srv, tok) return Web._handle(data, client, srv, tok, routes()) end

return M
