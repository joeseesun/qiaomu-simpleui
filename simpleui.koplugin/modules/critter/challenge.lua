-- challenge.lua — Simple UI
-- Daily challenges of the Critter module: a small reading goal the critter
-- proposes in the conversation and checks when the statistics arrive. The rules
-- are pure; only Challenge.read / write touch the settings.
--
-- A state is { day, kind, target?, hour?, base_secs, base_pages, at, started_at?,
-- done, credited }:
--   day          day of the acceptance ("YYYY-MM-DD"); the challenge ends with it
--   kind         "minutes" | "pages" | "streak" | "before"
--   target       minutes or pages to read after the acceptance (minutes, pages)
--   hour         hour (0-23) a session must start before (before)
--   base_secs    today's reading seconds when it was accepted
--   base_pages   today's pages when it was accepted
--   at           time of the acceptance
--   started_at   earliest start of a session after the acceptance (before)
--   done         the goal was met
--   credited     the mood and the reaction for meeting it were given
-- `stats` is { today_secs?, today_pages?, streak?, daily_goal_secs? }, the
-- homonymous facts of the module (phrases.lua). Every function returns a new
-- table and leaves its argument alone.

local Mood        = require("modules/critter/mood")
local SUISettings = require("infra/sui_store")
local _           = require("infra/sui_i18n").translate
local N_          = require("infra/sui_i18n").ngettext

local Challenge = {}

local KEY = "simpleui_critter_challenge"

local MINUTE_TARGETS = { 10, 15, 20, 30 }
local PAGE_TARGETS   = { 10, 20, 30 }
local DEADLINE_HOURS = { 10, 12, 15, 18, 21 }
local MIN_LEAD_MINS  = 60    -- a deadline must be at least this far ahead
local STREAK_SECS    = 60    -- reading that keeps a streak
local MAX_GOAL_MINS  = 60

local KINDS = { minutes = true, pages = true, streak = true, before = true }

local function copy(state, changes)
    local new = {
        day = state.day, kind = state.kind, target = state.target, hour = state.hour,
        base_secs = state.base_secs, base_pages = state.base_pages, at = state.at,
        started_at = state.started_at, done = state.done, credited = state.credited,
    }
    for k, v in pairs(changes) do new[k] = v end
    return new
end

local function number(value)
    return type(value) == "number" and value == value and value or nil
end

local function flag(value)
    if type(value) == "boolean" then return value end
    return false
end

local function today(now)
    return os.date("%Y-%m-%d", now)
end

-- Time of the deadline hour of a "before" challenge.
local function deadline(state)
    local year, month, day = state.day:match("^(%d+)-(%d+)-(%d+)$")
    return os.time{ year = tonumber(year), month = tonumber(month), day = tonumber(day),
                    hour = state.hour, min = 0 }
end

-- Half of the daily goal in minutes, in steps of five between five and sixty.
local function goalTarget(goal_secs)
    local mins = math.floor(goal_secs / 60 / 2 / 5 + 0.5) * 5
    return math.max(5, math.min(MAX_GOAL_MINS, mins))
end

-- Whether a deadline at `hour` is at least MIN_LEAD_MINS ahead of `now`.
local function hasLead(hour, now)
    local t = os.date("*t", now)
    return hour * 60 >= t.hour * 60 + t.min + MIN_LEAD_MINS
end

-- First deadline hour at least MIN_LEAD_MINS ahead of `now`, nil when none is.
local function nextDeadline(now)
    for _i, hour in ipairs(DEADLINE_HOURS) do
        if hasLead(hour, now) then return hour end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

--- A challenge to offer for `stats` at `now`, { kind, target?, hour? }, or nil
--- when none fits. `rand(n)` gives an integer from 1 to n.
function Challenge.offer(stats, now, rand)
    local options = {}
    if stats.today_secs ~= nil then
        local targets = { unpack(MINUTE_TARGETS) }
        if (stats.daily_goal_secs or 0) > 0 then targets[#targets + 1] = goalTarget(stats.daily_goal_secs) end
        options[#options + 1] = { kind = "minutes", targets = targets }
    end
    if stats.today_pages ~= nil then
        options[#options + 1] = { kind = "pages", targets = PAGE_TARGETS }
    end
    if (stats.streak or 0) > 0 and stats.today_secs == 0 then
        options[#options + 1] = { kind = "streak" }
    end
    local hour = nextDeadline(now)
    if hour then options[#options + 1] = { kind = "before", hour = hour } end
    if #options == 0 then return nil end

    local option = options[rand(#options)]
    return {
        kind   = option.kind,
        target = option.targets and option.targets[rand(#option.targets)] or nil,
        hour   = option.hour,
    }
end

--- The state of `offer` accepted at `now`, measuring from `stats`.
function Challenge.accepted(offer, stats, now)
    return {
        day = today(now), kind = offer.kind, target = offer.target, hour = offer.hour,
        base_secs = stats.today_secs or 0, base_pages = stats.today_pages or 0,
        at = now, done = false, credited = false,
    }
end

--- The state of `offer` accepted at `now`, or nil when `current` (the stored
--- challenge of the day) exists or a deadline offer no longer has its lead.
function Challenge.accept(offer, stats, now, current)
    if current then return nil end
    if offer.kind == "before" and not hasLead(offer.hour, now) then return nil end
    return Challenge.accepted(offer, stats, now)
end

--- How far `state` is: { done, have, need } (seconds for a streak, 1 for a
--- deadline met by a session).
function Challenge.progress(state, stats)
    local kind = state.kind
    local have, need
    if kind == "minutes" then
        have, need = math.floor(math.max(0, (stats.today_secs or 0) - state.base_secs) / 60), state.target
    elseif kind == "pages" then
        have, need = math.max(0, (stats.today_pages or 0) - state.base_pages), state.target
    elseif kind == "streak" then
        have, need = math.min(STREAK_SECS, math.max(0, (stats.today_secs or 0) - state.base_secs)), STREAK_SECS
    else
        have, need = state.started_at and 1 or 0, 1
    end
    return { done = state.done or have >= need, have = have, need = need }
end

--- `state`, marked done when its goal is met; a done state stays done.
function Challenge.evaluated(state, stats)
    if state.done or not Challenge.progress(state, stats).done then return state end
    return copy(state, { done = true })
end

--- `state` with the mood and the reaction for meeting it marked as given.
function Challenge.credited(state)
    return copy(state, { done = true, credited = true })
end

--- `state` with the start of a reading session at `at` taken into account: for a
--- deadline challenge, a session after the acceptance and before the deadline.
function Challenge.sessionStarted(state, at)
    if not state or state.kind ~= "before" or state.done then return state end
    if at < state.at or at >= deadline(state) then return state end
    if state.started_at and state.started_at <= at then return state end
    return copy(state, { started_at = at })
end

--- A valid state from whatever was stored, nil when it is invalid or from
--- another day than `day`.
function Challenge.normalize(raw, day)
    if type(raw) ~= "table" or raw.day ~= day or not Mood.isDay(raw.day) then return nil end
    if not KINDS[raw.kind] or not number(raw.at) then return nil end
    local target, hour = number(raw.target), number(raw.hour)
    if raw.kind == "minutes" or raw.kind == "pages" then
        if not (target and target > 0) then return nil end
    elseif raw.kind == "before" then
        if not (hour and hour == math.floor(hour) and hour >= 0 and hour <= 23) then return nil end
    end
    return {
        day = raw.day, kind = raw.kind, target = target, hour = hour,
        base_secs = number(raw.base_secs) or 0, base_pages = number(raw.base_pages) or 0,
        at = raw.at, started_at = number(raw.started_at),
        done = flag(raw.done), credited = flag(raw.credited),
    }
end

-- ---------------------------------------------------------------------------
-- Texts
-- ---------------------------------------------------------------------------

--- The question that proposes `offer`.
function Challenge.offerText(offer)
    if offer.kind == "minutes" then
        return string.format(N_("Read %d minute today?", "Read %d minutes today?", offer.target), offer.target)
    elseif offer.kind == "pages" then
        return string.format(N_("Read %d page today?", "Read %d pages today?", offer.target), offer.target)
    elseif offer.kind == "streak" then
        return _("Read a little today to keep your streak?")
    end
    return string.format(_("Read before %d:00?"), offer.hour)
end

--- What the critter says about the accepted challenge `state` at `progress`.
function Challenge.progressText(state, progress)
    if state.kind == "minutes" then
        return string.format(N_("%d of %d minute so far.", "%d of %d minutes so far.", progress.need),
            progress.have, progress.need)
    elseif state.kind == "pages" then
        return string.format(N_("%d of %d page so far.", "%d of %d pages so far.", progress.need),
            progress.have, progress.need)
    elseif state.kind == "streak" then
        return _("Read a little today and your streak is safe.")
    end
    return string.format(_("Start reading before %d:00 and it's yours."), state.hour)
end

--- The facts of the module about challenges: { offer?, active, text }, nil when
--- there is nothing to say (the challenge is met, or none can be offered).
function Challenge.facts(state, stats, now, rand)
    if state then
        if state.done then return nil end
        return { active = true, text = Challenge.progressText(state, Challenge.progress(state, stats)) }
    end
    local offer = Challenge.offer(stats, now, rand)
    if not offer then return nil end
    return { offer = offer, active = false, text = Challenge.offerText(offer) }
end

-- ---------------------------------------------------------------------------
-- Settings (one table, shared by every screen)
-- ---------------------------------------------------------------------------

--- The stored challenge of the day of `now` (default: now), nil when none.
function Challenge.read(now)
    return Challenge.normalize(SUISettings:get(KEY), today(now or os.time()))
end

--- Keeps `state` in memory; the settings are flushed on suspend or exit.
function Challenge.write(state)
    SUISettings:setNoFlush(KEY, state)
end

return Challenge
