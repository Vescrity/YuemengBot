local P = require("promise")
local http = require("http")
local server = require("server")
local cjson = require("cjson")

local Platform = require("core.platform")
local channel = require("core.channel")
local event = require("core.event")

---@class Test
local Test = {}
Test.__index = Test
setmetatable(Test, { __index = Platform })

function Test.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Test)
    self.type = "test"
    self.host = opts.host or "127.0.0.1"
    self.port = opts.port or 0
    self.channelId = opts.channelId or "test"
    self.replyUrl = opts.replyUrl
    self.replyUrls = {}
    self.srv = nil
    return self
end

function Test:_handle(req)
    if req.method ~= "POST" then
        return { status = 405, body = "method not allowed" }
    end
    local ok, data = pcall(cjson.decode, req.body)
    if not ok then
        return { status = 400, body = "bad json" }
    end
    local ch = channel.new(self.channelId, self)
    local senderId = tostring(data.senderId or "")
    if data.replyUrl then
        self.replyUrls[ch.id] = data.replyUrl
    end
    local sender = {
        id = senderId,
        name = data.senderName or "",
        level = self:resolveLevel(ch, senderId),
    }
    local e = event.new(data.type or "message", ch, sender, data)
    self:emit(e)
    return { status = 200, body = "ok" }
end

function Test:start()
    local srv = assert(server.new({ host = self.host, port = self.port }))
    self.port = srv.port
    self.srv = srv
    srv:start(function(req)
        return self:_handle(req)
    end)
end

function Test:stop()
    if self.srv then
        self.srv:close()
        self.srv = nil
    end
end

function Test:send(ch, content)
    local replyUrl = self.replyUrls[ch.id] or self.replyUrl
    if not replyUrl then
        return P.reject({ kind = "test", message = "无 replyUrl 可回发" })
    end
    return http.post(replyUrl, { json = { content = content } })
end

return Test
