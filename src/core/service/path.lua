local path = {}

local APP = "yuemeng"
local home = os.getenv("HOME") or "/"
local configDir

local function xdg(name, fallback)
    local v = os.getenv(name)
    if v and v ~= "" then return v end
    return fallback
end

function path.setConfigDir(dir)
    configDir = dir
end

function path.configDir()
    if configDir then return configDir end
    return xdg("XDG_CONFIG_HOME", home .. "/.config") .. "/" .. APP
end

function path.dataDir()
    return xdg("XDG_DATA_HOME", home .. "/.local/share") .. "/" .. APP
end

function path.cacheDir()
    return xdg("XDG_CACHE_HOME", home .. "/.cache") .. "/" .. APP
end

function path.runtimeDir()
    return xdg("XDG_RUNTIME_DIR", path.cacheDir()) .. "/" .. APP
end

function path.logDir()
    return path.dataDir() .. "/log"
end

return path
