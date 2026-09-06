local moonbus = require("core.moonbus")
local event = require("core.event")

---@class Platform
local Platform = {}
Platform.__index = Platform

function Platform.new(opts)
    opts = opts or {}
    return setmetatable({
        type = opts.type or "unknown",
    }, Platform)
end

function Platform.start(_self)
end

function Platform.stop(_self)
end

function Platform.send(self, _ch, _content)
    error("Platform:send 未实现 (" .. tostring(self.type) .. ")")
end

function Platform.resolveLevel(_self, _ch, _senderId)
    return 0
end

function Platform.emit(_self, e)
    moonbus:emit(e)
end

function Platform.makeEvent(_self, type, channel, sender, raw)
    return event.new(type, channel, sender, raw)
end

return Platform
