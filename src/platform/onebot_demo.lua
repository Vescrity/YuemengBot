local P = require("promise")
local http = require("http")
local server = require("server")
local cjson = require("cjson")

local Platform = require("core.platform")
local channel = require("core.channel")
local event = require("core.event")
local log = require("core.service.log")

---@class OneBotDemo
local OneBotDemo = {}
OneBotDemo.__index = OneBotDemo
setmetatable(OneBotDemo, { __index = Platform })

local function numId(v)
    if type(v) == "number" then
        return tostring(math.tointeger(v) or v)
    end
    return tostring(v)
end

function OneBotDemo.new(opts)
    opts = opts or {}
    local self = setmetatable({}, OneBotDemo)
    self.type = "onebot_demo"
    self.apiUrl = opts.apiUrl
    self.host = opts.host or "127.0.0.1"
    self.port = opts.port or 0
    self.srv = nil
    self.log = log.get("platform.onebot_demo")
    return self
end

function OneBotDemo:_handle(req)
    if req.method ~= "POST" then
        return { status = 405, body = "method not allowed" }
    end
    local ok, data = pcall(cjson.decode, req.body)
    if not ok then
        return { status = 400, body = "bad json" }
    end
    if data.post_type ~= "message" or data.message_type ~= "group" then
        self.log:debug("忽略非群消息: %s/%s", tostring(data.post_type), tostring(data.message_type))
        return { status = 200, body = "{}" }
    end
    local ch = channel.new(numId(data.group_id), self)
    local senderId = numId(data.user_id)
    local sender = {
        id = senderId,
        name = (data.sender and data.sender.nickname) or "",
        level = self:resolveLevel(ch, senderId),
    }
    self:emit(event.new("message", ch, sender, data))
    return { status = 200, body = "{}" }
end

function OneBotDemo:start()
    local srv = assert(server.new({ host = self.host, port = self.port }))
    self.port = srv.port
    self.srv = srv
    srv:start(function(req)
        return self:_handle(req)
    end)
end

function OneBotDemo:stop()
    if self.srv then
        self.srv:close()
        self.srv = nil
    end
end

function OneBotDemo:send(ch, content)
    if not self.apiUrl then
        return P.reject({ kind = "onebot", message = "未配置 apiUrl" })
    end
    return http.post(self.apiUrl .. "/send_group_msg", {
        json = { group_id = tonumber(ch.id), message = content },
    })
end

return OneBotDemo
