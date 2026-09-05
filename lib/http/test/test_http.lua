--- test_http.lua - http.lua 自测（依赖 test.local/http_server.py 慢服务端）
--- 跑法：先启动服务端 python3 test.local/http_server.py [port]，再
---   lua lib/http/test/test_http.lua [port]
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

print("=== http.lua 自测 ===")

-- parse_headers 单测（不依赖网络）
do
    local h = http.parse_headers(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n")
    check("parse_headers 单值", h["content-type"] == "text/html")
    check("parse_headers 重复头合并数组",
        type(h["set-cookie"]) == "table"
        and h["set-cookie"][1] == "a=1" and h["set-cookie"][2] == "b=2")
end

P.sync(function()
    -- GET 200
    local r = P.await(http.get(base .. "/hello"))
    check("GET 状态码 200", r.status == 200)
    check("GET body 含 path", r.body:find("path=/hello", 1, true) ~= nil)
    check("GET headers 原始段含状态码", r.headers:find("200", 1, true) ~= nil)

    -- query 拼接 + percent 编码
    local r2 = P.await(http.get(base .. "/q", { query = { a = 1, b = "x y" } }))
    check("query 拼接", r2.body:find("a=1", 1, true) and r2.body:find("b=x%%20y") ~= nil)

    -- POST + json
    local r3 = P.await(http.post(base .. "/echo", { json = { k = "v" } }))
    check("POST json body 送达", r3.status == 200 and r3.body:find('{"k":"v"}', 1, true) ~= nil)

    -- 并发 3 个（每个服务端睡 1 秒，应约 1 秒完成）
    local t0 = uv.hrtime()
    local rs = P.await(P.all({
        http.get(base .. "/one"),
        http.get(base .. "/two"),
        http.get(base .. "/three"),
    }))
    local dt = (uv.hrtime() - t0) / 1e9
    check("并发 3 个都成功", #rs == 3 and rs[1].status == 200 and rs[2].status == 200 and rs[3].status == 200)
    check("并发总耗时约 1s (<2s)", dt >= 0.8 and dt < 2.0)

    -- 404 -> reject kind=http
    local ok, err = pcall(function() return P.await(http.get(base .. "/404")) end)
    check("404 reject kind=http", not ok and type(err) == "table" and err.kind == "http" and err.status == 404)

    -- 连接被拒 -> reject kind=curl
    local ok2, err2 = pcall(function() return P.await(http.get("http://127.0.0.1:1/", { connect_timeout = 1 })) end)
    check("连接失败 reject kind=curl", not ok2 and type(err2) == "table" and err2.kind == "curl")
end)

P.run()

print(string.format("\n=== 结果: %d 通过, %d 失败 ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
