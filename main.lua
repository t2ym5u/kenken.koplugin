local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. _dir .. "common/?.lua;" .. _dir .. "../game-common/?.lua;" .. package.path

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local PluginBase   = require("plugin_base")
local _            = require("gettext")
local KenKenScreen = lrequire("screen")

local KenKen = PluginBase:extend{
    name      = "kenken",
    menu_text = _("KenKen"),
    menu_hint = "tools",
}

function KenKen:createScreen()
    return KenKenScreen:new{ plugin = self }
end

return KenKen
