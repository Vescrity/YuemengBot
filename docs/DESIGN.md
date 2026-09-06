# Yuemeng 设计文档

## 1. 概述

Yuemeng（月梦）是一个**多平台聊天机器人内核**，用 Lua 编写，构建在仓库自带的 `lib/promise` 与 `lib/http` 之上。核心是单线程事件循环下的异步模型，通过统一的**平台事件总线 `MoonBus`** 把「平台接入」与「业务插件」解耦。

一个 bot 实例可同时连接**多个平台实例**（同类型也可多个），共享同一个 `MoonBus`，事件可在平台间互转、互交互。

## 2. 目标与范围

- 稳定的核心抽象：事件 `Event`、频道 `Channel`、发送者/权限 `Sender`/`Perm`、总线 `MoonBus`、平台 `Platform`、插件 `Plugin`、核心服务。
- 平台与插件解耦；插件只通过核心抽象交互，不感知平台实现。
- 首期：核心骨架 + 测试平台 + debug 框架 + 最小插件跑通全链路。
- **不做**（至少现在）：OneBot、完整词库/answer、terminal、PCRE2 正则、会话上下文/历史窗口。

## 3. 运行基础

- 运行时：**Lua 5.5**（依赖 `luv`、`luasocket`、`cjson`）。
- 异步模型：`lib/promise`（单线程事件循环，后端 `luv`）。
  - `P.sync(fn, ...)`：创建协程入队，**不阻塞调用者**。
  - `P.await(p)`、`P.delay(ms)`、`P.fd(fd, events)`、`P.withTimeout(p, ms)`、`P.run()`。
- HTTP 客户端：`lib/http`（libcurl + 独立线程 + `P.fd`），`http.<method>(url, opts)` → promise，resolve `{ status, headers, body }`。
- HTTP 服务端：`lib/http.server`（luasocket + `P.fd`），`server.new(opts):start(handler)`，handler 可返回 promise。
- 约束：所有 IO/异步走 promise；禁止阻塞（日志 flush 等少数必要同步除外）。

## 4. 目录结构

```
jm26/
├── Makefile
├── .luarc.json
├── .luacheckrc
├── opencode.json
├── AGENTS.md
├── docs/DESIGN.md
├── lib/
│   ├── promise/
│   ├── http/
│   └── regex/                 # PCRE2 绑定
├── src/
│   ├── core/
│   │   ├── init.lua         # 引导与装配（导出 core 命名空间）
│   │   ├── perm.lua         # 权限等级常量
│   │   ├── channel.lua      # Channel 类型 + send 糖
│   │   ├── event.lua        # Event 类型/构造
│   │   ├── platform.lua     # 平台基类
│   │   ├── platforms.lua    # 平台实例注册表
│   │   ├── moonbus.lua      # MoonBus（平台事件总线）
│   │   ├── plugin.lua       # 插件加载器
│   │   ├── debug.lua        # debug 框架
│   │   └── service/
│   │       ├── path.lua     # XDG 路径
│   │       ├── config.lua   # 配置（装配脚本）
│   │       └── log.lua      # 分层日志
│   ├── platform/
│   │   └── test.lua         # 测试平台
│   ├── plugin/
│   │   └── echo.lua         # 最小插件
│   └── main.lua             # 入口
├── bin/
│   └── yuemeng.in           # 启动器模板（Makefile 生成 bin/yuemeng）
└── test/
    ├── test_core.lua         # 核心单元测试
    ├── test_integration.lua  # 测试平台 + echo 端到端
    ├── test_debug.lua        # debug 框架
    └── test_install.sh       # 安装冒烟
```

## 5. 核心抽象

### 5.1 事件 `Event`

```lua
---@class Event
---@field type    string     -- 事件类型，如 "message"、"notice"…
---@field channel Channel    -- 来源频道（含平台引用）
---@field sender? Sender     -- 发送者（message 类有；部分 notice 缺省）
---@field raw     table      -- 平台原始事件（透传）
```

事件处理器拿到的是完整 `Event`；`channel`、`sender.level`、`channel.platform` 等都是合法的触发判定条件。

### 5.2 频道 `Channel`（地点）

`Channel` 是**来源/去向的标识**，直接持有 `id` 与平台引用：

```lua
---@class Channel
---@field id       string     -- 平台内唯一
---@field platform Platform   -- 平台实例引用（Lua 表引用即指针）
```

- **唯一性契约**：`channel.id` 在平台实例内**唯一确定一个 channel**。
- 私聊：`id = "p" .. 对方QQ号`（如 `"p123456"`）——群号与 QQ 号可能重叠，故私聊加前缀区分。
- 群聊：`id = 群号`（如 `"123456"`，不加前缀）。
- 前缀方案是推荐约定，各平台可自定义，只要保证平台内唯一。
- 发送糖：`channel:send(content) -> Promise`，内部委托 `channel.platform:send(channel, content)`。
- **`session` 名字暂退役**，未来专指「可通过 Channel 索引的会话实例」，用于查看某窗口内的会话上下文；即便那时也几乎只读，收发仍传 Channel/id。

### 5.3 发送者与权限 `Sender` / `Perm`

核心只保留**加性得分的常量词汇**：

```lua
---@class Perm
local perm = {
  blacklist  = -1000,  -- 黑名单
  groupAdmin = 20,     -- 群管
  trusted    = 50,     -- 受信
  root       = 100,    -- bot 所有者
}
-- 普通用户 = 基准 0，不参与累加
```

- 最终等级 = 所有命中项得分之和；数值留白便于扩展；视为稳定契约。
- **判定（含名单）全部由平台实现**，更准确说是**用户在配置里重写**；未实现则默认普通用户，或平台特殊处理（如 terminal 只有一人 → 默认 root）。
- **默认门禁**：`sender.level < 0` 时事件不进总线，直接丢弃（可后续配置覆盖）。

```lua
---@class Sender
---@field id    string
---@field name  string
---@field level integer   -- 由平台 resolveLevel 算好的总分
---@field raw   table?
```

### 5.4 总线 `MoonBus`（平台事件总线）

- 结构：**双向链表**，`Handler` 按优先级**降序**排列（链表只是内部实现，不单独命名）。
- 插件通过 `moonbus:mount(handler, pluginName)` 注册。

```lua
---@class Handler
---@field priority integer
---@field plugin   string               -- 所属插件名
---@field match    fun(e: Event): boolean          -- 是否关心
---@field consume  fun(e: Event): boolean?         -- 同步处理；真则终止遍历
---@field run      fun(e: Event)?                  -- 异步处理，fire-and-forget
---@field destroy  fun(): boolean?                 -- 命中后决定是否摘除
---@field _prev    Handler?
---@field _next    Handler?
---@field _destroyed boolean
```

**`emit(e)` 流程**：

```lua
function MoonBus:emit(e)
  if e.sender and e.sender.level < 0 then return end  -- 门禁
  local saved = self._cursor
  self._cursor = { next = nil }
  local h = self._head
  while h do
    self._cursor.next = h._next
    if not h._destroyed and h.match(e) then
      local stop = h.consume(e)
      if h.run then P.sync(function() h.run(e) end) end
      if h.destroy and h.destroy() then self:_unlink(h) end
      if stop then break end
    end
    h = self._cursor.next
  end
  self._cursor = saved
end
```

- `match` 只判定；`consume` 返回真则终止遍历；`run` 走 `P.sync` 不等待；`destroy` 仅命中后询问。
- 挂载优先级：`config.priorityMap(plugin, handler.priority)` 生效后降序插入。

**链表摘除（`_unlink`）与 `_cursor`**：

```lua
function MoonBus:_unlink(node)
  if node._destroyed then return end
  node._destroyed = true
  if node._prev then node._prev._next = node._next end
  if node._next then node._next._prev = node._prev end
  if self._head == node then self._head = node._next end
  if self._tail == node then self._tail = node._prev end
  if self._cursor and self._cursor.next == node then
    self._cursor.next = node._next
  end
end
```

`_cursor` 在 `emit` 前后保存/恢复以支持重入。

### 5.5 平台 `Platform`

平台是**可实例化**的基类；同类型可多实例：

```lua
---@class Platform
---@field type string
---@field start fun(self: Platform)
---@field stop  fun(self: Platform)
---@field send  fun(self: Platform, ch: Channel, content: string): Promise
---@field resolveLevel fun(self: Platform, ch: Channel, senderId: string): integer
```

- **不设 `id`**（目前仅 debug 显示登记实例时有用，不用于寻址，先不定义）。
- **不持有会话表**（`Channel` 直接带平台引用，无需平台维护索引）。
- **发送**：`platform:send(ch, content) -> Promise`，异步、可 `P.await` 取结果，也可 fire-and-forget。
- **权限**：`resolveLevel(ch, senderId)` 由平台（或用户在配置里重写）实现，返回 `perm` 累加总分。

**实例注册表 `core.platforms`**（仅生命周期与 debug 显示）：

```lua
core.platforms.add(platform)
core.platforms.remove(platform)
core.platforms.list()      -- -> Platform[]
```

跨平台互操作 = 从 `list()` 找到目标平台实例，构造 `Channel{ id=…, platform=目标 }`，再 `channel:send(content)`。

### 5.6 插件 `Plugin`

- 私有环境加载：`load(chunk, name, "t", env)`，`env.__index = _G`（不沙箱）。
- 结构：

```lua
---@class Plugin
---@field name     string
---@field priority integer?
---@field init     fun(plugin: Plugin)?
```

- 插件在 `init` 里 `core.moonbus:mount(handler, plugin.name)`。

## 6. 核心服务

### 6.1 路径 `service/path`

XDG Base Directory（应用名 `yuemeng`）：`configDir`/`dataDir`/`cacheDir`/`runtimeDir`/`pluginDir`/`logDir`；支持 `--config <dir>` 覆盖。

### 6.2 配置 `service/config`（装配脚本）

配置是 **Lua 装配脚本**：用户创建平台实例 → 按需重写方法 → 注册 → 加载插件：

```lua
local core = require("core")
local terminal = require("platform.terminal")

local t = terminal.new({})
t.resolveLevel = function(ch, senderId)
  return core.perm.root   -- terminal 就一个人，直接 root
end
core.platforms.add(t)

-- 可选：core.service.config.priorityMap = function(plugin, pri) return pri end
```

启动器 `bin/yuemeng` 加载该脚本完成装配，再 `P.run()`。

### 6.3 日志 `service/log`

接口参照成熟方案（Log4j / lua-log 风格）**固定下来**，显示效果后续可自定义。

```lua
local log = require("core.service.log")

log.get(name)                      -- -> Logger（按名字分层）
log.setRootLevel("info")           -- 全局默认级别

logger:setLevel("debug")           -- 覆盖该名字层级及以下
logger:level()                     -- 生效级别（继承最近的显式设置）

logger:trace(msg, ...)             -- printf 风格
logger:debug(msg, ...)
logger:info(msg, ...)
logger:warn(msg, ...)
logger:error(msg, ...)
logger:fatal(msg, ...)
```

级别：`trace < debug < info < warn < error < fatal`。默认输出 stderr；布局/着色/文件输出留待自定义，不改动接口。

## 7. Debug 框架 `core/debug`

- unix socket（文件，默认 `$XDG_RUNTIME_DIR/yuemeng.sock`），非 TCP；底层用 luv pipe（luasocket 无 unix 支持）。
- 协议：4 字节大端长度前缀 + 载荷。
- 请求 = Lua 源码；响应 = 输出或 traceback；每请求独立 `P.sync` 协程，与总线解耦。

## 8. 正则 `lib/regex`（PCRE2）

C 绑定（`regex.so`，PCRE2-8），供插件做消息模式匹配：

```lua
local regex = require("regex")

regex.new(pattern, flags)      -- -> Regex；flags: i/m/s/x/u
regex.match(pattern, subject, flags)  -- 一次性匹配

re:match(subject)              -- 命中返回 { [1]=整体, [2..]=捕获组 }，否则 nil
re:find(subject)               -- 命中返回 start, end（1 基），否则 nil
```

## 9. 构建与安装

- 构建工具：**Makefile**（gcc）。
- 安装布局（`PREFIX` 默认 `/usr/local`）：
  - 原生 `.so` → `$(PREFIX)/lib/yuemeng/lua/5.5/`（目录名标注 Lua 5.5）
  - Lua 源码（`src/` 与 `lib/`） → `$(PREFIX)/share/yuemeng/`
  - 启动器 → `$(PREFIX)/bin/yuemeng`
- **启动器模板**：`bin/yuemeng.in` 是模板，Makefile 安装时用 `sed` **按需替换占位符**（如 `@PREFIX@`、`@VERSION@`）生成 `bin/yuemeng`，勿手改生成物。

```make
# 示意
sed -e 's|@PREFIX@|$(PREFIX)|g' -e 's|@VERSION@|$(VERSION)|g' \
    bin/yuemeng.in > $(DESTDIR)$(PREFIX)/bin/yuemeng
```

- 生成后的启动器设置 `LUA_PATH`（含 `share/yuemeng`）与 `LUA_CPATH`（含 `.so` 目录）后 `exec lua main.lua`。

## 10. 代码约定

- 标识符 **camelCase**；常量按 camelCase（`perm.groupAdmin`）。
- 模块文件名小写（`moonbus.lua`、`service/path.lua`）。
- 缩进 4 空格；`.luarc.json` 设 `runtime.version = "Lua 5.5"`；luacheck 关卡（命令写入 `AGENTS.md`）。
- 提交 `<type>: <简述>`，不用 skill。

## 11. 测试

- `test/test_core.lua`：核心单元测试（perm/channel/event/moonbus 遍历·摘除·游标·门禁/config/plugin/log）。
- `test/test_integration.lua`：测试平台 + echo 端到端。
- `test/test_debug.lua`：debug 框架往返。
- `test/test_install.sh`：装到临时 `PREFIX` + 指定 config 目录启动冒烟。
- `lib/regex/test/test_regex.lua`：PCRE2 绑定自测。
- 统一入口 `test.sh`；lint 关卡 `luacheck src/ lib/`。

## 12. 里程碑与延后项

- **M0**：核心骨架 + 服务（perm/channel/event/platform/moonbus/plugin + path/config/log）+ Makefile/启动器 + docs + `.luarc.json`/`opencode.json`/`AGENTS.md`。
- **M1**：测试平台 `platform/test.lua`（HTTP 最小协议）。
- **M2**：debug 框架。
- **M3**：插件收尾 + `plugin/echo.lua` 端到端。
- **M4**：`lib/regex`（PCRE2）。
- **M5**：单测 + HTTP 集成 + 安装/配置目录用例。

**延后**：OneBot、词库/answer、terminal、会话上下文（可索引的 session 实例）、`<0` 门禁可配置覆盖、platform 调试名/id。
