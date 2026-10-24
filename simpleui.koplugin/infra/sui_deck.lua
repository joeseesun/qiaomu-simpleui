-- sui_deck.lua — Simple UI
-- Persistent shuffle deck over a changing set of ids: every eligible id is
-- dealt once before any id repeats, and the progress survives restarts.
--
-- The deal is best effort: only ids still eligible are remembered, so an id
-- whose eligibility lapses and returns may come round before the cycle ends.
--
-- Public API:
--   Deck.pick(key, ids)   id from `ids` not dealt yet in this cycle, or nil
--                         when `ids` is empty
--   Deck.reset(key)       forgets the progress stored under `key`

local SUISettings = require("infra/sui_store")
require("random") -- seeds math.random once per process on first load

local Deck = {}

-- Ids already dealt in the current cycle, oldest first.
local function _readDealt(key)
    local state = SUISettings:get(key)
    return type(state) == "table" and type(state.dealt) == "table" and state.dealt or {}
end

function Deck.pick(key, ids)
    local count = #ids
    if count == 0 then return nil end

    local dealt, last = {}, nil
    for _i, id in ipairs(_readDealt(key)) do dealt[id] = true; last = id end

    local fresh = {}
    for _i, id in ipairs(ids) do
        if not dealt[id] then fresh[#fresh + 1] = id end
    end

    -- Cycle complete: start over, never opening with the id just dealt.
    if #fresh == 0 then
        dealt = {}
        for _i, id in ipairs(ids) do
            if id ~= last or count == 1 then fresh[#fresh + 1] = id end
        end
    end

    local picked = fresh[math.random(#fresh)]
    dealt[picked] = true

    -- Keep only ids that are still eligible, so the state stays bounded.
    local keep = {}
    for _i, id in ipairs(ids) do
        if dealt[id] and id ~= picked then keep[#keep + 1] = id end
    end
    keep[#keep + 1] = picked
    SUISettings:setNoFlush(key, { dealt = keep })
    return picked
end

function Deck.reset(key)
    SUISettings:delNoFlush(key)
end

return Deck
