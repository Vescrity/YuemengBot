--- test_concurrency.lua - 用真实 TCP 验证：多个慢请求是否同时发出
--- 场景：一个连接上连续发两个请求，服务端每个请求都要"慢"300ms 才回。
--- 如果两个请求是同时发出去的：服务端会在回第一个之前就收到两个，
--- 且总耗时应约 300ms（而非串行的 600ms）。
local dir = arg[0]:match("^(.*)/") or "."
package.path = dir .. "/../?.lua;" .. package.path

local socket = require("socket")
local P = require("promise")

local server = socket.tcp()
server:settimeout(0)
assert(server:bind("127.0.0.1", 0))
server:listen(1)
local _, port = server:getsockname()

local conn
local received = {}   -- { id=, at= } 服务端收到每个请求的时刻（相对 t0）
local t0 = socket.gettime()

-- ---------- 服务端：收到一行 -> 记录时间 -> 慢 300ms -> 回包 ----------
P.sync(function()
    P.await(P.fd(server))
    conn = server:accept()
    conn:settimeout(0)
    local buf = ""
    while true do
        P.await(P.fd(conn))
        local data, err, partial = conn:receive(4096)
        if data then buf = buf .. data
        elseif partial then buf = buf .. partial end
        while true do
            local nl = buf:find("\n", 1, true)
            if not nl then break end
            local line = buf:sub(1, nl - 1)
            buf = buf:sub(nl + 1)
            local id = line:match("id=([^,]+)")
            if id then
                received[#received + 1] = { id = id, at = socket.gettime() - t0 }
                P.sync(function()
                    P.await(P.delay(300))
                    conn:send("resp:" .. id .. "\n")
                end)
            end
        end
    end
end)

-- ---------- 客户端：发请求 -> 返回 promise（send 立即发生） ----------
local client = socket.tcp()
client:settimeout(1)
assert(client:connect("127.0.0.1", port))
client:settimeout(0)

local pending = {}
local cid = 0
local function request(name)
    cid = cid + 1
    local id = name .. cid
    return P.new(function(resolve)
        pending[id] = resolve
        client:send("id=" .. id .. "\n")
    end)
end

-- 客户端读回包，按 id 兑现 pending
P.sync(function()
    local buf = ""
    while true do
        P.await(P.fd(client))
        local data, err, partial = client:receive(4096)
        if data then buf = buf .. data
        elseif partial then buf = buf .. partial end
        while true do
            local nl = buf:find("\n", 1, true)
            if not nl then break end
            local line = buf:sub(1, nl - 1)
            buf = buf:sub(nl + 1)
            local id = line:match("resp:(.+)")
            if id then
                local r = pending[id]
                pending[id] = nil
                if r then r(id) end
            end
        end
    end
end)

-- ---------- 验证：all 并发发两个 ----------
P.sync(function()
    local t_send = socket.gettime()
    local rs = P.await(P.all({ request("A"), request("B") }))
    local dt = (socket.gettime() - t_send) * 1000

    print(string.format("结果: %s, %s", rs[1], rs[2]))
    print(string.format("客户端从发出到两个都返回: %.0fms", dt))
    for _, r in ipairs(received) do
        print(string.format("  服务端收到 %s 于 +%.1fms", r.id, r.at * 1000))
    end

    local both_before_respond = (#received == 2)
        and (received[1].at * 1000 < 250)
        and (received[2].at * 1000 < 250)
    local concurrent = dt >= 250 and dt < 550   -- 约 300ms，不是 600ms

    if both_before_respond and concurrent then
        print("\n结论: 两个请求确实是同时发出去的（服务端先收到两个，再一起回；总耗时约一个慢请求的时长）")
        os.exit(0)
    else
        print("\n结论: 疑似串行！请检查。")
        os.exit(1)
    end
end)

P.run()
