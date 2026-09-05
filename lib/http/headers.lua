--- headers.lua - HTTP 头部解析工具（client/server 共用）
--- 把原始 header 段文本解析成表：名字小写化，重复头合并成数组。

local M = {}

function M.parse_headers(raw)
    raw = raw or ""
    local headers = {}
    local function add(k, v)
        local cur = headers[k]
        if cur == nil then
            headers[k] = v
        elseif type(cur) == "table" then
            cur[#cur + 1] = v
        else
            headers[k] = { cur, v }
        end
    end
    for line in (raw:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
        local l = line:gsub("\r", "")
        if l ~= "" and not l:match("^HTTP/") then
            local name, value = l:match("^([^:]+):%s*(.*)$")
            if name then
                add(name:lower(), value)
            end
        end
    end
    return headers
end

return M
