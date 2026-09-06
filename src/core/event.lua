---@class Event
local Event = {}
Event.__index = Event

function Event.new(type, channel, sender, raw)
    return setmetatable({
        type = type,
        channel = channel,
        sender = sender,
        raw = raw,
    }, Event)
end

return Event
