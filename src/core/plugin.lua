local plugin = {}

local function loadChunk(chunk, name)
    local env = setmetatable({}, { __index = _G })
    local fn, err = load(chunk, name, "t", env)
    if not fn then
        error("插件加载失败 [" .. tostring(name) .. "]: " .. tostring(err))
    end
    local ok, mod = xpcall(fn, debug.traceback)
    if not ok then
        error("插件执行失败 [" .. tostring(name) .. "]: " .. tostring(mod))
    end
    if type(mod) ~= "table" then
        error("插件 [" .. tostring(name) .. "] 必须返回一个表")
    end
    return mod
end

function plugin.load(chunk, name)
    return loadChunk(chunk, name or "(plugin)")
end

function plugin.loadFile(path)
    local f = io.open(path, "rb")
    if not f then
        error("插件文件不存在: " .. tostring(path))
    end
    local chunk = f:read("a")
    f:close()
    local name = path:match("([^/]+)%.lua$") or path
    return loadChunk(chunk, name)
end

function plugin.init(pl)
    if pl.init then
        pl:init()
    end
    return pl
end

return plugin
