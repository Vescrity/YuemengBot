--- http.lua - 异步 HTTP(S) 客户端（libcurl + detached 线程 + P.fd）
--- 对外：http.<任意method>(url, opts) -> promise；http.request(method, url, opts)
--- 成功 resolve { status, headers(原始段), body }；失败 reject 错误表
--- 加载依赖：package.path 含本目录，package.cpath 含 _http_curl.so

local P = require("promise")
local curl = require("_http_curl")
local cjson = require("cjson")
local headers_lib = require("headers")

local M = {}

-- ---------- URL query ----------

local function escape(s)
    s = tostring(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function build_query(params)
    local keys = {}
    for k in pairs(params) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = escape(k) .. "=" .. escape(params[k])
    end
    return table.concat(parts, "&")
end

-- ---------- 核心请求 ----------

function M.request(method, url, opts)
    opts = opts or {}
    method = method:upper()

    local full_url = url
    if opts.query then
        local qs = build_query(opts.query)
        if qs ~= "" then
            full_url = full_url .. (full_url:find("?", 1, true) and "&" or "?") .. qs
        end
    end

    local headers = {}
    if opts.headers then
        for k, v in pairs(opts.headers) do headers[k] = v end
    end

    local body
    if opts.json ~= nil then
        body = cjson.encode(opts.json)
        if not (headers["Content-Type"] or headers["content-type"]) then
            headers["Content-Type"] = "application/json"
        end
    elseif opts.body ~= nil then
        body = opts.body
    end

    local c_opts = {
        method = method,
        url = full_url,
        headers = next(headers) and headers or nil,
        body = body,
        timeout = opts.timeout,
        connect_timeout = opts.connect_timeout,
        verify_ssl = opts.verify_ssl,
        follow_redirects = opts.follow_redirects,
        http_version = opts.http_version,
    }

    return P.new(function(resolve, reject)
        P.sync(function()
            local req, err = curl.start(c_opts)
            if not req then
                reject({ kind = "curl", message = tostring(err) })
                return
            end
            P.await(P.fd(req:fd()))
            local ok, a, b = req:finish()
            if not ok then
                reject({ kind = "curl", code = a, message = b })
            elseif a.status >= 400 then
                reject({
                    kind = "http",
                    status = a.status,
                    message = "HTTP " .. a.status,
                    body = a.body,
                    headers = a.headers,
                })
            else
                resolve(a) -- { status, headers, body }
            end
        end)
    end)
end

-- ---------- header 解析工具 ----------

M.parse_headers = headers_lib.parse_headers

-- ---------- 魔法：http.<method>(url, opts) ----------

setmetatable(M, {
    __index = function(_, method)
        local m = method:upper()
        return function(url, opts)
            return M.request(m, url, opts)
        end
    end,
})

return M
