--- server.lua - 异步 HTTP 服务端（luasocket raw fd + P.fd）
--- 用法：
---   local server = require("http.server")
---   local srv = assert(server.new({ host="127.0.0.1", port=5701 }))
---   srv:start(function(req) ... return resp end)  -- handler 可返回 promise
---   -- req  = { method, path, query, headers(表), body(字符串) }
---   -- resp = { status, headers, body } 或 字符串（简写 200）
---
--- 说明：v1 每个连接响应完即关闭（无 keep-alive）；body 按 Content-Length 或 Transfer-Encoding: chunked 读取。

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
    [408] = "Request Timeout",
    [413] = "Payload Too Large", [414] = "URI Too Long",
    [431] = "Request Header Fields Too Large",
    [500] = "Internal Server Error", [501] = "Not Implemented",
    [502] = "Bad Gateway", [503] = "Service Unavailable",
}

-- ---------- 发送 ----------

local function send_all(conn, data, timeout_ms)
    local off = 1
    local total = #data
    while off <= total do
        local n, err, sent = conn:send(data:sub(off))
        if n then
            off = off + n
        elseif err == "timeout" then
            if sent and sent > 0 then off = off + sent end
            local ok = pcall(function()
                P.await(P.withTimeout(P.fd(conn, "w"), timeout_ms))
            end)
            if not ok then return false, "timeout" end
        else
            return false, err
        end
    end
    return true
end

-- ---------- 响应写回 ----------

local function write_response(conn, resp, timeout_ms)
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

    send_all(conn, table.concat(lines, "\r\n") .. "\r\n\r\n" .. body, timeout_ms)
end

-- ---------- 单连接处理（在协程内运行，可 P.await） ----------

local function await_readable(conn, timeout_ms)
    return P.await(P.withTimeout(P.fd(conn, "r"), timeout_ms))
end

local function recv_more(conn, buf, cfg)
    local ok = pcall(await_readable, conn, cfg.idle_timeout_ms)
    if not ok then return nil end
    local data, err, partial = conn:receive(4096)
    if data then
        return buf .. data
    elseif partial then
        return buf .. partial
    elseif err == "closed" then
        return nil
    end
    return nil
end

-- 解码 Transfer-Encoding: chunked 的 body；失败返回 nil
local function read_chunked_body(conn, buf, cfg)
    local out = {}
    while true do
        local crlf = buf:find("\r\n", 1, true)
        while not crlf do
            buf = recv_more(conn, buf, cfg)
            if not buf then return nil end
            crlf = buf:find("\r\n", 1, true)
        end
        local size = tonumber(buf:sub(1, crlf - 1), 16)
        if not size then return nil end
        buf = buf:sub(crlf + 2)
        if size == 0 then
            return table.concat(out)
        end
        while #buf < size + 2 do
            buf = recv_more(conn, buf, cfg)
            if not buf then return nil end
        end
        out[#out + 1] = buf:sub(1, size)
        buf = buf:sub(size + 3)
    end
end

local function handle_connection(conn, handler, cfg)
    conn:settimeout(0)

    -- 读请求头直到 \r\n\r\n
    local buf = ""
    local head_end
    while true do
        head_end = buf:find("\r\n\r\n", 1, true)
        if head_end then break end
        local ok = pcall(await_readable, conn, cfg.idle_timeout_ms)
        if not ok then return end
        local data, err, partial = conn:receive(4096)
        if data then
            buf = buf .. data
        elseif partial then
            buf = buf .. partial
        elseif err == "closed" then
            return
        end
        if #buf > cfg.max_header_bytes then
            write_response(conn, { status = 431, body = "header too large" }, cfg.idle_timeout_ms)
            return
        end
    end

    local head = buf:sub(1, head_end - 1)
    local rest = buf:sub(head_end + 4)

    local reqline, header_block = head:match("^(.-)\r\n(.*)$")
    if not reqline then
        write_response(conn, { status = 400, body = "bad request" }, cfg.idle_timeout_ms)
        return
    end
    local method, target = reqline:match("^(%S+)%s+(%S+)%s+HTTP/")
    if not method then
        write_response(conn, { status = 400, body = "bad request" }, cfg.idle_timeout_ms)
        return
    end

    local headers = headers_lib.parse_headers(header_block or "")

    -- 按 Content-Length 或 chunked 读 body
    local body = rest
    local te = headers["transfer-encoding"]
    if type(te) == "table" then
        te = table.concat(te, ",")
    end
    if te and te:lower():find("chunked", 1, true) then
        body = read_chunked_body(conn, body, cfg)
        if not body then
            write_response(conn, { status = 400, body = "bad chunked body" }, cfg.idle_timeout_ms)
            return
        end
    else
        local cl = headers["content-length"]
        if type(cl) == "string" then
            cl = tonumber(cl)
        else
            cl = nil
        end
        if cl then
            if cl > cfg.max_body_bytes then
                write_response(conn, { status = 413, body = "body too large" }, cfg.idle_timeout_ms)
                return
            end
            while #body < cl do
                local more = recv_more(conn, body, cfg)
                if not more then return end
                body = more
            end
            if #body > cl then body = body:sub(1, cl) end
        end
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
        write_response(conn, { status = 500, body = tostring(resp) }, cfg.idle_timeout_ms)
        return
    end

    -- handler 可能返回 promise
    local ok2, resp2 = pcall(P.await, resp)
    if not ok2 then
        write_response(conn, { status = 500, body = tostring(resp2) }, cfg.idle_timeout_ms)
        return
    end
    write_response(conn, resp2, cfg.idle_timeout_ms)
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
        max_header_bytes = opts.max_header_bytes or 64 * 1024,
        max_body_bytes = opts.max_body_bytes or 4 * 1024 * 1024,
        idle_timeout_ms = opts.idle_timeout and (opts.idle_timeout * 1000) or 30000,
    }, M)

    local _, actual = srv:getsockname()
    self.port = actual
    return self
end

function M:start(handler)
    local srv = self.socket
    P.sync(function()
        while not self.closed do
            local p = P.new(function(resolve, reject)
                self._accept_resolve = resolve
                self._accept_stop = P.backend.wait_fd(srv, function()
                    self._accept_stop = nil
                    self._accept_resolve = nil
                    resolve(true)
                end, "r")
                if not self._accept_stop then
                    self._accept_resolve = nil
                    reject("wait_fd 创建失败")
                end
            end)
            local ok = pcall(P.await, p)
            if not ok then break end
            if self.closed then break end
            local conn = srv:accept()
            if conn then
                P.sync(function()
                    local ok2, err = pcall(handle_connection, conn, handler, self)
                    if not ok2 then
                        io.stderr:write("[http.server] 连接异常: " .. tostring(err) .. "\n")
                    end
                    conn:close()
                end)
            end
        end
    end)
    return self
end

function M:close()
    if self.closed then return self end
    self.closed = true
    if self._accept_stop then
        self._accept_stop()
        self._accept_stop = nil
    end
    if self._accept_resolve then
        local r = self._accept_resolve
        self._accept_resolve = nil
        r(false)
    end
    self.socket:close()
    return self
end

return M
