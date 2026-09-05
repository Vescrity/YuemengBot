--- server.lua - 异步 HTTP 服务端（luasocket raw fd + P.fd）
--- 用法：
---   local server = require("http.server")
---   local srv = assert(server.new({ host="127.0.0.1", port=5701 }))
---   srv:start(function(req) ... return resp end)  -- handler 可返回 promise
---   -- req  = { method, path, query, headers(表), body(字符串) }
---   -- resp = { status, headers, body } 或 字符串（简写 200）
---
--- 说明：v1 每个连接响应完即关闭（无 keep-alive）；body 按 Content-Length 读取。

local socket = require("socket")
local P = require("promise")
local headers_lib = require("headers")

local M = {}
M.__index = M

local REASON = {
    [200] = "OK", [201] = "Created", [202] = "Accepted", [204] = "No Content",
    [301] = "Moved Permanently", [302] = "Found", [304] = "Not Modified",
    [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden",
    [404] = "Not Found", [405] = "Method Not Allowed",
    [500] = "Internal Server Error", [501] = "Not Implemented",
    [502] = "Bad Gateway", [503] = "Service Unavailable",
}

-- ---------- 响应写回 ----------

local function write_response(conn, resp)
    if type(resp) == "string" then resp = { body = resp } end
    resp = resp or {}
    local status = resp.status or 200
    local reason = resp.reason or REASON[status] or "OK"
    local body = resp.body or ""
    local headers = resp.headers or {}

    local lines = { string.format("HTTP/1.1 %d %s", status, reason) }
    local has_cl = false
    for k, v in pairs(headers) do
        if k:lower() == "content-length" then has_cl = true end
        lines[#lines + 1] = k .. ": " .. tostring(v)
    end
    if not has_cl then
        lines[#lines + 1] = "Content-Length: " .. #body
    end
    lines[#lines + 1] = "Connection: close"

    conn:send(table.concat(lines, "\r\n") .. "\r\n\r\n" .. body)
end

-- ---------- 单连接处理（在协程内运行，可 P.await） ----------

local function handle_connection(conn, handler)
    conn:settimeout(0)

    -- 读请求头直到 \r\n\r\n
    local buf = ""
    local head_end
    while true do
        head_end = buf:find("\r\n\r\n", 1, true)
        if head_end then break end
        P.await(P.fd(conn))
        local data, err, partial = conn:receive(4096)
        if data then
            buf = buf .. data
        elseif partial then
            buf = buf .. partial
        elseif err == "closed" then
            return
        end
    end

    local head = buf:sub(1, head_end - 1)
    local rest = buf:sub(head_end + 4)

    local reqline, header_block = head:match("^(.-)\r\n(.*)$")
    if not reqline then
        write_response(conn, { status = 400, body = "bad request" })
        return
    end
    local method, target = reqline:match("^(%S+)%s+(%S+)%s+HTTP/")
    if not method then
        write_response(conn, { status = 400, body = "bad request" })
        return
    end

    local headers = headers_lib.parse_headers(header_block or "")

    -- 按 Content-Length 读 body
    local body = rest
    local cl = tonumber(headers["content-length"])
    if cl then
        while #body < cl do
            P.await(P.fd(conn))
            local data, err, partial = conn:receive(4096)
            if data then
                body = body .. data
            elseif partial then
                body = body .. partial
            elseif err == "closed" then
                break
            end
        end
        if #body > cl then body = body:sub(1, cl) end
    end

    -- 拆分 path / query
    local path, query = target, nil
    local qi = target:find("?", 1, true)
    if qi then
        path = target:sub(1, qi - 1)
        query = target:sub(qi + 1)
    end

    local req = { method = method, path = path, query = query, headers = headers, body = body }

    local ok, resp = pcall(handler, req)
    if not ok then
        write_response(conn, { status = 500, body = tostring(resp) })
        return
    end

    -- handler 可能返回 promise
    local ok2, resp2 = pcall(P.await, resp)
    if not ok2 then
        write_response(conn, { status = 500, body = tostring(resp2) })
        return
    end
    write_response(conn, resp2)
end

-- ---------- 服务器 ----------

function M.new(opts)
    opts = opts or {}
    local host = opts.host or "127.0.0.1"
    local port = opts.port or 0

    local srv = socket.tcp()
    srv:settimeout(0)
    local ok, err = srv:bind(host, port)
    if not ok then return nil, err end
    srv:listen(opts.backlog or 128)

    local self = setmetatable({
        socket = srv,
        host = host,
        port = port,
        closed = false,
    }, M)

    local _, actual = srv:getsockname()
    self.port = actual
    return self
end

function M:start(handler)
    local srv = self.socket
    P.sync(function()
        while not self.closed do
            P.await(P.fd(srv))
            if self.closed then break end
            local conn = srv:accept()
            if conn then
                P.sync(function()
                    local ok, err = pcall(handle_connection, conn, handler)
                    if not ok then
                        io.stderr:write("[http.server] 连接异常: " .. tostring(err) .. "\n")
                    end
                    conn:close()
                end)
            end
        end
    end)
    return self
end

-- 停止接受新连接（best-effort：不会唤醒已阻塞的 accept，进程退出场景够用）
function M:close()
    self.closed = true
    self.socket:close()
    return self
end

return M
