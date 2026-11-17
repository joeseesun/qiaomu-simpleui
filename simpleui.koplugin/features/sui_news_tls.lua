-- Scope the Mozilla CA store to news requests.
local M = {}

function M.curlOptions()
    local path = require("infra/sui_paths").getPluginDir() .. "data/ca/cacert.pem"
    local file = io.open(path, "rb")
    local first_byte = file and file:read(1)
    if file then file:close() end
    if not first_byte then return nil, "CA bundle could not be read; reinstall the complete plugin" end
    -- curl validates the nonempty bundle and the server certificate.
    return " --cacert '" .. path:gsub("'", "'\\''") .. "'"
end

return M
