--- backend_luv.lua - 调度后端：libuv（luv 绑定），epoll/kqueue/IOCP
--- 接口：timer(ms, cb) / wait_fd(fd, cb) / hold() / pending() / step()
local uv = require("luv")

local B = {}
local pending = 0

function B.hold()
    pending = pending + 1
    local released = false
    return function()
        if released then return end
        released = true
        pending = pending - 1
    end
end

function B.timer(ms, cb)
    local t = uv.new_timer()
    pending = pending + 1
    t:start(ms, 0, function()
        t:close()
        pending = pending - 1
        cb()
    end)
end

function B.wait_fd(fd, cb)
    if type(fd) ~= "number" and type(fd) == "userdata" and fd.getfd then
        fd = fd:getfd()
    end
    local h = uv.new_poll(fd)
    pending = pending + 1
    h:start("r", function()
        h:stop()
        h:close()
        pending = pending - 1
        cb()
    end)
end

function B.pending()
    return pending > 0
end

function B.step()
    uv.run("once")
end

return B
