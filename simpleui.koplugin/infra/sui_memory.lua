-- sui_memory.lua — Simple UI
-- Central memory policy: cache budgets sized to the device, garbage-collection
-- pressure accounting for native buffers, and plugin teardown hooks.
--
-- Blitbuffers live in C memory (calloc), so LuaJIT's collector only counts
-- their small cdata header and has no idea how much RAM a dropped buffer
-- still holds. Caches report the bytes they release here; once enough has
-- piled up, a full collection runs after the UI has been idle for a moment.

local logger    = require("logger")
local UIManager = require("ui/uimanager")

local Memory = {}

local MiB = 1024 * 1024

-- Cache budgets in bytes for a mid-range device (scale 1.0).
local BASE_BUDGETS = {
    covers = 20 * MiB,   -- stretched covers (infra/sui_cover_cache.lua)
    crop   =  4 * MiB,   -- cropped cover slots
    ref    =  4 * MiB,   -- downscaled reference covers
    raster =  3 * MiB,   -- masks, shadows and sprites (infra/sui_raster_cache.lua)
    tilt   =  4 * MiB,   -- warped cover deck slots
}

-- Released bytes that trigger a collection, at scale 1.0.
local BASE_RELEASE_THRESHOLD = 6 * MiB

-- Seconds without further releases before the collection runs.
local IDLE_DELAY = 1.5

-- Scale per total-RAM tier: { exclusive upper bound in bytes, scale }.
local RAM_TIERS = {
    {  384 * MiB, 0.5 },
    {  768 * MiB, 1.0 },
    { 1536 * MiB, 1.5 },
}
local MAX_RAM_SCALE = 2.0

-- Without a RAM reading the scale follows the screen area, since cover and
-- raster buffers grow with it.
local REFERENCE_SCREEN_AREA = 1072 * 1448
local MIN_AREA_SCALE, MAX_AREA_SCALE = 0.5, 1.5

local function _scaleFromRam()
    local ok_util, util = pcall(require, "util")
    if not (ok_util and util and util.calcFreeMem) then return nil end
    local ok, _, total = pcall(util.calcFreeMem)
    total = ok and tonumber(total) or nil
    if not total or total <= 0 then return nil end
    for _, tier in ipairs(RAM_TIERS) do
        if total < tier[1] then return tier[2] end
    end
    return MAX_RAM_SCALE
end

local function _scaleFromScreen()
    local ok, Device = pcall(require, "device")
    local screen = ok and Device and Device.screen
    if not screen then return 1.0 end
    local area = screen:getWidth() * screen:getHeight()
    if area <= 0 then return 1.0 end
    return math.min(MAX_AREA_SCALE, math.max(MIN_AREA_SCALE, area / REFERENCE_SCREEN_AREA))
end

local _scale, _budgets

local function _deviceScale()
    if not _scale then _scale = _scaleFromRam() or _scaleFromScreen() end
    return _scale
end

-- Returns the cache budgets in bytes, keyed by cache name. Computed once per
-- session; the table is shared and must not be modified.
function Memory.budgets()
    if not _budgets then
        _budgets = {}
        for name, bytes in pairs(BASE_BUDGETS) do
            _budgets[name] = math.floor(bytes * _deviceScale())
        end
    end
    return _budgets
end

-- Resident byte size of a Blitbuffer. `stride` is the bytes per row of the
-- underlying C allocation, so `stride * height` is the true RAM footprint,
-- including row padding, at any bit depth (1 byte/px on grayscale e-ink,
-- 4 bytes/px on a colour panel).
function Memory.bbBytes(bb)
    if not bb then return 0 end
    local ok, bytes = pcall(function()
        local h = (bb.getHeight and bb:getHeight()) or tonumber(bb.h) or 0
        local stride = tonumber(bb.stride)
        if stride and h > 0 then return stride * h end
        local w   = (bb.getWidth and bb:getWidth()) or 0
        local bpp = (bb.getBpp and bb:getBpp()) or 8
        return w * h * math.ceil(bpp / 8)
    end)
    return (ok and bytes) or 0
end

-- ---------------------------------------------------------------------------
-- Garbage-collection pressure
-- ---------------------------------------------------------------------------

local _pending_bytes = 0

local function _collect()
    _pending_bytes = 0
    collectgarbage("collect")
end

local function _scheduleCollect()
    UIManager:unschedule(_collect)
    UIManager:scheduleIn(IDLE_DELAY, _collect)
end

-- Reports `bytes` of native memory that were dereferenced and now wait for
-- the collector. Schedules a collection once enough has accumulated.
function Memory.noteReleased(bytes)
    if not bytes or bytes <= 0 then return end
    _pending_bytes = _pending_bytes + bytes
    if _pending_bytes >= BASE_RELEASE_THRESHOLD * _deviceScale() then
        _scheduleCollect()
    end
end

-- Schedules a collection for when the UI goes idle, regardless of how much
-- has been reported. For callers that drop widget trees whose size is unknown.
function Memory.requestCollect()
    _pending_bytes = BASE_RELEASE_THRESHOLD * _deviceScale()
    _scheduleCollect()
end

-- ---------------------------------------------------------------------------
-- Teardown hooks
-- ---------------------------------------------------------------------------

local _reset_hooks = {}

-- Registers `fn` to run on plugin teardown. Modules holding caches or
-- scheduled callbacks register their reset function when they load.
function Memory.onReset(fn)
    for _, registered in ipairs(_reset_hooks) do
        if registered == fn then return end
    end
    _reset_hooks[#_reset_hooks + 1] = fn
end

-- Cancels any pending collection and runs every registered reset hook once,
-- then forgets them so the hooked modules are not kept alive.
function Memory.reset()
    UIManager:unschedule(_collect)
    _pending_bytes = 0
    local hooks = _reset_hooks
    _reset_hooks = {}
    for _, fn in ipairs(hooks) do
        local ok, err = pcall(fn)
        if not ok then logger.warn("simpleui[memory]: reset hook failed:", err) end
    end
end

return Memory
