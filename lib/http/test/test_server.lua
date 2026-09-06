--- test_server.lua - http.server 自测（用 http 客户端打自建 server）
local dir = arg[0]:match("^(.*)/") or "."
package.cpath = dir .. "/../?.so;" .. package.cpath
package.path = dir .. "/../../promise/?.lua;" .. dir .. "/../?.lua;" .. package.path

local server = require("server")
local http = require("http")
local P = require("promise")
local cjson = require("cjson")
local uv = require("luv")
local socket = require("socket")

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

local srv431 = assert(server.new({ host = "127.0.0.1", port = 0, max_header_bytes = 200 }))
local base431 = "http://127.0.0.1:" .. srv431.port
srv431:start(function() return "ok" end)

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
    elseif req.path == "/big" then
        return string.rep("x", 200 * 1024)
    elseif req.path == "/huge" then
        return string.rep("0123456789", 400000)
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

    -- 大 body 不截断
    local rbig = P.await(http.get(base .. "/big"))
    check("大响应体完整 (200KB)", rbig.status == 200 and #rbig.body == 200 * 1024)

    -- 慢读客户端 + 大响应（backpressure）
    local ch = socket.tcp()
    ch:settimeout(0)
    ch:connect("127.0.0.1", srv.port)
    ch:send("GET /huge HTTP/1.1\r\nHost: x\r\n\r\n")
    local rawbuf = ""
    local read_t0 = uv.hrtime()
    while (uv.hrtime() - read_t0) / 1e9 < 20 do
        local data, e, p = ch:receive(8192)
        if data then rawbuf = rawbuf .. data end
        if p then rawbuf = rawbuf .. p end
        if e == "closed" then break end
        P.await(P.delay(1))
    end
    ch:close()
    local hend = rawbuf:find("\r\n\r\n", 1, true)
    local hbody = hend and rawbuf:sub(hend + 4) or ""
    check("慢读大响应体长度 (4MB)", #hbody == 4000000)
    check("慢读大响应体内容", hbody:sub(1, 10) == "0123456789" and hbody:sub(-10) == "0123456789")

    -- 超大头 -> 431
    local ok431, err431 = pcall(function()
        return P.await(http.get(base431 .. "/", { headers = { ["X-Big"] = string.rep("a", 500) } }))
    end)
    check("超大头返回 431", not ok431 and err431.kind == "http" and err431.status == 431)

    srv:close()
    srv431:close()
end)

P.run()

print(string.format("\n=== 结果: %d 通过, %d 失败 ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
