--- test_await_thenable.lua - await 对非本库 thenable 的语义测试
--- 预期：await 应像 resolve 一样接管 thenable，等待其 settle 后返回值/抛错，而非原样返回对象。
--- 跑法：lua lib/promise/test/test_await_thenable.lua
local dir = arg[0]:match("^(.*)/") or "."
package.path = dir .. "/../?.lua;" .. package.path

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

print("=== promise await 接管 thenable ===")

P.sync(function()
    -- fulfilled thenable：异步 resolve 值 42
    local then_called = false
    local thenable = {
        ["then"] = function(self, onF, onR)
            then_called = true
            P.delay(10, 42):thenDo(onF, onR)
        end,
    }
    local r = P.await(thenable)
    check("await 接管 thenable 并返回 settle 值(42)", r == 42 and then_called == true)
end)

P.sync(function()
    -- rejected thenable：异步 reject "boom"
    local rej_thenable = {
        ["then"] = function(self, onF, onR)
            P.delay(10):thenDo(function() onR("boom") end)
        end,
    }
    local ok, err = pcall(P.await, rej_thenable)
    check("await rejected thenable 抛 reason", (not ok) and tostring(err) == "boom")
end)

P.run()

print(string.format("\n=== 结果: %d 通过, %d 失败 ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
