--- test_server.lua - http.server 自测（用 http 客户端打自建 server）
local dir = arg[0]:match("^(.*)/") or "."
package.cpath = dir .. "/../?.so;" .. package.cpath
package.path = dir .. "/../../promise/?.lua;" .. dir .. "/../?.lua;" .. package.path

local server = require("server")
local http = require("http")
local P = require("promise")
local cjson = require("cjson")
local uv = require("luv")

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

print("=== http.server 自测 ===")

local srv = assert(server.new({ host = "127.0.0.1", port = 0 }))
local base = "http://127.0.0.1:" .. srv.port

local received = {}

srv:start(function(req)
    received[#received + 1] = req
    if req.path == "/echo" then
        return { status = 200, headers = { ["X-Test"] = "1" }, body = req.body }
    elseif req.path == "/json" then
        local d = cjson.decode(req.body)
        return cjson.encode({ got = d, method = req.method })
    elseif req.path == "/slow" then
        return P.delay(200, "slow ok")
    elseif req.path == "/async" then
        return P.new(function(res)
            P.sync(function()
                P.await(P.delay(100))
                res("async ok")
            end)
        end)
    elseif req.path == "/404" then
        return { status = 404, body = "nope" }
    else
        return "default"
    end
end)

P.sync(function()
    -- GET + query
    local r = P.await(http.get(base .. "/hello?x=1&y=2"))
    check("GET 默认响应", r.status == 200 and r.body == "default")
    check("请求行解析", received[1].method == "GET" and received[1].path == "/hello" and received[1].query == "x=1&y=2")

    -- POST body 回显
    local r2 = P.await(http.post(base .. "/echo", { body = "hello body" }))
    check("POST body 回显", r2.body == "hello body")
    check("自定义响应头", r2.headers:find("X-Test: 1", 1, true) ~= nil)

    -- POST json 往返
    local r3 = P.await(http.post(base .. "/json", { json = { a = 1 } }))
    local d = cjson.decode(r3.body)
    check("JSON body 解析", d.method == "POST" and d.got.a == 1)

    -- handler 返回 promise（delay）
    local r4 = P.await(http.get(base .. "/slow"))
    check("异步 handler (delay)", r4.body == "slow ok")

    -- handler 返回 promise（新协程）
    local r5 = P.await(http.get(base .. "/async"))
    check("异步 handler (新协程)", r5.body == "async ok")

    -- 404
    local ok, err = pcall(function() return P.await(http.get(base .. "/404")) end)
    check("404 reject", not ok and err.kind == "http" and err.status == 404)

    -- 并发（slow handler 200ms x 3 应 < 600ms）
    local t0 = uv.hrtime()
    local rs = P.await(P.all({
        http.get(base .. "/slow"),
        http.get(base .. "/slow"),
        http.get(base .. "/slow"),
    }))
    local dt = (uv.hrtime() - t0) / 1e9
    check("并发 3 个 slow 请求", #rs == 3 and rs[1].body == "slow ok" and rs[3].body == "slow ok")
    check("并发耗时 < 600ms", dt < 0.6)

    print(string.format("\n=== 结果: %d 通过, %d 失败 ===", passed, failed))
    os.exit(failed == 0 and 0 or 1)
end)

P.run()
