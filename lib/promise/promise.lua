--- promise.lua - 单线程事件循环 + Promise/A+ 风格
--- thenDo / catch / finally + 组合器(all/allSettled/race/any)
--- + 定时器(delay/withTimeout) + IO(fd) + 协程桥(sync/await)
--- 后端固定为 luv(libuv)。
--- 后端只提供 timer / wait_fd / pending / step 四个原语。

local backend = require("backend_luv")

local M = {}
M.__index = M
M.backend = backend

-- 状态用整数常量（0=pending / 1=fulfilled / 2=rejected），导出供调用方比较
local PENDING, FULFILLED, REJECTED = 0, 1, 2
M.PENDING = PENDING
M.FULFILLED = FULFILLED
M.REJECTED = REJECTED

-- ---------- 调度器状态 ----------
local microtasks = {}   -- 微任务队列（then/catch 回调统一在这里执行）
local ready_co = {}     -- 可运行协程队列
local unhandled = {}    -- 已 reject 且尚未挂 handler 的 promise（事件循环结束时统一检查）
local active = 0        -- 当前正在 await 一个未决 promise 的协程数（事件循环退出判据）

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
    local is_reject = (p._state == REJECTED)
    local arg = p._value
    if is_reject then arg = p._reason end
    for i = 1, #hs do
        local h = hs[i]
        enqueue(function() run_handler(h, arg, is_reject) end)
    end
end

-- 执行单个 handler，把结果（普通值/thenable/异常）传导到 child
run_handler = function(h, arg, is_reject)
    local fn = h.on_rejected
    if not is_reject then fn = h.on_fulfilled end
    local child = h.child
    if not fn then
        if is_reject then reject_promise(child, arg) else resolve_promise(child, arg) end
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
        local function on_fulfilled(v)
            if called then return end
            called = true
            resolve_promise(p, v)
        end
        local function on_rejected(e)
            if called then return end
            called = true
            reject_promise(p, e)
        end
        local ok, err = pcall(function()
            if is_promise(x) then
                x:thenDo(on_fulfilled, on_rejected)
            else
                x["then"](x, on_fulfilled, on_rejected)
            end
        end)
        if not ok then on_rejected(err) end
        return
    end
    p._state = FULFILLED
    p._value = x
    schedule_handlers(p)
end

reject_promise = function(p, e)
    p._state = REJECTED
    p._reason = e
    local handled = p._handlers ~= nil and #p._handlers > 0
    schedule_handlers(p)
    if not handled then
        unhandled[p] = true
    end
end

-- ---------- 实例方法 ----------

function M:thenDo(on_fulfilled, on_rejected)
    unhandled[self] = nil
    local child = new_promise()
    local h = { on_fulfilled = on_fulfilled, on_rejected = on_rejected, child = child }
    if self._state == PENDING then
        self._handlers = self._handlers or {}
        self._handlers[#self._handlers + 1] = h
    else
        local is_reject = (self._state == REJECTED)
        local arg = self._value
        if is_reject then arg = self._reason end
        enqueue(function() run_handler(h, arg, is_reject) end)
    end
    return child
end

function M:catch(on_rejected)
    return self:thenDo(nil, on_rejected)
end

function M:finally(fn)
    fn = fn or function() end
    return self:thenDo(
        function(value)
            return M.resolve(fn()):thenDo(function() return value end)
        end,
        function(reason)
            return M.resolve(fn()):thenDo(function() return M.reject(reason) end)
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
                function(v) results[i] = { status = FULFILLED, value = v } end,
                function(e) results[i] = { status = REJECTED, reason = e } end
            ):finally(function()
                remaining = remaining - 1
                if remaining == 0 then resolve(results) end
            end)
        end
    end)
end

-- race 空列表永不 settle（对齐 JS Promise.race([]) 永久 pending）
function M.race(list)
    list = list or {}
    return M.new(function(resolve, reject)
        local settled = false
        local function win(fn)
            return function(...)
                if settled then return end
                settled = true
                fn(...)
            end
        end
        for i = 1, #list do
            M.resolve(list[i]):thenDo(win(resolve), win(reject))
        end
    end)
end

function M.AggregateError(errors, message)
    return setmetatable({
        name = "AggregateError",
        message = message or "All Promises rejected",
        errors = errors or {},
    }, {
        __tostring = function(self)
            return "AggregateError: " .. self.message
        end,
    })
end

function M.any(list)
    list = list or {}
    local n = #list
    if n == 0 then return M.reject(M.AggregateError({}, "空列表")) end
    return M.new(function(resolve, reject)
        local remaining = n
        local errors = {}
        for i = 1, n do
            M.resolve(list[i]):thenDo(resolve, function(e)
                errors[i] = e
                remaining = remaining - 1
                if remaining == 0 then
                    reject(M.AggregateError(errors, "全部被拒绝"))
                end
            end)
        end
    end)
end

-- ---------- 定时器 / IO ----------

local function timer_promise(ms, on_fire)
    local p = new_promise()
    backend.timer(ms, function() on_fire(p) end)
    return p
end

function M.delay(ms, value)
    return timer_promise(ms, function(p) p._resolve_fn(value) end)
end

function M.fd(fd, events)
    local p = new_promise()
    local stop = backend.wait_fd(fd, function() p._resolve_fn(true) end, events)
    if not stop then
        p._reject_fn("wait_fd 创建失败")
    end
    return p
end

function M.withTimeout(p, ms, reason)
    local timeout = timer_promise(ms, function(tp) tp._reject_fn(reason or "timeout") end)
    return M.race({ M.resolve(p), timeout })
end

-- ---------- 协程桥 ----------

function M.sync(fn, ...)
    local args = { n = select("#", ...), ... }
    local p = new_promise()
    local co = coroutine.create(function()
        local ok, ret = xpcall(
            function() return fn(table.unpack(args, 1, args.n)) end,
            function(e)
                io.stderr:write("[promise] 协程异常:\n" .. debug.traceback(e, 2) .. "\n")
                return e
            end
        )
        if ok then
            p._resolve_fn(ret)
        else
            p._reject_fn(ret)
        end
    end)
    ready_co[#ready_co + 1] = co
    return p
end

function M.await(p)
    local co, isMain = coroutine.running()
    if isMain or co == nil then
        error("promise.await 只能在协程内调用（配合 promise.sync）", 2)
    end
    if not is_promise(p) then p = M.resolve(p) end
    local function resume()
        active = active - 1
        ready_co[#ready_co + 1] = co
    end
    p:thenDo(resume, resume)
    active = active + 1
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

-- 事件循环结束时统一报告：仍无人处理（无 handler）的 rejection
local function report_unhandled()
    for p in pairs(unhandled) do
        if p._state == REJECTED then
            io.stderr:write("[promise] 未处理的 rejection: " .. tostring(p._reason) .. "\n")
        end
        unhandled[p] = nil
    end
end

function M.run()
    while true do
        local did
        repeat
            did = false
            did = drain() or did
            did = run_coroutines() or did
        until not did

        if active == 0 and #ready_co == 0 and #microtasks == 0 then
            break
        end

        backend.step()
    end
    backend.clear()
    report_unhandled()
end

return M
