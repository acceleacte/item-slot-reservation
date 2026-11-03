local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

local callbacks = {}

-- 只用真实实现：isr_placement（ShouldReserveMarkedSlotsForItem）+ isr_candidates
-- （IsPocketOnlyItem / CanItemUseMarkedSlot）+ isr_inventoryhooks（GiveItem 包装）。
-- 其余外部依赖用最小桩替掉。
ISR =
{
    GetContainerSlotCount = function(container) return container:GetNumSlots() end,
    GetServerMarks = function(owner) return owner.marks or {} end,
    GetSortedServerMarksForPrefab = function(owner, prefab)
        return owner.marks ~= nil and owner.marks[prefab] or {}
    end,
    Log = function() end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_placement.lua")
dofile(ISR_TEST_ROOT.."/scripts/isr_candidates.lua")

local ember = { prefab = "willow_ember", components = { inventoryitem = { canonlygoinpocket = true } }, IsValid = function() return true end }
local soul = { prefab = "wortox_soul", components = { inventoryitem = { canonlygoinpocketorpocketcontainers = true } }, IsValid = function() return true end }
local grass = { prefab = "grass", components = { inventoryitem = {} }, IsValid = function() return true end }

-- 1. 口袋专用物品的识别。
assert_equal(ISR.IsPocketOnlyItem(ember), true, "以太余烬只能放物品栏")
assert_equal(ISR.IsPocketOnlyItem(soul), true, "沃拓克斯灵魂只能放物品栏/口袋容器")
assert_equal(ISR.IsPocketOnlyItem(grass), false, "普通物品照常参与预留")
assert_equal(ISR.IsPocketOnlyItem(nil), false, "nil 安全")

-- 2. 预留规则必须给口袋专用物品让路，否则物品栏全预留时它们无处可去。
local twigs_mark = { container_guid = 7, slot = 1, prefab = "twigs", order = 1 }
local owner = { GUID = 7, marks = { twigs = { twigs_mark } } }
assert_equal(ISR.ShouldReserveMarkedSlotsForItem(owner, ember), false, "余烬不参与预留")
assert_equal(ISR.ShouldReserveMarkedSlotsForItem(owner, soul), false, "灵魂不参与预留")
assert_equal(ISR.ShouldReserveMarkedSlotsForItem(owner, grass), true, "普通物品仍然参与预留")

-- 3. 落进被预留的格时，把那格的预留解除。
local cleared = {}
ISR.ClearServerSlotMarkIfItemMismatches = function(player, guid, slot, item)
    table.insert(cleared, { guid = guid, slot = slot, prefab = item.prefab })
end
ISR.IsPlayerInventoryComponent = function() return true end
ISR.GetNextUnmarkedAvailableSlot = function() return nil, nil end
ISR.GetInventorySlotContainerGUID = function(inventory, storage)
    return storage == inventory.itemslots and inventory.inst.GUID or storage.inst.GUID
end
ISR.MarkMatchesItem = function(mark, item)
    return mark ~= nil and item ~= nil and mark.prefab == item.prefab
end
ISR.GetServerSlotMark = function(player, container_guid, slot)
    return twigs_mark.container_guid == container_guid and twigs_mark.slot == slot and twigs_mark or nil
end

AddComponentPostInit = function(name, callback)
    if name == "inventory" then
        table.insert(callbacks, callback)
    end
end

dofile(ISR_TEST_ROOT.."/scripts/isr_inventoryhooks.lua")

local give_calls = {}
local inventory =
{
    inst = owner,
    itemslots = {},
    maxslots = 3,
    GetNumSlots = function() return 3 end,
    GetItemInSlot = function() return nil end,
    CanTakeItemInSlot = function() return true end,
    GetOverflowContainer = function() return nil end,
    GetSpecializedContainers = function() return nil end,
    GiveItem = function(_, item, slot)
        table.insert(give_calls, { item = item, slot = slot })
        return 2
    end,
}

for _, callback in ipairs(callbacks) do
    callback(inventory)
end

-- 余烬：即使物品栏有预留格也照常落进去（这里原版给 2 号格），并把该格预留解除。
assert_equal(inventory:GiveItem(ember, nil, nil), 2, "余烬正常落入物品栏")
assert_equal(#cleared, 1, "余烬落进 2 号格后清除该格预留")
assert_equal(cleared[1].slot, 2, "清除的是实际落入的格子")
assert_equal(cleared[1].prefab, "willow_ember", "清除时用的是余烬本身")

-- 灵魂同理。
cleared = {}
give_calls = {}
assert_equal(inventory:GiveItem(soul, nil, nil), 2, "灵魂正常落入物品栏")
assert_equal(#cleared, 1, "灵魂落进 2 号格后清除该格预留")

-- 普通物品：绕过 1 号预留格，落到 2 号；不是口袋专用物品，不做额外清除。
cleared = {}
give_calls = {}
assert_equal(inventory:GiveItem(grass, nil, nil), 2, "普通物品保持原有放置结果")
assert_equal(#give_calls, 1, "普通物品只调用一次原版 GiveItem")
assert_equal(give_calls[1].slot, 2, "普通物品跳过被预留的 1 号格")
assert_equal(#cleared, 0, "普通物品不做口袋专用的清除")
