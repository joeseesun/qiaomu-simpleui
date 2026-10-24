-- sui_lru.lua — Simple UI
-- Least-recently-used cache with O(1) get, put and eviction, bounded by entry
-- count and/or by bytes. Shared by every cache in the plugin.
--
-- Keys may be grouped in a scope (a second-level key such as a cache kind or
-- a file path). Lookups never allocate, and a whole scope can be dropped at
-- once with removeScope().
--
-- Ownership policy. When an entry leaves the cache (eviction, replacement,
-- removal or clear):
--   * with `free` set, the cache owns the value and `free(value)` releases it;
--   * without it, the value may still be held elsewhere (for example by a
--     widget), so the cache only drops its reference and reports the bytes to
--     Memory, which schedules a collection when enough has piled up.
--
-- The most recently used entry is never evicted, so a value larger than the
-- budget survives until the next insertion.
--
--   local cache = LRU.new{ max_bytes = 4 * 1024 * 1024 }
--   cache:put(key, value, bytes)       -- returns value
--   cache:get(key)                     -- promotes to most recently used
--   cache:peek(key)                    -- no promotion

local logger = require("logger")
local Memory = require("infra/sui_memory")

local LRU = {}
LRU.__index = LRU

-- opts.max_entries  maximum number of entries (optional)
-- opts.max_bytes    maximum total bytes (optional)
-- opts.free         function(value) releasing an evicted value (optional)
function LRU.new(opts)
    local head, tail = {}, {}   -- sentinels: head.next is the MRU, tail.prev the LRU
    head.next, tail.prev = tail, head
    return setmetatable({
        _max_entries = opts and opts.max_entries,
        _max_bytes   = opts and opts.max_bytes,
        _free        = opts and opts.free,
        _head        = head,
        _tail        = tail,
        _nodes       = {},   -- key -> node, for unscoped entries
        _scopes      = {},   -- scope -> { key -> node }
        _count       = 0,
        _bytes       = 0,
    }, LRU)
end

local function _index(self, scope, create)
    if scope == nil then return self._nodes end
    local idx = self._scopes[scope]
    if not idx and create then
        idx = {}
        self._scopes[scope] = idx
    end
    return idx
end

local function _unlink(node)
    node.prev.next = node.next
    node.next.prev = node.prev
end

local function _pushFront(self, node)
    local first = self._head.next
    node.prev, node.next = self._head, first
    self._head.next = node
    first.prev = node
end

local function _promote(self, node)
    if self._head.next == node then return end
    _unlink(node)
    _pushFront(self, node)
end

-- Hands a departed value back: explicit release when the cache owns it,
-- otherwise a GC pressure report.
local function _release(self, node)
    if self._free then
        local ok, err = pcall(self._free, node.value)
        if not ok then logger.warn("simpleui[lru]: free failed:", err) end
    else
        Memory.noteReleased(node.bytes)
    end
end

-- Takes a node out of the list, the index and the accounting.
local function _detach(self, node)
    _unlink(node)
    local idx = _index(self, node.scope)
    idx[node.key] = nil
    if node.scope ~= nil and next(idx) == nil then self._scopes[node.scope] = nil end
    self._count = self._count - 1
    self._bytes = self._bytes - node.bytes
end

local function _discard(self, node)
    _detach(self, node)
    _release(self, node)
end

local function _evictOverLimits(self)
    local max_entries, max_bytes = self._max_entries, self._max_bytes
    while self._count > 1
          and ((max_entries and self._count > max_entries)
               or (max_bytes and self._bytes > max_bytes)) do
        _discard(self, self._tail.prev)
    end
end

-- Returns the value stored under (key, scope) and makes it the most recently
-- used, or nil on a miss.
function LRU:get(key, scope)
    local idx = _index(self, scope)
    local node = idx and idx[key]
    if not node then return nil end
    _promote(self, node)
    return node.value
end

-- Same as get() without changing the recency order.
function LRU:peek(key, scope)
    local idx = _index(self, scope)
    local node = idx and idx[key]
    return node and node.value
end

function LRU:has(key, scope)
    local idx = _index(self, scope)
    return idx ~= nil and idx[key] ~= nil
end

-- Stores `value` (`bytes` resident, default 0) under (key, scope) as the most
-- recently used entry and evicts the least recently used ones while a limit
-- is exceeded. A previous value under the same key leaves the cache, unless
-- it is the same value. Returns `value`.
function LRU:put(key, value, bytes, scope)
    local idx = _index(self, scope, true)
    local old = idx[key]
    if old then
        if old.value == value then
            _promote(self, old)
            return value
        end
        _discard(self, old)
        idx = _index(self, scope, true)   -- the scope table is gone when `old` was its last entry
    end
    local node = { key = key, scope = scope, value = value, bytes = bytes or 0 }
    idx[key] = node
    _pushFront(self, node)
    self._count = self._count + 1
    self._bytes = self._bytes + node.bytes
    _evictOverLimits(self)
    return value
end

-- Removes one entry. Returns true when it existed.
function LRU:remove(key, scope)
    local idx = _index(self, scope)
    local node = idx and idx[key]
    if not node then return false end
    _discard(self, node)
    return true
end

-- Removes every entry stored under `scope`.
function LRU:removeScope(scope)
    local idx = scope ~= nil and self._scopes[scope]
    if not idx then return end
    local nodes = {}
    for _, node in pairs(idx) do nodes[#nodes + 1] = node end
    for _, node in ipairs(nodes) do _discard(self, node) end
end

-- Removes every entry for which `predicate(key, scope)` is true.
function LRU:removeWhere(predicate)
    local doomed = {}
    for _, node in pairs(self._nodes) do
        if predicate(node.key, nil) then doomed[#doomed + 1] = node end
    end
    for scope, idx in pairs(self._scopes) do
        for _, node in pairs(idx) do
            if predicate(node.key, scope) then doomed[#doomed + 1] = node end
        end
    end
    for _, node in ipairs(doomed) do _discard(self, node) end
end

-- Removes every entry.
function LRU:clear()
    local node, tail = self._head.next, self._tail
    self._head.next, tail.prev = tail, self._head
    self._nodes, self._scopes = {}, {}
    self._count, self._bytes = 0, 0
    while node ~= tail do
        local following = node.next
        _release(self, node)
        node = following
    end
end

function LRU:count() return self._count end
function LRU:bytes() return self._bytes end

return LRU
