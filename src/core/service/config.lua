local config = {
    table = {},
    priorityMap = function(_, pri)
        return pri
    end,
}

function config.load(path)
    local chunk, err = loadfile(path)
    if not chunk then
        error("配置加载失败: " .. tostring(err))
    end
    local ok, res = xpcall(chunk, debug.traceback)
    if not ok then
        error("配置执行失败: " .. tostring(res))
    end
    return res
end

return config
