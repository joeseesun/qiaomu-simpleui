-- sui_virtual_paths.lua — Simple UI
--
-- Bridges real book paths and the virtual paths exposed by an optional
-- virtual-library provider. When no provider is active every function returns
-- its input unchanged, so callers need no provider checks of their own.
--
--   VirtualPaths.isVirtual(fp)  true when fp is a virtual path
--   VirtualPaths.toVirtual(fp)  the virtual path for a real fp, or fp itself
--                               when it is already virtual or has no mapping
--
-- Documents must be opened and looked up through their virtual path, so the
-- provider can resolve covers, sidecars and protected content.

local logger = require("logger")

local M = {}

local PROVIDER_ID    = "kobo_plugin"
local VIRTUAL_PREFIX = "KOBO_VIRTUAL://"

-- The provider's virtual library, or nil when it is not active.
local function virtualLibrary()
    local ok, PluginLoader = pcall(require, "pluginloader")
    if not ok or not PluginLoader then return nil end
    local provider = PluginLoader:getPluginInstance(PROVIDER_ID)
    return provider and provider.virtual_library
end

function M.isVirtual(filepath)
    return type(filepath) == "string" and filepath:sub(1, #VIRTUAL_PREFIX) == VIRTUAL_PREFIX
end

function M.toVirtual(filepath)
    if not filepath or M.isVirtual(filepath) then return filepath end
    local library = virtualLibrary()
    if not library then return filepath end
    -- Path mappings are built lazily on first access.
    if not next(library.virtual_to_real) then
        local ok, err = pcall(library.buildPathMappings, library)
        if not ok then
            logger.warn("simpleui/virtual_paths: building path mappings failed:", err)
            return filepath
        end
    end
    return library:getVirtualPath(filepath) or filepath
end

return M
