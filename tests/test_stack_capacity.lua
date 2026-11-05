local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

ISR =
{
    GetContainerSlotCount = function(container) return container:GetNumSlots() end,
    GetServerSlotMark = function() return nil end,
    MarkMatchesItem = function() return false end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_candidates.lua")

local item =
{
    prefab = "rocks",
    skinname = nil,
    components =
    {
        inventoryitem = {},
        stackable =
        {
            StackSize = function() return 8 end,
            CanStackWith = function() return true end,
        },
    },
}

local function ExistingStack(room)
    return
    {
        components =
        {
            stackable =
            {
                RoomLeft = function() return room end,
                IsFull = function() return false end,
            },
        },
    }
end

local overflow =
{
    inst = { GUID = 2, components = { inventoryitem = {} } },
    slots = { [1] = ExistingStack(4) },
    acceptsstacks = true,
    GetNumSlots = function() return 1 end,
    GetItemInSlot = function(self, slot) return self.slots[slot] end,
    CanTakeItemInSlot = function() return true end,
    ShouldPrioritizeContainer = function() return false end,
}

local inventory =
{
    inst = { GUID = 1 },
    itemslots = { [1] = ExistingStack(4) },
    acceptsstacks = true,
    CanTakeItemInSlot = function() return true end,
    GetOverflowContainer = function() return overflow end,
    GetSpecializedContainers = function() return nil end,
}

assert_equal(ISR.CanFullyStackIntoAvailableStorage(inventory, item), true, "stack room is aggregated across inventory and overflow")

overflow.slots[1] = ExistingStack(3)
assert_equal(ISR.CanFullyStackIntoAvailableStorage(inventory, item), false, "insufficient aggregate room is rejected")

-- CanStackIntoInventorySlot：格中同类未满才算可用，空格不算堆叠目标
inventory.GetItemInSlot = function(self, slot) return self.itemslots[slot] end

local full_stack = { components = { stackable = { IsFull = function() return true end } } }
local foreign_item =
{
    prefab = "twigs",
    components =
    {
        inventoryitem = {},
        stackable = { CanStackWith = function() return false end },
    },
}

assert_equal(ISR.CanStackIntoInventorySlot(inventory, item, 1), true, "same-prefab unfinished stack accepts the item")
assert_equal(ISR.CanStackIntoInventorySlot(inventory, item, 2), false, "empty slot is not a stack target")

inventory.itemslots[1] = full_stack
assert_equal(ISR.CanStackIntoInventorySlot(inventory, item, 1), false, "full stack is rejected")

inventory.itemslots[1] = ExistingStack(4)
assert_equal(ISR.CanStackIntoInventorySlot(inventory, foreign_item, 1), false, "different prefab is rejected")
assert_equal(ISR.CanStackIntoInventorySlot(nil, item, 1), false, "missing inventory is rejected")
