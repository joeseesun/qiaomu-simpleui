-- phrases.lua — Simple UI
-- Phrase catalogue of the Critter module and the rules that pick one.
--
-- A phrase is { id, cat, mood, when(f), text(f), sub(f) }:
--   f      facts about the moment: period, weekday (os.date "*t" wday: 1 is
--          Sunday, 2 Monday ... 7 Saturday), weekday_name, month, day,
--          streak, streak_record, streak_milestone, books_year, goal,
--          today_secs, today_pages, daily_goal_secs, user_name (goal and
--          daily_goal_secs are numbers, 0 meaning none; the rest may be nil,
--          user_name being the name the user gave the critter)
--   when   whether the phrase fits `f`
--   text   main line;  sub  optional second line
--   mood   critter state shown with the phrase
-- A phrase flagged `celebrate` marks an achievement (a streak record or
-- milestone) and is dealt first while the achievement is due (see Phrases.pick).
-- Phrases are grouped in categories. A category is chosen by weight, then
-- a phrase of it is dealt from its own shuffle deck, so nothing repeats
-- before the whole category has been seen.
--
-- User phrases come from <dir>/phrases.lua, which returns a list of
--   { text = "...", sub = "...", mood = "happy", period = "morning",
--     min_streak = 3, min_books = 1 }
-- where only `text` is required, and text/sub may use {streak} {books}
-- {pages} {minutes} {goal} {weekday} {name}. A phrase whose placeholder has no
-- value right now is not offered.

local Deck = require("infra/sui_deck")
local _    = require("infra/sui_i18n").translate
local N_   = require("infra/sui_i18n").ngettext

local Phrases = {}

-- Moods of the critter: the image shown with a phrase (see assets.lua).
Phrases.MOODS = {
    "neutral", "happy", "party", "sleepy",
    "cheer", "love", "sad", "surprised", "curious", "grumpy", "shy", "playful",
}

local MOOD_SET = {}
for _i, mood in ipairs(Phrases.MOODS) do MOOD_SET[mood] = true end

-- Categories in menu order, with the weight each one has in the draw.
Phrases.CATEGORIES = {
    { id = "greeting", weight = 3, label = function() return _("Greetings") end },
    { id = "streak",   weight = 3, label = function() return _("Reading streak") end },
    { id = "books",    weight = 2, label = function() return _("Books this year") end },
    { id = "today",    weight = 2, label = function() return _("Today's reading") end },
    { id = "special",  weight = 3, label = function() return _("Milestones and goals") end },
    { id = "calendar", weight = 1, label = function() return _("Days and months") end },
    { id = "generic",  weight = 1, label = function() return _("General") end },
}

local CUSTOM_WEIGHT = 3
local DECK_KEY      = "simpleui_critter_deck_"

local PERIOD_SET = { morning = true, afternoon = true, evening = true, night = true }

-- Day period of an hour (0-23).
function Phrases.period(hour)
    if hour >= 5 and hour < 12 then return "morning" end
    if hour >= 12 and hour < 20 then return "afternoon" end
    if hour >= 20 then return "evening" end
    return "night"
end

local function atLeast(value, n) return value ~= nil and value >= n end

local function hasName(f) return f.user_name ~= nil end

local function daysStrong(f)
    return string.format(N_("%d day strong!", "%d days strong!", f.streak), f.streak)
end

local function booksThisYear(f)
    return string.format(N_("%d book finished this year", "%d books finished this year", f.books_year), f.books_year)
end

-- Built-in phrases. Texts are built lazily so they follow the current locale.
local BUILTIN = {
    -- Greetings, by time of day.
    { id = "morning_1", cat = "greeting", mood = "happy",
      when = function(f) return f.period == "morning" end,
      text = function() return _("Good morning!") end,
      sub  = function(f) return string.format(_("Have a great %s."), f.weekday_name) end },
    { id = "morning_2", cat = "greeting", mood = "cheer",
      when = function(f) return f.period == "morning" end,
      text = function() return _("Rise and read!") end,
      sub  = function() return _("A fresh day, a fresh page.") end },
    { id = "afternoon_1", cat = "greeting", mood = "happy",
      when = function(f) return f.period == "afternoon" end,
      text = function() return _("Good afternoon!") end,
      sub  = function() return _("Time for a few pages?") end },
    { id = "afternoon_2", cat = "greeting", mood = "curious",
      when = function(f) return f.period == "afternoon" end,
      text = function() return _("Taking a break?") end,
      sub  = function() return _("A chapter pairs well with a coffee.") end },
    { id = "evening_1", cat = "greeting", mood = "happy",
      when = function(f) return f.period == "evening" end,
      text = function() return _("Good evening!") end,
      sub  = function() return _("The perfect time to unwind with a book.") end },
    { id = "evening_2", cat = "greeting", mood = "sleepy",
      when = function(f) return f.period == "evening" end,
      text = function() return _("Winding down?") end,
      sub  = function() return _("One more chapter before bed.") end },
    { id = "night_1", cat = "greeting", mood = "sleepy",
      when = function(f) return f.period == "night" end,
      text = function() return _("Good night!") end,
      sub  = function() return _("Sleep well. The book will keep.") end },
    { id = "night_2", cat = "greeting", mood = "surprised",
      when = function(f) return f.period == "night" end,
      text = function() return _("Still awake?") end,
      sub  = function() return _("Don't forget to rest.") end },

    -- Greetings that use the name the user gave the critter.
    { id = "morning_name", cat = "greeting", mood = "happy",
      when = function(f) return hasName(f) and f.period == "morning" end,
      text = function(f) return string.format(_("Good morning, %s!"), f.user_name) end,
      sub  = function() return _("What shall we read today?") end },
    { id = "afternoon_name", cat = "greeting", mood = "cheer",
      when = function(f) return hasName(f) and f.period == "afternoon" end,
      text = function(f) return string.format(_("Good afternoon, %s!"), f.user_name) end,
      sub  = function() return _("Fancy a chapter or two?") end },
    { id = "evening_name", cat = "greeting", mood = "happy",
      when = function(f) return hasName(f) and f.period == "evening" end,
      text = function(f) return string.format(_("Good evening, %s!"), f.user_name) end,
      sub  = function() return _("Settle in with a good book.") end },
    { id = "night_name", cat = "greeting", mood = "sleepy",
      when = function(f) return hasName(f) and f.period == "night" end,
      text = function(f) return string.format(_("Good night, %s!"), f.user_name) end,
      sub  = function() return _("Sweet dreams and good books.") end },

    -- Reading streak.
    { id = "days", cat = "streak", mood = "happy",
      when = function(f) return atLeast(f.streak, 2) end,
      text = daysStrong,
      sub  = function() return _("Keep it going.") end },
    { id = "roll", cat = "streak", mood = "playful",
      when = function(f) return atLeast(f.streak, 2) end,
      text = function() return _("You're on a roll!") end,
      sub  = function(f)
          return string.format(N_("%d day of reading in a row.", "%d days of reading in a row.", f.streak), f.streak)
      end },
    { id = "start", cat = "streak", mood = "cheer",
      when = function(f) return f.streak == 1 end,
      text = function() return _("Streak started!") end,
      sub  = function() return _("Read again tomorrow to keep it going.") end },
    { id = "streak_name", cat = "streak", mood = "cheer",
      when = function(f) return hasName(f) and atLeast(f.streak, 2) end,
      text = function(f) return string.format(_("Great going, %s!"), f.user_name) end,
      sub  = daysStrong },
    { id = "alive", cat = "streak", mood = "curious",
      when = function(f) return atLeast(f.streak, 1) and f.today_secs == 0 end,
      text = function() return _("Keep your streak alive!") end,
      sub  = function(f) return string.format(_("Read a little today to reach day %d."), f.streak + 1) end },

    { id = "paused", cat = "streak", mood = "sad",
      when = function(f) return f.streak == 0 end,
      text = function() return _("Your streak is on a break.") end,
      sub  = function() return _("Read a little today to start a new one.") end },

    -- Books finished this year.
    { id = "year", cat = "books", mood = "happy",
      when = function(f) return atLeast(f.books_year, 1) end,
      text = booksThisYear,
      sub  = function(f)
          if f.goal > 0 and f.books_year < f.goal then
              local left = f.goal - f.books_year
              return string.format(N_("%d book to go for your goal.", "%d books to go for your goal.", left), left)
          end
          return _("Keep turning pages.")
      end },
    { id = "first", cat = "books", mood = "curious",
      when = function(f) return f.books_year == 0 end,
      text = function() return _("A new book awaits!") end,
      sub  = function() return _("Your first one this year is waiting.") end },
    { id = "half", cat = "books", mood = "cheer",
      when = function(f)
          return f.goal > 0 and atLeast(f.books_year, 1)
              and f.books_year * 2 > f.goal and f.books_year < f.goal
      end,
      text = function() return _("More than halfway there!") end,
      sub  = function(f)
          return string.format(N_("%d of %d book.", "%d of %d books.", f.goal), f.books_year, f.goal)
      end },

    -- Today's reading.
    { id = "minutes", cat = "today", mood = "happy",
      when = function(f) return atLeast(f.today_secs, 60) end,
      text = function(f)
          local minutes = math.floor(f.today_secs / 60)
          if minutes < 90 then
              return string.format(N_("%d minute read today!", "%d minutes read today!", minutes), minutes)
          end
          return string.format(_("%.1f hours read today!"), f.today_secs / 3600)
      end,
      sub  = function() return _("Nice work.") end },
    { id = "pages", cat = "today", mood = "happy",
      when = function(f) return atLeast(f.today_pages, 1) end,
      text = function(f)
          return string.format(N_("%d page turned today!", "%d pages turned today!", f.today_pages), f.today_pages)
      end,
      sub  = function() return _("One page at a time.") end },

    -- Milestones and goals.
    { id = "record", cat = "special", mood = "cheer", celebrate = true,
      when = function(f) return f.streak_record == true end,
      text = function() return _("A new personal best!") end,
      sub  = function(f)
          return string.format(N_("%d day, your longest streak yet.", "%d days, your longest streak yet.", f.streak), f.streak)
      end },
    { id = "milestone", cat = "special", mood = "party", celebrate = true,
      when = function(f) return f.streak_milestone == true end,
      text = function(f)
          return string.format(N_("Milestone: %d day!", "Milestone: %d days!", f.streak), f.streak)
      end,
      sub  = function() return _("What a habit!") end },
    { id = "goal_year", cat = "special", mood = "party",
      when = function(f) return f.goal > 0 and atLeast(f.books_year, f.goal) end,
      text = function() return _("Annual goal reached!") end,
      sub  = booksThisYear },
    { id = "goal_day", cat = "special", mood = "cheer",
      when = function(f) return f.daily_goal_secs > 0 and atLeast(f.today_secs, f.daily_goal_secs) end,
      text = function() return _("Daily goal reached!") end,
      sub  = function() return _("Well done today.") end },
    { id = "goal_day_name", cat = "special", mood = "cheer",
      when = function(f)
          return hasName(f) and f.daily_goal_secs > 0 and atLeast(f.today_secs, f.daily_goal_secs)
      end,
      text = function(f) return string.format(_("Well done, %s!"), f.user_name) end,
      sub  = function() return _("Daily goal reached!") end },
    { id = "new_year", cat = "special", mood = "party",
      when = function(f) return f.month == 1 and f.day == 1 end,
      text = function() return _("Happy New Year!") end,
      sub  = function() return _("May your year be full of good books.") end },

    -- Days and months.
    { id = "monday", cat = "calendar", mood = "neutral",
      when = function(f) return f.weekday == 2 end,
      text = function() return _("Happy Monday!") end,
      sub  = function() return _("A new week of stories.") end },
    { id = "monday_blues", cat = "calendar", mood = "grumpy",
      when = function(f) return f.weekday == 2 end,
      text = function() return _("Mondays, right?") end,
      sub  = function() return _("A good book helps.") end },
    { id = "friday", cat = "calendar", mood = "playful",
      when = function(f) return f.weekday == 6 end,
      text = function() return _("It's Friday!") end,
      sub  = function() return _("The weekend is made for reading.") end },
    { id = "weekend", cat = "calendar", mood = "playful",
      when = function(f) return f.weekday == 1 or f.weekday == 7 end,
      text = function() return _("Happy weekend!") end,
      sub  = function() return _("Plenty of time for reading.") end },
    { id = "month", cat = "calendar", mood = "cheer",
      when = function(f) return f.day == 1 and f.month ~= 1 end,
      text = function() return _("New month, new chapters!") end,
      sub  = function() return _("Pick your next read.") end },

    -- General.
    { id = "hello", cat = "generic", mood = "happy",
      when = function() return true end,
      text = function() return _("Hello, reader!") end,
      sub  = function() return _("Ready for a good story?") end },
    { id = "adventures", cat = "generic", mood = "curious",
      when = function() return true end,
      text = function() return _("Books are tiny adventures.") end },
    { id = "page", cat = "generic", mood = "happy",
      when = function() return true end,
      text = function() return _("Page by page!") end,
      sub  = function() return _("Every page counts.") end },
    { id = "thanks", cat = "generic", mood = "shy",
      when = function() return true end,
      text = function() return _("Aww, you're here!") end,
      sub  = function() return _("That makes me happy.") end },
    { id = "missed", cat = "generic", mood = "love",
      when = function() return true end,
      text = function() return _("Missed me?") end,
      sub  = function() return _("Let's read something.") end },
    { id = "hello_name", cat = "generic", mood = "happy",
      when = hasName,
      text = function(f) return string.format(_("Hello, %s!"), f.user_name) end,
      sub  = function() return _("Ready for a good story?") end },
    { id = "missed_name", cat = "generic", mood = "love",
      when = hasName,
      text = function(f) return string.format(_("I missed you, %s!"), f.user_name) end,
      sub  = function() return _("Let's read something.") end },
}

-- ---------------------------------------------------------------------------
-- User phrases
-- ---------------------------------------------------------------------------

-- Fact each placeholder reads.
local PLACEHOLDERS = {
    streak  = function(f) return f.streak end,
    books   = function(f) return f.books_year end,
    pages   = function(f) return f.today_pages end,
    minutes = function(f) return f.today_secs and math.floor(f.today_secs / 60) end,
    goal    = function(f) return f.goal > 0 and f.goal or nil end,
    weekday = function(f) return f.weekday_name end,
    name    = function(f) return f.user_name end,
}

-- Replaces the placeholders of `text`; nil when one has no value.
local function fill(text, f)
    local missing = false
    local out = text:gsub("{(%w+)}", function(name)
        local read  = PLACEHOLDERS[name]
        local value = read and read(f)
        if value == nil then missing = true; return "" end
        return tostring(value)
    end)
    if missing then return nil end
    return out
end

-- Optional number field of a user phrase: nil when absent, false when it is
-- not a number.
local function optionalNumber(value)
    if value == nil then return nil end
    return tonumber(value) or false
end

-- Stable id of a user phrase, from its text, so the shuffle deck survives
-- edits of the rest of the file.
local function textId(raw)
    local s = raw.text .. "\0" .. (type(raw.sub) == "string" and raw.sub or "")
    local h = 5381
    for i = 1, #s do h = bit.band(h * 33 + s:byte(i), 0x7fffffff) end
    return "custom_" .. h
end

local function customPhrase(index, raw)
    if type(raw) ~= "table" or type(raw.text) ~= "string" or raw.text == "" then return nil end
    local min_streak, min_books = optionalNumber(raw.min_streak), optionalNumber(raw.min_books)
    if min_streak == false or min_books == false or (raw.period ~= nil and not PERIOD_SET[raw.period]) then
        require("logger").warn("simpleui: critter: ignoring user phrase " .. index .. ": invalid period, min_streak or min_books")
        return nil
    end
    return {
        id   = textId(raw),
        cat  = "custom",
        mood = MOOD_SET[raw.mood] and raw.mood or "neutral",
        when = function(f)
            if raw.period and raw.period ~= f.period then return false end
            if min_streak and not atLeast(f.streak, min_streak) then return false end
            if min_books and not atLeast(f.books_year, min_books) then return false end
            return fill(raw.text, f) ~= nil and (type(raw.sub) ~= "string" or fill(raw.sub, f) ~= nil)
        end,
        text = function(f) return fill(raw.text, f) end,
        sub  = type(raw.sub) == "string" and raw.sub ~= "" and function(f) return fill(raw.sub, f) end or nil,
    }
end

local _custom = {}   -- path -> { mtime, list }

-- Phrases of the user's file; an empty list when it is missing or invalid.
-- The file is read as text and run in an empty environment: it can only
-- return data. The result is kept until the file changes.
function Phrases.loadCustom(path)
    local lfs = require("libs/libkoreader-lfs")
    local mtime = lfs.attributes(path, "modification")
    if not mtime then _custom[path] = nil; return {} end
    local cached = _custom[path]
    if cached and cached.mtime == mtime then return cached.list end

    local list = {}
    local chunk, err = loadfile(path, "t", {})
    local ok, data = false, err
    if chunk then ok, data = pcall(chunk) end
    if ok and type(data) == "table" then
        for index, raw in ipairs(data) do
            list[#list + 1] = customPhrase(index, raw)
        end
    else
        require("logger").warn("simpleui: critter: cannot load " .. path .. ": " .. tostring(data))
    end
    _custom[path] = { mtime = mtime, list = list }
    return list
end

-- ---------------------------------------------------------------------------
-- Choosing
-- ---------------------------------------------------------------------------

-- Phrases of `list` that fit `f`, as an id list and an id → phrase map.
local function eligible(list, f)
    local ids, by_id = {}, {}
    for _i, phrase in ipairs(list) do
        if phrase.when(f) then
            ids[#ids + 1] = phrase.id
            by_id[phrase.id] = phrase
        end
    end
    return ids, by_id
end

-- Phrase table shown for `phrase` at the facts `f`.
local function render(phrase, f)
    return {
        text   = phrase.text(f),
        sub    = phrase.sub and phrase.sub(f) or nil,
        mood   = phrase.mood,
        source = phrase,
    }
end

--- The phrase `previous` (a result of Phrases.pick) written again for the facts
--- `f`; nil when it no longer fits them.
function Phrases.refresh(previous, f)
    local phrase = previous and previous.source
    if not (phrase and phrase.when(f)) then return nil end
    return render(phrase, f)
end

-- Picks a phrase for the facts `f`; with `celebrate`, an achievement phrase
-- that fits comes first.
--   opts.enabled   set of the category ids to use (built-in phrases)
--   opts.builtin   whether built-in phrases are offered (when not, the general
--                  ones still stand in if no user phrase fits)
--   opts.custom    list from Phrases.loadCustom (may be empty)
-- Returns { text, sub, mood, source } or nil when nothing fits.
function Phrases.pick(f, opts, celebrate)
    if celebrate and opts.builtin and opts.enabled.special then
        local members = {}
        for _i, phrase in ipairs(BUILTIN) do
            if phrase.celebrate then members[#members + 1] = phrase end
        end
        local ids, by_id = eligible(members, f)
        if #ids > 0 then return render(by_id[Deck.pick(DECK_KEY .. "celebrate", ids)], f) end
    end

    local pools, total = {}, 0

    local function addPool(cat, weight, ids, by_id)
        if #ids == 0 then return end
        pools[#pools + 1] = { cat = cat, weight = weight, ids = ids, by_id = by_id }
        total = total + weight
    end

    if opts.builtin then
        for _i, cat in ipairs(Phrases.CATEGORIES) do
            if opts.enabled[cat.id] then
                local members = {}
                for _j, phrase in ipairs(BUILTIN) do
                    if phrase.cat == cat.id then members[#members + 1] = phrase end
                end
                local ids, by_id = eligible(members, f)
                addPool(cat.id, cat.weight, ids, by_id)
            end
        end
    end
    if opts.custom and #opts.custom > 0 then
        local ids, by_id = eligible(opts.custom, f)
        addPool("custom", CUSTOM_WEIGHT, ids, by_id)
    end
    -- Without built-in phrases and with no user phrase that fits, the critter
    -- falls back to the general built-in ones instead of staying mute.
    if total == 0 and not opts.builtin then
        local members = {}
        for _i, phrase in ipairs(BUILTIN) do
            if phrase.cat == "generic" then members[#members + 1] = phrase end
        end
        local ids, by_id = eligible(members, f)
        addPool("generic", 1, ids, by_id)
    end
    if total == 0 then return nil end

    local roll = math.random(total)
    for _i, pool in ipairs(pools) do
        roll = roll - pool.weight
        if roll <= 0 then
            return render(pool.by_id[Deck.pick(DECK_KEY .. pool.cat, pool.ids)], f)
        end
    end
end

return Phrases
