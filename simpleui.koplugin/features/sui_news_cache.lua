-- Only manages SimpleUI news files; books and their sidecars are never scanned.
local lfs = require("libs/libkoreader-lfs")
local M = { LIMIT = 512 * 1024 * 1024, MIN_FREE = 256 * 1024 * 1024 }
local reserved = 0
local root_dir
function M.root()
    if root_dir then return root_dir end
    local root = require("datastorage"):getSettingsDir() .. "/simpleui/news"
    require("util").makePath(root .. "/articles")
    require("util").makePath(root .. "/images")
    root_dir=root
    return root_dir
end
local function files(state)
    local result = {}
    for _, dir in ipairs{ "articles", "images" } do
        for name in lfs.dir(M.root() .. "/" .. dir) do
            local id = dir == "articles" and name:match("^([%w_-]+)%.json$")
            if id and #id>128 then id=nil end
            local digest,ext=name:match("^([a-f0-9]+)%.([a-z]+)$")
            local part=name:match("^([a-f0-9]+)%.part%.%d+$")
            local image = dir == "images" and ((digest and #digest==64 and ({png=true,jpg=true,gif=true,webp=true})[ext])
                or (part and #part==64))
            if id or image then
                local path = M.root() .. "/" .. dir .. "/" .. name
                local a = (lfs.symlinkattributes or lfs.attributes)(path)
                if a and a.mode == "file" then
                    result[#result+1] = { path=path, bytes=a.size, time=a.modification or 0,
                        id=id, pinned=(id and state and (state.flags[id] or {}).starred)
                            or (part and (a.modification or 0)>os.time()-60) }
                end
            end
        end
    end
    return result
end
local function inventory(state)
    local bytes = 0
    local candidates=files(state)
    for _, f in ipairs(candidates) do bytes = bytes + f.bytes end
    local index = lfs.attributes(M.root() .. "/index.json")
    bytes = bytes + (index and index.size or 0)
    local ok, total, free = pcall(function() return require("ffi/util").df(M.root()) end)
    return { bytes=bytes, limit=M.LIMIT, free=ok and free or nil, total=ok and total or nil },candidates
end
function M.stats() return (inventory()) end
function M.makeRoom(incoming, state, clear)
    local info,candidates = inventory(state)
    local target = clear and 0 or M.LIMIT - 1024*1024 - incoming - reserved
    table.sort(candidates, function(a,b)
        -- Image copies are expendable; saved article text is pinned.
        if not not a.id ~= not not b.id then return not a.id end
        if a.time ~= b.time then return a.time < b.time end
        return a.path < b.path
    end)
    local bytes, freed = info.bytes, 0
    for _, f in ipairs(candidates) do
        local enough_disk = not info.free or info.free + freed - incoming - reserved >= M.MIN_FREE
        if not clear and bytes <= target and enough_disk then break end
        if not f.pinned and os.remove(f.path) then
            bytes=bytes-f.bytes;freed=freed+f.bytes
            if f.id and state and state.flags[f.id] then state.flags[f.id].offline=false end
        end
    end
    if info.free and info.free + freed - incoming - reserved < M.MIN_FREE then return false end
    return bytes <= target
end
function M.reserve(bytes, state)
    if not M.makeRoom(bytes,state) then return end
    reserved=reserved+bytes
    local released=false
    return function()
        if not released then reserved=reserved-bytes;released=true end
    end
end
function M.touch(path)
    if lfs.touch then pcall(lfs.touch,path) end
end
return M
