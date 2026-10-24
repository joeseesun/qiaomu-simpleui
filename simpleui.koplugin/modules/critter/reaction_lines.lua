-- reaction_lines.lua — Simple UI
-- What the critter says about the things reactions.lua keeps: the catalogue of
-- lines of each kind of reaction and the rules that pick one.
--
-- A line is { id, kind, group, when(data), mood, text(data), sub?(data), by_tier? }:
--   kind, group  the reaction it is for, and which of the groups of that kind
--                (the bounds of the group are in `when`, so one group at a time
--                fits the data of a reaction)
--   data         what reactions.lua records with the reaction
--   mood         critter state shown with the line (see phrases.lua)
--   by_tier      lines of the critter in another mood tier (see mood.lua):
--                `by_tier[tier]` replaces the fields it sets; a replaced `text`
--                also leaves out the `sub`, unless it brings its own
-- A line deals from its own shuffle deck per kind and group, so nothing repeats
-- before the whole group has been seen.

local DateNames = require("infra/sui_datenames")
local Deck      = require("infra/sui_deck")
local _         = require("infra/sui_i18n").translate
local N_        = require("infra/sui_i18n").ngettext

local Lines = {}

Lines.DECK_KEY = "simpleui_critter_reaction_deck_"

-- Whether the data of a reaction fits each group; a group without data stays out.
local FITS = {
    ["book_finished/titled"]      = function(d) return d.title ~= nil end,
    ["book_finished/plain"]       = function(d) return d.title == nil end,
    ["session/short"]             = function(d) return d.minutes ~= nil and d.minutes < 10 end,
    ["session/medium"]            = function(d) return d.minutes ~= nil and d.minutes >= 10 and d.minutes < 45 end,
    ["session/long"]              = function(d) return d.minutes ~= nil and d.minutes >= 45 end,
    ["battery_low/low"]           = function(d) return d.capacity ~= nil end,
    ["special_date/new_year"]     = function(d) return d.which == "new_year" end,
    ["special_date/book_day"]     = function(d) return d.which == "book_day" end,
    ["special_date/anniversary"]  = function(d) return d.which == "anniversary" and (d.years or 0) >= 1 end,
    ["new_month/month"]           = function(d) return d.month ~= nil and d.month >= 1 and d.month <= 12 end,
    ["comeback/few"]              = function(d) return d.days ~= nil and d.days >= 3 and d.days < 7 end,
    ["comeback/week"]             = function(d) return d.days ~= nil and d.days >= 7 and d.days < 30 end,
    ["comeback/month"]            = function(d) return d.days ~= nil and d.days >= 30 end,
    ["charging/charging"]         = function() return true end,
    ["challenge_done/done"]       = function(d) return d.kind ~= nil end,
}

Lines.LINES = {}

local function add(kind, group, line)
    line.kind, line.group = kind, group
    line.when = FITS[kind .. "/" .. group]
    Lines.LINES[#Lines.LINES + 1] = line
end

local function monthName(d) return DateNames.monthFull()[d.month] end

-- ---------------------------------------------------------------------------
-- A book finished
-- ---------------------------------------------------------------------------

add("book_finished", "titled", { id = "bf_t1", mood = "party",
    text = function(d) return string.format(_("%s, finished!"), d.title) end,
    sub  = function() return _("Take a bow. I'll hold the applause.") end })
add("book_finished", "titled", { id = "bf_t2", mood = "cheer",
    text = function(d) return string.format(_("You finished %s."), d.title) end,
    sub  = function() return _("I'm not crying. It's dust.") end,
    by_tier = {
        grumpy = { mood = "grumpy", text = function(d) return string.format(_("%s is over. Good for you."), d.title) end },
        happy  = { mood = "party",  text = function(d) return string.format(_("%s! DONE! Incredible!"), d.title) end },
    } })
add("book_finished", "titled", { id = "bf_t3", mood = "love",
    text = function() return _("Another book on the done pile.") end,
    sub  = function(d) return string.format(_("%s was a good one."), d.title) end,
    by_tier = {
        meh     = { mood = "sleepy", text = function() return _("A book finished. I need to lie down.") end },
        radiant = { mood = "party",  text = function() return _("A new chapter of your legend is complete!") end,
                    sub = function(d) return string.format(_("%s will be sung about."), d.title) end },
    } })
add("book_finished", "titled", { id = "bf_t4", mood = "curious",
    text = function() return _("So, how did it end?") end,
    sub  = function(d) return string.format(_("Tell me about %s. No spoilers. Okay, spoilers."), d.title) end })

add("book_finished", "plain", { id = "bf_p1", mood = "party",
    text = function() return _("Book finished!") end,
    sub  = function() return _("Take a bow. I'll hold the applause.") end })
add("book_finished", "plain", { id = "bf_p2", mood = "cheer",
    text = function() return _("You finished a book.") end,
    sub  = function() return _("I'm not crying. It's dust.") end,
    by_tier = {
        grumpy = { mood = "grumpy", text = function() return _("A book is over. Good for you.") end },
        happy  = { mood = "party",  text = function() return _("DONE! Incredible!") end },
    } })
add("book_finished", "plain", { id = "bf_p3", mood = "love",
    text = function() return _("Another one for the done pile.") end,
    sub  = function() return _("That was a good one.") end,
    by_tier = {
        meh     = { mood = "sleepy", text = function() return _("One more finished. I need to lie down.") end },
        radiant = { mood = "party",  text = function() return _("Another chapter of your legend is complete!") end,
                    sub = function() return _("It will be sung about.") end },
    } })
add("book_finished", "plain", { id = "bf_p4", mood = "curious",
    text = function() return _("So, how did it end?") end,
    sub  = function() return _("No spoilers. Okay, spoilers.") end })

-- ---------------------------------------------------------------------------
-- A reading session
-- ---------------------------------------------------------------------------

add("session", "short", { id = "ss_1", mood = "curious",
    text = function() return _("A quick peek?") end,
    sub  = function(d) return string.format(N_("%d minute. A sneaky one.", "%d minutes. A sneaky one.", d.minutes), d.minutes) end })
add("session", "short", { id = "ss_2", mood = "playful",
    text = function() return _("Short and sweet.") end,
    sub  = function() return _("Even a few pages count.") end,
    by_tier = {
        grumpy = { mood = "grumpy", text = function() return _("That was short. I blinked and missed it.") end },
        happy  = { mood = "cheer",  text = function() return _("Every page counts! Hooray for pages!") end },
    } })
add("session", "short", { id = "ss_3", mood = "shy",
    text = function() return _("Just a little one today.") end,
    sub  = function() return _("Little reads add up.") end,
    by_tier = {
        meh     = { mood = "sleepy", text = function() return _("A short one. My kind of effort.") end },
        radiant = { mood = "cheer",  text = function() return _("A brief, brilliant visit to another world!") end },
    } })
add("session", "short", { id = "ss_4", mood = "happy",
    text = function() return _("A page here, a page there.") end,
    sub  = function() return _("That's how libraries get built.") end })

add("session", "medium", { id = "sm_1", mood = "happy",
    text = function(d) return string.format(N_("%d minute of reading.", "%d minutes of reading.", d.minutes), d.minutes) end,
    sub  = function() return _("A proper stretch.") end })
add("session", "medium", { id = "sm_2", mood = "cheer",
    text = function() return _("Nice little session!") end,
    sub  = function() return _("The book is warm now.") end,
    by_tier = {
        grumpy = { mood = "grumpy", text = function() return _("Fine. A decent session. Don't let it go to your head.") end },
        happy  = { mood = "party",  text = function() return _("What a lovely session! Bravo!") end },
    } })
add("session", "medium", { id = "sm_3", mood = "playful",
    text = function() return _("Look who's got staying power.") end,
    sub  = function() return _("Same time tomorrow?") end,
    by_tier = {
        meh     = { mood = "sleepy", text = function() return _("A decent session. I almost stayed awake.") end },
        radiant = { mood = "cheer",  text = function() return _("A session worthy of the great libraries!") end },
    } })
add("session", "medium", { id = "sm_4", mood = "love",
    text = function() return _("That was cosy.") end,
    sub  = function() return _("The book and you make a good team.") end })

add("session", "long", { id = "sl_1", mood = "surprised",
    text = function(d) return string.format(N_("%d minute! Did you eat?", "%d minutes! Did you eat?", d.minutes), d.minutes) end,
    sub  = function() return _("Drink some water, hero.") end })
add("session", "long", { id = "sl_2", mood = "party",
    text = function() return _("Marathon reader!") end,
    sub  = function(d) return string.format(N_("%d minute without surfacing.", "%d minutes without surfacing.", d.minutes), d.minutes) end,
    by_tier = {
        grumpy = { mood = "grumpy", text = function() return _("A marathon. I'm tired just watching.") end },
        happy  = { mood = "party",  text = function() return _("A MARATHON! You're unstoppable!") end },
    } })
add("session", "long", { id = "sl_3", mood = "love",
    text = function() return _("The world can wait.") end,
    sub  = function() return _("The book clearly deserved it.") end,
    by_tier = {
        meh     = { mood = "sleepy", text = function() return _("All that reading. Wake me when it's over.") end },
        radiant = { mood = "party",  text = function() return _("An epic voyage! The sagas will remember it!") end },
    } })
add("session", "long", { id = "sl_4", mood = "curious",
    text = function() return _("Was it that good?") end,
    sub  = function() return _("You must tell me everything.") end })

-- ---------------------------------------------------------------------------
-- The battery
-- ---------------------------------------------------------------------------

add("battery_low", "low", { id = "bl_1", mood = "surprised",
    text = function(d) return string.format(_("I'm at %d%%."), d.capacity) end,
    sub  = function() return _("Not to be dramatic, but find a charger.") end })
add("battery_low", "low", { id = "bl_2", mood = "sad",
    text = function() return _("Running on fumes.") end,
    sub  = function(d) return string.format(_("%d%% left. I'll be brave."), d.capacity) end,
    by_tier = {
        grumpy = { mood = "grumpy",    text = function() return _("Low battery. Typical.") end },
        happy  = { mood = "surprised", text = function() return _("Battery low! Quick, adventure's calling!") end },
    } })
add("battery_low", "low", { id = "bl_3", mood = "sleepy",
    text = function() return _("Feeling a bit faint.") end,
    sub  = function() return _("A charger would be lovely.") end,
    by_tier = {
        meh     = { mood = "sleepy",    text = function() return _("Low battery. Finally, a reason to nap.") end },
        radiant = { mood = "surprised", text = function() return _("My light is fading! Fetch the charger, brave soul!") end },
    } })
add("battery_low", "low", { id = "bl_4", mood = "shy",
    text = function() return _("Psst. The battery is low.") end,
    sub  = function() return _("I didn't want to say anything.") end })

add("charging", "charging", { id = "ch_1", mood = "happy",
    text = function() return _("Ooh, that's nice.") end,
    sub  = function() return _("Slurp. Thank you.") end })
add("charging", "charging", { id = "ch_2", mood = "sleepy",
    text = function() return _("Charging. Bliss.") end,
    sub  = function() return _("I'll just rest my eyes.") end,
    by_tier = {
        grumpy = { mood = "grumpy", text = function() return _("Charging. About time.") end },
        happy  = { mood = "cheer",  text = function() return _("Power! Glorious power!") end },
    } })
add("charging", "charging", { id = "ch_3", mood = "love",
    text = function() return _("You plugged me in.") end,
    sub  = function() return _("You're my favourite human.") end,
    by_tier = {
        meh     = { mood = "sleepy", text = function() return _("Charging. Wake me at 100%.") end },
        radiant = { mood = "love",   text = function() return _("Energy flows! I am reborn!") end },
    } })
add("charging", "charging", { id = "ch_4", mood = "playful",
    text = function() return _("Snack time!") end,
    sub  = function() return _("Electrons, my favourite.") end })

-- ---------------------------------------------------------------------------
-- Dates
-- ---------------------------------------------------------------------------

add("special_date", "new_year", { id = "ny_1", mood = "party",
    text = function() return _("Happy new year!") end,
    sub  = function() return _("A whole year of unread pages awaits.") end })
add("special_date", "new_year", { id = "ny_2", mood = "cheer",
    text = function() return _("New year, new shelf.") end,
    sub  = function() return _("What shall we read first?") end,
    by_tier = {
        grumpy = { mood = "grumpy", text = function() return _("Another year. The pile is still there.") end },
        happy  = { mood = "party",  text = function() return _("HAPPY NEW YEAR! Let's read everything!") end },
    } })
add("special_date", "new_year", { id = "ny_3", mood = "curious",
    text = function() return _("Resolutions?") end,
    sub  = function() return _("Mine is to nap more. Yours?") end,
    by_tier = {
        meh     = { mood = "sleepy", text = function() return _("A new year. Wake me in January. Oh, wait.") end },
        radiant = { mood = "party",  text = function() return _("A new year, a new saga! Onward!") end },
    } })
add("special_date", "new_year", { id = "ny_4", mood = "love",
    text = function() return _("The year turns like a page.") end,
    sub  = function() return _("Let's make it a good chapter.") end })

add("special_date", "book_day", { id = "bd_1", mood = "party",
    text = function() return _("Happy World Book Day!") end,
    sub  = function() return _("Today we celebrate you and your shelves.") end })
add("special_date", "book_day", { id = "bd_2", mood = "cheer",
    text = function() return _("It's World Book Day!") end,
    sub  = function() return _("Reading today is practically mandatory.") end,
    by_tier = {
        grumpy = { mood = "grumpy", text = function() return _("World Book Day. Fine. Read something.") end },
        happy  = { mood = "party",  text = function() return _("WORLD BOOK DAY! The best day of the year!") end },
    } })
add("special_date", "book_day", { id = "bd_3", mood = "love",
    text = function() return _("A day for books, at last.") end,
    sub  = function() return _("I've been waiting all year.") end,
    by_tier = {
        meh     = { mood = "sleepy", text = function() return _("Book Day. A holiday for my favourite thing: sitting.") end },
        radiant = { mood = "party",  text = function() return _("Today the whole world kneels to the book!") end },
    } })
add("special_date", "book_day", { id = "bd_4", mood = "playful",
    text = function() return _("Happy Book Day!") end,
    sub  = function() return _("Go on, pick something shiny.") end })

add("special_date", "anniversary", { id = "an_1", mood = "party",
    text = function(d) return string.format(N_("%d year together!", "%d years together!", d.years), d.years) end,
    sub  = function() return _("Look at us.") end })
add("special_date", "anniversary", { id = "an_2", mood = "love",
    text = function() return _("Happy anniversary!") end,
    sub  = function(d) return string.format(N_("%d year of pages and snacks.", "%d years of pages and snacks.", d.years), d.years) end,
    by_tier = {
        grumpy = { mood = "grumpy", text = function() return _("An anniversary. I suppose I'm fond of you.") end },
        happy  = { mood = "party",  text = function() return _("HAPPY ANNIVERSARY! I love us!") end },
    } })
add("special_date", "anniversary", { id = "an_3", mood = "shy",
    text = function() return _("I remember the day we met.") end,
    sub  = function() return _("You had a book in your hand.") end,
    by_tier = {
        meh     = { mood = "sleepy", text = function() return _("An anniversary. Cake? No? Nap, then.") end },
        radiant = { mood = "love",   text = function() return _("Our story is the finest of all libraries!") end },
    } })
add("special_date", "anniversary", { id = "an_4", mood = "cheer",
    text = function() return _("Another lap around the sun.") end,
    sub  = function() return _("Together, with books.") end })

add("new_month", "month", { id = "nm_1", mood = "cheer",
    text = function(d) return string.format(_("Welcome to %s!"), monthName(d)) end,
    sub  = function() return _("A fresh month, a fresh stack.") end })
add("new_month", "month", { id = "nm_2", mood = "curious",
    text = function(d) return string.format(_("%s already?"), monthName(d)) end,
    sub  = function() return _("Time flies when you're reading.") end,
    by_tier = {
        grumpy = { mood = "grumpy", text = function(d) return string.format(_("%s. Another month of the same pile."), monthName(d)) end },
        happy  = { mood = "cheer",  text = function(d) return string.format(_("%s! New month, new adventures!"), monthName(d)) end },
    } })
add("new_month", "month", { id = "nm_3", mood = "playful",
    text = function() return _("The calendar flipped a page.") end,
    sub  = function(d) return string.format(_("Let's see what %s brings."), monthName(d)) end,
    by_tier = {
        meh     = { mood = "sleepy", text = function(d) return string.format(_("It's %s. I barely noticed."), monthName(d)) end },
        radiant = { mood = "party",  text = function(d) return string.format(_("%s arrives! A new act begins!"), monthName(d)) end },
    } })
add("new_month", "month", { id = "nm_4", mood = "happy",
    text = function() return _("New month, new goals.") end,
    sub  = function() return _("Or the same ones. I'm not picky.") end })

-- ---------------------------------------------------------------------------
-- Coming back
-- ---------------------------------------------------------------------------

add("comeback", "few", { id = "cf_1", mood = "curious",
    text = function() return _("Look who's back!") end,
    sub  = function(d) return string.format(N_("%d day away. I counted.", "%d days away. I counted.", d.days), d.days) end })
add("comeback", "few", { id = "cf_2", mood = "shy",
    text = function() return _("I kept your place.") end,
    sub  = function() return _("Right where you left it.") end,
    by_tier = {
        grumpy = { mood = "grumpy", text = function() return _("Oh, you remember me.") end },
        happy  = { mood = "cheer",  text = function() return _("You're back! I missed you!") end },
    } })
add("comeback", "few", { id = "cf_3", mood = "playful",
    text = function() return _("A short holiday?") end,
    sub  = function() return _("Hope the books were jealous.") end,
    by_tier = {
        meh     = { mood = "sleepy", text = function() return _("You're back. I was napping, honest.") end },
        radiant = { mood = "love",   text = function() return _("The wanderer returns to the library!") end },
    } })
add("comeback", "few", { id = "cf_4", mood = "happy",
    text = function() return _("Welcome back!") end,
    sub  = function() return _("The shelves missed you.") end })

add("comeback", "week", { id = "cw_1", mood = "surprised",
    text = function(d) return string.format(N_("%d day! Where were you?", "%d days! Where were you?", d.days), d.days) end,
    sub  = function() return _("The books were worried.") end })
add("comeback", "week", { id = "cw_2", mood = "sad",
    text = function() return _("It's been a while.") end,
    sub  = function() return _("I dusted the shelves twice.") end,
    by_tier = {
        grumpy = { mood = "grumpy", text = function() return _("So you remember where I live.") end },
        happy  = { mood = "cheer",  text = function() return _("You're back! Best day ever!") end },
    } })
add("comeback", "week", { id = "cw_3", mood = "curious",
    text = function() return _("What did I miss?") end,
    sub  = function() return _("Tell me everything. Slowly.") end,
    by_tier = {
        meh     = { mood = "sleepy", text = function() return _("You're back. Finally. I got so bored I napped.") end },
        radiant = { mood = "love",   text = function() return _("The reader returns! Let the feast begin!") end },
    } })
add("comeback", "week", { id = "cw_4", mood = "playful",
    text = function() return _("I started talking to the bookcase.") end,
    sub  = function() return _("It's a good listener.") end })

add("comeback", "month", { id = "cm_1", mood = "surprised",
    text = function(d) return string.format(N_("%d day! I thought you'd moved.", "%d days! I thought you'd moved.", d.days), d.days) end,
    sub  = function() return _("Welcome home.") end })
add("comeback", "month", { id = "cm_2", mood = "love",
    text = function() return _("You came back.") end,
    sub  = function() return _("I never doubted you. Much.") end,
    by_tier = {
        grumpy = { mood = "grumpy", text = function() return _("A month. I kept busy. Mostly sulking.") end },
        happy  = { mood = "party",  text = function() return _("YOU'RE BACK! Confetti, everyone!") end },
    } })
add("comeback", "month", { id = "cm_3", mood = "shy",
    text = function() return _("It's been so long.") end,
    sub  = function() return _("The dust and I have become friends.") end,
    by_tier = {
        meh     = { mood = "sleepy", text = function() return _("You're back. I slept through half of it.") end },
        radiant = { mood = "love",   text = function() return _("The hero returns after a long quest!") end },
    } })
add("comeback", "month", { id = "cm_4", mood = "cheer",
    text = function() return _("Welcome back, stranger!") end,
    sub  = function() return _("Shall we pick up where we left off?") end })

-- ---------------------------------------------------------------------------
-- Picking
-- ---------------------------------------------------------------------------

--- A line of the reaction `kind` for its `data`, written for a critter in the
--- mood tier `tier`: { text, sub, mood }; nil when no line fits.
function Lines.pick(kind, data, tier)
    local ids, by_id, group = {}, {}, nil
    for _i, line in ipairs(Lines.LINES) do
        if line.kind == kind and line.when(data) then
            group = group or line.group
            if line.group == group then
                ids[#ids + 1] = line.id
                by_id[line.id] = line
            end
        end
    end
    local id = Deck.pick(Lines.DECK_KEY .. kind .. "_" .. tostring(group), ids)
    if not id then return nil end

    local line = by_id[id]
    local override = line.by_tier and line.by_tier[tier] or {}
    local text, sub = line.text, line.sub
    if override.text then text, sub = override.text, override.sub end
    return {
        text = text(data),
        sub  = sub and sub(data) or nil,
        mood = override.mood or line.mood,
    }
end

-- ---------------------------------------------------------------------------
-- A challenge met
-- ---------------------------------------------------------------------------

add("challenge_done", "done", { id = "cd_1", mood = "party",
    text = function() return _("Challenge met!") end,
    sub  = function() return _("I never doubted you. Much.") end,
    by_tier = {
        grumpy  = { mood = "grumpy", text = function() return _("Fine. You did it. Don't expect a parade.") end },
        radiant = { mood = "cheer",  text = function() return _("Challenge crushed! Take a bow, champion!") end },
    } })
add("challenge_done", "done", { id = "cd_2", mood = "cheer",
    text = function() return _("You said you would, and you did.") end,
    sub  = function() return _("That's the best kind of promise.") end })
add("challenge_done", "done", { id = "cd_3", mood = "happy",
    text = function() return _("Done and dusted.") end,
    sub  = function() return _("Shall I pick a harder one tomorrow?") end,
    by_tier = {
        meh   = { mood = "sleepy", text = function() return _("Done. Now I need a nap.") end },
        happy = { mood = "party",  text = function() return _("Done and dusted! Look at you go!") end },
    } })
add("challenge_done", "done", { id = "cd_4", mood = "love",
    text = function() return _("A small goal, a big grin.") end,
    sub  = function() return _("I'm keeping count, you know.") end })

return Lines
