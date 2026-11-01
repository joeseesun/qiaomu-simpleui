-- sui_upload_web.lua — Simple UI
-- Phone page for sending books to the Kindle. Books are written into the
-- library folder (documents/) so they show up in the shelf.
--
-- The skeleton (token, firewall, idle timeout, request dispatch) lives in
-- infra/sui_webserver and is shared with the AI settings page.
local JSON = require("json")
local logger = require("logger")
local Web = require("infra/sui_webserver")
local Multipart = require("features/sui_upload_multipart")
local M = { PORT = 8687, IDLE = 300 }

-- Books can be tens of megabytes; the body reader needs a bigger ceiling
-- than the AI page's 64 KB.
local MAX_UPLOAD = 200 * 1024 * 1024

--- The library folder the Kindle shows to the reader.
local function libraryDir()
    local ok, home = pcall(function()
        local Scan = require("engines/sui_library_scan")
        return Scan.resolveHomeDir()
    end)
    if ok and type(home) == "string" and home ~= "" then return home end
    local Device = require("device")
    -- On a Kindle the home dir is /mnt/us; the reader's library folder is
    -- documents/ inside it.
    local base = Device.home_dir or "/mnt/us"
    if base:sub(-1) == "/" then base = base:sub(1, -2) end
    return base .. "/documents"
end

--- Makes a filename safe: no path separators, no leading dots, printable.
local function safeName(name)
    name = tostring(name or ""):gsub("[%z\1-\31\127/\\:%*%?\"<>|]", "_")
    name = name:gsub("^[%.%s]+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    if #name > 120 then
        -- Keep the extension when trimming.
        local ext = name:match("(%.[%w]+)$")
        if ext and #ext < 20 then name = name:sub(1, 120 - #ext) .. ext else name = name:sub(1, 120) end
    end
    return name
end

--- Resolves the destination directory, refusing to escape the library.
local function destinationDir(subdir)
    local base = libraryDir()
    if not subdir or subdir == "" then return base end
    -- Only a relative path without ".." is allowed.
    if subdir:find("%.%.") or subdir:find("^/") then return nil, "Invalid folder" end
    local cleaned = subdir:gsub("[%z\1-\31\127\\]", "_"):gsub("/+", "/")
    local dir = base .. "/" .. cleaned:gsub("^/", "")
    return dir
end

local function routes()
    local r = {}

    r["GET /"] = function(client)
        Web.respond(client, 200, "text/html; charset=utf-8", require("features/sui_upload_page").HTML)
    end

    r["POST /api/upload"] = function(client, request)
        local length = Web.contentLength(request.headers)
        if not length then return Web.json(client, 400, { error = "Invalid request" }) end
        if length > MAX_UPLOAD then return Web.json(client, 413, { error = "File too large" }) end
        local raw, err = Web.requestBody(client, request.headers, MAX_UPLOAD)
        if not raw then
            local msg = err == "too large" and "File too large" or (err == "truncated" and "Upload interrupted" or "Invalid request")
            return Web.json(client, 400, { error = msg })
        end
        local ctype = request.headers:match("\r\n[Cc]ontent%-[Tt]ype:%s*([^\r\n]+)") or ""
        local boundary = Multipart.boundary(ctype)
        if not boundary then return Web.json(client, 400, { error = "Invalid upload" }) end
        local parts, parse_err = Multipart.parse(raw, boundary)
        if not parts then return Web.json(client, 400, { error = parse_err or "Invalid upload" }) end

        local subdir = ""
        local field = Multipart.field(parts, "subdir")
        if field then subdir = field.content end
        local dir, dir_err = destinationDir(subdir)
        if not dir then return Web.json(client, 400, { error = dir_err }) end
        os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "'")

        local saved = {}
        for _, part in ipairs(parts) do
            if part.name == "file" and part.filename then
                local name = safeName(part.filename)
                if not name then
                    return Web.json(client, 400, { error = "Invalid file name" })
                end
                local path = dir .. "/" .. name
                local fh = io.open(path, "wb")
                if not fh then return Web.json(client, 500, { error = "Cannot write file" }) end
                fh:write(part.content)
                fh:close()
                saved[#saved + 1] = name
                logger.info("simpleui upload:", name, #part.content, "bytes")
            end
        end
        if #saved == 0 then return Web.json(client, 400, { error = "No file received" }) end

        -- Let the shelf see the new book right away.
        pcall(function()
            local Scan = require("engines/sui_library_scan")
            Scan.invalidate(dir)
            local Engine = require("engines/sui_screen_engine")
            if Engine and Engine.markAllStale then Engine.markAllStale() end
        end)

        Web.json(client, 200, { ok = true, files = saved })
    end

    return r
end

--- Starts the page. Returns the URL, or nil and an error.
function M.start(callback)
    if Web.running() then Web.stop() end
    local url, err = Web.start{
        port = M.PORT,
        idle = M.IDLE,
        routes = routes(),
        on_event = function(kind)
            if kind == "stopped" and callback then callback("stopped") end
        end,
    }
    if not url then return nil, err end
    return url
end

function M.stop() Web.stop() end

function M.running() return Web.running() end

-- Test helper: the request handler without a socket.
M._handle = function(data, client, srv, tok) return Web._handle(data, client, srv, tok, routes()) end

-- Test helpers: the pieces that need to be reachable without a socket.
M._safeName = safeName
M._destinationDir = destinationDir
M._libraryDir = libraryDir

return M
