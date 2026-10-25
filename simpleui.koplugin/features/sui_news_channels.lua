-- Channel structure of Qiaomu AI RSS (Obsidian, src/discovery.ts):
-- all picks, four Qiaomu groups, individual Qiaomu channels and the reader
-- community. Personal RSS and transcription inboxes are not on Kindle.
local M = {}

M.GROUPS = { "wechat", "podcast", "newsletter", "blogs" }
M.GROUP_PREFIX = "@qiaomu:"

local HIDDEN = { ["wechat-bestblogs-2d790e38f8af54c5af77fa5fed687a7c66d34c22"] = true, levelingup = true }
local FEATURED_WECHAT = {}
for _, id in ipairs{ "wechat-qiaomu", "wechat-agentju", "wechat-cyberzen", "wechat-kazike",
        "wechat-latepost", "wechat-xinzhiyuan", "wechat-elsewhere", "wechat-zangai",
        "wechat-bestblogs-1c3e3571b1627d23ee9c64521a0b0a41d3fe2987",
        "wechat-bestblogs-9645a69180041ff935c458753174fa8bc2061295" } do
    FEATURED_WECHAT[id] = true
end
local FEATURED_XIAOYUZHOU = { "zhangxiaojun", "nexttoken", "42zhangjing", "latetalk", "bannatie" }
local ZH_PODCAST_ORDER = { "lex-zh", "allin-zh", "nopriors-zh", "cogrev-zh", "trainingdata-zh", "unsupervised-zh" }
local NEWSLETTERS = {}
for _, id in ipairs{ "james-clear", "bensbites", "levelingup", "tldrai", "importai", "nlp-elvis", "interconnects",
        "brainfood", "oneusefulthing", "whytryai", "chinai", "dankoe", "tylerfolkman",
        "superhuman_ai", "aibreakfast", "garymarcus", "dwarkesh", "experimental-history",
        "construction-physics", "ds-ai-section" } do
    NEWSLETTERS[id] = true
end

local function host(source)
    local h = type(source.siteUrl) == "string" and source.siteUrl:match("^%a[%w+.-]*://([^/:?#]+)")
    return h and h:lower():gsub("^www%.", "") or ""
end

local function enabled(source) return source.enabled ~= false end
local function endsWith(s, suffix) return s:sub(-#suffix) == suffix end

local function featuredPodcasts(sources)
    local rank = {}
    for i, id in ipairs(ZH_PODCAST_ORDER) do rank[id] = i end
    local zh = {}
    for i, source in ipairs(sources) do
        if enabled(source) and source.category == "podcast" and source.id:sub(-3) == "-zh"
                and endsWith(host(source), ".qiaomu.ai") then
            zh[#zh + 1] = { source = source, i = i }
        end
    end
    table.sort(zh, function(a, b)
        local ra, rb = rank[a.source.id] or #ZH_PODCAST_ORDER + 1, rank[b.source.id] or #ZH_PODCAST_ORDER + 1
        if ra ~= rb then return ra < rb end
        return a.i < b.i
    end)
    local result, covered, byId = {}, {}, {}
    for _, item in ipairs(zh) do result[#result + 1] = item.source; covered[item.source.id:sub(1, -4)] = true end
    for _, source in ipairs(sources) do
        if enabled(source) and source.category == "podcast" and host(source) == "xiaoyuzhoufm.com" then byId[source.id] = source end
    end
    for _, id in ipairs(FEATURED_XIAOYUZHOU) do
        if byId[id] and not covered[id] then result[#result + 1] = byId[id] end
    end
    return result
end

--- Which Qiaomu group a source belongs to (plugin: qiaomuChannelDivider).
function M.group(source)
    local h = host(source)
    if h == "mp.weixin.qq.com" or source.id:sub(1, 7) == "wechat-" then return "wechat" end
    if source.category == "podcast" or h == "xiaoyuzhoufm.com" then return "podcast" end
    if NEWSLETTERS[source.id] or endsWith(h, ".substack.com") or endsWith(h, ".beehiiv.com")
            or h:sub(1, 11) == "newsletter." or (source.name or ""):lower():find("newsletter", 1, true) then
        return "newsletter"
    end
    return "blogs"
end

--- Sources shown as individual Qiaomu channels (plugin: readerChannelSources).
function M.channels(sources)
    local podcasts = {}
    for _, source in ipairs(featuredPodcasts(sources)) do podcasts[source.id] = true end
    local result = {}
    for _, source in ipairs(sources) do
        if enabled(source) and not HIDDEN[source.id] and source.category ~= "community"
                and (source.id:sub(1, 7) ~= "wechat-" or FEATURED_WECHAT[source.id])
                and (source.category ~= "podcast" or podcasts[source.id]) then
            result[#result + 1] = source
        end
    end
    return result
end

function M.community(sources)
    local result = {}
    for _, source in ipairs(sources) do
        if enabled(source) and source.category == "community" then result[#result + 1] = source end
    end
    return result
end

--- Channel sources of one group, in catalog order.
function M.groupSources(sources, group)
    local result = {}
    for _, source in ipairs(M.channels(sources)) do
        if M.group(source) == group then result[#result + 1] = source end
    end
    return result
end

function M.isGroup(channel) return type(channel) == "string" and channel:sub(1, #M.GROUP_PREFIX) == M.GROUP_PREFIX end

--- Returns a predicate selecting the entries of `channel` (nil = all picks).
function M.filter(sources, channel)
    if not channel then return function() return true end end
    if M.isGroup(channel) then
        local ids = {}
        for _, source in ipairs(M.groupSources(sources, channel:sub(#M.GROUP_PREFIX + 1))) do ids[source.id] = true end
        return function(entry) return ids[entry.sourceId] == true end
    end
    return function(entry) return entry.sourceId == channel end
end

return M
