local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

ISR =
{
    GetGlobalValue = function(_, fallback) return fallback end,
    GetLocalPlayer = function() return nil end,
    GetEntitiesTable = function() return {} end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_storage.lua")
dofile(ISR_TEST_ROOT.."/scripts/isr_candidates.lua")

local inventory =
{
    inst = { GUID = 1 },
    itemslots = {},
    equipslots = {},
    GetOverflowContainer = function() return nil end,
}
local container =
{
    inst = { GUID = 2 },
    slots = {},
    CanTakeItemInSlot = function() return true end,
}

local player =
{
    HasTag = function(_, tag) return tag == "player" end,
    components = {},
}
player.components.inventory = inventory
inventory.inst = player

local portable_inst =
{
    components =
    {
        inventoryitem =
        {
            GetGrandOwner = function() return player end,
        },
    },
}
container.inst = portable_inst

assert_equal(ISR.GetStorageAdapter(inventory, "inventory").name, "inventory", "inventory adapter")
assert_equal(ISR.GetStorageAdapter(container, "container").name, "container", "container adapter")
assert_equal(ISR.ResolvePlayerStorageOwner(inventory, "inventory"), player, "player inventory resolves owner")
assert_equal(ISR.ResolvePlayerStorageOwner(container, "container"), player, "portable container resolves grand owner")

local world_container =
{
    inst = { components = {} },
    slots = {},
    CanTakeItemInSlot = function() return true end,
}
assert_equal(ISR.ResolvePlayerStorageOwner(world_container, "container"), nil, "world container has no player owner")

local custom = { special = true }
ISR.RegisterStorageAdapter("test_custom",
{
    CanHandle = function(_, storage)
        return storage.special == true
    end,
    GetStorageFromEntity = function(_, inst) return inst.special_storage end,
    GetGUID = function() return 99 end,
    GetSlotCount = function() return 3 end,
    GetItemInSlot = function() return nil end,
    CanUseEmptySlot = function() return true end,
    PlaceInSlot = function() return true end,
})

local adapter = ISR.GetStorageAdapter(custom)
assert_equal(adapter.name, "test_custom", "custom adapter is selected")
assert_equal(adapter:GetGUID(custom), 99, "custom adapter contract")
local custom_inst = { special_storage = custom }
assert_equal(ISR.GetStorageFromEntity(custom_inst), custom, "custom storage resolves from its entity")

local replaced = ISR.RegisterStorageAdapter("test_custom",
{
    CanHandle = function(_, storage) return storage.special == true end,
    GetStorageFromEntity = function(_, inst) return inst.special_storage end,
    GetGUID = function() return 100 end,
    GetSlotCount = function() return 1 end,
    GetItemInSlot = function() return nil end,
    CanUseEmptySlot = function() return true end,
    PlaceInSlot = function() return true end,
})
assert_equal(replaced, true, "named adapter can be replaced")
assert_equal(ISR.GetStorageAdapter(custom):GetGUID(custom), 100, "replacement takes effect")

assert_equal(ISR.RegisterStorageAdapter("invalid", {}), false, "invalid adapter is rejected")

-- 固定格里已经有同种物品的未满堆叠时，容器适配器要认这一格（草、树枝并堆），
-- 只判「空不空」会让采集到的资源被推回物品栏
local function NewStack(prefab, stacksize, maxsize)
    return
    {
        prefab = prefab,
        components =
        {
            stackable =
            {
                stacksize = stacksize,
                maxsize = maxsize,
                IsFull = function(self) return self.stacksize >= self.maxsize end,
                CanStackWith = function(_, other) return other.prefab == prefab end,
            },
        },
    }
end

local grass_stack = NewStack("cutgrass", 20, 40)
local full_grass = NewStack("cutgrass", 40, 40)
local picked_grass = NewStack("cutgrass", 1, 40)
local twig_stack = NewStack("twigs", 5, 40)

local stack_container =
{
    inst = { GUID = 7 },
    numslots = 5,
    slots = { [1] = grass_stack, [2] = full_grass, [3] = twig_stack },
    CanTakeItemInSlot = function() return true end,
    AcceptsStacks = function() return true end,
    GetItemInSlot = function(self, slot) return self.slots[slot] end,
}
local container_adapter = ISR.GetStorageAdapter(stack_container, "container")
assert_equal(container_adapter:CanUseEmptySlot(stack_container, picked_grass, 1), false,
    "a filled stack is not an empty slot")
assert_equal(container_adapter:CanUseSlot(stack_container, picked_grass, 1), true,
    "a container slot holding the same partial stack accepts the pickup")
assert_equal(container_adapter:CanUseSlot(stack_container, picked_grass, 2), false,
    "a full stack cannot take more")
assert_equal(container_adapter:CanUseSlot(stack_container, picked_grass, 3), false,
    "a different item cannot stack into the reserved slot")
assert_equal(container_adapter:CanUseSlot(stack_container, picked_grass, 4), true,
    "an empty container slot still works")
