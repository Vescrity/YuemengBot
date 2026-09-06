--- test_timeout_cancel.lua - withTimeout 超时后底层 HTTP 请求不被取消（对齐 JS race 语义）
--- 依赖：先启动慢服务端   python3 http_server.py [port]（每个请求延迟 1 秒）
--- 跑法：lua lib/http/test/test_timeout_cancel.lua [port]
--- 预期：超时后 race 立即 reject；底层 curl 继续跑完（约 1s 后完成），事件循环等到底层结束。
local dir = arg[0]:match("^(.*)/") or "."
package.cpath = dir .. "/../?.so;" .. package.cpath
package.path = dir .. "/../../promise/?.lua;" .. dir .. "/../?.lua;" .. package.path

local http = require("http")
local P = require("promise")
local uv = require("luv")

local port = tonumber(arg[1]) or 8000
local base = string.format("http://127.0.0.1:%d", port)

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

print("=== http withTimeout 不取消底层请求 ===")

local underlying_done = false

P.sync(function()
    local http_p = http.get(base .. "/hello")   -- 服务端睡 1s
    http_p:thenDo(function() underlying_done = true end, function() end)

    local t0 = uv.hrtime()
    local ok, err = pcall(P.await, P.withTimeout(http_p, 100, "timeout"))
    local dt = (uv.hrtime() - t0) / 1e9
    check("withTimeout 超时 reject 为 timeout", (not ok) and tostring(err) == "timeout")
    check("超时点在约 100ms (<0.5s)", dt < 0.5)
end)

P.run()

check("底层 HTTP 请求不被取消、仍继续完成", underlying_done == true)

print(string.format("\n=== 结果: %d 通过, %d 失败 ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
