Asset = function(kind, path) return { kind = kind, path = path } end
GetModConfigData = function(name)
    local defaults =
    {
        mark_modifier = "CTRL",
        icon_opacity = 0.35,
        debug_log = false,
    }
    return defaults[name]
end

GLOBAL =
{
    tonumber = tonumber,
    EQUIPSLOTS = { HEAD = "head", HANDS = "hands", BODY = "body", BEARD = "beard" },
}
EQUIPSLOTS = GLOBAL.EQUIPSLOTS
TheWorld = { ismastersim = true }

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
