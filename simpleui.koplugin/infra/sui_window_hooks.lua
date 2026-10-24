-- sui_window_hooks.lua — Simple UI
--
-- Single hook point for UIManager.show and UIManager.close.
--
-- UIManager receives one wrapper per function, owned by this module. The
-- wrappers hold no behaviour of their own: every reaction to a window being
-- shown or closed is a registered step, run in order.
--
-- A step is a table:
--   id      unique name; registering an existing id replaces that step
--   point   M.POINT.SHOW or M.POINT.CLOSE
--   order   position among the steps of the same point (see M.ORDER);
--           lower runs first
--   match   optional function(widget, ctx) -> boolean. Gates every phase of
--           the step. Evaluated once per call, right before the first phase
--           the step defines runs, so it can read state left in `ctx` by
--           earlier steps. Without it the step always applies.
--
-- Phases of a SHOW step, in call order:
--   intercept  function(widget, plugin, orig_show) -> boolean
--              Runs for every shown widget before anything else, so it must
--              be cheap. Returning true consumes the call. Ignores `match`.
--   enter      function(ctx)  Fullscreen widgets only, before `before`.
--   before     function(ctx)  Before the underlying show.
--   after      function(ctx)  After the underlying show; skipped when the
--              underlying show raised.
--   settled    function(ctx)  After the underlying show, errors included.
--
-- Phases of a CLOSE step:
--   intercept  function(widget, plugin, orig_close) -> boolean
--              Runs for every closed widget before anything else, so it must
--              be cheap. Returning true consumes the call. Ignores `match`.
--   before     function(ctx)  Before the underlying close.
--   after      function(ctx)  After the underlying close; ctx.result holds
--              its return value. Skipped when the underlying close raised.
--
-- Every step phase is isolated: an error in one step is logged and the next
-- step still runs. The underlying function always runs and is never wrapped
-- in a protected call, so its errors propagate to the caller as they would
-- without the hooks.
--
-- Fullscreen widgets only: non-fullscreen widgets go straight to the
-- underlying function (apart from intercept steps).
--
-- `ctx` is created per call and shared by the steps of that call:
--   um, widget  the UIManager and the widget being shown or closed
--   plugin      the live plugin instance when the call started
--   orig        the underlying function, for steps that must bypass the hooks
--   args        extra arguments of the call, with their count in args.n
--   result      return value of the underlying function (after phases)
--   outermost   SHOW only; true when no other show call is in flight
-- Steps may add their own fields to hand data to later steps.

local UIManager = require("ui/uimanager")
local logger    = require("logger")

local _unpack = table.unpack or unpack

local M = {}

M.POINT = { SHOW = "show", CLOSE = "close" }

-- Execution order of the steps (lower runs first), per point.
M.ORDER = {
    show = {
        NATIVE_SHEETS         = 5,
        NATIVE_ARRANGE        = 6,
        COVER_NOTICE          = 10,
        NATIVE_WIDGETS        = 15,
        READER_WIRING         = 20,
        READER_RELOAD         = 30,
        READER_COVER          = 40,
        READER_RELOAD_DONE    = 50,
        NAVBAR                = 60,
        WALLPAPER             = 70,
        NAVPAGER              = 80,
        DISPLACE_SCREEN       = 90,
    },
    close = {
        NATIVE_SHEETS         = 5,
        NATIVE_WIDGETS        = 6,
        NAVBAR_RESTORE        = 10,
        BAR_INJECTION_CLOSE   = 20,
        RELOAD_BLOCKER        = 30,
        LAZY_REFRESH          = 40,
        REOPEN_SCREEN         = 50,
    },
}

-- UIManager field that holds the hook state while the wrappers are installed.
local STATE_FIELD = "_sui_window_hooks"

local _steps = { show = {}, close = {} }

-- ---------------------------------------------------------------------------
-- Step dispatch
-- ---------------------------------------------------------------------------

-- True when `step` applies to the current call. The first evaluation is
-- cached in ctx so every phase of the step sees the same decision.
local function applies(step, widget, ctx)
    local cached = ctx.matched[step]
    if cached == nil then
        cached = not step.match or step.match(widget, ctx) and true or false
        ctx.matched[step] = cached
    end
    return cached
end

local function runStep(step, fn, ctx)
    if applies(step, ctx.widget, ctx) then fn(ctx) end
end

-- Runs `phase` of every applicable step of `point`, in order. A failing step
-- is logged and does not affect the others.
local function runPhase(point, phase, ctx)
    for _, step in ipairs(_steps[point]) do
        local fn = step[phase]
        if fn then
            local ok, err = pcall(runStep, step, fn, ctx)
            if not ok then
                logger.warn("simpleui/window_hooks: step", step.id, phase,
                    "failed:", tostring(err))
            end
        end
    end
end

local function newContext(um, widget, plugin, orig, ...)
    return {
        um = um, widget = widget, plugin = plugin, orig = orig,
        args = { n = select("#", ...), ... }, matched = {},
    }
end

-- ---------------------------------------------------------------------------
-- Wrappers
-- ---------------------------------------------------------------------------

local function newShowWrapper(state)
    local orig  = state.orig_show
    local depth = 0

    return function(um, widget, ...)
        local plugin = state.plugin

        for _, step in ipairs(_steps.show) do
            local intercept = step.intercept
            if intercept and intercept(widget, plugin, orig) then return end
        end

        if not (widget and widget.covers_fullscreen) then
            return orig(um, widget, ...)
        end

        local ctx = newContext(um, widget, plugin, orig, ...)
        ctx.outermost = depth == 0
        runPhase("show", "enter", ctx)
        runPhase("show", "before", ctx)

        depth = depth + 1
        local ok, result = pcall(orig, um, widget, _unpack(ctx.args, 1, ctx.args.n))
        depth = depth - 1

        if ok then
            ctx.result = result
            runPhase("show", "after", ctx)
        end
        runPhase("show", "settled", ctx)
        if not ok then error(result, 0) end
        return ctx.result
    end
end

local function newCloseWrapper(state)
    local orig = state.orig_close

    return function(um, widget, ...)
        for _, step in ipairs(_steps.close) do
            local intercept = step.intercept
            if intercept and intercept(widget, state.plugin, orig) then return end
        end

        if not (widget and widget.covers_fullscreen) then
            return orig(um, widget, ...)
        end

        local ctx = newContext(um, widget, state.plugin, orig, ...)
        runPhase("close", "before", ctx)
        ctx.result = orig(um, widget, ...)
        runPhase("close", "after", ctx)
        return ctx.result
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Registers a step (replacing any step with the same id and point).
function M.register(step)
    assert(step.id and step.order and _steps[step.point],
        "window hook steps need an id, an order and a valid point")
    local list = _steps[step.point]
    for i, existing in ipairs(list) do
        if existing.id == step.id then
            table.remove(list, i)
            break
        end
    end
    local pos = #list + 1
    for i, existing in ipairs(list) do
        if existing.order > step.order then
            pos = i
            break
        end
    end
    table.insert(list, pos, step)
end

--- Installs the wrappers once per session and records `plugin` as the live
--- instance. Repeated calls only refresh the live instance, so a wrapper is
--- never stacked on another one.
function M.install(plugin)
    local state = rawget(UIManager, STATE_FIELD)
    if state then
        state.plugin = plugin
        return
    end
    state = {
        plugin     = plugin,
        orig_show  = UIManager.show,
        orig_close = UIManager.close,
    }
    UIManager[STATE_FIELD] = state
    UIManager.show  = newShowWrapper(state)
    UIManager.close = newCloseWrapper(state)
end

--- Restores the original functions and drops every registered step. Does
--- nothing unless `plugin` is the live instance, so a stale instance tearing
--- down late cannot remove the hooks of the one that replaced it.
function M.uninstall(plugin)
    local state = rawget(UIManager, STATE_FIELD)
    if not (state and state.plugin == plugin) then return end
    UIManager.show        = state.orig_show
    UIManager.close       = state.orig_close
    UIManager[STATE_FIELD] = nil
    _steps = { show = {}, close = {} }
end

--- The UIManager.show that bypasses every step.
function M.origShow()
    local state = rawget(UIManager, STATE_FIELD)
    return state and state.orig_show or UIManager.show
end

--- The UIManager.close that bypasses every step.
function M.origClose()
    local state = rawget(UIManager, STATE_FIELD)
    return state and state.orig_close or UIManager.close
end

return M
