-- reactions.lua — Simple UI
-- Reactions of the Critter module: things that happened (a book finished, a
-- reading session, a return after days away, a new month or year, a special
-- date, a low battery, the charger plugged in), kept as one reaction that waits
-- for the next time the Home Screen shows the critter. The rules are pure; only
-- Reactions.read / write and the wrappers below touch the settings.
--
-- A state is { pending, first_seen, last_seen, last_month, last_year,
-- book_day_year, anniversary_years, armed, was_charging }:
--   pending            { kind, data, at } of the reaction that waits, if any
--   first_seen         first day the Home Screen was shown ("YYYY-MM-DD")
--   last_seen          last day it was shown
--   last_month         latest month seen ("YYYY-MM"); months only move forward
--   last_year          latest year seen; years only move forward
--   book_day_year      last year World Book Day was reacted to
--   anniversary_years  last anniversary reacted to, in years
--   armed              whether a low battery may be reacted to (nil: yes)
--   was_charging       whether the device was charging at the last observation
-- Every function returns a new table and leaves its argument alone.
--
-- Kinds, from the one that matters most: book_finished { title },
-- challenge_done { kind }, session { minutes }, battery_low { capacity }, special_date { which, years },
-- new_month { month }, comeback { days }, charging { capacity }.

local Mood        = require("modules/critter/mood")
local SUISettings = require("infra/sui_store")

local Reactions = {}

Reactions.TTL      = 2 * 24 * 3600   -- seconds a reaction waits before it is forgotten
Reactions.BOOK_DAY = "04-23"         -- World Book Day, as "MM-DD"

Reactions.PRIORITY = {
    book_finished = 8, challenge_done = 7, session = 6, battery_low = 5, special_date = 4,
    new_month = 3, comeback = 2, charging = 1,
}

local MIN_AWAY_DAYS    = 3        -- days away that make a comeback
local LOW_BATTERY      = 15       -- at or under this level the battery is low
local REARM_BATTERY    = 30       -- from this level a low battery may be reacted to again
local MIN_DAY          = "2020-01-01"  -- an earlier date is a clock that was reset
local MAX_JUMP_DAYS    = 365   -- a jump of the clock bigger than this is not a visit
local MIN_SESSION_SECS = 60
local MAX_SESSION_SECS = 6 * 3600 -- longer is the device asleep, not reading

local KEY = "simpleui_critter_reactions"

local function copy(state, changes)
    local new = {
        pending = state.pending, first_seen = state.first_seen, last_seen = state.last_seen,
        last_month = state.last_month, last_year = state.last_year,
        book_day_year = state.book_day_year, anniversary_years = state.anniversary_years,
        armed = state.armed, was_charging = state.was_charging,
    }
    for k, v in pairs(changes) do new[k] = v end
    if new.pending == false then new.pending = nil end   -- `pending = false` clears it
    return new
end

-- `value` when it is a boolean (false included), else nil.
local function bool(value)
    if type(value) == "boolean" then return value end
    return nil
end

local function whole(value)
    return type(value) == "number" and value == math.floor(value) and value or nil
end

-- Fields a reaction's data may carry, by type; anything else is dropped.
local DATA_FIELDS = {
    title = "string", which = "string", kind = "string",
    minutes = "number", days = "number", years = "number", month = "number", capacity = "number",
}

local function cleanData(data)
    local clean = {}
    for k, v in pairs(data) do
        if type(v) == DATA_FIELDS[k] and (type(v) ~= "number" or v == v) then clean[k] = v end
    end
    return clean
end

--- A valid state from whatever was stored; invalid fields take their defaults.
function Reactions.normalize(raw)
    raw = type(raw) == "table" and raw or {}
    local pending = raw.pending
    if not (type(pending) == "table" and Reactions.PRIORITY[pending.kind]
            and type(pending.data) == "table" and type(pending.at) == "number") then
        pending = nil
    else
        pending = { kind = pending.kind, data = cleanData(pending.data), at = pending.at }
    end
    return {
        pending           = pending,
        first_seen        = Mood.isDay(raw.first_seen) and raw.first_seen or nil,
        last_seen         = Mood.isDay(raw.last_seen) and raw.last_seen or nil,
        last_month        = type(raw.last_month) == "string" and raw.last_month:match("^%d%d%d%d%-%d%d$") or nil,
        last_year         = whole(raw.last_year),
        book_day_year     = whole(raw.book_day_year),
        anniversary_years = whole(raw.anniversary_years),
        armed             = bool(raw.armed),
        was_charging      = bool(raw.was_charging),
    }
end

--- The state with `kind` (and its `data`) waiting, unless a reaction that
--- matters more already is; an equal one is replaced by the newer.
function Reactions.recorded(state, kind, data, now)
    local current = state.pending
    if current and Reactions.PRIORITY[current.kind] > Reactions.PRIORITY[kind] then return state end
    return copy(state, { pending = { kind = kind, data = data, at = now } })
end

--- The state without the waiting reaction and that reaction ({ kind, data }), or
--- nil when none waits or it is older than Reactions.TTL.
function Reactions.taken(state, now)
    local pending = state.pending
    if not pending then return state, nil end
    local cleared = copy(state, { pending = false })
    if now - pending.at > Reactions.TTL then return cleared, nil end
    return cleared, { kind = pending.kind, data = pending.data }
end

--- The state after the Home Screen was shown on `today` ("YYYY-MM-DD"): the
--- first visit only sets the base; later ones record a comeback, a new month, an
--- anniversary of the first use, World Book Day and a new year. A day before the
--- last one seen (the clock went back) only moves the last day seen; a date before MIN_DAY and a jump of more
--- than MAX_JUMP_DAYS react to nothing too.
function Reactions.visited(state, today, now)
    if today < MIN_DAY then return state end
    local year, month_key = tonumber(today:sub(1, 4)), today:sub(1, 7)
    if not state.first_seen then
        return copy(state, { first_seen = today, last_seen = today, last_month = month_key, last_year = year })
    end
    local last_seen = state.last_seen or today
    local days = Mood.daysBetween(last_seen, today)
    if math.abs(days) > MAX_JUMP_DAYS then return copy(state, { last_seen = today }) end
    if today < last_seen then return copy(state, { last_seen = today }) end

    local s = state
    if days >= MIN_AWAY_DAYS then s = Reactions.recorded(s, "comeback", { days = days }, now) end

    local changes = { last_seen = today }
    if month_key > (state.last_month or month_key) then
        s = Reactions.recorded(s, "new_month", { month = tonumber(today:sub(6, 7)) }, now)
        changes.last_month = month_key
    end

    -- Whole years since the first visit, counted on the day of the year.
    local first_year = tonumber(state.first_seen:sub(1, 4))
    local before = today:sub(6) < state.first_seen:sub(6)
    local years = year - first_year - (before and 1 or 0)
    if years >= 1 and years > (state.anniversary_years or 0) then
        s = Reactions.recorded(s, "special_date", { which = "anniversary", years = years }, now)
        changes.anniversary_years = years
    end
    if today:sub(6) == Reactions.BOOK_DAY and state.book_day_year ~= year then
        s = Reactions.recorded(s, "special_date", { which = "book_day" }, now)
        changes.book_day_year = year
    end
    if year > (state.last_year or year) then
        s = Reactions.recorded(s, "special_date", { which = "new_year" }, now)
        changes.last_year = year
    end
    return copy(s, changes)
end

--- The state after observing the device: `capacity` (percent, nil or 0 when it
--- cannot be read) and whether it is `charging`. A low battery is reacted to
--- once, until it is charged or back above REARM_BATTERY; plugging in the charger
--- is reacted to once it is seen, the first observation being only the base.
function Reactions.visitedDevice(state, capacity, charging, now)
    local level = type(capacity) == "number" and capacity >= 1 and capacity <= 100 and capacity or nil
    local charging_now = charging == true
    local armed = state.armed ~= false
    if charging_now or (level and level >= REARM_BATTERY) then armed = true end

    -- A waiting device reaction that no longer holds is dropped.
    local s = state
    local pending = state.pending
    if pending and ((pending.kind == "battery_low" and (charging_now or (level and level > LOW_BATTERY)))
                    or (pending.kind == "charging" and not charging_now)) then
        s = copy(s, { pending = false })
    end
    if level and level <= LOW_BATTERY and not charging_now and armed then
        s = Reactions.recorded(s, "battery_low", { capacity = level }, now)
        armed = false
    end
    if state.was_charging == false and charging_now then
        s = Reactions.recorded(s, "charging", { capacity = level }, now)
    end
    return copy(s, { armed = armed, was_charging = charging_now })
end

--- What closing a book leaves behind, as a list of { kind, data }: the book
--- finished during the session (`status_after` "complete" where `session.status`
--- was not) and the session itself when it lasted between a minute and six hours.
function Reactions.closeReactions(session, status_after, title, now)
    local list = {}
    if not session then return list end
    if session.status ~= "complete" and status_after == "complete" then
        list[#list + 1] = {
            kind = "book_finished",
            data = { title = type(title) == "string" and title ~= "" and title or nil },
        }
    end
    local secs = now - session.at - (session.paused or 0)
    if secs >= MIN_SESSION_SECS and secs <= MAX_SESSION_SECS then
        list[#list + 1] = { kind = "session", data = { minutes = math.floor(secs / 60) } }
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Settings (one table, shared by every screen)
-- ---------------------------------------------------------------------------

--- The stored state.
function Reactions.read()
    return Reactions.normalize(SUISettings:get(KEY))
end

--- Keeps `state` in memory; the settings are flushed on suspend or exit.
function Reactions.write(state)
    SUISettings:setNoFlush(KEY, state)
end

local function same(a, b)
    local pa, pb = a.pending, b.pending
    if (pa == nil) ~= (pb == nil) then return false end
    if pa and (pa.kind ~= pb.kind or pa.at ~= pb.at) then return false end
    return a.first_seen == b.first_seen and a.last_seen == b.last_seen
        and a.last_month == b.last_month and a.last_year == b.last_year
        and a.book_day_year == b.book_day_year and a.anniversary_years == b.anniversary_years
        and a.armed == b.armed and a.was_charging == b.was_charging
end

-- Runs `rule(state)` on the stored state, keeps the result when it changed and
-- returns the rule's second result.
local function apply(rule)
    local stored = Reactions.read()
    local state, extra = rule(stored)
    if not same(state, stored) then Reactions.write(state) end
    return extra
end

--- Makes `kind` wait (see Reactions.recorded).
function Reactions.record(kind, data)
    apply(function(state) return Reactions.recorded(state, kind, data, os.time()) end)
end

--- Notes that the Home Screen is shown on `today` (see Reactions.visited).
function Reactions.observe(today)
    apply(function(state) return Reactions.visited(state, today, os.time()) end)
end

--- Notes the state of the device (see Reactions.visitedDevice).
function Reactions.observeDevice(capacity, charging)
    apply(function(state) return Reactions.visitedDevice(state, capacity, charging, os.time()) end)
end

--- The reaction that waits ({ kind, data }), which is then forgotten; nil when none.
function Reactions.take()
    return apply(function(state) return Reactions.taken(state, os.time()) end)
end

return Reactions
