local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

local callbacks = { inventory = {}, container = {} }
AddComponentPostInit = function(name, callback)
    table.insert(callbacks[name], callback)
end

local policy_calls = 0
local context_calls = 0
local transfer_calls = 0
ISR =
{
    IsPlayerInventoryComponent = function() return false end,
    MakePlacementContext = function()
        context_calls = context_calls + 1
        return {}
    end,
    ShouldRoutePlacementByMarks = function()
        policy_calls = policy_calls + 1
        return false
    end,
    ShouldReserveMarkedSlotsForItem = function()
        policy_calls = policy_calls + 1
        return false
    end,
    GetInventorySlotContainerGUID = function() return nil end,
    CanItemUseMarkedSlot = function() return true end,
    GetTransferContext = function() return nil end,
    WithTransferContext = function(_, fn, ...)
        transfer_calls = transfer_calls + 1
        return fn(...)
    end,
    ClearServerSlotMarkIfItemMismatches = function()
        policy_calls = policy_calls + 1
    end,
    Log = function() end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_inventoryhooks.lua")

local original_get_calls = 0
local original_give_calls = 0
local original_move_calls = 0
local received_item = nil
local received_slot = nil
local received_pos = nil
local itemslots = {}
local inventory =
{
    inst =
    {
        GUID = 77,
        HasTag = function() return false end,
    },
    itemslots = itemslots,
    GetNextAvailableSlot = function()
        original_get_calls = original_get_calls + 1
        return 3, itemslots
    end,
    GiveItem = function(_, item, slot, src_pos)
        original_give_calls = original_give_calls + 1
        received_item = item
        received_slot = slot
        received_pos = src_pos
        return true
    end,
    MoveItemFromAllOfSlot = function(_, slot, container)
        original_move_calls = original_move_calls + 1
        return slot, container
    end,
}

for _, callback in ipairs(callbacks.inventory) do
    callback(inventory)
end

local slot, storage = inventory:GetNextAvailableSlot({ prefab = "shell_cluster" })
assert_equal(slot, 3, "non-player slot query preserves result")
assert_equal(storage, itemslots, "non-player slot query preserves storage")

local item = { prefab = "shell_cluster" }
assert_equal(inventory:GiveItem(item, 1, "ocean"), true, "non-player GiveItem preserves result")
assert_equal(received_item, item, "non-player GiveItem preserves item")
assert_equal(received_slot, 1, "non-player GiveItem preserves slot")
assert_equal(received_pos, "ocean", "non-player GiveItem preserves source position")

local moved_slot, moved_container = inventory:MoveItemFromAllOfSlot(2, "underwater")
assert_equal(moved_slot, 2, "non-player transfer preserves slot")
assert_equal(moved_container, "underwater", "non-player transfer preserves target")

assert_equal(original_get_calls, 1, "original slot query called once")
assert_equal(original_give_calls, 1, "original GiveItem called once")
assert_equal(original_move_calls, 1, "original transfer called once")
assert_equal(context_calls, 0, "non-player inventory does not build placement context")
assert_equal(policy_calls, 0, "non-player inventory does not run ISR policy")
assert_equal(transfer_calls, 0, "non-player inventory does not create transfer context")
