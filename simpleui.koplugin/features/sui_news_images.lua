local Cache = require("features/sui_news_cache")
local lfs = require("libs/libkoreader-lfs")
local M = { ARTICLE_BUDGET=8*1024*1024, THUMB_BUDGET=4*1024*1024, MAX_IMAGE=2*1024*1024 }
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function key(url)
    local hash=require("ffi/sha2").sha256(url)
    assert(type(hash)=="string" and #hash==64 and hash:match("^[a-f0-9]+$"),"Invalid image digest")
    return hash
end
function M.safeUrl(url, base)
    if type(url)~="string" or #url>4096 or url:find("[%z\1-\32\127]") then return end
    url=url:gsub("&amp;","&")
    if url:sub(1,2)=="//" then url="https:"..url end
    if not url:match("^[%a][%w+.-]*:") and type(base)=="string" then
        url=require("socket.url").absolute(base,url)
    end
    url=url:gsub("^http://","https://"):gsub("#.*$","")
    local host=url:match("^https://([%w.-]+)[/?#]") or url:match("^https://([%w.-]+)$")
    if not host or not host:find("%.") or host:lower():match("%.local$") then return end
    return url,host:lower()
end
local function publicIPv4(ip)
    local a,b=ip:match("^(%d+)%.(%d+)%.%d+%.%d+$");a,b=tonumber(a),tonumber(b)
    return a and a>0 and a<224 and a~=10 and a~=127
        and not (a==169 and b==254) and not (a==172 and b>=16 and b<=31)
        and not (a==192 and b==168) and not (a==100 and b>=64 and b<=127)
        and not (a==198 and (b==18 or b==19))
end
function M.path(url)
    url=M.safeUrl(url)
    if not url then return end
    local digest=key(url)
    for _,ext in ipairs{"png","jpg","gif","webp"} do
        local path=Cache.root().."/images/"..digest.."."..ext
        if lfs.attributes(path,"mode")=="file" then return path end
    end
end
local function be(s,p) local a,b=s:byte(p,p+1);return a and b and a*256+b end
local function le(s,p) local a,b=s:byte(p,p+1);return a and b and a+b*256 end
local function u24(s,p) local a,b,c=s:byte(p,p+2);return a and c and a+b*256+c*65536 end
local function u32(s,p) local a,b,c,d=s:byte(p,p+3);return a and d and ((a*256+b)*256+c)*256+d end
function M.dimensions(s)
    if s:sub(1,8)=="\137PNG\13\10\26\10" then return u32(s,17),u32(s,21),"png" end
    if s:sub(1,3)=="GIF" then return le(s,7),le(s,9),"gif" end
    if s:sub(1,2)=="\255\216" then
        local p=3
        while p+8<=#s do
            if s:byte(p)~=255 then break end
            local marker=s:byte(p+1)
            if marker==255 then p=p+1
            else
                local n=be(s,p+2)
                if not n or n<2 then break end
                if marker>=192 and marker<=207 and marker~=196 and marker~=200 and marker~=204 then
                    return be(s,p+7),be(s,p+5),"jpg"
                end
                p=p+2+n
            end
        end
    end
    if s:sub(1,4)=="RIFF" and s:sub(9,12)=="WEBP" then
        if s:sub(13,16)=="VP8X" and #s>=30 then return u24(s,25)+1,u24(s,28)+1,"webp" end
        if s:sub(13,16)=="VP8 " and #s>=30 then return le(s,27)%16384,le(s,29)%16384,"webp" end
        if s:sub(13,16)=="VP8L" and #s>=25 then
            local a,b,c,d=s:byte(22,25)
            return 1+a+(b%64)*256,1+math.floor(b/64)+c*4+(d%16)*1024,"webp"
        end
    end
end
function M.fetch(url, budget, seconds)
    local safe,host=M.safeUrl(url)
    if not safe then return end
    local cached=M.path(safe)
    if cached then return cached,0 end
    local route=""
    if host=="rss.qiaomu.ai" then route=" --connect-to 'rss.qiaomu.ai:443:vps2.qiaomu.ai:443'"
    else
        local address
        for _,a in ipairs(require("socket").dns.getaddrinfo(host) or {}) do
            if a.family=="inet" and publicIPv4(a.addr) then address=a.addr;break end
        end
        if not address then return end
        route=" --resolve "..quote(host..":443:"..address)
    end
    local part=Cache.root().."/images/"..key(safe)..".part."..tonumber(require("ffi").C.getpid())
    local file=io.open(part,"wb");if not file then return end
    local max=math.min(budget,M.MAX_IMAGE)
    local cmd="/usr/bin/curl --silent --fail --ipv4 --proto '=https' --connect-timeout 3 --max-time "
        ..math.max(1,math.min(6,seconds or 6)).." --max-filesize "..max..route
        .." --user-agent 'Qiaomu-SimpleUI/3.0.0'"
        .." --header 'Accept: image/png,image/jpeg,image/webp,image/gif' --write-out '\\n%{http_code}' "..quote(safe)
        .." 2>/dev/null; qiaomu_image_exit=$?; printf '\\n%s' \"$qiaomu_image_exit\""
    local pipe=io.popen(cmd,"r")
    if not pipe then file:close();os.remove(part);return end
    local tail,total,oversized,write_ok="",0,false,true
    while true do
        local chunk=pipe:read(16384);if not chunk then break end
        total=total+#chunk
        if total>max+32 then oversized=true end
        if not oversized then
            tail=tail..chunk
            if #tail>32 then
                if not file:write(tail:sub(1,-33)) then write_ok=false end
                tail=tail:sub(-32)
            end
        end
    end
    pipe:close()
    local last,status,exit=tail:match("^(.*)\n(%d%d%d)\n(%d+)$")
    if last and not file:write(last) then write_ok=false end
    local closed=file:close()
    if oversized or not write_ok or status~="200" or exit~="0" or not closed then os.remove(part);return end
    local f=io.open(part,"rb");local head=f and f:read(65536);if f then f:close() end
    if (lfs.attributes(part,"size") or max+1)>max then os.remove(part);return end
    local w,h,ext=M.dimensions(head or "")
    if not w or not h or w<2 or h<2 or w>8192 or h>8192 or w*h>8000000 then os.remove(part);return end
    local path=Cache.root().."/images/"..key(safe).."."..ext
    if not os.rename(part,path) then os.remove(part);return end
    return path,lfs.attributes(path,"size") or 0
end
function M.urls(article)
    local result,seen={},{}
    local function add(url)
        url=M.safeUrl(url,article.base_url)
        if url and not seen[url] and #result<12 then seen[url]=true;result[#result+1]=url end
    end
    if article.format=="md" then
        for url in article.body:gmatch("!%[[^%]]*%]%(([^%s%)]+)") do add(url) end
    else
        for tag in article.body:gmatch("<[Ii][Mm][Gg]%s[^>]*>") do
            add(tag:match('[Ss][Rr][Cc]%s*=%s*"([^"]+)"') or tag:match("[Ss][Rr][Cc]%s*=%s*'([^']+)'"))
        end
    end
    return result
end
function M.download(urls,budget)
    local start,used,count=os.time(),0,0
    for _,url in ipairs(urls) do
        local remaining=25-(os.time()-start)
        if remaining<=0 or used>=budget then break end
        local path,bytes=M.fetch(url,budget-used,remaining)
        if path then used=used+(bytes or 0);count=count+1 end
    end
    return {count=count,bytes=used}
end
function M.html(article)
    local html=article.format=="md" and require("apps/filemanager/filemanagerconverter"):mdToHtml(article.body,"") or article.body
    return html:gsub("<[Ii][Mm][Gg]%s[^>]*>",function(tag)
        local raw=tag:match('[Ss][Rr][Cc]%s*=%s*"([^"]+)"') or tag:match("[Ss][Rr][Cc]%s*=%s*'([^']+)'")
        local url=M.safeUrl(raw,article.base_url)
        local path=url and M.path(url)
        if not path then return "" end
        Cache.touch(path)
        return '<img src="'..path:match("([^/]+)$")..'" style="max-width:100%;height:auto;"/>'
    end)
end
return M
