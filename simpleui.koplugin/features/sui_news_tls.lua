-- Scope the Mozilla CA store to news requests.
local M = {}

function M.curlOptions()
    local path = require("infra/sui_paths").getPluginDir() .. "data/ca/cacert.pem"
    -- Pass the explicit path even if missing so curl fails closed.
    return " --cacert '" .. path:gsub("'", "'\\''") .. "'"
end

return M
