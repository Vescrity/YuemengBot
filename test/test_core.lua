--- test_core.lua - 核心抽象单元测试（perm/channel/event/moonbus/config/plugin/log）
local dir = arg[0]:match("^(.*)/") or "."
package.path = dir .. "/../src/?.lua;" .. dir .. "/../src/?/init.lua;"
    .. dir .. "/../lib/promise/?.lua;" .. dir .. "/../lib/http/?.lua;" .. package.path
package.cpath = dir .. "/../lib/http/?.so;" .. dir .. "/../lib/regex/?.so;" .. package.cpath

local P = require("promise")
local core = require("core")

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

print("=== 核心单元测试 ===")

-- perm
check("perm 常量", core.perm.blacklist == -1000
    and core.perm.groupAdmin == 20
    and core.perm.trusted == 50
    and core.perm.root == 100
    and core.perm.user == 0)

-- channel
local sent = {}
local fakePlatform = {
    send = function(self, ch, content)
        sent[#sent + 1] = content
        return true
    end,
}
local ch = core.channel.new(123, fakePlatform)
check("channel.id 字符串化", ch.id == "123")
ch:send("hi")
check("channel:send 委托平台", sent[1] == "hi")

-- event
local e = core.event.new("message", ch, { id = "u1", level = 3 }, { x = 1 })
check("event 字段", e.type == "message" and e.channel == ch
    and e.sender.id == "u1" and e.raw.x == 1)

-- config priorityMap 覆盖
local config = core.service.config
local origPm = config.priorityMap
config.priorityMap = function(_, pri) return pri + 10 end
local node = core.moonbus:mount({ priority = 5, match = function() return false end }, "t")
check("priorityMap 覆盖生效", node.priority == 15)
core.moonbus:unmount(node)
config.priorityMap = origPm

-- moonbus：优先级降序 + consume 终止 + destroy 摘除
local order = {}
local a = core.moonbus:mount({
    priority = 100,
    match = function() return true end,
    consume = function() order[#order + 1] = "A" end,
    destroy = function() return true end,
}, "t")
local b = core.moonbus:mount({
    priority = 50,
    match = function() return true end,
    consume = function() order[#order + 1] = "B" end,
}, "t")
local c = core.moonbus:mount({
    priority = 10,
    match = function() return true end,
    consume = function() order[#order + 1] = "C"; return true end,
}, "t")
core.moonbus:mount({
    priority = 1,
    match = function() return true end,
    consume = function() order[#order + 1] = "D" end,
}, "t")

core.moonbus:emit(core.event.new("x", ch))
check("优先级降序 + consume 终止", table.concat(order, ",") == "A,B,C")
check("destroy 摘除", a._destroyed == true)

-- 清理剩余 handler
core.moonbus:unmount(b)
core.moonbus:unmount(c)

-- moonbus：遍历中删除「下一个」节点（游标修正）
local order2 = {}
local toRemove
local x1 = core.moonbus:mount({
    priority = 100,
    match = function() return true end,
    consume = function()
        order2[#order2 + 1] = "A"
        core.moonbus:unmount(toRemove)
    end,
}, "t")
toRemove = core.moonbus:mount({
    priority = 50,
    match = function() return true end,
    consume = function() order2[#order2 + 1] = "B" end,
}, "t")
core.moonbus:mount({
    priority = 10,
    match = function() return true end,
    consume = function() order2[#order2 + 1] = "C" end,
}, "t")
core.moonbus:emit(core.event.new("x", ch))
check("遍历中删除下一节点被跳过", table.concat(order2, ",") == "A,C")
core.moonbus:unmount(x1)

-- moonbus：<0 门禁
local gated = 0
local g = core.moonbus:mount({
    priority = 0,
    match = function() return true end,
    consume = function() gated = gated + 1 end,
}, "t")
core.moonbus:emit(core.event.new("x", ch, { id = "bad", level = -1 }))
check("<0 门禁丢弃事件", gated == 0)
core.moonbus:emit(core.event.new("x", ch, { id = "ok", level = 0 }))
check("普通用户正常派发", gated == 1)
core.moonbus:unmount(g)

-- plugin 按模块名加载
local pl = core.plugin.load("plugin.echo")
check("插件按模块名加载", type(pl) == "table" and pl.name == "echo")

-- log 分层
local log = core.service.log
log.setRootLevel("warn")
local lg = log.get("unit.core")
lg:info("不应显示")
check("log 级别继承（root=warn 屏蔽 info）", lg:level() == log.LEVELS.warn)
lg:setLevel("debug")
check("log 子 logger 覆盖级别", lg:level() == log.LEVELS.debug)
log.setRootLevel("info")

print(string.format("\n=== 结果: %d 通过, %d 失败 ===", passed, failed))
P.run()
os.exit(failed == 0 and 0 or 1)
