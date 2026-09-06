--- test_regex.lua - PCRE2 绑定自测
local dir = arg[0]:match("^(.*)/") or "."
package.cpath = dir .. "/../?.so;" .. package.cpath

local regex = require("regex")

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

print("=== regex 自测 ===")

local m = regex.match("^(\\w+) (\\d+)$", "foo 42")
check("match 捕获组", m ~= nil and m[1] == "foo 42" and m[2] == "foo" and m[3] == "42")

local re = regex.new("^h", "i")
check("caseless 标志", re:match("Hello") ~= nil and re:match("Hello")[1] == "H")
check("find 返回位置", re:find("Hello") == 1)
check("无匹配返回 nil", regex.match("zzz", "abc") == nil)

local bad, err = regex.new("(")
check("编译错误返回 nil+err", bad == nil and type(err) == "string")

print(string.format("\n=== 结果: %d 通过, %d 失败 ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
