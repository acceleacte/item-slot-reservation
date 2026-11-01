local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

Class = function(constructor)
    local class = {}
    class.__index = class
    return setmetatable(class,
    {
        __call = function(_, ...)
            local instance = setmetatable({}, class)
            constructor(instance, ...)
            return instance
        end,
    })
end

AddComponentPostInit = function() end
AddPlayerPostInit = function() end
TheWorld = { ismastersim = true }

ISR =
{
    GetGlobalValue = function(name, fallback)
        return name == "TheWorld" and TheWorld or fallback
    end,
    GetEntitiesTable = function() return {} end,
    GetLocalPlayer = function() return nil end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_storage.lua")
dofile(ISR_TEST_ROOT.."/scripts/isr_markstores.lua")

-- 组件由 dofile 在全局环境执行，注册表要认得同一个 ISR
local SlotMarkStore = dofile(ISR_TEST_ROOT.."/scripts/components/isr_slotmarkstore.lua")

local function NewContainer(guid, is_valid)
    local inst = { GUID = guid }
    inst.IsValid = function() return is_valid ~= false end
    inst.components = { isr_slotmarkstore = SlotMarkStore(inst) }
    return inst
end

local player = { GUID = 1, components = {} }
player.components.inventory = { inst = player, itemslots = {}, equipslots = {} }

-- 切斯特：没有 inventoryitem，只有 follower
local chester =
{
    GUID = 20,
    components =
    {
        follower = { GetLeader = function() return player end },
        container = { slots = {} },
    },
}
chester.components.isr_slotmarkstore = SlotMarkStore(chester)

assert_equal(#ISR.GetMarkContainerInstances(), 0, "registry starts empty")

-- 写标记的容器自动登记（跟随容器不在玩家物品栏里也能被枚举到）
chester.components.isr_slotmarkstore:SetMark(4, "bonestew", 7)
assert_equal(#ISR.GetMarkContainerInstances(), 1, "a marked follower container is registered")

local listed = ISR.GetMarkContainerInstances()[1]
assert_equal(listed, chester, "registry returns the container entity")
assert_equal(ISR.IsStorageOwnedByPlayer(player, chester), true, "follower container belongs to this player")
assert_equal(ISR.IsStorageOwnedByPlayer({ GUID = 2, components = {} }, chester), false,
    "follower container does not belong to another player")

-- 清空标记后从注册表移除
chester.components.isr_slotmarkstore:ClearMark(4)
assert_equal(#ISR.GetMarkContainerInstances(), 0, "container leaves the registry once it has no marks")

-- 组件被移除时也要注销
local backpack = NewContainer(30)
backpack.components.isr_slotmarkstore:SetMark(1, "twigs", 1)
assert_equal(#ISR.GetMarkContainerInstances(), 1, "marked container is registered")
backpack.components.isr_slotmarkstore:OnRemoveFromEntity()
assert_equal(#ISR.GetMarkContainerInstances(), 0, "removing the component unregisters the container")

-- 实体失效的残留项要被清掉
local ghost = NewContainer(40, true)
ghost.components.isr_slotmarkstore:SetMark(2, "grass", 1)
ghost.IsValid = function() return false end
assert_equal(#ISR.GetMarkContainerInstances(), 0, "invalid entities are dropped from the registry")
assert_equal(ISR._mark_containers[40], nil, "invalid entry is removed from the table")
