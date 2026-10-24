-- sui_fonts.lua — Simple UI
--
-- Font families shipped inside the plugin. Registers their files in
-- KOReader's font lists so the font pickers (features/sui_style.lua) treat
-- them like any installed family, and owns the settings keys and the family
-- names shared by the pickers and the defaults.

local logger = require("logger")

local _plugin_dir = require("infra/sui_paths").getPluginDir()

local M = {}

-- Settings keys of the UI Font picker.
M.KEY_ENABLED = "simpleui_ui_font_enabled"
M.KEY_NAME    = "simpleui_ui_font_name"

-- Family name as reported by the font files' metadata.
M.FAMILY = "Inter 18pt"

-- Pixel-art family (a single Regular weight; bold text is emboldened).
M.PIXEL_FAMILY = "Geist Pixel"

-- Bundled families: { name, dir, files, regular?, bold? }. `regular` and `bold`
-- are the files Font:getFace() should treat as the weights of one another.
local INTER_DIR = _plugin_dir .. "fonts/inter"
local PIXEL_DIR = _plugin_dir .. "fonts/Geist_Pixel"
local FAMILIES = {
    {
        name    = M.FAMILY,
        dir     = INTER_DIR,
        regular = INTER_DIR .. "/Inter_18pt-Regular.ttf",
        bold    = INTER_DIR .. "/Inter_18pt-Bold.ttf",
        files   = {
            INTER_DIR .. "/Inter_18pt-Regular.ttf",
            INTER_DIR .. "/Inter_18pt-Bold.ttf",
            INTER_DIR .. "/Inter_18pt-Italic.ttf",
            INTER_DIR .. "/Inter_18pt-BoldItalic.ttf",
        },
    },
    {
        name  = M.PIXEL_FAMILY,
        dir   = PIXEL_DIR,
        files = { PIXEL_DIR .. "/GeistPixel-Regular.ttf" },
    },
}

-- True when crengine already lists the family `name`.
local function creKnowsFamily(cre, name)
    for _i, face in ipairs(cre.getFontFaces()) do
        if face == name then return true end
    end
    return false
end

-- Adds the family's files to FontList, once. FontList must be initialised first:
-- its lazy scan is skipped as soon as the list holds an entry.
local function registerInFontList(family)
    local FontList = require("fontlist")
    FontList:getFontList()
    if FontList.fontinfo[family.files[1]] then return end
    FontList:_readList(family.dir, {})
    table.sort(FontList.fontlist)
end

-- Makes crengine list the family. The engine registers every FontList entry
-- when it initialises; fonts added after that need an explicit registration.
local function registerInCre(family)
    local cre = require("document/credocument"):engineInit()
    if creKnowsFamily(cre, family.name) then return end
    for _i, path in ipairs(family.files) do
        local ok, err = pcall(cre.registerFont, path)
        if not ok then logger.err("simpleui/fonts: failed to register", path, err) end
    end
    cre.regularizeRegisteredFontsWeights(false)
end

-- Lets Font:getFace() recognise the bold file as the real bold of the regular
-- one, so bold text drawn with the regular face is not emboldened twice.
local function linkBoldVariant(family)
    if not (family.regular and family.bold) then return end
    local Font = require("ui/font")
    Font.bold_font_variant[family.regular] = family.bold
    Font.regular_font_variant[family.bold] = family.regular
end

--- Registers the bundled families. Idempotent; safe to call on every start.
--- Returns true when every family registered.
function M.register()
    local all_ok = true
    for _i, family in ipairs(FAMILIES) do
        local ok, err = pcall(function()
            registerInFontList(family)
            registerInCre(family)
            linkBoldVariant(family)
        end)
        if not ok then
            all_ok = false
            logger.warn("simpleui/fonts: bundled font registration failed:", family.name, err)
        end
    end
    return all_ok
end

--- Removes what register() added to FontList and Font. crengine keeps the
--- family it already loaded; the picker hides it once its files are gone.
function M.unregister()
    local FontList = package.loaded["fontlist"]
    if FontList then
        local mine = {}
        for _i, family in ipairs(FAMILIES) do
            for _j, path in ipairs(family.files) do
                mine[path] = true
                FontList.fontinfo[path] = nil
            end
        end
        for i = #FontList.fontlist, 1, -1 do
            if mine[FontList.fontlist[i]] then table.remove(FontList.fontlist, i) end
        end
    end
    local Font = package.loaded["ui/font"]
    if Font then
        for _i, family in ipairs(FAMILIES) do
            if family.regular and family.bold then
                Font.bold_font_variant[family.regular] = nil
                Font.regular_font_variant[family.bold] = nil
            end
        end
    end
end

return M
