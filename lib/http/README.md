# http

异步 HTTP 客户端与服务端，构建在 [`promise`](../promise/) 之上，风格统一为「返回 promise，`sync`/`await` 里写同步代码」。

- 客户端 `http.lua`：libcurl + detached 线程 + `P.fd`，真正异步不阻塞事件循环。
- 服务端 `server.lua`：luasocket raw fd + `P.fd`，handler 可返回 promise。

## 依赖

- Lua 5.5、`luv`、`luasocket`、`cjson`
- libcurl、pthread（客户端 C 绑定）

## 构建

```bash
bash lib/http/build.sh        # 生成 _http_curl.so
```

## 客户端

```lua
package.cpath = "lib/http/?.so;" .. package.cpath
package.path  = "lib/promise/?.lua;lib/http/?.lua;" .. package.path

local http = require("http")
local P = require("promise")

P.sync(function()
    local r = P.await(http.get("https://example.com", { query = { q = "hi" } }))
    print(r.status, #r.body)

    local p = P.await(http.post("https://example.com/api", { json = { k = "v" } }))
    print(p.status)
end)

P.run()
```

### API

`http.<method>(url, opts)` 对任意 HTTP 方法可用（`get`/`post`/`put`/`delete`/…），等价于 `http.request(method, url, opts)`。

**opts 字段**

| 字段 | 说明 |
| --- | --- |
| `query` | 表，拼成 URL query string |
| `headers` | 表，自定义请求头 |
| `json` | 表，JSON body，自动设 `Content-Type: application/json` |
| `body` | 字符串，原始 body |
| `timeout` | 总超时（毫秒） |
| `connect_timeout` | 连接超时（毫秒） |
| `verify_ssl` / `follow_redirects` / `http_version` | 透传 libcurl 选项 |

**结果**：成功 resolve `{ status, headers, body }`（`headers` 为原始响应段）。

**失败 reject**：

- 连接/传输层错误：`{ kind = "curl", code?, message }`
- HTTP 4xx/5xx：`{ kind = "http", status, message, body, headers }`

### 辅助

- `http.parse_headers(str)` — 解析原始响应头为表（重复头合并为数组）。

## 服务端

```lua
local server = require("server")
local P = require("promise")

local srv = assert(server.new({ host = "127.0.0.1", port = 5701 }))

srv:start(function(req)
    -- req = { method, path, query, headers, body }
    if req.path == "/hello" then
        return { status = 200, body = "hi" }     -- 或直接返回字符串（简写 200）
    end
    if req.path == "/async" then
        -- handler 也可返回 promise，实现异步响应
        return P.delay(100):thenDo(function() return "ok" end)
    end
    return { status = 404, body = "not found" }
end)

P.run()
```

### API

**`server.new(opts)`** 返回 server 对象或 `nil, err`。

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `host` | `127.0.0.1` | 监听地址 |
| `port` | `0` | 端口，0 表示随机（用 `srv.port` 读取实际端口） |
| `backlog` | `128` | 监听队列长度 |
| `max_header_bytes` | 64KB | 头部上限，超限返回 431 |
| `max_body_bytes` | 4MB | body 上限，超限返回 413 |
| `idle_timeout` | 30（秒） | 读写空闲超时 |

**`srv:start(handler)`** 启动 accept 循环；`handler(req)` 返回响应（字符串 / `{status, headers, body}` / promise）。

**`srv:close()`** 停止监听并关闭 socket。

## 测试

```bash
# 启动慢服务端（每个请求延迟 1s）
python3 lib/http/test/http_server.py 8000 &

lua lib/http/test/test_http.lua 8000             # 客户端自测
lua lib/http/test/test_timeout_cancel.lua 8000   # withTimeout 不取消底层请求
lua lib/http/test/test_server.lua                # 服务端自测
```

也可直接 `bash test.sh` 一键跑全量测试。
