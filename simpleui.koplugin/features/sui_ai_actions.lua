-- AI translation and word lookup inside KOReader's reader: replaces the
-- highlight dialog's Translate button (Google is unreachable here) once AI is
-- set up, and adds "AI meaning" to the dictionary popup.
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local JSON = require("json")
local Config = require("features/sui_ai_config")
local Lookup = require("features/sui_ai_lookup")
local _ = require("infra/sui_i18n").translate
local M = {}

local function notice(text)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text })
end

local function bookTitle(ui)
    local props = ui and ui.doc_props
    return props and (props.display_title or props.title) or ""
end

--- Runs one chat request in a cancellable subprocess with a loading card.
--- Logs kind, model, duration and outcome only (never text or key).
function M.ask(title, messages, model, done, kind, on_cancel)
    local cfg = Config.load()
    local logger = require("logger")
    local Card = require("screens/sui_ai_card")
    require("ui/network/manager"):runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local loading = Card.loading(title, on_cancel)
            local started = os.time()
            local completed, payload = Trapper:dismissableRunInSubprocess(function()
                local ok, answer, err = pcall(require("features/sui_ai_client").chat, cfg, messages,
                    { model = model, thinking = kind == "chat" })
                return JSON.encode(ok and { answer = answer, error = err } or { error = tostring(answer) })
            end, loading, true)
            loading.dismiss_callback = nil
            if not completed then -- cancelled by tapping outside
                logger.info("simpleui ai:", kind or "request", model, "cancelled")
                return
            end
            loading:finish()
            local decoded, response = pcall(JSON.decode, payload or "")
            local answer = decoded and type(response) == "table" and response.answer
            if type(answer) ~= "string" or answer == "" then
                local err = decoded and type(response) == "table" and response.error
                logger.info("simpleui ai:", kind or "request", model, "failed", os.time() - started, "s")
                notice(_("AI request failed.") .. "\n" .. tostring(err or ""))
                if on_cancel then on_cancel() end
                return
            end
            logger.info("simpleui ai:", kind or "request", model, "ok", os.time() - started, "s", #answer, "bytes")
            done(answer)
        end)
    end)
end

local function copyButton(text)
    local Device = require("device")
    if not Device:hasClipboard() then return nil end
    return { text = _("Copy"), callback = function() Device.input.setClipboardText(text) end }
end

--- Model answers may carry Markdown emphasis; the card shows plain text.
function M.plain(text)
    text = tostring(text or ""):gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1")
    text = text:gsub("%*([^%*\n]+)%*", "%1"):gsub("\n#+%s*", "\n"):gsub("^#+%s*", ""):gsub("\n>%s?", "\n")
    return text
end

-- Share of Han characters, to name the language a translation actually went to.
local function hanShare(text)
    local total, han = 0, 0
    for ch in tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if ch:match("^%a$") then total = total + 1
        elseif #ch == 3 then
            total = total + 1
            local b1, b2 = ch:byte(1, 2)
            local cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64
            if cp >= 0x3400 and cp < 0xA000 then han = han + 1 end
        end
    end
    return total > 0 and han / total or 0
end

function M.translatedInto(text, target)
    local zh = target == "zh-CN" or target == "zh-TW"
    if zh and hanShare(text) > 0.6 then return Lookup.fallbackTarget(target) end
    return target
end

--- Result card. `ctx`: highlight (can save a note), word (can go to the vocabulary builder),
--- ui, clear (drop the selection when the card closes without saving).
local function showResult(title, subtitle, body, note_text, ctx)
    local Card = require("screens/sui_ai_card")
    local card
    local saved = false
    local row = {}
    local copy = copyButton(note_text)
    if copy then row[#row + 1] = copy end
    if ctx.highlight and ctx.highlight.selected_text then
        row[#row + 1] = { text = _("Save as note"), callback = function()
            saved = true
            card:finish()
            ctx.highlight:addNote(note_text)
        end }
    end
    if ctx.word and ctx.ui then
        row[#row + 1] = { text = _("Add to vocabulary"), callback = function()
            ctx.ui:handleEvent(Event:new("WordLookedUp", ctx.word, bookTitle(ctx.ui), true))
            require("ui/widget/notification"):notify(_("Added to vocabulary builder."))
        end }
    end
    row[#row + 1] = { text = _("Close"), callback = function() card:dismiss() end }
    card = Card.show{ title = title, subtitle = subtitle, text = body, buttons = { row },
        on_close = function()
            if ctx.clear and not saved and ctx.highlight then pcall(ctx.highlight.clear, ctx.highlight) end
        end }
end

local function lookup(ui, highlight, term, sentence, clear)
    local cfg = Config.load()
    local messages = Lookup.lookupMessages{ term = term, sentence = sentence, book = bookTitle(ui), target = cfg.translate_to }
    M.ask(term, messages, cfg.translate_model, function(answer)
        local card = Lookup.parseLookup(answer, JSON)
        local lines = {}
        if card.meaning ~= "" then lines[#lines + 1] = card.meaning end
        if #card.senses > 0 then
            lines[#lines + 1] = ""
            for _, s in ipairs(card.senses) do lines[#lines + 1] = (s.pos ~= "" and (s.pos .. "  ") or "") .. s.def end
        end
        if card.note ~= "" then lines[#lines + 1] = ""; lines[#lines + 1] = card.note end
        if card.example ~= "" then
            lines[#lines + 1] = ""
            lines[#lines + 1] = card.example
            if card.exampleTranslation ~= "" then lines[#lines + 1] = card.exampleTranslation end
        end
        showResult(card.lemma ~= "" and card.lemma or term, card.phonetic, M.plain(table.concat(lines, "\n")),
            Lookup.cardText(term, card), { highlight = highlight, word = term, ui = ui, clear = clear })
    end, "lookup", clear and function() pcall(highlight.clear, highlight) end)
end

local function translate(ui, highlight, text, context, clear)
    local cfg = Config.load()
    local messages = Lookup.translateMessages{ text = text, context = context, book = bookTitle(ui), target = cfg.translate_to }
    M.ask(_("Translation"), messages, cfg.translate_model, function(answer)
        local clean = M.plain(answer)
        showResult(_("Translation"), "→ " .. Lookup.languageName(M.translatedInto(text, cfg.translate_to)), clean, clean,
            { highlight = highlight, ui = ui, clear = clear })
    end, "translate", clear and function() pcall(highlight.clear, highlight) end)
end

local function context(highlight, text)
    local ok, prev, next_ = pcall(highlight.getSelectedWordContext, highlight, 20)
    if not ok then return "" end
    return (prev or "") .. text .. (next_ or "")
end

--- From the highlight dialog: a term gets a lookup card, longer text a translation.
function M.fromHighlight(highlight)
    local selected = highlight.selected_text
    local text = selected and selected.text or ""
    if text == "" then return end
    -- Close the button dialog but keep the selection for "Save as note";
    -- the selection is cleared when the result card closes unsaved.
    pcall(highlight.onClose, highlight, true)
    if Lookup.isTerm(text) then
        return lookup(highlight.ui, highlight, (Lookup.trimTerm(text)), context(highlight, text), true)
    end
    -- Like KOReader's Translate: extend to whole sentence segments.
    local ui = highlight.ui
    if ui.rolling and selected.pos0 and selected.pos1 then
        local ok, extended = pcall(ui.document.extendXPointersToSentenceSegment, ui.document, selected.pos0, selected.pos1)
        if ok and extended and extended.text and extended.text ~= "" then text = extended.text end
    end
    translate(ui, highlight, text, nil, true)
end

--- From the dictionary popup.
function M.fromDictionary(popup)
    local word = popup.lookupword or popup.word
    if type(word) ~= "string" or word == "" then return end
    local ui = popup.ui
    local highlight = ui and ui.highlight
    local sentence = highlight and highlight.selected_text and context(highlight, highlight.selected_text.text or word) or ""
    lookup(ui, highlight, word, sentence)
end

--- KOReader gesture action for asking about the current page.
function M.registerActions()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok then return end
    Dispatcher:registerAction("qiaomu_ai_page", { category = "none", event = "QiaomuAiPage",
        title = _("Qiaomu AI: ask about this page"), reader = true })
end

--- Attaches the buttons to one ReaderUI instance (called from plugin init).
function M.attach(ui)
    local highlight = ui and ui.highlight
    if highlight and highlight._highlight_buttons and not highlight._qiaomu_ai then
        highlight._qiaomu_ai = true
        local native = highlight._highlight_buttons["07_translate"]
        highlight:addToHighlightDialog("07_translate", function(this, index)
            if not Config.ready() then return native and native(this, index) end
            return { text = _("AI translate"), callback = function() M.fromHighlight(this) end }
        end)
        -- One-tap AI actions on the selection (opens setup first when needed).
        highlight:addToHighlightDialog("08_qiaomu_ask", function(this)
            return { text = _("Ask AI"), callback = function() require("screens/sui_ai_ask").fromHighlight(this) end }
        end)
    end
    -- Gesture action "Qiaomu AI: ask about this page" (registered in registerActions).
    local ReaderUI = require("apps/reader/readerui")
    if not ReaderUI.onQiaomuAiPage then
        function ReaderUI:onQiaomuAiPage()
            if self.document then require("screens/sui_ai_ask").fromPage(self) end
            return true
        end
    end
    local dictionary = ui and ui.dictionary
    if dictionary and dictionary.addToDictButtons and not dictionary._qiaomu_ai then
        dictionary._qiaomu_ai = true
        dictionary:addToDictButtons{
            id = "qiaomu_ai_meaning", conditional = true, text = _("AI meaning"),
            show_func = function() return Config.ready() end,
            callback = function(popup) M.fromDictionary(popup) end,
        }
    end
end

return M
