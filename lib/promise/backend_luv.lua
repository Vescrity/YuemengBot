--- backend_luv.lua - 调度后端：libuv（luv 绑定），epoll/kqueue/IOCP
--- 接口：timer(ms, cb) / wait_fd(fd, cb, events) / pending() / step() / clear()
--- timer / wait_fd 返回一个停止函数（停止并关闭底层句柄），供资源方（如 server）使用。
--- 句柄统一登记到 handles；clear() 在事件循环退出时统一停止全部残留句柄。
local uv = require("luv")

local B = {}
local handles = {}   -- 活跃句柄集合（键为句柄对象）

local function release(h)
    handles[h] = nil
    pcall(function() h:stop() end)
    pcall(function() h:close() end)
end

function B.timer(ms, cb)
    local t = uv.new_timer()
    if not t then return nil end
    local done = false
    handles[t] = true
    t:start(ms, 0, function()
        if done then return end
        done = true
        release(t)
        cb()
    end)
    return function()
        if done then return end
        done = true
        release(t)
    end
end

function B.wait_fd(fd, cb, events)
    events = events or "r"
    if type(fd) == "userdata" and fd.getfd then
        fd = fd:getfd()
    end
    local h = uv.new_poll(fd)
    if not h then return nil end
    local done = false
    handles[h] = true
    h:start(events, function(err)
        if done then return end
        done = true
        release(h)
        cb(err)
    end)
    return function()
        if done then return end
        done = true
        release(h)
    end
end

function B.pending()
    return next(handles) ~= nil
end

function B.step()
    uv.run("once")
end

function B.clear()
    for h in pairs(handles) do
        release(h)
    end
end

return B
