local uv = require("luv")
local P = require("promise")
local cjson = require("cjson")

local debug = {}

local state = {
    pipe = nil,
    path = nil,
}

local function readInt32BE(s, i)
    local a, b, c, d = string.byte(s, i, i + 3)
    return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end

local function packFrame(payload)
    local n = #payload
    return string.char(
        math.floor(n / 0x1000000) % 0x100,
        math.floor(n / 0x10000) % 0x100,
        math.floor(n / 0x100) % 0x100,
        n % 0x100
    ) .. payload
end

local function execute(source)
    local out = {}
    local env = setmetatable({}, { __index = _G })
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        out[#out + 1] = table.concat(parts, "\t")
    end
    local fn, err = load(source, "=debug", "t", env)
    if not fn then
        return { ok = false, output = table.concat(out, "\n"), error = err }
    end
    local results = table.pack(pcall(fn))
    if not results[1] then
        return { ok = false, output = table.concat(out, "\n"), error = tostring(results[2]) }
    end
    local ret = {}
    for i = 2, results.n do
        ret[#ret + 1] = tostring(results[i])
    end
    return { ok = true, output = table.concat(out, "\n"), result = table.concat(ret, "\t") }
end

local function onRequest(client, source)
    P.sync(function()
        local resp = execute(source)
        client:write(packFrame(cjson.encode(resp)))
    end)
end

local function onClient(client)
    local buf = ""
    client:read_start(function(err, data)
        if err then
            client:close()
            return
        end
        if not data then return end
        buf = buf .. data
        while #buf >= 4 do
            local n = readInt32BE(buf, 1)
            if #buf < 4 + n then break end
            local payload = buf:sub(5, 4 + n)
            buf = buf:sub(5 + n)
            onRequest(client, payload)
        end
    end)
end

function debug.start(opts)
    opts = opts or {}
    if state.pipe then return debug end
    local path = opts.path or (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/yuemeng.sock"
    os.remove(path)
    local pipe = uv.new_pipe(false)
    assert(uv.pipe_bind(pipe, path), "debug socket 绑定失败: " .. path)
    uv.listen(pipe, 128, function(err)
        if err then return end
        local client = uv.new_pipe(false)
        if uv.accept(pipe, client) then
            onClient(client)
        else
            client:close()
        end
    end)
    state.pipe = pipe
    state.path = path
    return debug
end

function debug.stop()
    if state.pipe then
        state.pipe:close()
        state.pipe = nil
    end
    if state.path then
        os.remove(state.path)
        state.path = nil
    end
    return debug
end

return debug
