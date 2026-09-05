--- backend_luasocket.lua - 调度后端：LuaSocket 的 socket.select / socket.gettime
--- 接口：timer(ms, cb) / wait_fd(fd, cb) / pending() / step()
local socket = require("socket")

local B = {}
local timers = {}       -- { deadline=ms, cb=fn }
local fd_waiters = {}   -- fd -> { cb=fn, ... }

local function now_ms()
    return socket.gettime() * 1000
end

function B.timer(ms, cb)
    timers[#timers + 1] = { deadline = now_ms() + ms, cb = cb }
end

function B.wait_fd(fd, cb)
    local list = fd_waiters[fd]
    if not list then
        list = {}
        fd_waiters[fd] = list
    end
    list[#list + 1] = cb
end

function B.pending()
    if #timers > 0 then return true end
    return next(fd_waiters) ~= nil
end

function B.step()
    local fds = {}
    for fd in pairs(fd_waiters) do
        fds[#fds + 1] = fd
    end

    local now = now_ms()
    local timeout
    if #timers > 0 then
        local nearest = math.huge
        for i = 1, #timers do
            if timers[i].deadline < nearest then nearest = timers[i].deadline end
        end
        timeout = math.max(0, (nearest - now) / 1000)
    end

    local recvt = {}
    if #fds > 0 then
        local r = socket.select(fds, nil, timeout)
        recvt = r or {}
    elseif timeout ~= nil then
        socket.sleep(timeout)
    end

    now = now_ms()
    local rest = {}
    for i = 1, #timers do
        if timers[i].deadline <= now then
            local cb = timers[i].cb
            cb()
        else
            rest[#rest + 1] = timers[i]
        end
    end
    timers = rest

    for i = 1, #recvt do
        local fd = recvt[i]
        local list = fd_waiters[fd]
        if list then
            fd_waiters[fd] = nil
            for j = 1, #list do
                list[j]()
            end
        end
    end
end

return B
