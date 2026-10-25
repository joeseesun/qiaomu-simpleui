-- Kindle side of Qiaomu AI settings: status, phone setup by QR code,
-- connection test and an on-device key fallback.
local UIManager = require("ui/uimanager")
local Config = require("features/sui_ai_config")
local _ = require("infra/sui_i18n").translate
local M = {}

local function notice(text, timeout)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = timeout })
end

local function providerLabel(cfg)
    local p = Config.provider(cfg.provider)
    if not p then return "" end
    return p.custom and _("Custom service") or p.label
end

function M.summary(cfg)
    cfg = cfg or Config.load()
    if not Config.ready(cfg) then return _("Not set up yet. Set it up from your phone: no typing on the Kindle.") end
    local lines = { providerLabel(cfg) .. " · " .. cfg.chat_model }
    if cfg.translate_model ~= cfg.chat_model then lines[#lines + 1] = _("Translation") .. "：" .. cfg.translate_model end
    if Config.keyHint(cfg) ~= "" then lines[#lines + 1] = _("API key") .. " " .. Config.keyHint(cfg) end
    return table.concat(lines, "\n")
end

--- Full-screen QR code page; closes itself when the phone saves or the page times out.
function M.phone(after_save)
    require("ui/network/manager"):runWhenOnline(function() M._phone(after_save) end)
end

function M._phone(after_save)
    local Web = require("features/sui_ai_web")
    local page
    local url, err = Web.start(function(kind)
        if kind == "saved" then
            UIManager:scheduleIn(1, function()
                Web.stop()
                notice(_("Saved.") .. "\n" .. M.summary(), 4)
                if after_save then after_save() end
            end)
        elseif kind == "test" then
            UIManager:setDirty(page, "ui")
        elseif kind == "stopped" and page then
            local closing = page
            page = nil
            UIManager:close(closing)
        end
    end)
    if not url then
        notice(_("Could not start the phone setup page.") .. "\n" .. _(tostring(err)))
        return
    end
    local Screen = require("device").screen
    local Geom = require("ui/geometry")
    local Font = require("ui/font")
    local Size = require("ui/size")
    local Blitbuffer = require("ffi/blitbuffer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextWidget = require("ui/widget/textwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local QRWidget = require("ui/widget/qrwidget")
    local Button = require("ui/widget/button")
    local w, h = Screen:getWidth(), Screen:getHeight()
    local inner = w - 2 * Size.padding.large * 3
    local qr_size = math.floor(math.min(w, h) * 0.62)
    page = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = w, h = h }, covers_fullscreen = true }
    local function cancel() Web.stop() end
    local content = VerticalGroup:new{ align = "center",
        TextWidget:new{ text = _("Qiaomu AI · Set up from your phone"), face = Font:getFace("tfont", 24), bold = true },
        VerticalSpan:new{ width = Size.padding.large * 2 },
        QRWidget:new{ text = url, width = qr_size, height = qr_size },
        VerticalSpan:new{ width = Size.padding.large * 2 },
        TextBoxWidget:new{ width = inner, alignment = "center", face = Font:getFace("cfont", 18),
            text = _("Scan with a phone on the same Wi-Fi, then fill in the service, API key and models.") },
        VerticalSpan:new{ width = Size.padding.default },
        TextWidget:new{ text = url:gsub("%?t=.*$", ""), face = Font:getFace("infont", 16), fgcolor = Blitbuffer.COLOR_DARK_GRAY },
        VerticalSpan:new{ width = Size.padding.default },
        TextBoxWidget:new{ width = inner, alignment = "center", face = Font:getFace("cfont", 15), fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            text = _("Available for 5 minutes and closes after saving. Use only on a Wi-Fi network you trust.") },
        VerticalSpan:new{ width = Size.padding.large * 2 },
        Button:new{ text = _("Cancel"), width = math.floor(w * 0.5), callback = cancel, show_parent = page },
    }
    page[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, content } }
    function page:onShow() UIManager:setDirty(self, "full") end
    function page:onCloseWidget()
        UIManager:setDirty(nil, "full")
        if Web.running() then Web.stop() end
    end
    UIManager:show(page)
end

function M.test()
    local cfg = Config.load()
    if not Config.ready(cfg) then return M.show() end
    local Trapper = require("ui/trapper")
    local JSON = require("json")
    require("ui/network/manager"):runWhenOnline(function()
        Trapper:wrap(function()
            local done, payload = Trapper:dismissableRunInSubprocess(function()
                local ok, result, err = pcall(require("features/sui_ai_client").test, cfg)
                return JSON.encode(ok and { result = result, error = err } or { error = tostring(result) })
            end, _("Testing connection… Tap to cancel."), true)
            if not done then return end
            local decoded, response = pcall(JSON.decode, payload or "")
            if decoded and type(response) == "table" and type(response.result) == "table" then
                notice(string.format(_("Connected in about %d s."), response.result.seconds or 0), 4)
            else
                notice(_("Connection failed.") .. "\n" .. tostring(decoded and type(response) == "table" and response.error or ""))
            end
        end)
    end)
end

--- Fallback: type the key on the Kindle keyboard.
function M.typeKey()
    local dialog
    dialog = require("ui/widget/inputdialog"):new{
        title = _("API key") .. " · " .. providerLabel(Config.load()),
        input = "", input_hint = "sk-…", text_type = "password",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local cfg = Config.load()
                local merged, err = Config.merge(cfg, { provider = cfg.provider, base = cfg.base, key = dialog:getInputText(),
                    chat_model = cfg.chat_model, translate_model = cfg.translate_model, thinking = cfg.thinking,
                    answer_lang = cfg.answer_lang, translate_to = cfg.translate_to })
                if not merged then notice(tostring(err)); return end
                Config.save(merged)
                UIManager:close(dialog)
                notice(_("Saved.") .. "\n" .. M.summary(), 3)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function M.show()
    local cfg = Config.load()
    local dialog
    local function action(fn) return function() UIManager:close(dialog); fn() end end
    local buttons = {}
    local reader = require("apps/reader/readerui").instance
    if reader and reader.document then
        buttons[#buttons + 1] = {{ text = _("Ask AI about this page"), callback = action(function()
            require("screens/sui_ai_ask").fromPage(reader)
        end) }}
    end
    buttons[#buttons + 1] = {{ text = _("Set up from your phone"), callback = action(function() M.phone() end) }}
    if Config.ready(cfg) then
        buttons[#buttons + 1] = {{ text = _("Test connection"), callback = action(M.test) }}
    end
    buttons[#buttons + 1] = {{ text = _("Type the API key on Kindle"), callback = action(M.typeKey) }}
    if Config.ready(cfg) or Config.keyHint(cfg) ~= "" then
        buttons[#buttons + 1] = {{ text = _("Clear AI settings"), callback = action(function()
            Config.clear(); notice(_("AI settings cleared."), 2)
        end) }}
    end
    buttons[#buttons + 1] = {{ text = _("Close"), callback = action(function() end) }}
    dialog = require("ui/widget/buttondialog"):new{ title = _("Qiaomu AI") .. "\n\n" .. M.summary(cfg), buttons = buttons }
    UIManager:show(dialog)
end

--- Runs `fn` when AI is ready, otherwise opens setup first (Qiaomu Reader
--- mobile behaviour) and continues after the phone saves.
function M.ensure(fn)
    if Config.ready() then return fn() end
    M.phone(function() if Config.ready() then fn() end end)
end

return M
