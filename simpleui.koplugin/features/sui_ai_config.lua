-- Qiaomu AI settings: one OpenAI-compatible service, its key and models.
-- Stored outside the USB volume (/var/local on Kindle), readable by root only.
local JSON = require("json")
local M = {}

-- Presets follow Qiaomu Reader 4.9 (src/ai-providers.js); all were reachable
-- from the reference Kindle on 2026-10-25 except where noted.
M.PROVIDERS = {
    { id = "deepseek", label = "DeepSeek", base = "https://api.deepseek.com", model = "deepseek-flash",
      models = { "deepseek-flash", "deepseek-v4-pro" }, key_url = "https://platform.deepseek.com/api_keys", thinking = true },
    { id = "kimi", label = "Kimi（Moonshot）", base = "https://api.moonshot.cn/v1", model = "kimi-k2.6",
      models = { "kimi-k2.6" }, key_url = "https://platform.moonshot.cn/console/api-keys" },
    { id = "qwen", label = "通义千问", base = "https://dashscope.aliyuncs.com/compatible-mode/v1", model = "qwen-plus",
      models = { "qwen-plus", "qwen-max", "qwen-turbo" }, key_url = "https://bailian.console.aliyun.com/?tab=model#/api-key" },
    { id = "zhipu", label = "智谱 GLM", base = "https://open.bigmodel.cn/api/paas/v4", model = "glm-5.3",
      models = { "glm-5.3" }, key_url = "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys" },
    { id = "siliconflow", label = "硅基流动", base = "https://api.siliconflow.cn/v1", model = "Qwen/Qwen3-8B",
      models = { "Qwen/Qwen3-8B", "deepseek-ai/DeepSeek-V3" }, key_url = "https://cloud.siliconflow.cn/account/ak" },
    { id = "doubao", label = "豆包（火山方舟）", base = "https://ark.cn-beijing.volces.com/api/v3", model = "",
      models = {}, key_url = "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey", model_hint = "endpoint" },
    { id = "minimax", label = "MiniMax", base = "https://api.minimax.cn/v1", model = "MiniMax-M3",
      models = { "MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.5" }, key_url = "https://platform.minimaxi.com/user-center/basic-information/interface-key" },
    { id = "openrouter", label = "OpenRouter", base = "https://openrouter.ai/api/v1", model = "deepseek/deepseek-chat",
      models = { "deepseek/deepseek-chat" }, key_url = "https://openrouter.ai/settings/keys", slow = true },
    { id = "custom", label = "custom", base = "", model = "", models = {}, custom = true },
}

-- Built-in one-tap actions: on Kindle tapping beats typing. Wording follows
-- Qiaomu Reader's quick prompts (src/main.js DEFAULT_AI_QUICK_PROMPTS).
M.SELECTION_ACTIONS = {
    { name = "解释", prompt = "请用简单易懂的语言解释这段内容" },
    { name = "总结要点", prompt = "请提炼这段内容的核心要点，用简洁的条目列出" },
    { name = "举个例子", prompt = "请用一个具体的生活或现实案例来说明这段内容" },
    { name = "补充背景", prompt = "请补充理解这段内容所需的背景知识：相关的人物、事件、概念或术语" },
    { name = "换个角度看", prompt = "请从不同立场或视角出发，对这段内容提出补充、质疑或反驳" },
    { name = "出题考考我", prompt = "请根据这段内容出 2–3 道测试题，帮我检验是否真正理解" },
}
-- For a whole article (Qiaomu picks) or the current page of a book.
M.WHOLE_ACTIONS = {
    { name = "总结全文", prompt = "请用 3–5 句话总结这篇内容的核心观点" },
    { name = "核心要点", prompt = "请提炼这篇内容的核心要点，用简洁的条目列出，每条一句话" },
    { name = "通俗讲讲", prompt = "请用通俗易懂的语言，向没有背景知识的人讲清楚这篇内容在说什么" },
    { name = "对我有什么用", prompt = "请结合实际生活或工作场景，说明这篇内容对我有什么具体价值和启发" },
    { name = "值得追问", prompt = "读完这篇内容，有哪些值得进一步追问或核实的问题？列出 3 个，并说明为什么" },
    { name = "出题考考我", prompt = "请根据这篇内容出 3 道测试题，帮我检验是否真正读懂" },
}
-- Shown under an answer to continue without typing.
M.FOLLOW_UPS = {
    { name = "说得更简单", prompt = "请用更简单的话再解释一遍，像讲给中学生听" },
    { name = "举个例子", prompt = "请举一个具体的例子说明你刚才的回答" },
    { name = "继续深入", prompt = "请在刚才的基础上更深入地展开" },
}
-- Phone-configured extra actions are appended after the built-in ones.
M.QUICK_PROMPTS = {}

--- Built-in actions followed by the user's extra ones (deduplicated by name).
function M.actions(builtin, cfg)
    local list, seen = {}, {}
    for _, a in ipairs(builtin) do list[#list + 1] = a; seen[a.name] = true end
    for _, a in ipairs((cfg or M.load()).quick_prompts or {}) do
        if type(a) == "table" and type(a.name) == "string" and not seen[a.name] then
            list[#list + 1] = a; seen[a.name] = true
        end
    end
    return list
end

M.LANGUAGES = { "zh-CN", "zh-TW", "en", "ja", "ko" }
M.DIR = "/var/local/qiaomu"

function M.path() return M.DIR .. "/ai.json" end

function M.provider(id)
    for _, p in ipairs(M.PROVIDERS) do if p.id == id then return p end end
end

function M.defaults()
    local p = M.PROVIDERS[1]
    return { version = 1, provider = p.id, base = p.base, chat_model = p.model, translate_model = p.model,
        thinking = false, key = "", answer_lang = "zh-CN", translate_to = "zh-CN", quick_prompts = M.QUICK_PROMPTS }
end

local cached
function M.load()
    if cached then return cached end
    local cfg = M.defaults()
    local f = io.open(M.path(), "rb")
    if f then
        local ok, data = pcall(JSON.decode, f:read("*a") or "")
        f:close()
        if ok and type(data) == "table" then
            for k, v in pairs(data) do cfg[k] = v end
        end
    end
    cached = cfg
    return cfg
end

local function shell(path) return "'" .. path:gsub("'", "'\\''") .. "'" end

function M.save(cfg)
    os.execute("mkdir -p " .. shell(M.DIR) .. " && chmod 700 " .. shell(M.DIR))
    local tmp = M.path() .. ".tmp"
    local f = assert(io.open(tmp, "wb"))
    -- Restrict before the key is written.
    os.execute("chmod 600 " .. shell(tmp))
    f:write(JSON.encode(cfg)); f:close()
    assert(os.rename(tmp, M.path()))
    cached = cfg
end

function M.clear()
    os.remove(M.path())
    cached = nil
end

function M.reset() cached = nil end

--- True when requests can be sent: a service, endpoint, model and key.
function M.ready(cfg)
    cfg = cfg or M.load()
    local p = M.provider(cfg.provider)
    return p ~= nil and type(cfg.base) == "string" and cfg.base ~= "" and type(cfg.chat_model) == "string"
        and cfg.chat_model ~= "" and (p.custom or (type(cfg.key) == "string" and cfg.key ~= ""))
end

function M.keyHint(cfg)
    local key = (cfg or M.load()).key
    if type(key) ~= "string" or key == "" then return "" end
    return "••••" .. key:sub(-4)
end

--- Settings safe to show in the phone page: never the key itself.
function M.public(cfg)
    cfg = cfg or M.load()
    local out = {}
    for k, v in pairs(cfg) do if k ~= "key" then out[k] = v end end
    out.key_hint = M.keyHint(cfg)
    return out
end

local function str(v, limit) return type(v) == "string" and #v <= limit and v or nil end

--- Validates settings posted from the phone page and merges them into a
--- copy of `cfg`. An empty key keeps the stored one. Returns cfg or nil, error.
function M.merge(cfg, input)
    if type(input) ~= "table" then return nil, "Invalid settings" end
    local out = {}
    for k, v in pairs(cfg) do out[k] = v end
    local p = M.provider(input.provider)
    if not p then return nil, "Unknown service" end
    out.provider = p.id
    local base = str(input.base, 300) or p.base
    base = base:gsub("%s", ""):gsub("/+$", "")
    if p.custom then
        if not base:match("^https?://[%w%.%-]+[:%d]*[/%w%.%-_~]*$") then return nil, "Invalid service URL" end
    else
        base = p.base
    end
    out.base = base
    for _, k in ipairs{ "chat_model", "translate_model" } do
        local v = str(input[k], 200)
        if v then
            v = v:gsub("^%s+", ""):gsub("%s+$", "")
            if v ~= "" and not v:match("^[%w%._:/%-]+$") then return nil, "Invalid model name" end
            out[k] = v
        end
    end
    if out.translate_model == "" then out.translate_model = out.chat_model end
    local key = str(input.key, 400)
    if key and key ~= "" then
        key = key:gsub("%s", "")
        -- Keys go into a curl config header; allow only token characters.
        if not key:match("^[%w%-%._~+/=:]+$") then return nil, "Invalid API key" end
        out.key = key
    end
    -- Switching service drops a key that belonged to another service.
    if p.id ~= cfg.provider and not (key and key ~= "") then out.key = "" end
    out.thinking = input.thinking == true and p.thinking == true
    for _, k in ipairs{ "answer_lang", "translate_to" } do
        for _, lang in ipairs(M.LANGUAGES) do if input[k] == lang then out[k] = lang end end
    end
    if type(input.quick_prompts) == "table" then
        local prompts = {}
        for _, item in ipairs(input.quick_prompts) do
            local name, prompt = type(item) == "table" and str(item.name, 60), type(item) == "table" and str(item.prompt, 1000)
            if name and prompt and name ~= "" and prompt ~= "" and #prompts < 20 then
                prompts[#prompts + 1] = { name = name, prompt = prompt }
            end
        end
        out.quick_prompts = prompts
    end
    return out
end

return M
