local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

local callbacks = { inventory = {}, container = {} }
AddComponentPostInit = function(name, callback)
    table.insert(callbacks[name], callback)
end

ISR =
{
    IsPlayerInventoryComponent = function() return true end,
    ShouldReserveMarkedSlotsForItem = function() return true end,
    GetInventorySlotContainerGUID = function(inventory, storage)
        return storage == inventory.itemslots and inventory.inst.GUID or storage.inst.GUID
    end,
    CanItemUseMarkedSlot = function() return true end,
    GetNextUnmarkedAvailableSlot = function() return 99, "unexpected_global_search" end,
    CanUseEmptyInventorySlot = function(inventory, _, slot)
        return slot == 2 and inventory.itemslots[slot] == nil
    end,
    GetTransferContext = function()
        return { reason = "shift_transfer", source_guid = 2, target_guid = 1 }
    end,
    Log = function() end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_inventoryhooks.lua")

local overflow = { inst = { GUID = 2 } }
local inventory =
{
    inst = { GUID = 1, HasTag = function(_, tag) return tag == "player" end },
    itemslots = {},
    GetNumSlots = function() return 3 end,
    GetNextAvailableSlot = function()
        return 1, overflow
    end,
    GiveItem = function() return true end,
}

callbacks.inventory[1](inventory)
local slot, storage = inventory:GetNextAvailableSlot({ prefab = "armor" })
assert_equal(slot, 2, "shift transfer searches the selected main inventory only")
assert_equal(storage, inventory.itemslots, "shift transfer does not return to source overflow")
