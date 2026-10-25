-- Ask AI by tapping: built-in actions for a selection, the current page or
-- a whole article; answers open full screen with one-tap follow-ups.
local UIManager = require("ui/uimanager")
local Config = require("features/sui_ai_config")
local Chat = require("features/sui_ai_chat")
local _ = require("infra/sui_i18n").translate
local M = {}

local KIND_LABEL = { selection = "Selected text", page = "This page", article = "This article" }

local function notice(text, timeout)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = timeout })
end

local function preview(text)
    local list = {}
    for ch in tostring(text or ""):gsub("%s+", " "):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        list[#list + 1] = ch
        if #list >= 90 then list[#list + 1] = "…"; break end
    end
    return table.concat(list)
end

--- `state`: source {kind, title, text}, highlight (selection only), messages, saved.
local function release(state)
    if state.highlight and not state.saved then pcall(state.highlight.clear, state.highlight) end
end

local run

--- Full-screen answer with follow-ups, more actions, typing (fallback) and save.
local function answerPage(state, question, answer)
    local viewer
    local function close() if viewer then UIManager:close(viewer) end end
    local function ask(item) return function() close(); run(state, item) end end
    local follow = {}
    for _, item in ipairs(Config.FOLLOW_UPS) do follow[#follow + 1] = { text = item.name, callback = ask(item) } end
    local buttons = { follow, {
        { text = _("More actions…"), callback = function() close(); M.actions(state) end },
        { text = _("Type a question"), callback = function() close(); M.type(state) end },
        { text = _("Save"), callback = function()
            state.saved = true
            if state.highlight and state.highlight.selected_text then
                close()
                state.highlight:addNote("【" .. question .. "】\n" .. answer)
            else
                local ok, path = pcall(Chat.saveNote, state.source.title, state.source, question, answer)
                notice(ok and (_("Saved to") .. "\n" .. path) or (_("Could not save.") .. "\n" .. tostring(path)), ok and 3 or nil)
            end
        end },
    } }
    viewer = require("ui/widget/textviewer"):new{
        title = question .. " · " .. _(KIND_LABEL[state.source.kind] or "AI"),
        title_multilines = false, title_shrink_font_to_fit = true,
        text = answer, text_format = "md", text_type = "general",
        width = require("device").screen:getWidth(), height = require("device").screen:getHeight(),
        buttons_table = buttons,
        close_callback = function() release(state) end,
    }
    UIManager:show(viewer)
end

--- Sends `item` (or continues the conversation with it) and shows the answer.
run = function(state, item)
    local cfg = Config.load()
    local messages = state.messages and Chat.follow(state.messages, state.last_answer, item.prompt)
        or Chat.start(state.source, item, cfg.answer_lang)
    require("features/sui_ai_actions").ask(item.name, messages, cfg.chat_model, function(answer)
        state.messages, state.last_answer = messages, answer
        answerPage(state, item.name, answer)
    end, "chat", function() release(state) end)
end

--- Typing fallback (KOReader's keyboard).
function M.type(state)
    local dialog
    dialog = require("ui/widget/inputdialog"):new{
        title = _("Ask AI"), input = "", input_hint = _("Your question"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog); release(state) end },
            { text = _("Ask"), is_enter_default = true, callback = function()
                local q = dialog:getInputText()
                if not q or not q:match("%S") then return end
                UIManager:close(dialog)
                run(state, { name = q, prompt = q })
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- The action card: one tap per common reading task.
function M.actions(state)
    local Card = require("screens/sui_ai_card")
    local card
    local continuing = state.messages ~= nil
    local list = Config.actions(state.source.kind == "selection" and Config.SELECTION_ACTIONS or Config.WHOLE_ACTIONS)
    local cells = {}
    if state.source.kind == "selection" and not continuing and state.highlight then
        cells[#cells + 1] = { text = _("Translate"), callback = function()
            card:finish()
            require("features/sui_ai_actions").fromHighlight(state.highlight)
        end }
    end
    for _, item in ipairs(list) do
        cells[#cells + 1] = { text = item.name, callback = function() card:finish(); run(state, item) end }
    end
    local rows = {}
    for i = 1, #cells, 2 do rows[#rows + 1] = { cells[i], cells[i + 1] } end
    rows[#rows + 1] = {
        { text = _("Type a question"), callback = function() card:finish(); M.type(state) end },
        { text = _("Close"), callback = function() card:dismiss() end },
    }
    card = Card.show{
        title = _("Ask AI"), subtitle = _(KIND_LABEL[state.source.kind] or ""),
        text = continuing and _("Continue this conversation.") or preview(state.source.text),
        buttons = rows, on_close = function() release(state) end,
    }
end

local function start(source, highlight)
    if not source.text or not source.text:match("%S") then
        return notice(_("Nothing to ask about here."))
    end
    require("screens/sui_ai_setup").ensure(function() M.actions{ source = source, highlight = highlight } end)
end

local function title(ui)
    local props = ui and ui.doc_props
    return props and (props.display_title or props.title) or ""
end

--- From the highlight dialog: the selected text.
function M.fromHighlight(highlight)
    local text = highlight.selected_text and highlight.selected_text.text or ""
    pcall(highlight.onClose, highlight, true) -- keep the selection for "Save"
    start({ kind = "selection", title = title(highlight.ui), text = text }, highlight)
end

--- The text on the current screen of a book.
function M.fromPage(ui)
    local Screen = require("device").screen
    local ok, result = pcall(function()
        return ui.document:getTextFromPositions({ x = 0, y = 0 }, { x = Screen:getWidth(), y = Screen:getHeight() }, true)
    end)
    local text = ok and type(result) == "table" and result.text or ""
    start({ kind = "page", title = title(ui), text = text })
end

--- A whole Qiaomu picks article (from the news cache).
function M.fromArticle(entry, article)
    local body = article and article.body or ""
    start({ kind = "article", title = entry and (entry.titleZh ~= "" and entry.titleZh or entry.title) or "",
        text = Chat.plain(body) })
end

return M
