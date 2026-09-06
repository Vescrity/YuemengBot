# promise

单线程事件循环上的 Promise 库，语义对齐 [Promise/A+](https://promisesaplus.com/) 与 JS 标准组合器，并提供协程桥（`sync`/`await`）让你像写同步代码一样写异步逻辑。

后端固定为 [luv](https://github.com/luvit/luv)（libuv 绑定），定时器与 fd IO 都走 epoll/kqueue/IOCP。

## 依赖

- Lua 5.5
- `luv`（`require("luv")`）

## 快速开始

```lua
local P = require("promise")

P.sync(function()
    -- 并发等两个定时器，逐个 await
    local a = P.await(P.delay(100, "A"))
    local b = P.await(P.delay(50, "B"))
    print(a, b)                        -- A B

    -- 组合器
    local rs = P.await(P.all({ P.delay(20, 1), P.delay(30, 2) }))
    print(rs[1], rs[2])                -- 1 2
end)

P.run()                                 -- 跑事件循环直到没有协程在等
```

## 核心概念

### 事件循环

库不是常驻循环，而是显式调用 `P.run()` 一次性把事件循环跑到「没有任何协程在等待」（`active == 0`）为止，随后清掉残留句柄退出。这适合「跑一批任务、拿结果、退出」的场景；常驻服务请自行让 `sync` 协程保持等待（例如 `server` 的 accept 循环）。

### 协程桥

- `P.sync(fn, ...)` 返回一个 **promise**（对齐 JS 的 async 函数）：协程正常 `return` 的值会 resolve，内部抛错会 reject（reason 为原始错误对象，并同时把 traceback 打到 stderr）。若 `return` 的是 thenable，会被自动接管。
- `P.await(p)` 只能在 `sync` 协程内调用，挂起当前协程直到 `p` 落定，然后返回值或抛 reason。

## API

### 构造 / 静态

| 函数 | 说明 |
| --- | --- |
| `P.new(executor)` | `executor(resolve, reject)` 同步执行；抛错即 reject |
| `P.resolve(v)` | 值直接 fulfill；thenable 被接管 |
| `P.reject(e)` | 返回已 reject 的 promise |
| `P.AggregateError(errors, message)` | 聚合错误表 `{name, message, errors}` |

### 实例方法

| 方法 | 说明 |
| --- | --- |
| `p:thenDo(onF, onR)` | 返回新 promise（`then` 是 Lua 关键字，故名 `thenDo`） |
| `p:catch(onR)` | 只处理 reject |
| `p:finally(fn)` | 值透传；`fn` 返回值/异常会接管 |

### 组合器

| 函数 | 说明 |
| --- | --- |
| `P.all(list)` | 全成功才 resolve；任一失败整体 reject |
| `P.allSettled(list)` | 全部落定，元素为 `{status, value}` 或 `{status, reason}` |
| `P.race(list)` | 快者胜；**不取消输者** |
| `P.any(list)` | 首个成功；全拒 reject `AggregateError` |

空列表语义对齐 JS：`all({})`/`allSettled({})` 立即 resolve `{}`；`race({})` 永久 pending（可用 `withTimeout` 观察）。

### 定时器 / IO

| 函数 | 说明 |
| --- | --- |
| `P.delay(ms, value)` | 定时器，`ms` 毫秒后 resolve `value` |
| `P.fd(fd, events)` | 等 fd 就绪；`events` 为 `"r"`/`"w"`，`fd` 可为数字或 luasocket socket |
| `P.withTimeout(p, ms, reason)` | `ms` 内未落定则 reject `reason`（默认 `"timeout"`）；**不取消**底层 |

### 事件循环 / 常量

| 项 | 说明 |
| --- | --- |
| `P.run()` | 跑事件循环，直到没有协程在等，清理残留句柄后返回 |
| `P.PENDING` / `P.FULFILLED` / `P.REJECTED` | 状态常量（整数 0/1/2） |

## 语义说明

- **race 不取消输者**：对齐 JS `Promise.race`。被丢弃的输者照常执行完并触发副作用。
- **孤儿不等自动退**：`P.run()` 以「是否有协程在 `await`」为退出判据。被 `race` 丢弃、没有协程在等的 `delay` timer 会被清理，不再拖住事件循环；而 `http` 这类内部还有协程在等 fd 的 promise 会正常等到完成。
- **未处理 rejection**：事件循环结束时，仍无 handler 的 reject 会统一打到 stderr 告警。

## 测试

```bash
lua lib/promise/test/test_promise.lua            # 主自测
lua lib/promise/test/test_concurrency.lua        # 真实 TCP 并发验证
lua lib/promise/test/test_await_thenable.lua     # await 接管 thenable
lua lib/promise/test/test_unhandled_rejection.lua # 未处理 rejection 双向用例
```
