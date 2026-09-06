--- test_unhandled_rejection.lua - 未处理 rejection 检测的语义测试
--- 双向用例：永不处理的 rejection 应告警；稍后（异步）补 catch 的 rejection 不应告警。
--- 跑法：lua lib/promise/test/test_unhandled_rejection.lua
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

print("=== promise 未处理 rejection 检测 ===")

-- 截获 stderr，跑完整时间线后再判定
local tmp_path = os.tmpname()
local f = assert(io.open(tmp_path, "w"))
local old_stderr = io.stderr
io.stderr = f -- luacheck: ignore 122

-- 正向：永不处理的 rejection，应在事件循环结束时告警
P.reject("leaked_rejection")

-- 负向：稍后（异步）注册 catch 的 rejection，不应告警
local p = P.reject("handled_rejection")
P.sync(function()
    P.await(P.delay(50))
    p:catch(function() end)   -- 稍后才异步注册处理
end)

P.run()

f:flush()
f:close()
io.stderr = old_stderr -- luacheck: ignore 122
local content = assert(io.open(tmp_path, "r")):read("*a")
os.remove(tmp_path)

check("已处理的 rejection 不误报",
    content:find("handled_rejection", 1, true) == nil)
check("未处理的 rejection 确实告警",
    content:find("leaked_rejection", 1, true) ~= nil)

print(string.format("\n=== 结果: %d 通过, %d 失败 ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
