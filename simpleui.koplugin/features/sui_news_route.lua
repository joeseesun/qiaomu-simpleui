-- curl 7.33 (Paperwhite 1) supports --resolve, but not --connect-to.
local M = {}

local function publicIPv4(ip)
    if type(ip) ~= "string" then return false end
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    return a and b <= 255 and c <= 255 and d <= 255 and a > 0 and a < 224
        and a ~= 10 and a ~= 127
        and not (a == 169 and b == 254) and not (a == 172 and b >= 16 and b <= 31)
        and not (a == 192 and b == 168) and not (a == 100 and b >= 64 and b <= 127)
        and not (a == 198 and (b == 18 or b == 19))
end

function M.resolve(host)
    -- Only the connection address changes; URL, Host, SNI and certificate
    -- verification continue to use the requested hostname. Never pin an IP.
    assert(type(host) == "string" and host:match("^[%w.-]+$"), "Invalid news host")
    local target = host == "rss.qiaomu.ai" and "vps2.qiaomu.ai" or host
    local ok, addresses = pcall(function() return require("socket").dns.getaddrinfo(target) end)
    if ok and type(addresses) == "table" then
        for _, address in ipairs(addresses) do
            if address.family == "inet" and publicIPv4(address.addr) then
                return " --resolve '" .. host .. ":443:" .. address.addr .. "'"
            end
        end
    end
end

function M.error(code)
    local reasons = {
        [2] = "unsupported curl option", [5] = "proxy DNS failed", [6] = "DNS failed",
        [7] = "connection failed", [28] = "request timed out", [35] = "TLS handshake failed",
        [60] = "TLS certificate verification failed", [63] = "response too large",
        [77] = "CA bundle could not be read; reinstall the complete plugin",
    }
    return "curl " .. tostring(code or "unknown") .. ": " .. (reasons[tonumber(code)] or "transfer incomplete")
end

return M
