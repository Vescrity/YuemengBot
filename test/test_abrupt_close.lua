--- test_abrupt_close.lua - 客户端异常断连不应让连接协程空转/泄漏句柄
--- 回归：LuaSocket 在对端关闭时返回 nil, "closed", ""，空串 partial 曾被当成数据，
--- 导致连接协程在 EOF 上无限循环，并不断创建 30s 超时定时器。
local dir = arg[0]:match("^(.*)/") or "."
package.path = dir .. "/../src/?.lua;" .. dir .. "/../src/?/init.lua;"
    .. dir .. "/../lib/promise/?.lua;" .. dir .. "/../lib/http/?.lua;" .. package.path
package.cpath = dir .. "/../lib/http/?.so;" .. dir .. "/../lib/regex/?.so;" .. package.cpath

local P = require("promise")
local uv = require("luv")
local socket = require("socket")
local server = require("server")

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

local function handleCount()
    local n = 0
    uv.walk(function() n = n + 1 end)
    return n
end

print("=== 客户端异常断连 ===")

local hits = 0
local srv = assert(server.new({ host = "127.0.0.1", port = 0, idle_timeout = 0.5 }))
srv:start(function()
    hits = hits + 1
    return { status = 200, body = "ok" }
end)

P.sync(function()
    -- 20 个客户端：不发数据直接断开 / 发半截请求后断开
    for i = 1, 20 do
        local c = assert(socket.tcp())
        c:settimeout(1)
        assert(c:connect("127.0.0.1", srv.port))
        if i % 2 == 0 then
            c:send("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n{")
        end
        c:close()
    end

    P.await(P.delay(100))
    local h1 = handleCount()
    check("异常断连后句柄不堆积", h1 < 10)

    -- 之后的正常请求仍应被处理（非阻塞读写，避免阻塞事件循环）
    local c = assert(socket.tcp())
    c:settimeout(1)
    assert(c:connect("127.0.0.1", srv.port))
    c:settimeout(0)
    c:send("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}")
    P.await(P.fd(c, "r"))
    local resp = c:receive("*l") or ""
    c:close()
    check("异常断连后仍能接收消息", resp:find("200 OK", 1, true) ~= nil)
    check("handler 被正常调用", hits == 1)

    srv:close()
end)

P.run()

print(string.format("\n=== 结果: %d 通过, %d 失败 ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
