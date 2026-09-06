local P = require("promise")
local config = require("core.service.config")

---@class Handler
---@field priority integer
---@field plugin string
---@field match fun(e: Event): boolean
---@field consume fun(e: Event): boolean?
---@field run fun(e: Event)?
---@field destroy fun(): boolean?
---@field _prev Handler?
---@field _next Handler?
---@field _destroyed boolean

---@class MoonBus
local MoonBus = {}
MoonBus.__index = MoonBus

function MoonBus.new()
    return setmetatable({
        _head = nil,
        _tail = nil,
        _cursor = nil,
    }, MoonBus)
end

function MoonBus:mount(handler, plugin)
    local node = {
        priority = config.priorityMap(plugin, handler.priority or 0),
        plugin = plugin,
        match = handler.match,
        consume = handler.consume,
        run = handler.run,
        destroy = handler.destroy,
        _prev = nil,
        _next = nil,
        _destroyed = false,
    }
    if not self._head then
        self._head = node
        self._tail = node
        return node
    end
    local cur = self._head
    while cur and cur.priority >= node.priority do
        cur = cur._next
    end
    if not cur then
        node._prev = self._tail
        self._tail._next = node
        self._tail = node
    elseif cur == self._head then
        node._next = self._head
        self._head._prev = node
        self._head = node
    else
        node._next = cur
        node._prev = cur._prev
        cur._prev._next = node
        cur._prev = node
    end
    return node
end

function MoonBus:_unlink(node)
    if node._destroyed then return end
    node._destroyed = true
    local prev, next = node._prev, node._next
    if prev then
        prev._next = next
    else
        self._head = next
    end
    if next then
        next._prev = prev
    else
        self._tail = prev
    end
    if self._cursor and self._cursor.next == node then
        self._cursor.next = next
    end
end

function MoonBus:unmount(node)
    self:_unlink(node)
end

function MoonBus:emit(e)
    if e.sender and e.sender.level < 0 then return end
    local saved = self._cursor
    self._cursor = { next = nil }
    local h = self._head
    while h do
        self._cursor.next = h._next
        if not h._destroyed and h.match(e) then
            local stop = h.consume(e)
            if h.run then P.sync(h.run, e) end
            if h.destroy and h.destroy() then self:_unlink(h) end
            if stop then break end
        end
        h = self._cursor.next
    end
    self._cursor = saved
end

function MoonBus:count()
    local n = 0
    local h = self._head
    while h do
        n = n + 1
        h = h._next
    end
    return n
end

return MoonBus.new()
