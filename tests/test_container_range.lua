local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

ISR =
{
    GetGlobalValue = function(name, fallback) return fallback end,
    GetLocalPlayer = function() return nil end,
    GetEntitiesTable = function() return {} end,
    ContainerRangeLimits = { near = 10, medium = 24, far = 48 },
    Config = { container_range = "near" },
}

dofile(ISR_TEST_ROOT.."/scripts/isr_storage.lua")

local function NewEntity(guid, x, z)
    local inst = { GUID = guid, components = {} }
    inst.Transform = { GetWorldPosition = function() return x, 0, z end }
    inst.IsInLimbo = function() return false end
    return inst
end

local player = NewEntity(1, 0, 0)
player.userid = "KU_player"

-- 配置到距离的映射
assert_equal(ISR.GetContainerRangeLimit(), 10, "near range")
ISR.Config.container_range = "medium"
assert_equal(ISR.GetContainerRangeLimit(), 24, "medium range")
ISR.Config.container_range = "far"
assert_equal(ISR.GetContainerRangeLimit(), 48, "far range")
ISR.Config.container_range = "no_such_option"
assert_equal(ISR.GetContainerRangeLimit(), 24, "unknown option falls back to medium")
ISR.Config.container_range = "near"

-- 玩家自己的物品栏：不设限
assert_equal(ISR.IsStorageWithinRange(player, { inst = player }), true,
    "the player's own inventory is always in range")

-- 随身携带的容器（背包、背包里的桶）：多远都算在手边
local carried = NewEntity(2, 500, 500)
carried.components.inventoryitem = { GetGrandOwner = function() return player end }
assert_equal(ISR.IsStorageWithinRange(player, { inst = carried }), true,
    "a carried container is always in range")

-- 世界里的箱子：按距离
local chest = NewEntity(3, 20, 0)
chest.components.inventoryitem = { GetGrandOwner = function() return nil end }
assert_equal(ISR.IsStorageWithinRange(player, { inst = chest }), false, "20 units away is out of near range")
assert_equal(ISR.IsStorageWithinRange(player, { inst = chest }, 24), true, "20 units away is inside medium range")

-- 跟随型容器（切斯特）：没有 inventoryitem，按实际位置判
local chester = NewEntity(4, 5, 0)
assert_equal(ISR.IsStorageWithinRange(player, { inst = chester }), true, "a following Chester next to you is in range")
chester.Transform = { GetWorldPosition = function() return 30, 0, 0 end }
assert_equal(ISR.IsStorageWithinRange(player, { inst = chester }), false, "a Chester left behind is out of near range")

-- 装在容器里的容器（limbo）：没有世界坐标，按宿主容器算距离
local nested_in_chest = NewEntity(5, 0, 0)
nested_in_chest.components.inventoryitem = { GetGrandOwner = function() return chest end }
nested_in_chest.IsInLimbo = function() return true end
assert_equal(ISR.IsStorageWithinRange(player, { inst = nested_in_chest }), false,
    "a container stored inside a distant chest is still out of range")

local nested_in_chester = NewEntity(7, 0, 0)
nested_in_chester.components.inventoryitem = { GetGrandOwner = function() return chester end }
nested_in_chester.IsInLimbo = function() return true end
chester.Transform = { GetWorldPosition = function() return 5, 0, 0 end }
assert_equal(ISR.IsStorageWithinRange(player, { inst = nested_in_chester }), true,
    "a container stored inside a nearby Chester is in range")

-- 没有任何坐标信息的实体不能拦（宁可放行也不要卡住）
local formless = { GUID = 6, components = {} }
assert_equal(ISR.IsStorageWithinRange(player, { inst = formless }), true, "missing transforms are not rejected")
