local log = {}

log.LEVELS = {
    trace = 10,
    debug = 20,
    info  = 30,
    warn  = 40,
    error = 50,
    fatal = 60,
}

local root = { name = "root", _level = log.LEVELS.info }
local byName = { root = root }

local function newLogger(name)
    local self = { name = name, _level = nil }
    byName[name] = self
    return setmetatable(self, { __index = log })
end

function log.get(name)
    return byName[name] or newLogger(name)
end

function log.setRootLevel(levelName)
    local lvl = log.LEVELS[levelName]
    if not lvl then error("未知日志级别: " .. tostring(levelName)) end
    root._level = lvl
end

function log:setLevel(levelName)
    local lvl = log.LEVELS[levelName]
    if not lvl then error("未知日志级别: " .. tostring(levelName)) end
    self._level = lvl
end

function log:level()
    local name = self.name
    while name do
        local l = byName[name]
        if l and l._level then return l._level end
        name = name:match("^(.*)%.")
    end
    return root._level
end

function log:log(levelName, msg, ...)
    local lvl = log.LEVELS[levelName]
    if lvl < self:level() then return end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    io.stderr:write(string.format("[%s][%s] %s\n", os.date("%H:%M:%S"), levelName, msg))
end

for levelName in pairs(log.LEVELS) do
    log[levelName] = function(self, msg, ...)
        self:log(levelName, msg, ...)
    end
end

return log
