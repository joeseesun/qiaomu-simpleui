-- mood.lua — Simple UI
-- Mood of the Critter module: a score that rises when the user reads and talks
-- to the critter and falls after days without reading. The model is pure; only
-- Mood.read / Mood.write / Mood.update touch the settings.
--
-- A state is { score, day, read_day, read_gain, chat_gain }:
--   score      FLOOR..MAX, DEFAULT at first
--   day        last day the state was rolled forward ("YYYY-MM-DD")
--   read_day   last day reading was credited
--   read_gain  what that credit added on `read_day`
--   chat_gain  affection gained from conversation on `day`
-- Every function returns a new table and leaves its argument alone.

local SUISettings = require("infra/sui_store")

local Mood = {}

Mood.DEFAULT = 50
Mood.FLOOR   = 10
Mood.MAX     = 100

local READ_GAIN      = 8     -- reading credited once a day
local GOAL_GAIN      = 12    -- same, with the daily goal reached
local MISSED_LOSS    = 5     -- per day without reading
local MAX_LOSS       = 30    -- most a single absence takes away
local CHAT_DAILY_CAP = 10    -- most conversation adds in a day

local KEY = "simpleui_critter_mood"

-- Highest score of each tier, lowest tier first.
local TIER_LIMITS = {
    { limit = 19, id = "grumpy" },
    { limit = 39, id = "meh" },
    { limit = 59, id = "okay" },
    { limit = 79, id = "happy" },
    { limit = 100, id = "radiant" },
}

local function clamp(score)
    return math.max(Mood.FLOOR, math.min(Mood.MAX, score))
end

local function isDay(value)
    if type(value) ~= "string" then return false end
    local month, day = value:match("^%d%d%d%d%-(%d%d)%-(%d%d)$")
    month, day = tonumber(month), tonumber(day)
    return month ~= nil and month >= 1 and month <= 12 and day >= 1 and day <= 31
end

local function copy(state, changes)
    local new = {
        score = state.score, day = state.day, read_day = state.read_day,
        read_gain = state.read_gain, chat_gain = state.chat_gain,
    }
    for k, v in pairs(changes) do new[k] = v end
    return new
end

-- Whole days from day `a` to day `b`; noon avoids daylight saving shifts.
local function daysBetween(a, b)
    local function at(day)
        local y, m, d = day:match("^(%d+)-(%d+)-(%d+)$")
        return os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
    end
    return math.floor((at(b) - at(a)) / 86400 + 0.5)
end

--- Whole days from day `a` to day `b` (both "YYYY-MM-DD"), negative when `b` is
--- the earlier one.
Mood.daysBetween = daysBetween

--- Whether `value` is a "YYYY-MM-DD" day.
Mood.isDay = isDay

--- Tier id of `score`: grumpy, meh, okay, happy or radiant.
function Mood.tier(score)
    for _i, tier in ipairs(TIER_LIMITS) do
        if score <= tier.limit then return tier.id end
    end
    return TIER_LIMITS[#TIER_LIMITS].id
end

--- A valid state from whatever was stored; invalid fields take their defaults.
function Mood.normalize(raw)
    raw = type(raw) == "table" and raw or {}
    local function number(v) return type(v) == "number" and v == v and v or nil end
    local score = number(raw.score) or Mood.DEFAULT
    local gain  = number(raw.chat_gain) or 0
    local read_gain = number(raw.read_gain) or 0
    return {
        score     = clamp(math.floor(score)),
        day       = isDay(raw.day) and raw.day or nil,
        read_day  = isDay(raw.read_day) and raw.read_day or nil,
        read_gain = math.max(0, math.floor(read_gain)),
        chat_gain = math.max(0, math.floor(gain)),
    }
end

--- The state on `today`: a new day takes away what the days without reading
--- cost and clears the conversation gain. The same day, or an earlier one (the
--- clock was ahead and went back) is taken as the new day, with nothing lost.
function Mood.rollDay(state, today)
    if not state.day then return copy(state, { day = today }) end
    if today == state.day then return state end
    if today < state.day then return copy(state, { day = today, chat_gain = 0 }) end
    local elapsed = daysBetween(state.day, today)
    local missed = math.max(0, elapsed - (state.read_day == state.day and 1 or 0))
    local score = state.score
    if score > Mood.FLOOR then
        score = math.max(Mood.FLOOR, score - math.min(MAX_LOSS, MISSED_LOSS * missed))
    end
    return copy(state, { score = score, day = today, chat_gain = 0 })
end

--- The state after crediting today's reading. A day is credited once; reaching
--- the daily goal later in the day adds what the first credit left out.
--- `today_secs` nil or zero credits nothing; `goal_secs` 0 means no daily goal.
function Mood.creditReading(state, today, today_secs, goal_secs)
    if not today_secs or today_secs <= 0 then return state end
    local target = (goal_secs > 0 and today_secs >= goal_secs) and GOAL_GAIN or READ_GAIN
    local given = state.read_day == today and state.read_gain or 0
    if target <= given then return state end
    return copy(state, { score = clamp(state.score + target - given), read_day = today, read_gain = target })
end

--- The state after a conversation choice worth `delta`: gains stop at the daily
--- cap, descents are free.
function Mood.applyChoice(state, delta)
    if delta > 0 then
        local gain = math.max(0, math.min(delta, CHAT_DAILY_CAP - state.chat_gain, Mood.MAX - state.score))
        return copy(state, { score = clamp(state.score + gain), chat_gain = state.chat_gain + gain })
    end
    return copy(state, { score = clamp(state.score + delta) })
end

--- The state with the score raised by `n`, outside the daily cap of the chat.
function Mood.reward(state, n)
    return copy(state, { score = clamp(state.score + n) })
end

-- ---------------------------------------------------------------------------
-- Settings (one table, shared by every screen)
-- ---------------------------------------------------------------------------

--- The stored state.
function Mood.read()
    return Mood.normalize(SUISettings:get(KEY))
end

--- Keeps `state` in memory; the settings are flushed on suspend or exit.
function Mood.write(state)
    SUISettings:setNoFlush(KEY, state)
end

local function same(a, b)
    return a.score == b.score and a.day == b.day and a.read_day == b.read_day
        and a.read_gain == b.read_gain and a.chat_gain == b.chat_gain
end

--- Brings the stored state to `today` and credits today's reading; returns it.
function Mood.update(today, today_secs, goal_secs)
    local stored = Mood.read()
    local state = Mood.creditReading(Mood.rollDay(stored, today), today, today_secs, goal_secs)
    if not same(state, stored) then Mood.write(state) end
    return state
end

return Mood
