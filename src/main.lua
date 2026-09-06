local P = require("promise")
local path = require("core.service.path")
local config = require("core.service.config")
local platforms = require("core.platforms")
local log = require("core.service.log")

for i = 1, #arg do
    if arg[i] == "--config" and arg[i + 1] then
        path.setConfigDir(arg[i + 1])
    end
end

local configFile = path.configDir() .. "/yuemeng.lua"
local logg = log.get("yuemeng")

local f = io.open(configFile, "rb")
if f then
    f:close()
    config.load(configFile)
    logg:info("已加载配置: %s", configFile)
else
    logg:warn("未找到配置文件: %s", configFile)
end

local list = platforms.list()
for _, p in ipairs(list) do
    p:start()
end
logg:info("启动完成，共 %d 个平台实例", #list)

P.run()
