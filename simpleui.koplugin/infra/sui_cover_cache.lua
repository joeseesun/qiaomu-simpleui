-- sui_cover_cache.lua — Simple UI
-- Single-layer LRU of stretched cover bitmaps, keyed by filepath ONLY
-- ("canonical-dim" caching). One entry per book, sized to the LARGEST
-- render dims requested across every consumer in this session.
--
-- This is one of two cover caches in the plugin. The other is the
-- reference cover cache in infra/sui_config.lua (backing
-- Config.getCroppedCoverBB), which crops fresh on every call instead of
-- stretching. Together they replaced an older three-layer design (exact-
-- size cache, uncropped reference cache, separate canonical-3:2 crop
-- cache) that predates this split.
--
-- THIS cache is for every consumer that renders a book at a fixed 3:2
-- aspect and STRETCHES to fit (no crop): Recent, TBR, New Books, Library,
-- Currently, CoverDeck's centre slot, Collections' Single style. It is NOT
-- used by anything that needs an actual crop: Collections' Quad style
-- (~1:1 quadrants, crop-to-fill) and CoverDeck's near/far "peek" slots
-- (deliberately non-3:2 slivers cropped left/right-aligned) both go
-- through the reference cache instead — cropping is a framing decision
-- that depends on target shape, so it can't share a filepath-only entry
-- with this stretch-only group. See infra/sui_config.lua's
-- Config.getCroppedCoverBB for that path.
--
-- Why filepath-only works here (and wouldn't for a crop consumer): every
-- consumer of THIS cache targets the exact same 3:2 aspect ratio. Stretching
-- a book's cover once, to the LARGEST 3:2 box requested so far, and letting
-- every smaller consumer downscale that same 3:2 bitmap at paint time (via
-- ImageWidget's own width/height, no scale_factor) is an EXACT uniform
-- downscale — not an approximation — because source and target share the
-- same aspect. A (filepath, w, h) key, which an exact-size cache needs,
-- produces a separate resident copy per distinct (module, scale) pair for
-- the same book; this collapses all of them into one.
--
-- Put policy: prefer-larger. On put, if an existing entry has at least as
-- many pixels as the incoming bb, the incoming bb is unused (caller must
-- treat it as never cached — free it if they owned it) and the existing
-- entry is kept. If the incoming bb is larger, it replaces the entry. This
-- means the FIRST consumer built in a session seeds the cache at its size;
-- a later, larger consumer (e.g. CoverDeck's hero after Recent's small
-- thumbnail) upgrades it; smaller consumers thereafter read the larger
-- bitmap and downscale. Stable regardless of build order.
--
-- Get returns whatever bb is cached, at ANY dimensions — the caller is
-- responsible for comparing it against its own target slot:
--   * cached >= target in both axes → use it, let ImageWidget downscale
--     at paint time (the safe direction on every device this plugin
--     targets, Kindle included).
--   * cached < target in either axis → treat as a miss: decode+stretch a
--     fresh bb at the target size (which will then upgrade the cache via
--     put's prefer-larger rule). NEVER hand a too-small cached bb to
--     ImageWidget expecting it to upscale — that is the corruption-prone
--     path this module deliberately never takes. See the "Upscale safety"
--     note below.
--
-- Lifetime: the cache holds a strong reference to each cached bb. Callers
-- pass it to ImageWidget with image_disposable = false. When the cache
-- drops an entry (eviction or prefer-larger replace) it only nils its own
-- reference — it does NOT call bb:free(). Other live widgets may still
-- hold that bb (e.g. a Recent thumbnail whose shared entry just got
-- upgraded to CoverDeck-hero dimensions by a later put); an explicit free
-- here would yank the C memory out from under those widgets' next partial
-- repaint. Blitbuffer sets up an ffi.gc finalizer at allocation time (see
-- ffi/blitbuffer.lua's setAllocated(1)), so the underlying C memory is
-- reclaimed automatically once every Lua reference is gone. The dropped
-- bytes are reported to infra/sui_memory.lua, which schedules the
-- collection that actually returns them. Slight memory-reclaim latency,
-- never a use-after-free.
--
-- clear() follows the same rule — it drops references, it doesn't free.
--
-- Upscale safety: this cache never performs, and never asks ImageWidget to
-- perform, an upscale of a bb that's smaller than the requested slot.
-- SimpleUI's own cover-scaling code (infra/sui_config.lua's
-- _scaleBBToSlot) already documents blitbuffer corruption ("TV static" on
-- repaint) tied to exactly this class of mistake — ownership confusion
-- around scale/free on a buffer that's reused across calls. The contract
-- this module expects from its caller is: only ever call get() to decide
-- whether a fresh decode+stretch is needed; only ever call put() with a bb
-- that was just produced by a stretch to AT LEAST the caller's own target
-- size. Never construct an ImageWidget from a get() result that is smaller
-- than the target slot.

local logger = require("logger")
local LRU    = require("infra/sui_lru")
local Memory = require("infra/sui_memory")

-- Per-cover cache logging is verbose (one line per PUT) and, because Lua
-- evaluates the string.format() argument before logger.dbg can discard it at
-- the info level, the format cost is paid on every cover even with debug
-- logging off. Gate it behind a constant so production pays nothing; flip to
-- true when diagnosing cache churn.
local _PERF_LOG = false

-- Entry-count backstop for pathological many-tiny-covers cases; the byte
-- budget (sized to the device by infra/sui_memory.lua) binds first for
-- normal covers.
local MAX_ENTRIES = 512

-- Entries are { bb, revision }. Revisions come from one session-wide counter,
-- so a revision is never reused, even after its entry has left the cache.
local _last_revision = 0

local SUICoverCache = {
    _lru  = LRU.new{ max_entries = MAX_ENTRIES, max_bytes = Memory.budgets().covers },
    _hits = 0,   -- perf: cache hits this session
    _puts = 0,   -- perf: cache misses (fresh stretch) this session
}

local function _pixels(bb)
    return (bb.getWidth and bb:getWidth() or 0) * (bb.getHeight and bb:getHeight() or 0)
end

-- get(filepath) — returns the cached bb (at whatever dimensions it was last
-- put at) or nil. On hit, the entry is promoted to MRU. Caller MUST compare
-- the returned bb's dimensions against its own target slot — see the
-- "Upscale safety" note at the top of this file.
function SUICoverCache:get(filepath)
    if not filepath or filepath == "" then return nil end
    local entry = self._lru:get(filepath)
    if not entry then return nil end
    self._hits = self._hits + 1
    return entry.bb
end

-- revision(filepath) — identifies the cover currently cached for filepath.
-- It changes when a cover is installed into an empty slot (first load, or
-- after an eviction or drop) and stays put when put() only enlarges it, so
-- derived rasters stay valid across enlargements and are rebuilt otherwise.
function SUICoverCache:revision(filepath)
    local entry = self._lru:peek(filepath)
    return entry and entry.revision or 0
end

-- has(filepath) — boolean probe. Doesn't touch MRU order or counters. Lets
-- a caller skip a slow BookInfoManager decode when the cover is already
-- resident (the cache-first check should still call get() to actually use
-- the bb — this is only for "is it worth trying the fast path at all").
function SUICoverCache:has(filepath)
    if not filepath or filepath == "" then return false end
    return self._lru:has(filepath)
end

-- put(filepath, bb) — insert or upgrade. Returns the bb now serving as the
-- cache entry for filepath, which is NOT always the bb the caller passed
-- in. Prefer-larger semantics:
--   * No existing entry: cache the new bb. Returns new bb.
--   * Existing entry with >= pixel count: keep existing, return the
--     existing bb. The caller's bb is unused — the caller MUST treat the
--     passed-in bb as if it were never put (don't hand it to an
--     ImageWidget expecting cache ownership; free() it if the caller
--     owned it and has no other use for it).
--   * Existing entry with < pixel count: install new as the cache entry.
--     The existing bb is no longer in the cache but is NOT freed — other
--     widgets may still hold references and need to paint with it before
--     LuaJIT's FFI finalizer reclaims it. Returns new bb.
--
-- Callers should use the return value to decide what to paint with; this
-- avoids a redundant get() round-trip and makes the discard case explicit
-- at the call site.
function SUICoverCache:put(filepath, bb)
    if not filepath or filepath == "" or not bb then return bb end
    local existing = self._lru:peek(filepath)
    if existing and existing.bb == bb then return bb end  -- identity put (no-op)
    if existing and _pixels(existing.bb) >= _pixels(bb) then
        self._lru:get(filepath)  -- keep existing; touch MRU
        return existing.bb
    end
    -- A cover installed into an empty slot may differ from the previous one;
    -- an upgrade only enlarges the same cover and keeps the revision.
    local revision = existing and existing.revision
    if not revision then
        _last_revision = _last_revision + 1
        revision = _last_revision
    end
    self._puts = self._puts + 1
    self._lru:put(filepath, { bb = bb, revision = revision }, Memory.bbBytes(bb))
    if _PERF_LOG then logger.dbg(string.format(
        "[simpleui perf] SUICoverCache: PUT fp=%s %dx%d size=%d/%d bytes=%d/%d hits=%d puts=%d",
        filepath, bb:getWidth(), bb:getHeight(),
        self._lru:count(), MAX_ENTRIES, self._lru:bytes(), Memory.budgets().covers,
        self._hits, self._puts)) end
    return bb
end

-- drop(filepath) — surgical eviction for a single book. For callers that
-- know that book's source cover changed out of band (manual cover
-- override, metadata refresh) and the next render must re-decode rather
-- than serve a stale stretched bb. Same lifetime contract as put/clear:
-- drops the reference, doesn't bb:free().
function SUICoverCache:drop(filepath)
    if not filepath or filepath == "" then return end
    self._lru:remove(filepath)
end

-- clear() — drop every cached reference. Same lifetime contract as put: we
-- do NOT explicitly free; live widgets may still be holding bbs. LuaJIT
-- reclaims once every reference is gone.
function SUICoverCache:clear()
    if _PERF_LOG then logger.dbg(string.format(
        "[simpleui perf] SUICoverCache: clear hits=%d puts=%d", self._hits, self._puts)) end
    self._lru:clear()
    self._hits = 0
    self._puts = 0
end

return SUICoverCache
