-- dialog.lua — Simple UI
-- Conversation catalogue of the Critter module and the rules that pick an
-- exchange.
--
-- An exchange is { id, when(f, tier), opener(f), options }: the critter opens
-- with a line and the user answers with one of the options. An option is
--   { id, text(f), when?(f, tier), delta, reply }
--   delta   effect of the answer on the critter's mood (mood.lua)
--   accept  true when the answer accepts the challenge on offer (talk.lua)
--   recommend  true when the answer asks for a book suggestion (talk.lua); its
--           reply is then what the critter says when it finds none
--   reply   { mood, text(f), sub?(f), by_tier? }: what the critter says back,
--           shown as a phrase of the bubble. `by_tier[tier]` replaces the
--           fields it sets for a critter in that mood tier.
-- `f` are the facts about the moment (see phrases.lua) and `tier` is the mood
-- tier (see mood.lua).

local Deck = require("infra/sui_deck")
local _    = require("infra/sui_i18n").translate
local N_   = require("infra/sui_i18n").ngettext

local Dialog = {}

Dialog.TIERS = { "grumpy", "meh", "okay", "happy", "radiant" }

Dialog.DECK_KEY = "simpleui_critter_dialog_deck"

-- Options offered at most, and fewest an exchange needs to be offered.
local MAX_OPTIONS = 3
local MIN_OPTIONS = 2

local function hasName(f) return f.user_name ~= nil end

local function named(text)
    return function(f) return string.format(text(), f.user_name) end
end

-- Answer that turns a suggestion down.
local function notNow() return _("Not now") end

-- What the critter says when the user turns a book suggestion down.
local LATER_REPLY = {
    mood = "playful",
    text = function() return _("Fine. They'll keep.") end,
    by_tier = {
        grumpy  = { mood = "grumpy", text = function() return _("Fine. The books can wait. So can I.") end },
        happy   = { mood = "cheer",  text = function() return _("No rush! The shelf isn't going anywhere.") end },
        radiant = { mood = "love",   text = function() return _("Whenever you're ready. I'll be right here.") end },
    },
}

Dialog.EXCHANGES = {
    -- General.
    { id = "thinking",
      when   = function() return true end,
      opener = function() return _("I've been thinking.") end,
      options = {
          { id = "dangerous", delta = 1,
            text  = function() return _("Dangerous.") end,
            reply = {
                mood = "playful",
                text = function() return _("Rude. Accurate, but rude.") end,
                by_tier = {
                    happy   = { mood = "cheer", text = function() return _("Dangerous! Thrilling! Say it again!") end },
                    grumpy  = { mood = "grumpy", text = function() return _("Rude. Also correct. I hate that.") end },
                    radiant = { mood = "cheer",  text = function() return _("Dangerous AND brilliant. Naturally.") end },
                },
            } },
          { id = "about", delta = 2,
            text  = function() return _("About what?") end,
            reply = {
                mood = "curious",
                text = function() return _("Whether books read us back.") end,
                sub  = function() return _("Don't answer. It's a trap.") end,
                by_tier = {
                    happy   = { mood = "cheer", text = function() return _("Oh, EVERYTHING! Where do I even start?") end },
                    grumpy  = { mood = "grumpy", text = function() return _("Whether anyone reads me. Never mind.") end },
                    radiant = { mood = "cheer",  text = function() return _("Whether I am a footnote or a whole chapter.") end },
                },
            } },
          { id = "not_now", delta = -1,
            text  = function() return _("Not now.") end,
            reply = {
                mood = "grumpy",
                text = function() return _("Noted. I'll sulk quietly. Loudly.") end,
            } },
          { id = "go_on", delta = 3,
            text  = function() return _("Go on, I'm listening.") end,
            reply = {
                mood = "happy",
                text = function() return _("Finally, an audience.") end,
                sub  = function() return _("Where was I? Ah, yes: snacks.") end,
                by_tier = {
                    radiant = { mood = "cheer", text = function() return _("An audience! I knew this day would come.") end },
                },
            } },
      } },

    { id = "lonely_books",
      when   = function() return true end,
      opener = function() return _("Do you think books get lonely?") end,
      options = {
          { id = "unread", delta = 2,
            text  = function() return _("Only the unread ones.") end,
            reply = {
                mood = "sad",
                text = function() return _("That's the saddest true thing I've heard.") end,
                sub  = function() return _("Go and visit one.") end,
                by_tier = {
                    happy   = { mood = "love", text = function() return _("Aww! We'll cheer them up with a visit!") end },
                    grumpy  = { mood = "grumpy", text = function() return _("Great. Now I'm thinking about it.") end },
                    radiant = { mood = "love",   text = function() return _("Then we rescue them, one chapter at a time!") end },
                },
            } },
          { id = "no_feelings", delta = -1,
            text  = function() return _("Books don't have feelings.") end,
            reply = {
                mood = "surprised",
                text = function() return _("Tell that to the ending of that one book.") end,
                sub  = function() return _("You know the one.") end,
                by_tier = {
                    grumpy  = { mood = "grumpy",  text = function() return _("Says the one who needs a charger.") end },
                    radiant = { mood = "playful", text = function() return _("Careful. They can hear you.") end },
                },
            } },
          { id = "happy_books", delta = 1,
            text  = function() return _("Mine are perfectly happy.") end,
            reply = {
                mood = "happy",
                text = function() return _("Spoiled books. I approve.") end,
            } },
          { id = "never_thought", delta = 1,
            text  = function() return _("I never thought about it.") end,
            reply = {
                mood = "curious",
                text = function() return _("Now you never will stop.") end,
            } },
      } },

    { id = "bookmark",
      when   = function() return true end,
      opener = function() return _("I found a bookmark in the sofa.") end,
      options = {
          { id = "mine", delta = 1,
            text  = function() return _("That's mine!") end,
            reply = {
                mood = "surprised",
                text = function() return _("Finders keepers. Kidding. Mostly.") end,
                by_tier = {
                    happy   = { mood = "cheer", text = function() return _("Yours! Take it! Take two!") end },
                    grumpy  = { mood = "grumpy", text = function() return _("Finders keepers.") end },
                    radiant = { mood = "cheer",  text = function() return _("Returned with full honours!") end },
                },
            } },
          { id = "page", delta = 2,
            text  = function() return _("Page 212, probably.") end,
            reply = {
                mood = "playful",
                text = function() return _("Impressive. Terrifying, but impressive.") end,
                by_tier = {
                    happy   = { mood = "cheer", text = function() return _("Wow! Page 212! You're amazing!") end },
                    meh     = { text = function() return _("Impressive. I'd clap, but effort.") end },
                    radiant = { mood = "cheer", text = function() return _("A mind like an index. I'm honoured.") end },
                },
            } },
          { id = "put_back", delta = -1,
            text  = function() return _("Put it back.") end,
            reply = {
                mood = "shy",
                text = function() return _("Fine. But it's looking at me.") end,
            } },
          { id = "dog_ears", delta = -2,
            text  = function() return _("Dog-ears are better.") end,
            reply = {
                mood = "surprised",
                text = function() return _("Heresy! Call the librarian.") end,
            } },
      } },

    { id = "plot_twist",
      when   = function() return true end,
      opener = function() return _("I'd like a plot twist today.") end,
      options = {
          { id = "like_what", delta = 2,
            text  = function() return _("Like what?") end,
            reply = {
                mood = "curious",
                text = function() return _("The butler did it. In a library. With a bookmark.") end,
                sub  = function() return _("Obviously.") end,
                by_tier = {
                    happy   = { mood = "cheer", text = function() return _("Confetti! Dragons! A talking bookcase!") end },
                    grumpy  = { mood = "grumpy", text = function() return _("Nothing. Nothing happens. Perfect.") end,
                                sub = function() return _("Peace at last.") end },
                    radiant = { mood = "cheer",  text = function() return _("The critter was the author all along!") end,
                                sub = function() return _("Gasp.") end },
                },
            } },
          { id = "careful", delta = 0,
            text  = function() return _("Be careful what you wish for.") end,
            reply = {
                mood = "surprised",
                text = function() return _("Sound advice. I'll ignore it.") end,
            } },
          { id = "spoilers", delta = 1,
            text  = function() return _("Spoilers, please.") end,
            reply = {
                mood = "playful",
                text = function() return _("Everyone's fine. The tea isn't.") end,
            } },
          { id = "quiet", delta = 1,
            text  = function() return _("Make it a quiet one.") end,
            reply = {
                mood = "sleepy",
                text = function() return _("Deal. A twist so quiet nobody notices.") end,
                by_tier = {
                    grumpy  = { mood = "grumpy", text = function() return _("A twist? In this economy?") end },
                    radiant = { mood = "happy",  text = function() return _("A whisper of a twist. Exquisite.") end },
                },
            } },
      } },

    { id = "favourite_word",
      when   = function() return true end,
      opener = function() return _("Quick: favourite word?") end,
      options = {
          { id = "serendipity", delta = 2,
            text  = function() return _("Serendipity.") end,
            reply = {
                mood = "happy",
                text = function() return _("Fancy. Very fancy.") end,
                by_tier = {
                    happy   = { mood = "love", text = function() return _("Ooh, so pretty! Say it again!") end },
                    grumpy  = { mood = "grumpy", text = function() return _("Show-off.") end },
                    radiant = { mood = "love",   text = function() return _("A word that tastes like old paper. Divine.") end },
                },
            } },
          { id = "nap", delta = 1,
            text  = function() return _("Nap.") end,
            reply = {
                mood = "sleepy",
                text = function() return _("Wise. Spoken like a scholar.") end,
            } },
          { id = "unputdownable", delta = 3,
            text  = function() return _("Unputdownable.") end,
            reply = {
                mood = "cheer",
                text = function() return _("Invented by a publisher, loved by everyone.") end,
                by_tier = {
                    happy   = { mood = "cheer", text = function() return _("YES! The best kind of book!") end },
                    meh     = { mood = "sleepy", text = function() return _("Unputdownable. Unlike my energy levels.") end },
                    radiant = { text = function() return _("A word that earned its place on the shelf!") end },
                },
            } },
          { id = "none", delta = -1,
            text  = function() return _("I don't have one.") end,
            reply = {
                mood = "shy",
                text = function() return _("Then borrow mine: snack.") end,
            } },
      } },

    { id = "last_page",
      when   = function() return true end,
      opener = function() return _("Be honest: do you read the last page first?") end,
      options = {
          { id = "never", delta = 2,
            text  = function() return _("Never!") end,
            reply = {
                mood = "cheer",
                text = function() return _("A purist. I knew I liked you.") end,
                by_tier = {
                    happy   = { mood = "cheer", text = function() return _("Wonderful! Suspense is the best part!") end },
                    grumpy  = { mood = "grumpy", text = function() return _("A purist. Boring. Respect.") end },
                    radiant = { mood = "love",   text = function() return _("A noble soul! Bards will sing of this.") end },
                },
            } },
          { id = "sometimes", delta = 1,
            text  = function() return _("Sometimes.") end,
            reply = {
                mood = "playful",
                text = function() return _("Gasp. Your secret is safe with the shelves.") end,
            } },
          { id = "always", delta = 0,
            text  = function() return _("Always.") end,
            reply = {
                mood = "surprised",
                text = function() return _("Monstrous. I'll allow it.") end,
                by_tier = {
                    grumpy  = { mood = "grumpy",  text = function() return _("Monstrous. And yet, efficient.") end },
                    radiant = { mood = "playful", text = function() return _("Chaos! I adore you.") end },
                },
            } },
          { id = "what_last_page", delta = 1,
            text  = function() return _("What's a last page?") end,
            reply = {
                mood = "curious",
                text = function() return _("Exactly the energy I need.") end,
            } },
      } },

    -- Time.
    { id = "time_of_day",
      when   = function() return true end,
      opener = function(f)
          if f.period == "morning" then return _("Is it morning already?") end
          if f.period == "afternoon" then return _("Is it already nap o'clock?") end
          if f.period == "evening" then return _("The light is nice this time of day.") end
          return _("Shouldn't we both be asleep?")
      end,
      options = {
          { id = "agree", delta = 1,
            text  = function() return _("Very much.") end,
            reply = {
                mood = "happy",
                text = function() return _("Then we agree. A rare event.") end,
                by_tier = {
                    happy   = { mood = "cheer", text = function() return _("Yes! We agree! What a lovely day!") end },
                    grumpy  = { mood = "grumpy", text = function() return _("We agree. Mark the calendar.") end },
                    radiant = { mood = "cheer",  text = function() return _("We agree! Fetch the confetti!") end },
                },
            } },
          { id = "disagree", delta = 0,
            text  = function() return _("Not really.") end,
            reply = {
                mood = "playful",
                text = function() return _("Bold words, with no book in hand.") end,
            } },
          { id = "all_day", delta = 2,
            text  = function() return _("What do you do all day?") end,
            reply = {
                mood = "cheer",
                text = function() return _("I supervise the shelves.") end,
                sub  = function() return _("Very demanding work.") end,
                by_tier = {
                    meh     = { mood = "sleepy", text = function() return _("I supervise the shelves. Sitting down.") end },
                    radiant = { text = function() return _("I preside over a kingdom of paper.") end,
                                sub = function() return _("Taxes are low.") end },
                },
            } },
          { id = "leave_me", delta = -2,
            text  = function() return _("Leave me be.") end,
            reply = {
                mood = "sad",
                text = function() return _("Fine. I'll go be dramatic elsewhere.") end,
            } },
      } },

    { id = "weekday",
      when   = function() return true end,
      opener = function(f) return string.format(_("Happy %s, I suppose?"), f.weekday_name) end,
      options = {
          { id = "reading_day", delta = 2,
            text  = function() return _("Every day is a reading day.") end,
            reply = {
                mood = "cheer",
                text = function() return _("Hear, hear! Put it on a mug.") end,
                by_tier = {
                    happy   = { mood = "cheer", text = function() return _("Every day! Hooray!") end },
                    grumpy  = { mood = "grumpy", text = function() return _("Put it on a mug. Then leave me alone.") end },
                    radiant = { text = function() return _("Put it on a banner. On a flag!") end },
                },
            } },
          { id = "already", delta = 0,
            text  = function() return _("Is it already?") end,
            reply = {
                mood = "surprised",
                text = function() return _("Time is an illusion. So are weekends.") end,
            } },
          { id = "optional", delta = 1,
            text  = function() return _("Weekdays should be optional.") end,
            reply = {
                mood = "playful",
                text = function() return _("Put it to a vote. I'm in favour.") end,
                by_tier = {
                    meh     = { mood = "sleepy", text = function() return _("Put it to a vote. Tomorrow.") end },
                    radiant = { mood = "cheer",  text = function() return _("A motion! Seconded by the entire shelf!") end },
                },
            } },
          { id = "rather_not", delta = -1,
            text  = function() return _("I'd rather not discuss it.") end,
            reply = {
                mood = "shy",
                text = function() return _("Understood. Let us speak of the weather. Damp.") end,
            } },
      } },

    -- Reading streak.
    { id = "streak_talk",
      when   = function(f) return f.streak ~= nil and f.streak >= 2 end,
      opener = function(f)
          return string.format(N_("Our streak is at %d day. No pressure.",
              "Our streak is at %d days. No pressure.", f.streak), f.streak)
      end,
      options = {
          { id = "keep_going", delta = 3,
            text  = function() return _("Let's keep it going.") end,
            reply = {
                mood = "cheer",
                text = function() return _("That's the spirit! I'll sharpen the bookmarks.") end,
                by_tier = {
                    happy   = { mood = "cheer", text = function() return _("Yes yes yes! Let's gooo!") end },
                    grumpy  = { mood = "grumpy", text = function() return _("Fine. But I'm not wearing a party hat.") end },
                    radiant = { text = function() return _("Onward! Glory awaits in chapter nine!") end },
                },
            } },
          { id = "no_pressure", delta = 1,
            text  = function() return _("No pressure? Sure.") end,
            reply = {
                mood = "playful",
                text = function() return _("Zero pressure. Pure vibes.") end,
                by_tier = {
                    grumpy  = { mood = "grumpy", text = function() return _("Zero. None. Breathe.") end },
                    radiant = { mood = "cheer",  text = function() return _("Zero pressure, infinite splendour.") end },
                },
            } },
          { id = "stop_counting", delta = -1,
            text  = function() return _("Stop counting.") end,
            reply = {
                mood = "shy",
                text = function() return _("Counting is my love language.") end,
            } },
          { id = "miss_a_day", delta = 0,
            text  = function() return _("What if I miss a day?") end,
            reply = {
                mood = "curious",
                text = function() return _("Then we start again, with snacks.") end,
                sub  = function() return _("No shame in snacks.") end,
            } },
      } },

    { id = "streak_restart",
      when   = function(f) return f.streak == 0 end,
      opener = function() return _("The streak took a little break.") end,
      options = {
          { id = "restart", delta = 3,
            text  = function() return _("Let's restart it today.") end,
            reply = {
                mood = "cheer",
                text = function() return _("Chapter one of a brand new saga!") end,
                by_tier = {
                    grumpy  = { mood = "grumpy", text = function() return _("Chapter one. Again. Wonderful.") end },
                    radiant = { text = function() return _("The sequel will be better. I can feel it!") end },
                },
            } },
          { id = "holiday", delta = 1,
            text  = function() return _("It's on holiday.") end,
            reply = {
                mood = "playful",
                text = function() return _("Postcards expected.") end,
                by_tier = {
                    meh     = { mood = "sleepy", text = function() return _("Lucky streak. I could use a holiday.") end },
                    radiant = { mood = "cheer",  text = function() return _("Sunburnt and ready to return, I hope!") end },
                },
            } },
          { id = "promise", delta = 2,
            text  = function() return _("I'll be back, promise.") end,
            reply = {
                mood = "shy",
                text = function() return _("I'll hold you to it. Gently. With snacks.") end,
            } },
          { id = "dont_remind", delta = -2,
            text  = function() return _("Don't remind me.") end,
            reply = {
                mood = "shy",
                text = function() return _("Never mentioned. Never existed.") end,
            } },
      } },

    -- Books this year.
    { id = "goal_watching",
      when   = function(f) return f.books_year ~= nil and f.books_year >= 1 and f.goal > 0 end,
      opener = function(f)
          return string.format(N_("%d book this year. The goal is watching.",
              "%d books this year. The goal is watching.", f.books_year), f.books_year)
      end,
      options = {
          { id = "let_it", delta = 2,
            text  = function() return _("Let it watch.") end,
            reply = {
                mood = "playful",
                text = function() return _("Brave. I'd hide behind the sofa.") end,
                by_tier = {
                    grumpy  = { mood = "grumpy", text = function() return _("Brave. I'm already behind the sofa.") end },
                    radiant = { mood = "cheer",  text = function() return _("Let it watch! We shall dazzle it!") end },
                },
            } },
          { id = "on_track", delta = 2,
            text  = function() return _("I'm on track.") end,
            reply = {
                mood = "cheer",
                text = function() return _("On track and on fire. Metaphorically.") end,
                by_tier = {
                    meh     = { mood = "happy", text = function() return _("On track. I'm proud, quietly.") end },
                    radiant = { mood = "love",  text = function() return _("On track and in legend. Metaphorically.") end },
                },
            } },
          { id = "can_wait", delta = -1,
            text  = function() return _("The goal can wait.") end,
            reply = {
                mood = "curious",
                text = function() return _("Goals are patient. Until they aren't.") end,
            } },
          { id = "which_next", delta = 1,
            text  = function() return _("Which book next?") end,
            reply = {
                mood = "curious",
                text = function() return _("Ooh. A question for a committee of me.") end,
            } },
      } },

    -- The name the user gave the critter.
    { id = "question",
      when   = hasName,
      opener = function(f) return string.format(_("Psst, %s. Can I ask you something?"), f.user_name) end,
      options = {
          { id = "sure", delta = 1,
            text  = function() return _("Sure.") end,
            reply = {
                mood = "curious",
                text = function() return _("Do the unread books judge us?") end,
                sub  = function() return _("Asking for a friend. The friend is me.") end,
                by_tier = {
                    grumpy  = { mood = "grumpy", text = function() return _("Do the unread books judge us? I think so.") end },
                    radiant = { mood = "cheer",  text = function() return _("Shall we read them all and settle it?") end },
                },
            } },
          { id = "depends", delta = 0,
            text  = function() return _("That depends.") end,
            reply = {
                mood = "playful",
                text = named(function() return _("Spoken like a true diplomat, %s.") end),
            } },
          { id = "please_dont", delta = -1,
            text  = function() return _("Please don't.") end,
            reply = {
                mood = "surprised",
                text = function() return _("Too late. It's already in the air.") end,
            } },
          { id = "snacks", delta = 2,
            text  = function() return _("Only if it's about snacks.") end,
            reply = {
                mood = "cheer",
                text = named(function() return _("It's always about snacks, %s.") end),
                by_tier = {
                    meh     = { mood = "sleepy", text = named(function() return _("It's always about snacks, %s. And naps.") end) },
                    radiant = { mood = "love",   text = named(function() return _("You understand me, %s. Truly.") end) },
                },
            } },
      } },

    -- Book suggestion: "Yes, pick one" has the conversation suggest an unopened
    -- book (talk.lua); its reply is what the critter says when there is none.
    { id = "read_next",
      when   = function() return true end,
      opener = function() return _("Want something new to read?") end,
      options = {
          { id = "yes", delta = 1, recommend = true,
            text  = function() return _("Yes, pick one") end,
            reply = {
                mood = "surprised",
                text = function() return _("Nothing unopened on your shelves.") end,
                sub  = function() return _("Impressive. Or suspicious.") end,
                by_tier = {
                    grumpy  = { mood = "grumpy", text = function() return _("Not one unopened book. Show-off.") end },
                    happy   = { mood = "cheer",  text = function() return _("Every single book opened! Look at you!") end },
                    radiant = { mood = "love",   text = function() return _("You've opened them all. I'm so proud.") end },
                },
            } },
          { id = "later", delta = 0,
            text  = notNow,
            reply = LATER_REPLY },
      } },

    -- Challenges (challenge.lua): the opener is the offer or the progress, ready
    -- as text in `f.challenge`. Accepting an offer is handled by talk.lua.
    { id = "challenge_offer",
      when   = function(f) return f.challenge ~= nil and f.challenge.offer ~= nil end,
      opener = function(f) return f.challenge.text end,
      options = {
          { id = "accept", delta = 1, accept = true,
            text  = function() return _("Challenge accepted") end,
            reply = {
                mood = "cheer",
                text = function() return _("That's the spirit. I'll be watching.") end,
                sub  = function() return _("Kindly. Mostly kindly.") end,
                by_tier = {
                    grumpy  = { mood = "grumpy", text = function() return _("Bold. We'll see how long that lasts.") end },
                    happy   = { mood = "party",  text = function() return _("Yes! You've got this!") end },
                    radiant = { mood = "love",   text = function() return _("I knew you'd say yes. I love this for us.") end },
                },
            } },
          { id = "later", delta = 0,
            text  = function() return _("Maybe later") end,
            reply = {
                mood = "playful",
                text = function() return _("The offer stands. Dramatically.") end,
                by_tier = {
                    grumpy  = { mood = "grumpy", text = function() return _("Typical.") end },
                    radiant = { mood = "shy",    text = function() return _("Of course. No pressure at all.") end },
                },
            } },
      } },
    { id = "challenge_active",
      when   = function(f) return f.challenge ~= nil and f.challenge.active == true end,
      opener = function(f) return f.challenge.text end,
      options = {
          { id = "on_it", delta = 1,
            text  = function() return _("On it!") end,
            reply = {
                mood = "cheer",
                text = function() return _("Go, go, go! Pages await.") end,
                by_tier = {
                    grumpy  = { mood = "grumpy", text = function() return _("Less talking. More reading.") end },
                    radiant = { mood = "party",  text = function() return _("Unstoppable! I can feel it!") end },
                },
            } },
          { id = "tough", delta = 0,
            text  = function() return _("Tough one…") end,
            reply = {
                mood = "curious",
                text = function() return _("Small steps. One page is still a page.") end,
                by_tier = {
                    happy = { mood = "cheer", text = function() return _("You can do it! One page at a time!") end },
                    meh   = { mood = "sleepy", text = function() return _("Then let's take it slowly. Very slowly.") end },
                },
            } },
      } },
}

-- Options of `exchange` open to `tier` at the facts `f`.
local function eligibleOptions(exchange, f, tier)
    local list = {}
    for _i, option in ipairs(exchange.options) do
        if option.when == nil or option.when(f, tier) then list[#list + 1] = option end
    end
    return list
end

-- What the critter answers `reply` says for a critter in mood tier `tier`.
local function renderReply(reply, f, tier)
    local override = reply.by_tier and reply.by_tier[tier] or {}
    local sub = override.sub or reply.sub
    return {
        mood = override.mood or reply.mood,
        text = (override.text or reply.text)(f),
        sub  = sub and sub(f) or nil,
    }
end

local function shuffle(list)
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

--- An exchange for the facts `f` and the mood tier `tier`, or nil when none
--- fits. Returns { id, opener, options } with 2 or 3 options dealt at random
--- ({ id, text, delta, recommend, accept, reply = function(tier) -> { text, sub, mood } }), all
--- texts written for `f`. Exchanges are dealt from a deck, so none comes
--- round before the others have been seen.
function Dialog.pick(f, tier)
    local ids, by_id = {}, {}
    for _i, exchange in ipairs(Dialog.EXCHANGES) do
        if exchange.when(f, tier) then
            local options = eligibleOptions(exchange, f, tier)
            if #options >= MIN_OPTIONS then
                ids[#ids + 1] = exchange.id
                by_id[exchange.id] = { exchange = exchange, options = options }
            end
        end
    end
    local id = Deck.pick(Dialog.DECK_KEY, ids)
    if not id then return nil end

    local entry = by_id[id]
    local options = {}
    for _i, option in ipairs(shuffle(entry.options)) do
        if #options == MAX_OPTIONS then break end
        options[#options + 1] = {
            id    = option.id,
            text  = option.text(f),
            delta = option.delta,
            recommend = option.recommend,
            accept = option.accept,
            reply = function(reply_tier) return renderReply(option.reply, f, reply_tier) end,
        }
    end
    return { id = id, opener = entry.exchange.opener(f), options = options }
end

--- The lines of the second step of a book suggestion for `book` ({ title,
--- authors }) and a critter in mood tier `tier`: { opener, open_text,
--- another_text, later_text, later_reply = { mood, text, sub? } }.
function Dialog.suggestion(book, f, tier)
    local authors = book.authors and book.authors:gsub("\n", ", ")
    local opener = authors and authors ~= ""
        and string.format(_("Try “%s”, by %s."), book.title, authors)
        or string.format(_("Try “%s”."), book.title)
    return {
        opener       = opener,
        open_text    = _("Open it"),
        another_text = _("Another one"),
        later_text   = notNow(),
        later_reply  = renderReply(LATER_REPLY, f, tier),
    }
end

return Dialog
