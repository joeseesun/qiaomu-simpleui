-- module_critter.lua — Simple UI
-- Homescreen module with a pixel-art critter and a speech bubble that says
-- something about the moment: a greeting for the time of day, the reading
-- streak, books finished this year, goals... Tapping the critter (or pressing
-- Enter on it) opens a short conversation: a bubble with an opening line takes
-- the place of the module's bubble, with the answers in a panel under it; the one
-- the user picks gets a reply from the critter in place of the phrase in the
-- bubble, and the last row asks for another phrase instead. The bubble is drawn
-- in blocks of the critter's pixel size or smooth, as chosen.
--
-- The critter also comments, unasked, on what happened: a book finished, a
-- reading session, a return after days away, a new month or year, a special
-- date, a low battery, the charger plugged in. The reaction waits for the next
-- time the Home Screen shows the critter and takes the place of the phrase once.
-- A row of the module's menu turns this off.
-- The critter has a mood, shared by every screen, that rises when the user
-- reads and talks to it and falls after days without reading; it shapes what
-- the critter says in the conversation.
--
-- The row holds, from left to right, up to two decorations, the critter and the
-- bubble (the critter on the side the user picks) and up to two decorations.
-- The decorations of each side are an arranged list, in the order they stand
-- on the screen. The bubble has a fixed size, so the group has a width that
-- never depends on the phrase and the critter and the decorations never move.
-- On a small screen the group fills the row; on a wide one it is placed at the
-- left, centre or right of the row. Decorations stand on the floor, on the wall
-- or hang from the top as their nature asks and share the critter's pixel size;
-- the ones next to the bubble keep more distance from it than the others. A
-- decoration that does not fit is left out, the farthest from the centre
-- first, and the bubble only shrinks to make room for them down to a share of
-- the row.
--
-- The user may tell the critter their name (one setting for every screen); some
-- phrases then use it.
--
-- The module has a fixed height. The phrase is kept while the facts it was
-- picked for stay the same, so rebuilding the screen (rotation, a menu, a page
-- turn) neither changes it nor uses up the phrase decks of phrases.lua.
--
-- Files of the module live in modules/critter/:
--   phrases.lua  catalogue of phrases and the rules that pick one
--   assets.lua   critters and decorations (bundled and the user's)
--   sprite.lua   critter and decoration image
--   bubble.lua   speech bubble, pixel or smooth
--   pixel_shapes.lua  geometry of the pixel-art bubble, glyphs and panel placement
--   mood.lua     the critter's mood: score, tiers and how it changes
--   dialog.lua   catalogue of conversation exchanges and the rules that pick one
--   reactions.lua       what happened and waits to be commented on
--   reaction_lines.lua  what the critter says about it
--   talk.lua     conversation: what is asked, what a choice does
--   talk_window.lua  window that shows the conversation

local Device          = require("device")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TopContainer    = require("ui/widget/container/topcontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local T               = require("ffi/util").template
local util            = require("util")
local lfs             = require("libs/libkoreader-lfs")
local i18n            = require("infra/sui_i18n")
local _               = i18n.translate
local N_              = i18n.ngettext

local Config      = require("infra/sui_config")
local DateNames   = require("infra/sui_datenames")
local SUIFonts    = require("infra/sui_fonts")
local Recommend   = require("modules/critter/recommend")
local Challenge   = require("modules/critter/challenge")
local Goals       = require("infra/sui_goals")
local SUISettings = require("infra/sui_store")
local UI          = require("infra/sui_core")
local Arrange     = require("features/sui_arrange")
local Chrome      = require("features/sui_module_chrome")
local SUIStyle    = require("features/sui_style")
local Assets      = require("modules/critter/assets")
local Bubble      = require("modules/critter/bubble")
local Mood        = require("modules/critter/mood")
local Phrases     = require("modules/critter/phrases")
local ReactionLines = require("modules/critter/reaction_lines")
local Reactions   = require("modules/critter/reactions")
local Sprite      = require("modules/critter/sprite")
local Talk        = require("modules/critter/talk")

local Screen = Device.screen

-- Settings, under the screen prefix.
local KEY_PICK   = "critter_pick"      -- id of the chosen critter
local KEY_SIDE   = "critter_side"      -- "left" | "right"
local KEY_ALIGN  = "critter_align"     -- "left" | "center" | "right"
local KEY_STYLE  = "critter_bubble_style"   -- "pixel" | "smooth"
local KEY_SOURCE = "critter_source"    -- "builtin" | "both" | "custom"
local KEY_CAT    = "critter_cat_"      -- .. category id; false = category off
local KEY_REACT  = "critter_reactions"  -- false = the critter does not react to events
local KEY_DECOR  = "critter_decor_"    -- .. side; ids of the decorations of that side, left to right

-- Longest streak already celebrated and the name the user gave the critter, shared by every screen.
local BEST_STREAK_KEY = "simpleui_critter_best_streak"
local BEST_DAY_KEY    = "simpleui_critter_best_streak_day"
local USER_NAME_KEY   = "simpleui_critter_user_name"
local CELEBRATED_KEY  = "simpleui_critter_celebrated"   -- token of the last achievement shown

local MAX_NAME_CHARS = 20

local SIDES   = { "left", "right" }
local ALIGNS  = { "left", "center", "right" }
local DEFAULT_ALIGN = "center"

-- Decorations a side of the group holds at most, and what each side holds
-- until the user arranges it.
local DECOR_PER_SIDE = 2
local DEFAULT_DECOR  = { left = { "bookcase", "lamp" }, right = {} }
local STYLES = { "pixel", "smooth" }
local DEFAULT_STYLE = "pixel"
local SOURCES = { "builtin", "both", "custom" }
local DEFAULT_SOURCE = "both"

-- A streak is a record from this length on, and a milestone at these lengths.
local MIN_RECORD_STREAK = 3
local MILESTONES = { [7] = true, [14] = true, [30] = true, [50] = true, [100] = true, [365] = true }

-- Seconds after which a phrase that is still valid gives way to another one.
local REROLL_SECS = 20 * 60
local CHALLENGE_REWARD = 5   -- mood a met challenge is worth

-- Layout at 100% scale.
local BASE_H_DP        = 104
local GAP_DP           = 6
local BUBBLE_GAP_DP    = 12    -- between the bubble and a decoration
local BUBBLE_DP         = 280   -- width of the bubble, tail included
local MAX_CRITTER_FRAC  = 0.45  -- widest share of the row the critter may take
local MIN_BUBBLE_FRAC  = 0.4   -- share of the row the bubble keeps for itself
local ANSWER_FONT_SCALE = 1.1   -- size of the conversation's answers against the bubble's message

local TEXT_ELEMS = { "message", "detail" }

-- The main line is bold until the user picks another variant.
Config.declareTextVariants("critter", { message = "bold" })
-- The pixel bubble speaks in the pixel font until another one is picked.
local function pixelFamily(pfx)
    return Config.readChoice(pfx .. KEY_STYLE, STYLES, DEFAULT_STYLE) == "pixel" and SUIFonts.PIXEL_FAMILY or nil
end
Config.declareTextFamilies("critter", { message = pixelFamily, detail = pixelFamily })

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local function enabledCategories(pfx)
    local set = {}
    for _i, cat in ipairs(Phrases.CATEGORIES) do
        set[cat.id] = SUISettings:nilOrTrue(pfx .. KEY_CAT .. cat.id)
    end
    return set
end

-- Options for Phrases.pick, and a signature that changes with them.
local function phraseOptions(pfx)
    local source  = Config.readChoice(pfx .. KEY_SOURCE, SOURCES, DEFAULT_SOURCE)
    local enabled = enabledCategories(pfx)
    local parts = { source }
    if source ~= "builtin" then
        parts[#parts + 1] = tostring(lfs.attributes(Assets.phrasesFile(), "modification"))
    end
    for _i, cat in ipairs(Phrases.CATEGORIES) do
        parts[#parts + 1] = enabled[cat.id] and "1" or "0"
    end
    return {
        enabled = enabled,
        builtin = source ~= "custom",
        custom  = source ~= "builtin" and Phrases.loadCustom(Assets.phrasesFile()) or nil,
    }, table.concat(parts)
end

-- Ids of the decorations of `side`, left to right: the ones the user arranged,
-- the default ones until then.
local function decorIds(pfx, side)
    local ids = SUISettings:get(pfx .. KEY_DECOR .. side)
    return type(ids) == "table" and ids or { unpack(DEFAULT_DECOR[side]) }
end

-- ---------------------------------------------------------------------------
-- Facts and phrase choice
-- ---------------------------------------------------------------------------

-- Name the user gave the critter, nil when there is none.
local function userName()
    local name = SUISettings:get(USER_NAME_KEY)
    return type(name) == "string" and name ~= "" and name or nil
end

-- Whether the critter reacts to events on the screen with prefix `pfx`.
local function reactionsOn(pfx)
    return SUISettings:nilOrTrue(pfx .. KEY_REACT)
end

-- Checks the accepted challenge against fresh statistics; the first time it is
-- met the mood rises and the critter reacts on the next visit.
local function creditChallenge(facts)
    local state = Challenge.read()
    if not state or state.credited then return end
    local checked = Challenge.evaluated(state, facts)
    if not checked.done then return end
    Mood.write(Mood.reward(Mood.read(), CHALLENGE_REWARD))
    Reactions.record("challenge_done", { kind = checked.kind })
    Challenge.write(Challenge.credited(checked))
    facts.challenge = nil
end

-- Lets the critter notice the day and, with `with_device` and reactions on, the
-- state of the device: its battery and charger, which may be read from the hardware, so this
-- is left for after the first paint.
local function observeReactions(pfx, with_device)
    -- The day is noted even when reactions are off, so that turning them on
    -- does not read the days off as an absence.
    Reactions.observe(os.date("%Y-%m-%d"))
    if not (with_device and reactionsOn(pfx)) then return end
    local ok, capacity, charging = pcall(function()
        local powerd = Device:getPowerDevice()
        return powerd:getCapacity(), powerd:isCharging()
    end)
    if ok then Reactions.observeDevice(capacity, charging == true) end
end

-- True on the day `streak` beat the longest streak of the reading history
-- (`longest`, which includes the current run). The first longest streak seen
-- only sets the mark; the one already celebrated and the day it was reached
-- are remembered.
local function trackStreakRecord(streak, longest)
    if not (streak and longest) then return false end
    local today = os.date("%Y-%m-%d")
    local best = tonumber(SUISettings:get(BEST_STREAK_KEY))
    if best == nil or longest < best then
        SUISettings:setNoFlush(BEST_STREAK_KEY, longest)
        return false
    end
    if longest > best then
        SUISettings:setNoFlush(BEST_STREAK_KEY, longest)
        if streak < longest then return false end
        SUISettings:setNoFlush(BEST_DAY_KEY, today)
        return streak >= MIN_RECORD_STREAK
    end
    return streak == longest and streak >= MIN_RECORD_STREAK and SUISettings:get(BEST_DAY_KEY) == today
end

-- Facts about the moment, as phrases.lua describes them.
local function collectFacts(ctx)
    local stats = ctx.stats or {}
    local now = os.date("*t")
    local streak = stats.streak
    -- Stale statistics (first paint after a return) may be from a past day: they
    -- only move the mood to today, the reading is credited once they are fresh.
    Mood.update(os.date("%Y-%m-%d"), not ctx.stats_stale and stats.today_secs or nil, Goals.get("daily"))
    local facts = {
        period           = Phrases.period(now.hour),
        weekday          = now.wday,
        weekday_name     = DateNames.weekdayFull()[now.wday],
        month            = now.month,
        day              = now.day,
        streak           = streak,
        streak_record    = trackStreakRecord(streak, stats.longest_streak),
        streak_milestone = streak ~= nil and MILESTONES[streak] == true,
        books_year       = stats.books_year,
        today_secs       = stats.today_secs,
        today_pages      = stats.today_pages,
        goal             = Goals.get("annual"),
        daily_goal_secs  = Goals.get("daily"),
        user_name        = userName(),
    }
    -- Challenges stand on fresh statistics: their base and progress come from them.
    if not ctx.stats_stale then
        facts.challenge = Challenge.facts(Challenge.read(), facts, os.time(), math.random)
    end
    return facts
end

-- Identifies what a phrase was picked for: while it stays the same the phrase
-- is still good.
local function factsKey(facts, signature)
    local books, secs = facts.books_year or 0, facts.today_secs or 0
    return table.concat({
        signature, facts.period, os.date("%j"),
        tostring(facts.streak), tostring(facts.books_year),
        secs > 0 and "1" or "0",
        facts.goal, books >= facts.goal and "1" or "0",
        facts.daily_goal_secs, secs >= facts.daily_goal_secs and "1" or "0",
        tostring(facts.user_name),
    }, "|")
end

-- Token of the achievement (streak record or milestone) the critter has still
-- to celebrate today, nil when there is none or it was already shown.
local function celebrationDue(facts)
    local kind = (facts.streak_record and "record") or (facts.streak_milestone and "milestone")
    if not kind then return nil end
    local token = table.concat({ os.date("%Y-%m-%d"), kind, facts.streak }, ":")
    if SUISettings:get(CELEBRATED_KEY) == token then return nil end
    return token
end

-- screen prefix -> { key, signature, phrase, at, cold, sticky }; a sticky phrase (a
-- reaction or a reply of the conversation) stays until REROLL_SECS, whatever the facts do
local _picks = {}

-- The phrase last picked, written again for `facts` so its numbers are current;
-- nil when it no longer fits them. The same table is kept while its text is
-- unchanged.
local function rewritten(last, facts)
    local kept = last.phrase and Phrases.refresh(last.phrase, facts)
    if not kept then return nil end
    if last.phrase.text ~= kept.text or last.phrase.sub ~= kept.sub then last.phrase = kept end
    return last.phrase
end

-- Phrase for `facts`: the last one while it still fits, else a new one (nil
-- when nothing fits). `force` always picks a new one. A phrase picked before
-- the statistics arrived (`cold`) is kept, rewritten, when it still fits them.
local function choosePhrase(pfx, facts, opts, signature, force)
    local key, now = factsKey(facts, signature), os.time()
    -- A sticky phrase on show keeps its place; a waiting reaction takes the next turn.
    local shown = _picks[pfx]
    local holding = shown and shown.sticky and now - shown.at < REROLL_SECS
    if not force and not holding and reactionsOn(pfx) then
        local reaction = Reactions.take()
        local line = reaction and ReactionLines.pick(reaction.kind, reaction.data, Mood.tier(Mood.read().score))
        if line then
            _picks[pfx] = { key = key, signature = signature, phrase = line, at = now, sticky = true }
            return line
        end
    end
    local due = celebrationDue(facts)
    local last = _picks[pfx]
    if not force and last and now - last.at < REROLL_SECS then
        if last.sticky then return last.phrase end
        if last.key == key then return rewritten(last, facts) or last.phrase end
        if last.cold and last.signature == signature and not due then
            local kept = rewritten(last, facts)
            if kept then
                last.key, last.cold = key, facts.streak == nil
                return kept
            end
        end
    end
    local phrase = Phrases.pick(facts, opts, due ~= nil)
    if due and phrase and phrase.source.celebrate then SUISettings:setNoFlush(CELEBRATED_KEY, due) end
    _picks[pfx] = {
        key = key, signature = signature, phrase = phrase, at = now,
        cold = facts.streak == nil,
    }
    return phrase
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

local function moduleScale(ctx, pfx)
    local lf = (ctx and ctx.landscape_factor) or (UI.isLandscape() and UI.getLandscapeFactor() or 1)
    return Config.getModuleScale("critter", pfx) * lf
end

local function rowHeight(scale)
    return math.floor(Screen:scaleBySize(BASE_H_DP) * scale)
end

-- Container that records where it was painted, so the module can refresh its
-- own box. It paints its child itself: WidgetContainer:paintTo would add the
-- recorded position to the one it is given.
local Stage = WidgetContainer:extend{}

function Stage:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self[1]:paintTo(bb, x, y)
end

-- Containers that place the group in the row, by alignment.
local ALIGN_CONTAINERS = { left = LeftContainer, center = CenterContainer, right = RightContainer }

-- Vertical placement of a decoration in the row, by its anchor (assets.lua).
local ANCHOR_CONTAINERS = { floor = BottomContainer, wall = CenterContainer, ceiling = TopContainer }

-- Decoration `entry` as a cell of the row height, placed by its anchor:
-- returns it and its width, or nil and 0 when there is none or no room (`budget`).
local function decorCell(entry, height, pixel, budget)
    if not entry or budget <= 0 then return nil, 0 end
    local image = Sprite:new{ path = entry.path, max_w = budget, max_h = height, max_pixel = pixel }
    local width = image.dimen.w
    if width <= 0 then return nil, 0 end
    return ANCHOR_CONTAINERS[entry.anchor]:new{ dimen = Geom:new{ w = width, h = height }, image }, width
end

-- The chosen decorations that still exist, the nearest to the centre first and
-- alternating between the sides: { side = "left" | "right", entry = decoration }.
local function decorOrder(pfx)
    local by_id = {}
    for _i, entry in ipairs(Assets.decorList()) do by_id[entry.id] = entry end
    local ids = { left = decorIds(pfx, "left"), right = decorIds(pfx, "right") }

    local order = {}
    for rank = 1, DECOR_PER_SIDE do
        local left, right = by_id[ids.left[#ids.left + 1 - rank]], by_id[ids.right[rank]]
        if left then order[#order + 1] = { side = "left", entry = left } end
        if right then order[#order + 1] = { side = "right", entry = right } end
    end
    return order
end

-- Chosen decorations that fit in `budget`, in the order of decorOrder: the
-- cells of each side, the nearest to the centre first, and the width the two
-- sides take. Every cell is followed, towards the centre, by `gap` and the one
-- nearest to the centre by `centre_gap[side]`.
local function decorCells(pfx, height, pixel, budget, gap, centre_gap)
    local cells, used = { left = {}, right = {} }, { left = 0, right = 0 }
    local total, closed = 0, {}
    for _i, slot in ipairs(decorOrder(pfx)) do
        if not closed[slot.side] then
            local side_cells = cells[slot.side]
            local spacing = #side_cells == 0 and centre_gap[slot.side] or gap
            local cell, width = decorCell(slot.entry, height, pixel, budget - total - spacing)
            if cell then
                side_cells[#side_cells + 1] = cell
                used[slot.side] = used[slot.side] + width + spacing
                total = total + width + spacing
            else
                closed[slot.side] = true   -- the ones farther out are left out too
            end
        end
    end
    return cells, used
end

-- Row of `cells` (the nearest to the centre first) with `gap` between them and
-- `centre_gap` next to the centre. `before` is true when the row stands before
-- the centre.
local function decorRow(cells, gap, centre_gap, before)
    local row = HorizontalGroup:new{ align = "center", allow_mirroring = false }
    for i, cell in ipairs(cells) do
        local span = HorizontalSpan:new{ width = i == 1 and centre_gap or gap }
        if before then
            table.insert(row, 1, span)
            table.insert(row, 1, cell)
        else
            row[#row + 1] = span
            row[#row + 1] = cell
        end
    end
    return row
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------

local M = {}

M.id          = "critter"
M.name        = _("Tiny Critter")
M.enabled_key = "critter_enabled"
M.default_on  = false
M.text_elems  = TEXT_ELEMS
M.needs       = { stats = true, books = true }

function M.build(w, ctx)
    local pfx    = ctx.pfx
    local scale  = moduleScale(ctx, pfx)
    local height = rowHeight(scale)
    local gap    = math.floor(Screen:scaleBySize(GAP_DP) * scale)
    local bubble_gap = math.floor(Screen:scaleBySize(BUBBLE_GAP_DP) * scale)
    local side   = Config.getAlignment(pfx .. KEY_SIDE, SIDES, "left")
    local align  = Config.getAlignment(pfx .. KEY_ALIGN, ALIGNS, DEFAULT_ALIGN)
    local critter = Assets.get(SUISettings:get(pfx .. KEY_PICK))
    local bubble_style = Config.readChoice(pfx .. KEY_STYLE, STYLES, DEFAULT_STYLE)

    local styles = Config.resolveTextStyles(ctx, M.id, TEXT_ELEMS)
    local msg_fs = math.max(8, math.floor(SUIStyle.FS_BODY   * scale * styles.message.scale))
    local det_fs = math.max(7, math.floor(SUIStyle.FS_DETAIL * scale * styles.detail.scale))
    local msg_face, msg_bold = SUIStyle.getTextFace(styles.message, msg_fs)
    local det_face, det_bold = SUIStyle.getTextFace(styles.detail,  det_fs)

    local opts, signature = phraseOptions(pfx)
    local facts  = collectFacts(ctx)
    if not ctx.stats_stale then creditChallenge(facts) end
    observeReactions(pfx, false)
    local phrase = choosePhrase(pfx, facts, opts, signature, false)

    -- Sprite of `mood` inside the box of `max_w`, nil when there is none.
    local function sprite(mood, max_w)
        local path = critter and Assets.imagePath(critter, mood)
        if not path then return nil end
        local image = Sprite:new{ path = path, max_w = max_w, max_h = height }
        return image.dimen.w > 0 and image or nil
    end

    local neutral    = sprite("neutral", math.floor(w * MAX_CRITTER_FRAC))
    local critter_w  = neutral and neutral.dimen.w or 0
    local group_gap  = neutral and gap or 0

    -- Decorations share the pixel size of the critter. They may use what the row
    -- has left once the critter and the bubble are taken, and the bubble gives up
    -- room to them down to its share of the row. A bubble that fits is always
    -- of the same width.
    local critter_right = neutral ~= nil and side == "right"
    local pixel   = neutral and neutral.pixel
    local unit    = pixel or math.max(1, Screen:scaleBySize(2))   -- pixel size of the bubble
    local avail   = w - critter_w - group_gap
    local target  = math.floor(Screen:scaleBySize(BUBBLE_DP) * scale)
    local min_w   = math.min(math.max(math.min(target, math.floor(w * MIN_BUBBLE_FRAC)),
                                      Bubble.minWidth(scale, neutral ~= nil, bubble_style, unit)), avail)
    local centre_gap = {
        left  = (critter_right or not neutral) and bubble_gap or gap,
        right = not critter_right and bubble_gap or gap,
    }
    local cells, used = decorCells(pfx, height, pixel, avail - min_w, gap, centre_gap)
    local left_decor  = #cells.left  > 0 and decorRow(cells.left,  gap, centre_gap.left,  true)  or nil
    local right_decor = #cells.right > 0 and decorRow(cells.right, gap, centre_gap.right, false) or nil
    local bubble_w = math.min(target, avail - used.left - used.right)
    local group_w  = used.left + critter_w + group_gap + bubble_w + used.right

    local function moodSprite(current)
        return current and sprite(current.mood, critter_w) or neutral
    end

    local live_bubble
    local function makeBubble(current)
        if not (current and current.text and current.text ~= "") then return nil end
        local bubble = Bubble.build{
            w        = bubble_w,
            h        = height,
            side     = neutral and side or nil,
            message  = current.text,
            detail   = current.sub ~= "" and current.sub or nil,
            msg_face = msg_face, msg_bold = msg_bold,
            det_face = det_face, det_bold = det_bold,
            scale    = scale,
            style    = bubble_style,
            unit     = unit,
        }
        if not bubble then return nil end
        -- Records where the bubble is painted, which the conversation takes over.
        local size = bubble:getSize()
        return Stage:new{ dimen = Geom:new{ w = size.w, h = size.h }, bubble }
    end

    local root = Stage:new{ dimen = Geom:new{ w = w, h = height } }
    local holder, cell

    if neutral then
        holder = BottomContainer:new{ dimen = Geom:new{ w = critter_w, h = height }, neutral }
        cell = InputContainer:new{ dimen = Geom:new{ w = critter_w, h = height }, holder }
        cell.ges_events = {
            TapCritter = { GestureRange:new{ ges = "tap", range = function() return cell.dimen end } },
        }
    end

    -- The row for `current`: the group of decorations, critter and bubble, placed
    -- in the row when it is narrower. The bubble has a fixed size, so only its
    -- text changes from one phrase to another.
    local function compose(current)
        local bubble = makeBubble(current)
        live_bubble = bubble
        if holder then holder[1] = moodSprite(current) end

        local group = HorizontalGroup:new{ align = "center", allow_mirroring = false }
        local function add(widget) if widget then group[#group + 1] = widget end end
        local function addGap() if cell then add(HorizontalSpan:new{ width = group_gap }) end end
        add(left_decor)
        if critter_right then
            add(bubble or HorizontalSpan:new{ width = bubble_w })
            addGap()
            add(cell)
        else
            add(cell)
            addGap()
            add(bubble or HorizontalSpan:new{ width = bubble_w })
        end
        add(right_decor)
        if group_w >= w then return group end
        return ALIGN_CONTAINERS[align]:new{
            dimen = Geom:new{ w = w, h = height },
            allow_mirroring = false,
            group,
        }
    end

    -- Shows `current` (mood image and bubble) in place of what is there.
    local function show(current)
        local old_bubble = live_bubble
        root[1] = compose(current)
        if old_bubble then old_bubble:free() end
    end
    root[1] = compose(phrase)

    -- Repaints the module's box.
    local function repaint()
        if ctx.dirty_region_fn then
            ctx.dirty_region_fn(root.dimen)
        else
            UIManager:setDirty("all", function() return "ui", root.dimen end)
        end
    end

    -- Rectangle the bubble stands in: where it was painted, else where it would.
    local function bubbleRect()
        local at = live_bubble and live_bubble.dimen
        if at and at.x then return Geom:new{ x = at.x, y = at.y, w = at.w, h = at.h } end
        local x = critter_right and cell.dimen.x - group_gap - bubble_w
                                or cell.dimen.x + critter_w + group_gap
        return Geom:new{ x = x, y = root.dimen.y, w = bubble_w, h = height }
    end

    if cell then
        function cell:onTapCritter()
            -- Answers in the message's family, regular and a step smaller.
            local answer_face = SUIStyle.getTextFace(
                { family = styles.message.family, variant = "regular" },
                math.max(8, math.floor(msg_fs * ANSWER_FONT_SCALE)))
            Talk.open{
                facts        = facts,
                anchor       = bubbleRect(),
                side         = critter_right and "right" or "left",
                critter_rect = Geom:new{ x = cell.dimen.x, y = cell.dimen.y, w = cell.dimen.w, h = cell.dimen.h },
                style        = bubble_style,
                unit         = unit,
                scale        = scale,
                faces        = { message = msg_face, message_bold = msg_bold, answer = answer_face },
                on_accept    = function(offer)
                    local now = os.time()
                    local state = Challenge.accept(offer, facts, now, Challenge.read(now))
                    if state then Challenge.write(state) end
                    facts.challenge = Challenge.facts(state or Challenge.read(now), facts, now, math.random)
                end,
                library      = {
                    next = Recommend.nextBook,
                    open = function(fp)
                        if not (ctx.open_fn and Recommend.exists(fp)) then return false end
                        ctx.open_fn(fp)
                        return true
                    end,
                },
                on_other = function()
                    phrase = choosePhrase(pfx, facts, opts, signature, true)
                    show(phrase)
                    repaint()
                end,
                on_reply = function(reply)
                    phrase = { text = reply.text, sub = reply.sub, mood = reply.mood }
                    _picks[pfx] = {
                        key = factsKey(facts, signature), signature = signature, phrase = phrase,
                        at = os.time(), sticky = true,
                    }
                    show(phrase)
                    repaint()
                end,
            }
            return true
        end
        if ctx.kbStops then
            UI.makeFocusable(cell, cell.onTapCritter)
            ctx.kbStops(M.id, { { id = "critter", widget = cell } })
        end
    elseif ctx.kbStops then
        ctx.kbStops(M.id, {})
    end

    -- Follows fresh statistics (they arrive after a deferred render): returns
    -- true when the phrase changed.
    root.critter_update = function(new_ctx)
        facts = collectFacts(new_ctx)
        if not new_ctx.stats_stale then creditChallenge(facts) end
        observeReactions(pfx, true)
        local current = choosePhrase(pfx, facts, opts, signature, false)
        if current == phrase then return false end
        phrase = current
        show(phrase)
        return true
    end
    return root
end

-- Called by the screen engine when statistics were refreshed.
function M.updateStats(widget, ctx)
    return widget.critter_update ~= nil and widget.critter_update(ctx)
end

function M.getHeight(ctx)
    local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
    return rowHeight(moduleScale(ctx, pfx)) + Chrome.boxInset(Chrome.resolve(pfx, M.id))
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

local function makeCritterItem(ctx_menu)
    local pfx, refresh, _lc = ctx_menu.pfx, ctx_menu.refresh, ctx_menu._
    local function get()
        local entry = Assets.get(SUISettings:get(pfx .. KEY_PICK))
        return entry and entry.id
    end
    return {
        text_func  = function() return _lc("Critter") end,
        value_func = function()
            local entry = Assets.get(SUISettings:get(pfx .. KEY_PICK))
            return entry and entry.name or ""
        end,
        sub_item_table_func = function()
            Assets.relist()
            Assets.ensureUserDir()
            local options = {}
            for _i, entry in ipairs(Assets.list()) do
                options[#options + 1] = { value = entry.id, label = entry.name }
            end
            local rows = Config.appendRadioItems({}, {
                options = options,
                get     = get,
                set     = function(id) SUISettings:set(pfx .. KEY_PICK, id) end,
                refresh = refresh,
            })
            rows[#rows + 1] = {
                text    = T(_lc("Add your own critters in %1"), Assets.userDir()),
                enabled = false,
            }
            return rows
        end,
    }
end

-- Arrange row for the decorations of both sides, in one list: those of the left
-- side, then those of the right, each as they stand on the screen.
local function makeDecorItem(ctx_menu)
    local pfx, _lc = ctx_menu.pfx, ctx_menu._
    local title = _lc("Decorations")
    return Arrange.makeSectionedItem{
        ctx_menu = ctx_menu,
        title    = title,
        labels   = {
            action  = string.format(_lc("Arrange %s"), title),
            empty   = _lc("No decorations selected."),
            too_few = _lc("Add at least 2 decorations to arrange."),
            full    = function(max)
                return string.format(N_("The maximum of %d decoration per side has been reached. Remove one first.",
                    "The maximum of %d decorations per side has been reached. Remove one first.", max), max)
            end,
        },
        sections = {
            { id = "left",  label = _lc("Left") },
            { id = "right", label = _lc("Right") },
        },
        max    = DECOR_PER_SIDE,
        pool   = function()
            local pool = {}
            for _i, entry in ipairs(Assets.decorList()) do
                pool[#pool + 1] = { id = entry.id, label = entry.name }
            end
            return pool
        end,
        getIds = function(side) return decorIds(pfx, side) end,
        setIds = function(side, ids) SUISettings:set(pfx .. KEY_DECOR .. side, ids) end,
    }
end

-- Menu row that asks for the name the critter uses for the user; an empty text
-- clears it.
local function makeNameItem(ctx_menu)
    local refresh, _lc = ctx_menu.refresh, ctx_menu._
    return {
        text_func      = function() return _lc("Your name") end,
        keep_menu_open = true,
        value_func     = function() return userName() or _lc("Not set") end,
        callback       = function()
            require("features/dialogs/sui_dialogs").prompt{
                title       = _lc("Your name"),
                description = _lc("The critter may use it in what it says."),
                value       = userName() or "",
                hint        = _lc("Name"),
                allow_empty = true,
                validate    = function(text)
                    if #util.splitToChars(text) > MAX_NAME_CHARS then
                        return T(_lc("Use at most %1 characters."), tostring(MAX_NAME_CHARS))
                    end
                end,
                on_submit   = function(text)
                    SUISettings:set(USER_NAME_KEY, text ~= "" and text or nil)
                    refresh()
                end,
            }
        end,
    }
end

local function makeStyleItem(ctx_menu)
    local pfx, _lc = ctx_menu.pfx, ctx_menu._
    return Config.makeRadioSubmenuItem{
        text    = _lc("Bubble style"),
        options = {
            { value = "pixel",  label = _lc("Pixel") },
            { value = "smooth", label = _lc("Smooth") },
        },
        get     = function() return Config.readChoice(pfx .. KEY_STYLE, STYLES, DEFAULT_STYLE) end,
        set     = function(v) SUISettings:set(pfx .. KEY_STYLE, v) end,
        refresh = ctx_menu.refresh,
    }
end

local function makeSourceItem(ctx_menu)
    local pfx, _lc = ctx_menu.pfx, ctx_menu._
    return Config.makeRadioSubmenuItem{
        text    = _lc("Phrases"),
        options = {
            { value = "builtin", label = _lc("Included") },
            { value = "both",    label = _lc("Included and mine") },
            { value = "custom",  label = _lc("Mine only") },
        },
        get     = function() return Config.readChoice(pfx .. KEY_SOURCE, SOURCES, DEFAULT_SOURCE) end,
        set     = function(v) SUISettings:set(pfx .. KEY_SOURCE, v) end,
        refresh = ctx_menu.refresh,
    }
end

local function makeCategoriesItem(ctx_menu)
    local pfx, refresh, _lc = ctx_menu.pfx, ctx_menu.refresh, ctx_menu._
    return {
        text_func = function() return _lc("Topics") end,
        sub_item_table_func = function()
            local rows = {}
            for _i, cat in ipairs(Phrases.CATEGORIES) do
                local key = pfx .. KEY_CAT .. cat.id
                rows[#rows + 1] = {
                    text           = cat.label(),
                    checked_func   = function() return SUISettings:nilOrTrue(key) end,
                    keep_menu_open = true,
                    callback       = function()
                        SUISettings:set(key, not SUISettings:nilOrTrue(key))
                        refresh()
                    end,
                }
            end
            return rows
        end,
    }
end

local function makeReactionsItem(ctx_menu)
    local pfx, refresh, _lc = ctx_menu.pfx, ctx_menu.refresh, ctx_menu._
    return {
        text           = _lc("React to events"),
        checked_func   = function() return reactionsOn(pfx) end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:set(pfx .. KEY_REACT, not reactionsOn(pfx))
            refresh()
        end,
    }
end

local function makeScaleItem(ctx_menu)
    local pfx, _lc = ctx_menu.pfx, ctx_menu._
    return Config.makeScaleItem{
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct(M.id, pfx) end,
        set          = function(v) Config.setModuleScale(v, M.id, pfx) end,
        refresh      = ctx_menu.refresh,
    }
end

function M.getMenuItems(ctx_menu)
    local pfx, refresh, _lc = ctx_menu.pfx, ctx_menu.refresh, ctx_menu._
    -- Picks up the decorations the user added since the last time.
    Assets.relist()
    Assets.ensureUserDir()
    return Config.buildModuleMenu({
        content = {
            makeCritterItem(ctx_menu),
            Config.makeAlignmentItem{
                key     = pfx .. KEY_SIDE,
                values  = SIDES,
                default = "left",
                text    = _lc("Critter position"),
                refresh = refresh,
                _lc     = _lc,
            },
            Config.makeAlignmentItem{
                key     = pfx .. KEY_ALIGN,
                values  = ALIGNS,
                default = DEFAULT_ALIGN,
                text    = _lc("Alignment"),
                refresh = refresh,
                _lc     = _lc,
            },
            makeStyleItem(ctx_menu),
            makeDecorItem(ctx_menu),
            {
                text    = T(_lc("Add your own decorations in %1"), Assets.userDecorDir()),
                enabled = false,
            },
            makeNameItem(ctx_menu),
            makeSourceItem(ctx_menu),
            makeCategoriesItem(ctx_menu),
            makeReactionsItem(ctx_menu),
        },
        appearance = {
            size = { makeScaleItem(ctx_menu) },
            text = {
                mod_id  = M.id,
                elems   = TEXT_ELEMS,
                labels  = { message = _lc("Message"), detail = _lc("Details") },
                info    = _lc("Size of this text.\n100% is the default size."),
                pfx     = pfx,
                refresh = refresh,
                _lc     = _lc,
            },
        },
    }, ctx_menu)
end

return M
