local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

local callbacks = { inventory = {}, container = {} }
AddComponentPostInit = function(name, callback)
    table.insert(callbacks[name], callback)
end

local give_calls = {}

ISR =
{
    IsPlayerInventoryComponent = function() return true end,
    ShouldReserveMarkedSlotsForItem = function() return true end,
    ShouldRoutePlacementByMarks = function() return false end,
    MakePlacementContext = function(data)
        local transfer = ISR.GetTransferContext()
        data.target_guid = data.target_guid or (transfer ~= nil and transfer.target_guid or nil)
        data.source_guid = data.source_guid or (transfer ~= nil and transfer.source_guid or nil)
        data.reason = data.reason or (transfer ~= nil and transfer.reason or nil)
        return data
    end,
    CanFullyStackIntoAvailableStorage = function() return false end,
    GetInventorySlotContainerGUID = function(inventory, storage)
        return storage == inventory.itemslots and inventory.inst.GUID or storage.inst.GUID
    end,
    CanItemUseMarkedSlot = function() return true end,
    GetNextUnmarkedAvailableSlot = function() return nil, nil end,
    CanUseEmptyInventorySlot = function() return false end,
    CanStackIntoInventorySlot = function() return false end,
    GetTransferContext = function()
        return { reason = "shift_transfer", source_guid = 2, target_guid = 1 }
    end,
    Log = function() end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_inventoryhooks.lua")

local overflow = { inst = { GUID = 2 } }

-- 原版 GetNextAvailableSlot 的返回值；包装后不能直接替换方法，只能用可变变量模拟
local old_next_slot, old_next_container = nil, nil

local inventory =
{
    inst = { GUID = 1, HasTag = function(_, tag) return tag == "player" end },
    itemslots = {},
    ignoreoverflow = false,
    GetNumSlots = function() return 3 end,
    GetNextAvailableSlot = function() return old_next_slot, old_next_container end,
    GiveItem = function(_, item, slot)
        table.insert(give_calls, { item = item, slot = slot })
        return true
    end,
}

callbacks.inventory[1](inventory)

-- 1. 物品栏没有未预留的落点：交回原版 GiveItem，让物品进背包；不再强制屏蔽 overflow
local item = { prefab = "meat", components = { inventoryitem = {} } }
assert_equal(inventory:GiveItem(item, nil, nil), true, "no free slot falls back to the original GiveItem")
assert_equal(#give_calls, 1, "original GiveItem runs exactly once")
assert_equal(give_calls[1].slot, nil, "fallback passes no forced slot")
assert_equal(inventory.ignoreoverflow, false, "overflow is not forcibly ignored")

-- 2. 物品栏里有可堆叠的格（原版把落点让给了背包）：应改投物品栏
old_next_slot, old_next_container = 1, overflow
ISR.CanStackIntoInventorySlot = function(_, _, slot) return slot == 3 end
local slot, storage = inventory:GetNextAvailableSlot({ prefab = "grass" })
assert_equal(slot, 3, "stackable main-inventory slot wins over the overflow container")
assert_equal(storage, inventory.itemslots, "stackable slot stays in the main inventory")

-- 2b. 堆叠优先于「原版给的合法格」：原版给了物品栏 1 号空格，仍应堆到 3 号
old_next_slot, old_next_container = 1, inventory.itemslots
slot, storage = inventory:GetNextAvailableSlot({ prefab = "grass" })
assert_equal(slot, 3, "stacking beats the vanilla suggested slot")
assert_equal(storage, inventory.itemslots, "stacking stays in the main inventory")

-- 2c. 没有可堆叠的格时才用原版给的合法格，最后才是未预留空格
ISR.CanStackIntoInventorySlot = function() return false end
old_next_slot, old_next_container = 1, inventory.itemslots
slot, storage = inventory:GetNextAvailableSlot({ prefab = "grass" })
assert_equal(slot, 1, "vanilla suggested slot is used when nothing can stack")
assert_equal(storage, inventory.itemslots, "vanilla slot stays in the main inventory")

-- 3. 兜底搜索先给可堆叠的格，再给空格
old_next_slot, old_next_container = nil, nil
give_calls = {}
ISR.CanStackIntoInventorySlot = function(_, _, slot) return slot == 2 end
inventory:GiveItem({ prefab = "grass", components = { inventoryitem = {} } }, nil, nil)
assert_equal(#give_calls, 1, "fallback placement calls the original GiveItem once")
assert_equal(give_calls[1].slot, 2, "fallback prefers the stackable slot")
