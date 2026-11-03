-- 容器 GiveItem 与预留格的两条接线：
--   1. 物品进容器时优先避开预留格（原版自己挑格也要判，不能只看 slot 参数）；
--   2. 没有在线主人的容器（基地箱子）也要走这套，不能整条 early return 掉；
--   3. 真占进预留格且 prefab 不匹配时，解除预留（和物品栏一致）。
local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

local callbacks = { container = {}, inventory = {} }
AddComponentPostInit = function(name, callback)
    table.insert(callbacks[name], callback)
end
AddPlayerPostInit = function() end
TheWorld = { ismastersim = true }

local cleared = {}
local placed_slots = {}
local stub = {}

ISR =
{
    GetGlobalValue = function(name, fallback)
        return name == "TheWorld" and TheWorld or fallback
    end,
    EnsureSlotMarkStore = function(inst)
        inst.components.isr_slotmarkstore = inst.components.isr_slotmarkstore or {}
        return inst.components.isr_slotmarkstore
    end,
    SyncAllMarksToClient = function() end,
    IsPlayerInventoryComponent = function() return false end,
    MakePlacementContext = function(context) return context end,
    TryPlaceByMarks = function() return false end,
    ResolvePlayerStorageOwner = function() return stub.live_owner end,
    GetMarkOwnerPlayer = function() return stub.mark_owner end,
    ShouldReserveMarkedSlotsForItem = function() return stub.reserve end,
    ContainerTreeHasMarkedEmptySlot = function() return stub.has_marked_empty end,
    GetNextUnmarkedContainerAvailableSlot = function() return stub.next_slot, stub.next_slot and stub.self end,
    ClearContainerSlotMarkOnMismatch = function(inst, slot, item)
        cleared[#cleared + 1] =
        {
            guid = inst ~= nil and inst.GUID or nil,
            slot = slot,
            prefab = item ~= nil and item.prefab or nil,
        }
        return true
    end,
    Log = function() end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_markstores.lua")
dofile(ISR_TEST_ROOT.."/scripts/isr_inventoryhooks.lua")

-- 容器桩：原版给 slot 就落 slot，没给就落 4 号格（模拟 GetSpecificSlotForItem）
local function NewContainer(guid)
    local container =
    {
        inst = { GUID = guid, components = {} },
        slots = {},
        GetItemSlot = function(self, item)
            for slot, held in pairs(self.slots) do
                if held == item then
                    return slot
                end
            end
            return nil
        end,
        GiveItem = function(self, item, slot)
            slot = slot or 4
            self.slots[slot] = item
            placed_slots[#placed_slots + 1] = slot
            return true
        end,
    }

    for _, callback in ipairs(callbacks.container) do
        callback(container)
    end

    stub.self = container
    return container
end

-- 1. 自动放入（slot 为 nil）：落点靠 GetItemSlot 找回来再判
local container = NewContainer(4242)
local auto_item = { prefab = "boards" }
assert_equal(container:GiveItem(auto_item, nil), true, "auto placement succeeds")
assert_equal(#cleared, 1, "auto placement still checks the landed slot")
assert_equal(cleared[1].slot, 4, "the landed slot is resolved from GetItemSlot")
assert_equal(cleared[1].guid, 4242, "the container guid is passed through")
assert_equal(cleared[1].prefab, "boards", "the item prefab is passed through")

-- 2. 手动拖入（带 slot）：按给定 slot 判
cleared = {}
placed_slots = {}
assert_equal(container:GiveItem({ prefab = "log" }, 2), true, "explicit slot placement succeeds")
assert_equal(#cleared, 1, "explicit slot placement checks that slot")
assert_equal(cleared[1].slot, 2, "the explicit slot wins over GetItemSlot")
assert_equal(placed_slots[1], 2, "an explicit slot is never redirected")

-- 3. 有预留空格时避开它：没有在线主人，靠 mark store 的 owner 参与路由
cleared = {}
placed_slots = {}
stub.live_owner = nil
stub.mark_owner = { GUID = 7, userid = "KU_player", components = {} }
stub.reserve = true
stub.has_marked_empty = true
stub.next_slot = 2
local chest = NewContainer(5000)
stub.self = chest
assert_equal(chest:GiveItem({ prefab = "boards" }, nil), true, "auto placement into a marked container succeeds")
assert_equal(placed_slots[1], 2, "the item is steered to the unmarked slot")
assert_equal(cleared[1].slot, 2, "the steered slot is the one checked for a mismatched mark")

-- 4. 没有非预留空位时交回原版（而不是直接拒收）
cleared = {}
placed_slots = {}
stub.next_slot = nil
local full_chest = NewContainer(5100)
stub.self = full_chest
assert_equal(full_chest:GiveItem({ prefab = "boards" }, nil), true, "a full unmarked set still accepts the item")
assert_equal(placed_slots[1], 4, "vanilla picks the slot when no unmarked one is free")
assert_equal(cleared[1].slot, 4, "the vanilla-chosen slot is checked for a mismatched mark")

-- 5. 失败时不判（物品没进容器）
cleared = {}
stub.reserve = false
local failing = NewContainer(5200)
failing.GiveItem = function() return false end
assert_equal(failing:GiveItem({ prefab = "log" }, nil), false, "failed placement")
assert_equal(#cleared, 0, "a failed placement clears nothing")

print("PASS test_container_giveitem_marks")
