-- talk.lua — Simple UI
-- The conversation of the Critter module: the critter opens with a line and the
-- user picks one of a few answers, or asks for another phrase. Choosing an
-- answer moves the critter's mood (mood.lua) and hands its reply back to the
-- module, which shows it in the bubble. The window that shows the exchange is
-- talk_window.lua.

local Dialog     = require("modules/critter/dialog")
local Mood       = require("modules/critter/mood")
local TalkWindow = require("modules/critter/talk_window")
local _          = require("infra/sui_i18n").translate

local Talk = {}

-- Mood gain of opening a suggested book.
local OPEN_GAIN = 3

-- The mood on today's date: a new day starts from that day's cap.
local function currentState()
    return Mood.rollDay(Mood.read(), os.date("%Y-%m-%d"))
end

local function applyDelta(delta)
    Mood.write(Mood.applyChoice(currentState(), delta))
end

local function currentTier()
    return Mood.tier(currentState().score)
end

-- Arguments the window takes from the conversation's opts, plus `extra`.
local function windowOpts(opts, extra)
    local window = {
        anchor       = opts.anchor,
        side         = opts.side,
        critter_rect = opts.critter_rect,
        style        = opts.style,
        unit         = opts.unit,
        scale        = opts.scale,
        faces        = opts.faces,
    }
    for k, v in pairs(extra) do window[k] = v end
    return window
end

-- Second step of a book suggestion: offers an unopened book of the library, or
-- answers with the reply of `option` when there is none. `skip` is the book that
-- was offered before.
local function suggest(opts, option, skip)
    local book = opts.library.next(skip and skip.fp)
    if not book then
        opts.on_reply(option.reply(currentTier()))
        return
    end
    local lines = Dialog.suggestion(book, opts.facts, currentTier())
    TalkWindow.open(windowOpts(opts, {
        opener  = lines.opener,
        options = {
            { text = lines.open_text, on_pick = function()
                if opts.library.open(book.fp) then
                    applyDelta(OPEN_GAIN)
                else
                    suggest(opts, option, book)
                end
            end },
            { text = lines.later_text, on_pick = function()
                opts.on_reply(lines.later_reply)
            end },
        },
        other = { text = lines.another_text, on_pick = function() suggest(opts, option, book) end },
    }))
end

--- Opens the conversation and returns its window.
--   opts.facts         facts about the moment (see phrases.lua)
--   opts.on_reply      function(reply): the critter answered; reply = { text, sub, mood }
--   opts.on_other      function(): the user asked for another phrase
--   opts.anchor        Geom of the module's bubble, which the conversation takes over
--   opts.side          "left" | "right": where the critter stands, nil without one
--   opts.critter_rect  Geom of the critter
--   opts.style         "pixel" | "smooth": style of the bubble
--   opts.unit          pixel size of the pixel-art drawing, in px
--   opts.scale         size factor of the module
--   opts.faces         { message, message_bold, answer }: the faces of the
--                      module's text, which the conversation follows
--   opts.on_accept     function(offer): the user accepted the challenge on offer
--                      (opts.facts.challenge.offer)
--   opts.library       { next = function(skip_fp) -> { fp, title, authors } | nil,
--                        open = function(fp) -> boolean }: where a book suggestion
--                      finds an unopened book and opens it (false: the file is
--                      gone); without it the suggestion answers like any option
function Talk.open(opts)
    local exchange = Dialog.pick(opts.facts, Mood.tier(Mood.read().score))

    local options = {}
    for _i, option in ipairs(exchange and exchange.options or {}) do
        options[#options + 1] = {
            text    = option.text,
            on_pick = function()
                applyDelta(option.delta)
                local challenge = opts.facts and opts.facts.challenge
                if option.accept and opts.on_accept and challenge and challenge.offer then
                    opts.on_accept(challenge.offer)
                end
                if option.recommend and opts.library then
                    suggest(opts, option, nil)
                else
                    opts.on_reply(option.reply(currentTier()))
                end
            end,
        }
    end

    return TalkWindow.open(windowOpts(opts, {
        opener  = exchange and exchange.opener or nil,
        options = options,
        other   = { text = _("Say something else…"), on_pick = opts.on_other },
    }))
end

return Talk
