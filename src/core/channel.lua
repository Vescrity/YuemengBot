---@class Channel
local Channel = {}
Channel.__index = Channel

function Channel.new(id, platform)
    return setmetatable({
        id = tostring(id),
        platform = platform,
    }, Channel)
end

function Channel:send(content)
    return self.platform:send(self, content)
end

return Channel
