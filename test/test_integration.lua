--- test_integration.lua - 测试平台 + echo 插件端到端
local dir = arg[0]:match("^(.*)/") or "."
package.path = dir .. "/../src/?.lua;" .. dir .. "/../src/?/init.lua;"
    .. dir .. "/../lib/promise/?.lua;" .. dir .. "/../lib/http/?.lua;" .. package.path
package.cpath = dir .. "/../lib/http/?.so;" .. dir .. "/../lib/regex/?.so;" .. package.cpath

local P = require("promise")
local http = require("http")
local server = require("server")
local cjson = require("cjson")
local core = require("core")
local Test = require("platform.test")

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

print("=== 测试平台 + echo 集成 ===")

local replies = {}
local replySrv = assert(server.new({ host = "127.0.0.1", port = 0 }))
replySrv:start(function(req)
    replies[#replies + 1] = cjson.decode(req.body).content
    return { status = 200, body = "ok" }
end)
local replyUrl = "http://127.0.0.1:" .. replySrv.port .. "/reply"

local tp = Test.new({ replyUrl = replyUrl })
core.platforms.add(tp)
tp:start()
core.plugin.init(core.plugin.load("plugin.echo"))

P.sync(function()
    local url = "http://127.0.0.1:" .. tp.port .. "/event"

    local r1 = P.await(http.post(url, { json = { type = "message", text = "echo hello", senderId = "u1" } }))
    check("事件 POST 200", r1.status == 200)
    P.await(P.delay(100))
    check("echo 回发 1 条", #replies == 1)
    check("echo 内容正确", replies[1] == "hello")

    local r2 = P.await(http.post(url, { json = { type = "message", text = "not a match", senderId = "u1" } }))
    check("非 echo 文本不触发", r2.status == 200)
    P.await(P.delay(50))
    check("非 echo 不回发", #replies == 1)

    tp:stop()
    replySrv:close()
end)

P.run()

print(string.format("\n=== 结果: %d 通过, %d 失败 ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
