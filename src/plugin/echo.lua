local core = require("core")

local echo = {
    name = "echo",
    priority = 0,
}

function echo:init()
    core.moonbus:mount({
        plugin = self.name,
        priority = self.priority,
        match = function(e)
            return e.type == "message"
                and e.raw.text ~= nil
                and e.raw.text:sub(1, 5) == "echo "
        end,
        consume = function(_)
            return false
        end,
        run = function(e)
            e.channel:send(e.raw.text:sub(6)):catch(function(err)
                core.service.log.get("plugin.echo"):error("回复失败: %s", tostring(err))
            end)
        end,
    }, self.name)
end

return echo
