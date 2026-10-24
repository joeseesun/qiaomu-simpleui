-- sui_perf.lua — Simple UI
-- Opt-in timing marks for the reader → screen return. Enabled by the setting
-- simpleui_debug_return_timing; each mark logs the milliseconds since
-- Perf.begin() and the resident memory of the process (Linux only).

local UIManager   = require("ui/uimanager")
local logger      = require("logger")
local time        = require("ui/time")
local SUISettings = require("infra/sui_store")

local KEY = "simpleui_debug_return_timing"

local Perf = {}

-- The start time lives on UIManager: plugin modules are unloaded on every
-- plugin teardown, which happens between the reader close and the screen show.
local FIELD = "_simpleui_perf_t0"

local function _rssKb()
    local f = io.open("/proc/self/statm", "r")
    if not f then return nil end
    local _, resident = f:read("*n", "*n")
    f:close()
    return resident and resident * 4 or nil
end

function Perf.enabled()
    return SUISettings:isTrue(KEY)
end

-- Starts a new sequence; later marks are relative to this call.
function Perf.begin(label)
    if not Perf.enabled() then UIManager[FIELD] = nil; return end
    UIManager[FIELD] = time.now()
    logger.info("simpleui[perf]: begin", label, "rss_kb=", _rssKb())
end

-- Logs the time elapsed since begin(). No-op outside a running sequence.
function Perf.mark(label)
    local t0 = UIManager[FIELD]
    if not t0 then return end
    logger.info("simpleui[perf]:", label, "+ms=", time.to_ms(time.since(t0)), "rss_kb=", _rssKb())
end

-- Ends the running sequence.
function Perf.finish(label)
    Perf.mark(label)
    UIManager[FIELD] = nil
end

return Perf
