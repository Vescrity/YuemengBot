--- test_debug.lua - debug 框架（unix socket + 长度前缀协议）
local dir = arg[0]:match("^(.*)/") or "."
package.path = dir .. "/../src/?.lua;" .. dir .. "/../src/?/init.lua;"
    .. dir .. "/../lib/promise/?.lua;" .. dir .. "/../lib/http/?.lua;" .. package.path
package.cpath = dir .. "/../lib/http/?.so;" .. dir .. "/../lib/regex/?.so;" .. package.cpath

local P = require("promise")
local uv = require("luv")
local cjson = require("cjson")
local debug = require("core.debug")

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

print("=== debug 框架 ===")

local function readInt32BE(s, i)
    local a, b, c, d = string.byte(s, i, i + 3)
    return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end
local function packFrame(payload)
    local n = #payload
    return string.char(
        math.floor(n / 0x1000000) % 0x100,
        math.floor(n / 0x10000) % 0x100,
        math.floor(n / 0x100) % 0x100,
        n % 0x100
    ) .. payload
end
local function request(path, source)
    return P.new(function(resolve, reject)
        local client = uv.new_pipe(false)
        uv.pipe_connect(client, path, function(err)
            if err then reject(err); return end
            client:write(packFrame(source))
            local buf = ""
            client:read_start(function(er, data)
                if er then reject(er); return end
                if not data then return end
                buf = buf .. data
                if #buf >= 4 then
                    local n = readInt32BE(buf, 1)
                    if #buf >= 4 + n then
                        local payload = buf:sub(5, 4 + n)
                        client:close()
                        resolve(cjson.decode(payload))
                    end
                end
            end)
        end)
    end)
end

local path = "/tmp/opencode/yuemeng-test.sock"
debug.start({ path = path })

P.sync(function()
    local r1 = P.await(request(path, "return 1+2"))
    check("求值返回结果", r1.ok and r1.result == "3")

    local r2 = P.await(request(path, "print('hi') return 'x'"))
    check("print 被捕获", r2.ok and r2.output == "hi" and r2.result == "x")

    local r3 = P.await(request(path, "error('boom')"))
    check("错误返回 traceback", not r3.ok and tostring(r3.error):find("boom", 1, true) ~= nil)

    local r4 = P.await(request(path, "1 + "))
    check("语法错误返回", not r4.ok and r4.error ~= nil)

    debug.stop()
end)

P.run()

print(string.format("\n=== 结果: %d 通过, %d 失败 ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
