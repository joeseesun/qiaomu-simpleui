-- Keep link destinations out of luamd's greedy inline delimiter parser.
-- KOReader still owns block layout, headings, lists and text emphasis.
local M = {}
local function escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end
local function unescape(s)
    return (s:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'"))
end
local function delimiters(s)
    local pairs, brackets, parens, i = {}, {}, {}, 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "\\" then i = i + 2
        else
            local stack = (c == "[" or c == "]") and brackets or parens
            if c == "[" or c == "(" then stack[#stack + 1] = i
            elseif (c == "]" or c == ")") and #stack > 0 then
                pairs[stack[#stack]] = i; stack[#stack] = nil
            end
            i = i + 1
        end
    end
    return pairs
end
local function destination(s, pos, pairs)
    local close = pairs[pos]
    if not close then return end
    local inner = s:sub(pos + 1, close - 1):match("^%s*(.-)%s*$")
    local url, rest
    if inner:sub(1, 1) == "<" then url, rest = inner:match("^<([^>]+)>(.*)$")
    else url, rest = inner:match("^(%S+)(.*)$") end
    if not url or (rest:match("%S") and not rest:match('^%s+["\'(].*["\')]%s*$')) then return end
    url = unescape((url:gsub("\\([%p])", "%1")))
    return url, close
end
local function safeLink(url, base)
    if url:find("[%z\1-\32\127]") then return end
    if url:sub(1, 1) == "#" then return url end
    if url:sub(1, 2) == "//" then url = "https:" .. url end
    if not url:match("^[%a][%w+.-]*:") and base then
        url = require("socket.url").absolute(base, url)
    end
    if url:match("^https?://") or url:match("^mailto:") then return url end
end
local function fragment(html)
    html = html:match("<body[^>]*>(.*)</body>") or html
    return (html:gsub("^%s*<p>", ""):gsub("</p>%s*$", ""))
end
function M.html(article)
    if article.format ~= "md" then return article.body end
    local converter = require("apps/filemanager/filemanagerconverter")
    local body, prefix, saved = article.body, "QIAOMULINKTOKEN", {}
    local pairs = delimiters(body)
    while body:find(prefix, 1, true) do prefix = prefix .. "X" end
    local function token(html)
        saved[#saved + 1] = html
        return prefix .. #saved .. "Q"
    end
    local parts, i = {}, 1
    while i <= #body do
        local c = body:sub(i, i)
        if c == "\\" then
            parts[#parts + 1] = body:sub(i, i + 1); i = i + 2
        elseif c == "`" or (body:sub(i, i + 2) == "~~~") then
            -- Leave code spans/fences to the native parser, without consuming
            -- links or images that are only examples inside code.
            local marker = body:match(c == "`" and "^`+" or "^~+", i)
            local close = body:find(marker, i + #marker, true)
            local last = close and close + #marker - 1 or i + #marker - 1
            parts[#parts + 1] = body:sub(i, last); i = last + 1
        elseif c == "<" then
            local last = body:find(">", i + 1, true)
            if last then parts[#parts + 1] = body:sub(i, last); i = last + 1
            else parts[#parts + 1] = c; i = i + 1 end
        else
            local image = body:sub(i, i + 1) == "!["
            local start = image and i + 1 or i
            local close = body:sub(start, start) == "[" and pairs[start]
            local url, finish
            if close and body:sub(close + 1, close + 1) == "(" then
                url, finish = destination(body, close + 1, pairs)
            end
            if url then
                local label = body:sub(start + 1, close - 1)
                if image then
                    parts[#parts + 1] = token('<img src="' .. escape(url) .. '" alt="' .. escape(label) .. '"/>')
                else
                    local href = safeLink(url, article.base_url)
                    local text = fragment(converter:mdToHtml(escape(label), "") or escape(label))
                    parts[#parts + 1] = token(href and ('<a href="' .. escape(href) .. '">' .. text .. '</a>') or text)
                end
                i = finish + 1
            else parts[#parts + 1] = c; i = i + 1 end
        end
    end
    local html = converter:mdToHtml(table.concat(parts), "")
    if type(html) ~= "string" then
        return "<p>" .. escape(body):gsub("\n%s*\n", "</p><p>"):gsub("\n", "<br/>") .. "</p>"
    end
    return (html:gsub(prefix .. "(%d+)Q", function(n) return saved[tonumber(n)] end))
end

-- Read quoted or unquoted attributes without confusing src with data-src.
function M.attribute(tag, wanted)
    local pos = 1
    while pos <= #tag do
        local _, last, name = tag:find("([%w_:%-]+)%s*=%s*", pos)
        if not last then return end
        local quote = tag:sub(last + 1, last + 1)
        local value, finish
        if quote == '"' or quote == "'" then
            finish = tag:find(quote, last + 2, true)
            if not finish then return end
            value = tag:sub(last + 2, finish - 1)
        else
            value = tag:match("^([^%s>]+)", last + 1)
            finish = last + #(value or "")
        end
        if name:lower() == wanted then return value and unescape(value) end
        pos = finish + 1
    end
end
function M.imageSource(tag)
    for _, name in ipairs{ "data-src", "data-original", "data-lazy-src", "src" } do
        local value = M.attribute(tag, name)
        if value and value ~= "" then return value end
    end
    local srcset = M.attribute(tag, "data-srcset") or M.attribute(tag, "srcset")
    return srcset and srcset:match("^%s*(%S+)")
end
return M
