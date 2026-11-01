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
