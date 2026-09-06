local core = {}

core.perm = require("core.perm")
core.channel = require("core.channel")
core.event = require("core.event")
core.platform = require("core.platform")
core.platforms = require("core.platforms")
core.moonbus = require("core.moonbus")
core.plugin = require("core.plugin")
core.debug = require("core.debug")
core.service = {
    path = require("core.service.path"),
    config = require("core.service.config"),
    log = require("core.service.log"),
}

return core
