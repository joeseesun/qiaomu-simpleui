-- sui_screen_nav.lua — Simple UI
-- Leaving the open screen (the built-in Homescreen or a Custom Screen) for
-- another view and coming back to it.
--
-- A screen closed on purpose keeps its cached state (current page, books), so
-- reopening it is a warm start instead of a cold rebuild.
--
-- Public API
-- ----------
--   ScreenNav.handOff(open) -> id?
--       Runs `open`, which shows a widget that closes the open screen by
--       itself, and keeps the screen's state. Returns the id of that screen,
--       nil when none is open.
--   ScreenNav.close()       -> id?
--       Closes the open screen, keeping its state. Returns its id.
--   ScreenNav.reopen(id)
--       Shows the screen `id` again.

local UIManager = require("ui/uimanager")
local UI        = require("infra/sui_core")

local ScreenNav = {}

function ScreenNav.handOff(open)
    local id, screen = UI.getOpenScreen()
    if screen then screen._navbar_closing_intentionally = true end
    open()
    if screen then screen._navbar_closing_intentionally = nil end
    return id
end

function ScreenNav.close()
    local _id, screen = UI.getOpenScreen()
    if not screen then return nil end
    return ScreenNav.handOff(function() pcall(UIManager.close, UIManager, screen) end)
end

-- The built-in Homescreen and the Custom Screens share one engine table,
-- which exposes both ways of showing a screen.
function ScreenNav.reopen(id)
    local ok, ScreenEngine = pcall(require, "screens/sui_homescreen")
    if not (ok and ScreenEngine) then return end
    if id == "hs" then
        ScreenEngine.show()
    elseif ScreenEngine.showCustomScreen then
        ScreenEngine.showCustomScreen(id)
    end
end

return ScreenNav
