Asset = function(kind, path) return { kind = kind, path = path } end
GetModConfigData = function(name)
    local defaults =
    {
        mark_modifier = "CTRL",
        icon_opacity = 0.35,
        debug_log = false,
        pickup_to_container = true,
        pin_key = "V",
        pin_modifier = "NONE",
    }
    return defaults[name]
end

-- 服务端跑着 scripts/strict.lua：读 _G 上没声明过的名字会抛 "variable is not declared"，
-- GLOBAL["Xxx"] 写错一个名字就能把整台服务器打崩（0.1.4 第一次装的时候就是
-- GLOBAL["IsMasterSimulation"] —— 它其实是 isr_markstores 里的局部函数，不是全局）
-- 这里照着 strict 的行为造一个 GLOBAL，把「模组允许碰的全局名」钉死在这张表里
local declared = {}
local global_proxy = {}
setmetatable(global_proxy,
{
    __index = function(_, name)
        if not declared[name] then
            error("variable '"..tostring(name).."' is not declared", 2)
        end
        return rawget(global_proxy, name)
    end,
    __newindex = function(_, name, value)
        declared[name] = true
        rawset(global_proxy, name, value)
    end,
})

GLOBAL = global_proxy
assert(pcall(function() return GLOBAL.NotARealGlobal end) == false,
    "the strict GLOBAL proxy must reject undeclared names")
GLOBAL.tonumber = tonumber
GLOBAL.debug = debug
GLOBAL.error = error
GLOBAL.pcall = pcall
GLOBAL.select = select
GLOBAL.unpack = table.unpack
GLOBAL.xpcall = xpcall
GLOBAL.EQUIPSLOTS = { HEAD = "head", HANDS = "hands", BODY = "body", BEARD = "beard" }
GLOBAL.TheWorld = { ismastersim = true }
GLOBAL.LOC = nil
GLOBAL.Prefabs = {}
GLOBAL.PICKUPSOUNDS = { wood = "aqol/new_test/wood", DEFAULT_FALLBACK = "dontstarve/HUD/collect_resource" }
GLOBAL.MOUSEBUTTON_LEFT = 1000
GLOBAL.MOUSEBUTTON_RIGHT = 1001
GLOBAL.MOUSEBUTTON_MIDDLE = 1002
GLOBAL.CONTROL_PRIMARY = 0
GLOBAL.CONTROL_SECONDARY = 1
GLOBAL.CONTROL_ACCEPT = 29
GLOBAL.KEY_V = 118
GLOBAL.KEY_B = 98
GLOBAL.KEY_N = 110
GLOBAL.KEY_G = 103
GLOBAL.KEY_F = 102
GLOBAL.KEY_C = 99
GLOBAL.KEY_X = 120
GLOBAL.KEY_Z = 122
GLOBAL.KEY_R = 114
GLOBAL.KEY_T = 116
GLOBAL.KEY_H = 104
GLOBAL.KEY_J = 106
GLOBAL.KEY_K = 107
GLOBAL.KEY_L = 108
GLOBAL.KEY_SHIFT = 402
GLOBAL.KEY_CTRL = 401
GLOBAL.KEY_ALT = 400
-- isr_crafting 用到的常驻全局（scripts/recipes.lua / util.lua）
GLOBAL.GetValidRecipe = function() return nil end
GLOBAL.RoundBiasedUp = function(value) return value end

EQUIPSLOTS = GLOBAL.EQUIPSLOTS
TheWorld = GLOBAL.TheWorld

AddComponentPostInit = function() end
AddPlayerPostInit = function() end
AddClassPostConstruct = function() end
AddPrefabPostInit = function() end
AddModRPCHandler = function() end
AddClientModRPCHandler = function() end

modimport = function(path)
    dofile(ISR_TEST_ROOT.."/"..path)
end

dofile(ISR_TEST_ROOT.."/modmain.lua")

if ISR == nil or ISR.MakePlacementContext == nil or ISR.RegisterStorageAdapter == nil then
    error("modmain did not load the refactored ISR modules")
end

-- 运行时同样不能碰未声明的全局：拾取音效就是在服务端这条路上崩的
local played = {}
local owner =
{
    SoundEmitter = { PlaySound = function(_, sound) table.insert(played, sound) end },
}
ISR.PlayPickupSound(owner, { prefab = "log", pickupsound = "wood" })
assert(#played == 1 and played[1] == "aqol/new_test/wood",
    "the pickup sound must only use declared globals")
