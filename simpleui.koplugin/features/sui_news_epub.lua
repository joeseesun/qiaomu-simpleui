-- Packs one news article as an EPUB in the hidden news cache, so KOReader's
-- own reader supplies typography, TOC, dictionary and highlights.
local Cache = require("features/sui_news_cache")
local Images = require("features/sui_news_images")
local lfs = require("libs/libkoreader-lfs")
local M = { KEEP = 30 }

function M.dir()
    local dir = Cache.root() .. "/epub"
    require("util").makePath(dir)
    return dir
end

-- ReaderUI reports "./settings/..." while history stores absolute paths.
function M.absolute(path)
    if type(path) ~= "string" then return end
    local ok, real = pcall(function() return require("ffi/util").realpath(path) end)
    return ok and real or path
end

function M.isNewsDoc(path)
    path = M.absolute(path)
    local prefix = (M.absolute(Cache.root()) or Cache.root()) .. "/epub/"
    return type(path) == "string" and path:sub(1, #prefix) == prefix
end

function M.path(id) return M.dir() .. "/" .. id .. ".epub" end

local function escape(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function plain(s)
    return (s:gsub("<[^>]*>", ""):gsub("&nbsp;", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Remove source typography, not semantics such as bold, alignment or hiding.
local typography = { font=true, ["font-size"]=true, ["font-family"]=true,
    ["font-size-adjust"]=true, ["line-height"]=true, ["text-size-adjust"]=true,
    ["-webkit-text-size-adjust"]=true, ["-moz-text-size-adjust"]=true }

local function cleanStyle(value)
    value = require("util").htmlEntitiesToUtf8(value)
    local kept, start, quote, depth, comment = {}, 1, nil, 0, false
    local function declaration(last)
        local item = value:sub(start, last)
        local property = item:gsub("/%*.-%*/", ""):match("^%s*(.-)%s*:")
        if not property then return end
        -- CSS identifiers may contain escapes/comments (HTML entities were
        -- already decoded). Normalize only the name; preserve other values.
        property = property:gsub("/%*.-%*/", ""):gsub("\\(%x+)%s?", function(hex)
            local n = tonumber(hex, 16)
            return n > 0 and n < 128 and string.char(n) or "?"
        end):lower():gsub("^%s+", ""):gsub("%s+$", "")
        if not typography[property] then kept[#kept + 1] = item end
    end
    for i = 1, #value do
        local c = value:sub(i, i)
        if comment then
            if c == "/" and value:sub(i-1, i-1) == "*" then comment = false end
        elseif quote then
            if c == quote and value:sub(i-1, i-1) ~= "\\" then quote = nil end
        elseif c == "/" and value:sub(i+1, i+1) == "*" then comment = true
        elseif c == '"' or c == "'" then quote = c
        elseif c == "(" then depth = depth + 1
        elseif c == ")" then depth = math.max(0, depth - 1)
        elseif c == ";" and depth == 0 then declaration(i-1); start = i+1 end
    end
    declaration(#value)
    return table.concat(kept, ";")
end

local function cleanAttributes(tag, attrs)
    if tag:lower() == "img" then return attrs end
    local parts, pos = {}, 1
    while pos <= #attrs do
        local first = pos
        local _, spaces = attrs:find("^%s*", pos)
        pos = (spaces or pos-1) + 1
        local name = attrs:sub(pos):match("^([%w_:%-]+)")
        if not name then parts[#parts+1] = attrs:sub(first, pos); pos = pos+1
        else
            pos = pos + #name
            local _, gap = attrs:find("^%s*", pos); pos = (gap or pos-1)+1
            local value
            if attrs:sub(pos, pos) == "=" then
                pos = pos+1
                local _, ws = attrs:find("^%s*", pos); pos = (ws or pos-1)+1
                local q = attrs:sub(pos, pos)
                if q == '"' or q == "'" then
                    local last = attrs:find(q, pos+1, true) or (#attrs+1)
                    value = attrs:sub(pos+1, last-1); pos = last+1
                else
                    local last = attrs:find("%s", pos) or (#attrs+1)
                    value = attrs:sub(pos, last-1); pos = last
                end
            end
            local lower = name:lower()
            if lower == "style" and value then
                local cleaned = cleanStyle(value)
                if cleaned:find("%S") then parts[#parts+1] = ' style="' .. escape(cleaned) .. '"' end
            elseif not (tag:lower() == "font" and (lower == "size" or lower == "face")) then
                parts[#parts+1] = attrs:sub(first, pos-1)
            end
        end
    end
    return table.concat(parts)
end

local function cleanTypography(html)
    local parts, pos = {}, 1
    while pos <= #html do
        local first = html:find("<", pos, true)
        if not first then parts[#parts+1] = html:sub(pos); break end
        parts[#parts+1] = html:sub(pos, first-1)
        if html:sub(first, first+3) == "<!--" then
            local last = html:find("-->", first+4, true)
            if not last then parts[#parts+1] = html:sub(first); break end
            parts[#parts+1] = html:sub(first, last+2); pos = last+3
        else
            local last, quote = first+1, nil
            while last <= #html do
                local c = html:sub(last, last)
                if quote then if c == quote then quote = nil end
                elseif c == '"' or c == "'" then quote = c
                elseif c == ">" then break end
                last = last+1
            end
            if last > #html then parts[#parts+1] = html:sub(first); break end
            local text = html:sub(first, last)
            local tag, attrs = text:match("^<([%a][%w_:%-]*)(.-)>$")
            parts[#parts+1] = tag and ("<" .. tag .. cleanAttributes(tag, attrs) .. ">") or text
            pos = last+1
        end
    end
    return table.concat(parts)
end

M.CSS = [[
body { line-height: 1.6; }
p, div, section { margin: 0 0 0.8em 0; text-indent: 0; }
h1.qm-title { font-size: 1.4em; line-height: 1.35; margin: 0 0 0.3em 0; text-align: left; }
p.qm-meta { font-size: 0.8em; color: #555; margin: 0 0 1.6em 0; }
h1, h2, h3 { line-height: 1.4; margin: 1.2em 0 0.5em 0; }
img { max-width: 100%; height: auto; }
blockquote { margin: 0.8em 1.2em; border-left: 2px solid #555; padding-left: 0.6em; }
pre { white-space: pre-wrap; font-size: 0.85em; }
p.qm-end { margin-top: 2.5em; text-align: center; font-size: 0.85em; color: #555; }
p.qm-next { margin-top: 1.2em; padding: 0.6em 0; text-align: center; font-weight: bold; }
]]

-- Returns body HTML with ids on h1-h3 and the matching TOC entries.
local function outline(body)
    local toc, n = {}, 0
    body = body:gsub("<([Hh])([1-3])([^>]*)>(.-)</[Hh]%2%s*>", function(h, level, attrs, inner)
        n = n + 1
        local id = attrs:match('[Ii][Dd]%s*=%s*"([^"]+)"')
        if not id then id = "qm-h" .. n; attrs = attrs .. ' id="' .. id .. '"' end
        local label = plain(inner)
        if label ~= "" then toc[#toc + 1] = { level = tonumber(level), id = id, label = label } end
        return "<" .. h .. level .. attrs .. ">" .. inner .. "</" .. h .. level .. ">"
    end)
    return body, toc
end

local function ncx(title, toc)
    local parts, play = {}, 1
    parts[#parts + 1] = string.format('<navPoint id="np-1" playOrder="1"><navLabel><text>%s</text></navLabel><content src="content.html"/></navPoint>', escape(title))
    for _, item in ipairs(toc) do
        play = play + 1
        parts[#parts + 1] = string.format('<navPoint id="np-%d" playOrder="%d"><navLabel><text>%s</text></navLabel><content src="content.html#%s"/></navPoint>',
            play, play, escape(item.label), item.id)
    end
    return [[<?xml version='1.0' encoding='utf-8'?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head><meta name="dtb:uid" content="qiaomu-news"/><meta name="dtb:depth" content="1"/></head>
<docTitle><text>]] .. escape(title) .. "</text></docTitle><navMap>" .. table.concat(parts) .. "</navMap></ncx>"
end

-- Removes the oldest EPUBs (and their sidecars) beyond KEEP, except `keep_path`.
local function prune(keep_path)
    local items = {}
    for name in lfs.dir(M.dir()) do
        if name:match("^[%w_-]+%.epub$") then
            local path = M.dir() .. "/" .. name
            items[#items + 1] = { path = path, time = lfs.attributes(path, "modification") or 0 }
        end
    end
    table.sort(items, function(a, b) return a.time > b.time end)
    local DocSettings = require("docsettings")
    for i = M.KEEP + 1, #items do
        if items[i].path ~= keep_path then
            pcall(function() DocSettings:open(items[i].path):purge() end)
            os.remove(items[i].path)
        end
    end
end

local EPUB_BUILDER_REV = "2"

--- Builds (or reuses) the EPUB for `entry`, ending with a link to `next_entry`.
--- Returns path, or nil and an error.
function M.build(entry, article, News, next_entry)
    local path = M.path(entry.id)
    local inputs = { EPUB_BUILDER_REV, article.version or "", article.format or "", article.body,
        News.title(entry), entry.sourceName or "", entry.sourceId or "", entry.published or "",
        next_entry and next_entry.id or "", next_entry and News.title(next_entry) or "", M.CSS }
    for i, value in ipairs(inputs) do inputs[i] = #value .. ":" .. value end
    local version = EPUB_BUILDER_REV .. ":" .. require("ffi/sha2").sha256(table.concat(inputs))
    local stamp = path .. ".version"
    local f = io.open(stamp, "rb")
    local existing = f and f:read("*a"); if f then f:close() end
    if existing == version and lfs.attributes(path, "mode") == "file" then return path end

    local html = Images.html(article)
    local body = html:match("<[Bb][Oo][Dd][Yy][^>]*>(.*)</[Bb][Oo][Dd][Yy]>") or html
    body = cleanTypography(body)
    local toc
    body, toc = outline(body)
    local title = News.title(entry)
    local meta = escape((entry.sourceName ~= "" and entry.sourceName or entry.sourceId or "") .. "  ·  " .. (entry.published or ""):sub(1, 10))
    local images, seen = {}, {}
    body = body:gsub('<img src="([%x]+%.%a+)"', function(name)
        if not seen[name] then
            seen[name] = true
            images[#images + 1] = name
        end
        return '<img src="images/' .. name .. '"'
    end)
    local content = "<html><head><title>" .. escape(title) .. '</title><link rel="stylesheet" type="text/css" href="stylesheet.css"/></head><body>'
        .. '<h1 class="qm-title">' .. escape(title) .. "</h1>"
        .. '<p class="qm-meta">' .. meta .. "</p>"
        .. body .. '<p class="qm-end">（全文完）</p>'
        .. (next_entry and ('<p class="qm-next"><a href="' .. require("features/sui_news_session").NEXT_URI .. next_entry.id .. '">下一篇：'
            .. escape(News.title(next_entry)) .. ' ›</a></p>') or "")
        .. "</body></html>"

    local types = { png = "image/png", jpg = "image/jpeg", gif = "image/gif", webp = "image/webp" }
    local manifest = {}
    for i, name in ipairs(images) do
        manifest[#manifest + 1] = string.format('<item id="img%d" href="images/%s" media-type="%s"/>', i, name, types[name:match("%.(%a+)$")] or "image/jpeg")
    end
    local opf = [[<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" unique-identifier="bookid" version="2.0">
<metadata><dc:title>]] .. escape(title) .. "</dc:title><dc:creator>" .. escape(entry.sourceName or "") .. [[</dc:creator>
<dc:language>zh</dc:language><dc:identifier id="bookid">qiaomu-]] .. entry.id .. [[</dc:identifier></metadata>
<manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="content" href="content.html" media-type="application/xhtml+xml"/>
<item id="css" href="stylesheet.css" media-type="text/css"/>]] .. table.concat(manifest) .. [[</manifest>
<spine toc="ncx"><itemref idref="content"/></spine></package>]]

    local Archiver = require("ffi/archiver")
    local epub = Archiver.Writer:new{}
    local tmp = path .. ".tmp"
    if not epub:open(tmp, "epub") then return nil, "Could not create EPUB" end
    local mtime = os.time()
    epub:setZipCompression("store")
    epub:addFileFromMemory("mimetype", "application/epub+zip", mtime)
    epub:setZipCompression("deflate")
    epub:addFileFromMemory("META-INF/container.xml", [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]], mtime)
    epub:addFileFromMemory("OEBPS/content.opf", opf, mtime)
    epub:addFileFromMemory("OEBPS/toc.ncx", ncx(title, toc), mtime)
    epub:addFileFromMemory("OEBPS/stylesheet.css", M.CSS, mtime)
    epub:addFileFromMemory("OEBPS/content.html", content, mtime)
    epub:setZipCompression("store")
    for _, name in ipairs(images) do
        local img = io.open(Cache.root() .. "/images/" .. name, "rb")
        if img then
            epub:addFileFromMemory("OEBPS/images/" .. name, img:read("*a"), mtime)
            img:close()
        end
    end
    epub:close()
    if not os.rename(tmp, path) then os.remove(tmp); return nil, "Could not save EPUB" end
    f = io.open(stamp, "wb")
    if f then f:write(version); f:close() end
    prune(path)
    return path
end

-- Typography keys carried from one news article to the next.
M.TYPOGRAPHY = { "font_face", "copt_font_size", "copt_line_spacing", "copt_h_page_margins",
    "copt_t_page_margin", "copt_b_page_margin", "copt_word_spacing", "copt_font_gamma", "copt_font_base_weight" }

--- Seeds a new article's sidecar with the news typography profile.
function M.seed(path, profile)
    local DocSettings = require("docsettings")
    if DocSettings:hasSidecarFile(path) then return end
    local settings = DocSettings:open(path)
    local font = profile and profile.font_face
    if not font then
        -- Prefer the bundled screen KaiTi when crengine knows it.
        local ok, faces = pcall(function() return require("document/credocument"):engineInit().getFontFaces() end)
        for _, face in ipairs(ok and faces or {}) do
            if face:find("WenKai", 1, true) then font = face; break end
        end
    end
    if font then settings:saveSetting("font_face", font) end
    for _, key in ipairs(M.TYPOGRAPHY) do
        if key ~= "font_face" and profile and profile[key] ~= nil then settings:saveSetting(key, profile[key]) end
    end
    settings:flush()
end

--- Reads the typography a reader session ended with.
function M.capture(doc_settings)
    local profile = {}
    for _, key in ipairs(M.TYPOGRAPHY) do profile[key] = doc_settings:readSetting(key) end
    return profile
end

return M
