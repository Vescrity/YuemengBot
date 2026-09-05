--- test_promise.lua - promise.lua 自测（不依赖 fake_onebot）
local dir = arg[0]:match("^(.*)/") or "."
package.path = dir .. "/../?.lua;" .. package.path

local socket = require("socket")
local P = require("promise")

local passed, failed = 0, 0
local function check(name, cond)
    if cond then
        passed = passed + 1
        print("  [PASS] " .. name)
    else
        failed = failed + 1
        print("  [FAIL] " .. name)
    end
end

print("=== promise.lua 自测 ===")

P.sync(function()
    local r = P.await(
        (P.new(function(resolve) resolve(1) end)
            :thenDo(function(v) return v + 1 end)
            :thenDo(function(v) return v * 3 end))
    )
    check("then 链式传值 (1+1)*3=6", r == 6)
end)

P.sync(function()
    local r = P.await(P.reject("boom"):catch(function(e) return "caught:" .. e end))
    check("catch 捕获并恢复", r == "caught:boom")
end)

P.sync(function()
    local p = P.new(function(resolve) resolve(1) end)
    local p2 = p:thenDo(function() error("inner", 0) end)
    local p3 = p2:thenDo(function() return "never" end)
    local ok, err = pcall(P.await, p3)
    check("错误沿链传播到 await", (not ok) and tostring(err):find("inner") ~= nil)
end)

P.sync(function()
    local inner = P.delay(30, 42)
    local r = P.await(P.resolve(inner))
    check("resolve(promise) 接管", r == 42)
end)

P.sync(function()
    local cnt = 0
    local v = P.await(P.resolve(7):finally(function() cnt = cnt + 1 end))
    check("finally 成功后执行", v == 7 and cnt == 1)
    local ok, err = pcall(P.await, P.reject("x"):finally(function() cnt = cnt + 1 end))
    check("finally 失败后执行且错误保留", (not ok) and cnt == 2 and tostring(err) == "x")
end)

P.sync(function()
    local rs = P.await(P.all({
        P.delay(20, "a"),
        P.delay(30, "b"),
        P.new(function(resolve) resolve("c") end),
    }))
    check("all 汇总结果", rs[1] == "a" and rs[2] == "b" and rs[3] == "c")
end)

P.sync(function()
    local ok, err = pcall(P.await, P.all({
        P.resolve(1),
        P.reject("oops"),
        P.delay(50, 3),
    }))
    check("all 任一失败整体 reject", (not ok) and tostring(err) == "oops")
end)

P.sync(function()
    local rs = P.await(P.allSettled({
        P.resolve(1),
        P.reject("bad"),
    }))
    check("allSettled 状态", rs[1].status == "fulfilled" and rs[1].value == 1
        and rs[2].status == "rejected" and rs[2].reason == "bad")
end)

P.sync(function()
    local r = P.await(P.race({
        P.delay(50, "slow"),
        P.delay(10, "fast"),
    }))
    check("race 快者胜", r == "fast")
end)

P.sync(function()
    local r = P.await(P.any({
        P.reject("a"),
        P.delay(10, "win"),
        P.reject("c"),
    }))
    check("any 首个成功", r == "win")
end)

P.sync(function()
    local ok, err = pcall(P.await, P.any({ P.reject("a"), P.reject("b") }))
    check("any 全失败 reject", (not ok) and type(err) == "table" and err.errors ~= nil)
end)

P.sync(function()
    local t0 = socket.gettime()
    local rs = P.await(P.all({ P.delay(150, 1), P.delay(150, 2) }))
    local dt = (socket.gettime() - t0) * 1000
    check("两个 delay 并发等待 (约150ms, 非300ms)", rs[1] == 1 and rs[2] == 2 and dt >= 130 and dt < 260)
end)

P.sync(function()
    local ok, err = pcall(P.await, P.withTimeout(P.delay(300, "late"), 40, "timeout"))
    check("withTimeout 超时 reject", (not ok) and tostring(err) == "timeout")
end)

P.sync(function()
    local r = P.await(P.withTimeout(P.delay(20, "ok"), 200, "timeout"))
    check("withTimeout 不超时返回原值", r == "ok")
end)

local server = socket.tcp()
server:settimeout(0)
assert(server:bind("127.0.0.1", 0))
server:listen(1)
local _, port = server:getsockname()
local client = socket.tcp()
client:settimeout(1)
assert(client:connect("127.0.0.1", port))
client:settimeout(0)
client:send("hi\n")

P.sync(function()
    local ok = P.await(P.fd(server))
    local conn = server:accept()
    check("fd 等待可读 + accept", ok == true and conn ~= nil)
end)

P.run()

print(string.format("\n=== 结果: %d 通过, %d 失败 ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
