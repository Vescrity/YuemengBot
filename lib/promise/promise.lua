--- promise.lua - 单线程事件循环 + Promise/A+ 风格
--- thenDo / catch / finally + 组合器(all/allSettled/race/any)
--- + 定时器(delay/withTimeout) + IO(fd) + 协程桥(sync/await)
--- 后端固定为 luv(libuv)。
--- 后端只提供 timer / wait_fd / hold / pending / step 五个原语。

local backend = require("backend_luv")

local M = {}
M.__index = M
M.backend = backend

local PENDING, FULFILLED, REJECTED = "pending", "fulfilled", "rejected"

-- ---------- 调度器状态 ----------
local microtasks = {}   -- 微任务队列（then/catch 回调统一在这里执行）
local ready_co = {}     -- 可运行协程队列

local function enqueue(fn)
    microtasks[#microtasks + 1] = fn
end

-- ---------- 内部：promise 解析/拒绝（互递归，需前向声明） ----------
local resolve_promise, reject_promise, schedule_handlers, run_handler

local function new_promise()
    local p = setmetatable({
        _state = PENDING,
        _value = nil,
        _reason = nil,
        _handlers = nil,
        _locked = false,
        _unhandled = true,
    }, M)
    local function lock()
        if p._locked then return false end
        p._locked = true
        return true
    end
    p._resolve_fn = function(x)
        if not lock() then return end
        resolve_promise(p, x)
    end
    p._reject_fn = function(e)
        if not lock() then return end
        reject_promise(p, e)
    end
    return p
end

local function is_promise(x)
    return getmetatable(x) == M
end

local function is_thenable(x)
    return is_promise(x) or (type(x) == "table" and type(x["then"]) == "function")
end

-- 结算时把挂着的 handler 逐个排进微任务
schedule_handlers = function(p)
    local hs = p._handlers
    p._handlers = nil
    if not hs then return end
    local isReject = (p._state == REJECTED)
    local arg = p._value
    if isReject then arg = p._reason end
    for i = 1, #hs do
        local h = hs[i]
        enqueue(function() run_handler(h, arg, isReject) end)
    end
end

-- 执行单个 handler，把结果（普通值/thenable/异常）传导到 child
run_handler = function(h, arg, isReject)
    local fn = h.onRejected
    if not isReject then fn = h.onFulfilled end
    local child = h.child
    if not fn then
        if isReject then reject_promise(child, arg) else resolve_promise(child, arg) end
        return
    end
    local ok, result = pcall(fn, arg)
    if not ok then
        reject_promise(child, result)
    else
        resolve_promise(child, result)
    end
end

-- resolve 完整语义：普通值直接 fulfill，thenable/promise 则接管
resolve_promise = function(p, x)
    if x == p then
        return reject_promise(p, "Promise 不能 resolve 自己")
    end
    if is_thenable(x) then
        local called = false
        local function onFulfilled(v)
            if called then return end
            called = true
            resolve_promise(p, v)
        end
        local function onRejected(e)
            if called then return end
            called = true
            reject_promise(p, e)
        end
        local ok, err = pcall(function()
            if is_promise(x) then
                x:thenDo(onFulfilled, onRejected)
            else
                x["then"](x, onFulfilled, onRejected)
            end
        end)
        if not ok then onRejected(err) end
        return
    end
    p._state = FULFILLED
    p._value = x
    schedule_handlers(p)
end

reject_promise = function(p, e)
    p._state = REJECTED
    p._reason = e
    schedule_handlers(p)
    if p._unhandled then
        enqueue(function()
            if p._unhandled and p._state == REJECTED then
                io.stderr:write("[promise] 未处理的 rejection: " .. tostring(e) .. "\n")
            end
        end)
    end
end

-- ---------- 实例方法 ----------

function M:thenDo(onFulfilled, onRejected)
    self._unhandled = false
    local child = new_promise()
    local h = { onFulfilled = onFulfilled, onRejected = onRejected, child = child }
    if self._state == PENDING then
        self._handlers = self._handlers or {}
        self._handlers[#self._handlers + 1] = h
    else
        local isReject = (self._state == REJECTED)
        local arg = self._value
        if isReject then arg = self._reason end
        enqueue(function() run_handler(h, arg, isReject) end)
    end
    return child
end

function M:catch(onRejected)
    return self:thenDo(nil, onRejected)
end

function M:finally(fn)
    fn = fn or function() end
    return self:thenDo(
        function(value)
            return M.resolve(fn()):thenDo(function() return value end)
        end,
        function(reason)
            return M.resolve(fn()):thenDo(function() error(reason, 0) end)
        end
    )
end

-- ---------- 构造 / 静态 ----------

function M.new(executor)
    if type(executor) ~= "function" then
        error("Promise.new 需要一个函数", 2)
    end
    local p = new_promise()
    local ok, err = pcall(executor, p._resolve_fn, p._reject_fn)
    if not ok then p._reject_fn(err) end
    return p
end

function M.resolve(v)
    if is_promise(v) then return v end
    local p = new_promise()
    p._resolve_fn(v)
    return p
end

function M.reject(e)
    local p = new_promise()
    p._reject_fn(e)
    return p
end

-- ---------- 组合器 ----------

function M.all(list)
    list = list or {}
    local n = #list
    local results = {}
    if n == 0 then return M.resolve(results) end
    return M.new(function(resolve, reject)
        local remaining = n
        for i = 1, n do
            M.resolve(list[i]):thenDo(function(v)
                results[i] = v
                remaining = remaining - 1
                if remaining == 0 then resolve(results) end
            end, reject)
        end
    end)
end

function M.allSettled(list)
    list = list or {}
    local n = #list
    local results = {}
    if n == 0 then return M.resolve(results) end
    return M.new(function(resolve)
        local remaining = n
        for i = 1, n do
            M.resolve(list[i]):thenDo(
                function(v) results[i] = { status = "fulfilled", value = v } end,
                function(e) results[i] = { status = "rejected", reason = e } end
            ):finally(function()
                remaining = remaining - 1
                if remaining == 0 then resolve(results) end
            end)
        end
    end)
end

function M.race(list)
    list = list or {}
    return M.new(function(resolve, reject)
        for i = 1, #list do
            M.resolve(list[i]):thenDo(resolve, reject)
        end
    end)
end

function M.any(list)
    list = list or {}
    local n = #list
    if n == 0 then return M.reject({ message = "空列表" }) end
    return M.new(function(resolve, reject)
        local remaining = n
        local errors = {}
        for i = 1, n do
            M.resolve(list[i]):thenDo(resolve, function(e)
                errors[i] = e
                remaining = remaining - 1
                if remaining == 0 then
                    reject({ message = "全部被拒绝", errors = errors })
                end
            end)
        end
    end)
end

-- ---------- 定时器 / IO ----------

-- 保活事件循环：返回一个 release 函数，调用前会阻止 run() 提前退出。
-- 供线程池等"不在 timer/wait_fd 内"的异步操作使用。
function M.hold()
    return backend.hold()
end

function M.delay(ms, value)
    local p = new_promise()
    backend.timer(ms, function() p._resolve_fn(value) end)
    return p
end

function M.fd(fd)
    local p = new_promise()
    backend.wait_fd(fd, function() p._resolve_fn(true) end)
    return p
end

function M.withTimeout(p, ms, reason)
    return M.race({
        M.resolve(p),
        M.new(function(_, reject)
            backend.timer(ms, function() reject(reason or "timeout") end)
        end),
    })
end

-- ---------- 协程桥 ----------

function M.sync(fn, ...)
    local args = { n = select("#", ...), ... }
    local co = coroutine.create(function()
        local ok, err = xpcall(fn, debug.traceback, table.unpack(args, 1, args.n))
        if not ok then
            io.stderr:write("[promise] 协程异常:\n" .. tostring(err) .. "\n")
        end
    end)
    ready_co[#ready_co + 1] = co
    return co
end

function M.await(p)
    local co, isMain = coroutine.running()
    if isMain or co == nil then
        error("promise.await 只能在协程内调用（配合 promise.sync）", 2)
    end
    if not is_promise(p) then return p end
    if p._state == FULFILLED then return p._value end
    if p._state == REJECTED then error(p._reason, 0) end
    local function resume() ready_co[#ready_co + 1] = co end
    p:thenDo(resume, resume)
    coroutine.yield()
    if p._state == REJECTED then error(p._reason, 0) end
    return p._value
end

-- ---------- 事件循环 ----------

local function drain()
    local did = false
    while #microtasks > 0 do
        did = true
        local batch = microtasks
        microtasks = {}
        for i = 1, #batch do
            local ok, err = pcall(batch[i])
            if not ok then
                io.stderr:write("[promise] 微任务异常: " .. tostring(err) .. "\n")
            end
        end
    end
    return did
end

local function run_coroutines()
    local did = false
    while #ready_co > 0 do
        did = true
        local co = table.remove(ready_co, 1)
        local ok, err = coroutine.resume(co)
        if not ok then
            io.stderr:write("[promise] 协程异常: " .. tostring(err) .. "\n")
        end
    end
    return did
end

function M.run()
    while true do
        local did
        repeat
            did = false
            did = drain() or did
            did = run_coroutines() or did
        until not did

        if not backend.pending() and #ready_co == 0 and #microtasks == 0 then
            break
        end

        backend.step()
    end
end

return M
