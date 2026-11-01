-- sui_upload_multipart.lua — Simple UI
-- Minimal multipart/form-data parser for the phone book-upload page.
--
-- The browser posts a form with `multipart/form-data; boundary=...`.
-- This module finds the boundary in the Content-Type header, splits the
-- body into parts and returns each part's headers and payload.
--
-- The payload of one part is kept as a string (Lua strings are byte
-- strings, so binary books survive intact). Book files are several
-- megabytes, so the parser avoids per-byte loops and works on the
-- boundary markers only.
--
-- Public API
--   Multipart.boundary(content_type) -> boundary or nil
--   Multipart.parse(body, boundary)    -> parts or nil, err
--
-- Each part is:
--   { headers = "<raw header block>", name = "field", filename = "a.epub",
--     content = "<bytes>" }

local M = {}

--- Extracts the boundary from a Content-Type header value.
--- e.g. "multipart/form-data; boundary=----WebKitFormBoundaryXYZ"
function M.boundary(content_type)
    if type(content_type) ~= "string" then return nil end
    local b = content_type:match("[Bb]oundary=\"?([^\";\r\n]+)\"?")
    if b then b = b:gsub("%s+$", "") end
    return (b and b ~= "") and b or nil
end

--- Finds the header value of a part.
--- The header block may or may not start with a CRLF (the first header
--- follows the delimiter directly), so the lines are walked instead of
--- matched positionally.
local function partHeader(headers, name)
    name = name:lower()
    for line in (headers .. "\r\n"):gmatch("([^\r\n]*)\r\n") do
        local key, value = line:match("^([%w%-_]+)%s*:%s*(.*)$")
        if key and key:lower() == name then return value end
    end
    return nil
end

--- Parses a multipart body.
--- Returns a list of parts, or nil and an error.
function M.parse(body, boundary)
    if type(body) ~= "string" then return nil, "no body" end
    if type(boundary) ~= "string" or boundary == "" then return nil, "no boundary" end

    local delimiter = "--" .. boundary
    -- The first delimiter may be preceded by nothing, later ones by CRLF.
    local parts = {}
    local search_from = 1

    while true do
        local d_start, d_end = body:find(delimiter, search_from, true)
        if not d_start then break end
        -- After a delimiter comes either "--" (end of body) or CRLF.
        local after = body:sub(d_end + 1, d_end + 2)
        if after == "--" then break end
        if after ~= "\r\n" then
            search_from = d_end + 1
        else
            -- Header block ends at the first blank line.
            local body_start = body:find("\r\n\r\n", d_end + 3, true)
            if not body_start then break end
            local headers = body:sub(d_end + 3, body_start - 1)
            local content_start = body_start + 4
            -- The part ends at the next CRLF + delimiter.
            local next_delim = body:find("\r\n" .. delimiter, content_start, true)
            if not next_delim then break end
            local content = body:sub(content_start, next_delim - 1)

            local disposition = partHeader(headers, "content-disposition") or ""
            local name = disposition:match('name="([^"]*)"') or disposition:match("name=([^;%s]+)")
            local filename = disposition:match('filename="([^"]*)"') or disposition:match("filename=([^;%s]+)")
            local ctype = partHeader(headers, "content-type")

            parts[#parts + 1] = {
                headers = headers,
                name = name,
                filename = filename,
                content_type = ctype,
                content = content,
            }
            search_from = next_delim + 2
        end
    end

    if #parts == 0 then return nil, "no parts" end
    return parts, nil
end

--- Returns the part with the given form field name.
function M.field(parts, name)
    for _, p in ipairs(parts) do
        if p.name == name then return p end
    end
    return nil
end

return M
