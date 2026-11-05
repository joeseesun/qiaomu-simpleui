-- sui_arrivals.lua — Simple UI
-- Books delivered over Wi-Fi (乔木 Kindle 助手 / any SSH or SFTP sender)
-- land in a folder while KOReader is running, and KOReader receives no event
-- for that. This file owns two things:
--
--   1. Where those books are: Arrivals.resolveDir() — the "我的文章" folder
--      under the library home (or the Kindle documents root).
--   2. A cheap watcher that keeps a visible screen current:
--      Arrivals.watch(screen) / Arrivals.stop(screen) / Arrivals.check(screen)
--
-- Power budget (single-core PW1/PW3): one tick every INTERVAL seconds, only
-- while the screen is in front of the reader. A tick is one stat() per
-- watched directory (the arrivals folder and the home root). Only when a
-- directory mtime changed is that one directory listed, and the screen is
-- repainted only when its visible book/folder names differ. Hidden entries
-- (".receiving-1234", ".Trash", dotfiles) never count, so a half-written
-- transfer triggers no repaint; the final rename does.
--
-- The timer stops when the screen is closed, parked under the reader,
-- suspended or covered; ScreenWidget:onResume / onShow / unpark re-arm it,
-- and re-arming checks once immediately so a book that arrived meanwhile
-- shows up on wake.

local lfs = require("libs/libkoreader-lfs")

local Arrivals = {}

Arrivals.DIR_NAME     = "我的文章"
Arrivals.INTERVAL     = 12   -- seconds between ticks while in front
Arrivals.SETTING_KEY  = "simpleui_arrivals_autorefresh"
-- Kindle's documents root, used when the library home points elsewhere.
Arrivals.FALLBACK_ROOTS = { "/mnt/us/documents" }

-- Modules whose content depends on what is in the library folders. A screen
-- showing none of them has nothing to refresh and is never polled.
Arrivals.LIBRARY_MODULES = { "flat_library", "new_books" }

local function joinPath(parent, child)
    if parent:sub(-1) == "/" then return parent .. child end
    return parent .. "/" .. child
end

local function isDir(path)
    return path and lfs.attributes(path, "mode") == "directory"
end

local function libraryScan()
    return require("engines/sui_library_scan")
end

--- The arrivals folder, or nil while it does not exist yet (the first
--- transfer creates it). Checked under the library home first.
function Arrivals.resolveDir(home)
    home = home or libraryScan().resolveHomeDir()
    if home and home ~= "" then
        local p = joinPath(home, Arrivals.DIR_NAME)
        if isDir(p) then return p end
    end
    for _, root in ipairs(Arrivals.FALLBACK_ROOTS) do
        local p = joinPath(root, Arrivals.DIR_NAME)
        if isDir(p) then return p end
    end
    return nil
end

--- Whether a directory entry name can ever be a visible library item.
--- Hidden names (in-flight ".receiving-*" temp files included) and .sdr
--- sidecars (created when a book is opened) never count.
function Arrivals.isVisibleName(name)
    if not name or name == "" or name:sub(1, 1) == "." then return false end
    if name:sub(-4) == ".sdr" then return false end
    return true
end

local function isBookName(name)
    local ext = name:match("%.([^%.]+)$")
    return ext ~= nil and libraryScan().BOOK_EXTS[ext:lower()] == true
end

--- Sorted, newline-joined names of the books and folders directly inside
--- `dir` that a library scan would show. Only computed after the
--- directory's mtime changed, so the listing cost is paid once per change.
function Arrivals.listingSignature(dir)
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok or type(iter) ~= "function" then return "" end
    local names = {}
    for name in iter, dir_obj do
        if Arrivals.isVisibleName(name) then
            if isBookName(name) or isDir(joinPath(dir, name)) then
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)
    return table.concat(names, "\n")
end

--- Directories a tick stats: the arrivals folder (when present) and the
--- library home root, which changes when the arrivals folder is created.
function Arrivals.watchedDirs()
    local Scan = libraryScan()
    local home = Scan.resolveHomeDir()
    local dirs, seen = {}, {}
    local function add(p)
        if p and not seen[p] and isDir(p) then
            seen[p] = true
            dirs[#dirs + 1] = p
        end
    end
    add(Arrivals.resolveDir(home))
    add(home)
    return dirs
end

--- Fresh state for `dirs`: { [dir] = { mtime =, sig = } }.
function Arrivals.snapshot(dirs)
    local state = {}
    for _, d in ipairs(dirs or Arrivals.watchedDirs()) do
        state[d] = {
            mtime = lfs.attributes(d, "modification"),
            sig   = Arrivals.listingSignature(d),
        }
    end
    return state
end

--- Compares `state` with the filesystem, updating it in place. Returns true
--- when a visible book or folder appeared, disappeared or was renamed.
--- A directory not tracked yet (e.g. "我的文章" just created) is a change.
function Arrivals.detectChange(state)
    local changed = false
    for _, d in ipairs(Arrivals.watchedDirs()) do
        local rec = state[d]
        local mtime = lfs.attributes(d, "modification")
        if not rec then
            state[d] = { mtime = mtime, sig = Arrivals.listingSignature(d) }
            changed = true
        elseif rec.mtime ~= mtime then
            rec.mtime = mtime
            local sig = Arrivals.listingSignature(d)
            if sig ~= rec.sig then
                rec.sig = sig
                changed = true
            end
        end
    end
    return changed
end

-- ---------------------------------------------------------------------------
-- Screen watcher
-- ---------------------------------------------------------------------------

local function settings()
    return require("infra/sui_store")
end

function Arrivals.isEnabled()
    local S = settings()
    if S.nilOrTrue then return S:nilOrTrue(Arrivals.SETTING_KEY) end
    return S:readSetting(Arrivals.SETTING_KEY) ~= false
end

-- Whether `screen` shows a module that lists library files.
function Arrivals.screenWantsWatch(screen)
    local ok, Registry = pcall(require, "modules/moduleregistry")
    if not ok or not Registry then return false end
    local pfx = screen and screen._pfx or "simpleui_hs_"
    for _, id in ipairs(Arrivals.LIBRARY_MODULES) do
        local mod = Registry.get(id)
        if mod and Registry.isEnabled(mod, pfx) then return true end
    end
    return false
end

local function deviceAsleep()
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.screen_saver_mode then return true end
    local FM = package.loaded["apps/filemanager/filemanager"]
    local plugin = FM and FM.instance and FM.instance._simpleui_plugin
    return plugin ~= nil and plugin._simpleui_suspended == true
end

-- True while `screen` can be seen: open, not parked under the reader, not
-- suspended, and no dialog/menu/fullscreen window above it. Toasts and
-- invisible helpers above it don't count.
function Arrivals.isInFront(screen)
    if not screen or screen._suspended or screen._parked then return false end
    if screen.isActive and not screen:isActive() then return false end
    local UIManager = require("ui/uimanager")
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return true end
    local idx
    for i = #stack, 1, -1 do
        if stack[i].widget == screen then idx = i; break end
    end
    if not idx then return false end
    for i = idx + 1, #stack do
        local w = stack[i].widget
        if w and not w.invisible and not w.toast then return false end
    end
    return true
end

-- Drops every cached library listing and repaints `screen` with fresh rows.
function Arrivals.refreshScreen(screen)
    libraryScan().invalidate()
    local Sources = package.loaded["engines/sui_book_sources"]
    if Sources and Sources.invalidate then pcall(Sources.invalidate, "new_books") end
    if screen and screen._refreshImmediate then
        -- keep_cache=true: clears every row's memoised file list (and the
        -- page header cache) but keeps covers/titles already prefetched, so
        -- the repaint costs one rebuild, not a full cold open.
        screen:_refreshImmediate(true)
    end
end

--- One check now. Returns true when the screen was repainted.
function Arrivals.check(screen)
    if not screen then return false end
    if not screen._arrivals_state then
        screen._arrivals_state = Arrivals.snapshot()
        return false
    end
    -- A repaint is already queued; _refreshImmediate would cancel it. Leave
    -- the baseline untouched so the next tick still sees the change.
    if screen._refresh_scheduled then return false end
    if Arrivals.detectChange(screen._arrivals_state) then
        local logger = require("logger")
        logger.info("simpleui: arrivals: library folder changed, refreshing", tostring(screen._id))
        Arrivals.refreshScreen(screen)
        return true
    end
    return false
end

function Arrivals.stop(screen)
    if screen and screen._arrivals_timer then
        require("ui/uimanager"):unschedule(screen._arrivals_timer)
        screen._arrivals_timer = nil
    end
end

local function liveInstance(screen)
    local SE = package.loaded["engines/sui_screen_engine"]
    if not (SE and SE.getInstance) then return true end
    local ok, inst = pcall(SE.getInstance, screen._id)
    return not ok or inst == nil or inst == screen
end

--- Starts (or restarts) polling for `screen`. Checks once right away when
--- a baseline already exists, so books that arrived while the screen was
--- hidden or the device asleep appear immediately.
function Arrivals.watch(screen)
    if not screen then return end
    Arrivals.stop(screen)
    if not Arrivals.isEnabled() or not Arrivals.screenWantsWatch(screen) then return end
    if screen._suspended or screen._parked then return end

    Arrivals.check(screen)

    local UIManager = require("ui/uimanager")
    local timer
    timer = function()
        if screen._arrivals_timer ~= timer then return end
        screen._arrivals_timer = nil
        if not liveInstance(screen) or deviceAsleep()
                or screen._suspended or screen._parked
                or (screen.isActive and not screen:isActive()) then
            return  -- stopped; onShow/onResume/unpark re-arm it
        end
        -- Covered by a menu or dialog: skip the I/O, keep the baseline; the
        -- change is picked up by the first tick after it closes.
        if Arrivals.isInFront(screen) then Arrivals.check(screen) end
        screen._arrivals_timer = timer
        UIManager:scheduleIn(Arrivals.INTERVAL, timer)
    end
    screen._arrivals_timer = timer
    UIManager:scheduleIn(Arrivals.INTERVAL, timer)
end

return Arrivals
