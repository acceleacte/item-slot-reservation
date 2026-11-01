local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

-- 只用真实实现：scripts/isr_clientpredict.lua。
-- 原版 prefabs/inventory_classified 的 ReceiveItem 用「第一个能放的空格」近似，
-- 足以验证预测守卫把哪些格让了出去。

local hooks = {}
local marks = nil
local local_player = nil

ISR =
{
    Log = function() end,
    NormalizePrefabKey = function(value)
        if value == nil then
            return nil
        end
        local key = string.lower(tostring(value))
        return key ~= "" and key or nil
    end,
    GetSlotKey = function(container_guid, slot)
        return tostring(container_guid)..":"..tostring(slot)
    end,
    GetLocalPlayer = function() return local_player end,
    GetClientMarks = function() return marks end,
    IsPocketOnlyItem = function(item)
        return item ~= nil and item.pocket_only == true
    end,
}

AddPrefabPostInit = function(prefab, fn)
    if prefab == "inventory_classified" then
        table.insert(hooks, fn)
    end
end

dofile(ISR_TEST_ROOT.."/scripts/isr_clientpredict.lua")

local function MakeItem(prefab, pocket_only)
    return { prefab = prefab, pocket_only = pocket_only == true, replica = { inventoryitem = {} } }
end

local const_grass = MakeItem("grass")
local const_meat = MakeItem("meat")
local const_ember = MakeItem("willow_ember", true)

local function MakeWorld(slot_count)
    local player = { GUID = 7 }
    local inventory =
    {
        inst = player,
        slots = {},
        GetNumSlots = function() return slot_count end,
        GetItemInSlot = function(self, slot) return self.slots[slot] end,
        CanTakeItemInSlot = function(self, item, slot)
            return slot >= 1 and slot <= slot_count
        end,
    }
    player.replica = { inventory = inventory }

    local classified = { _parent = player }
    function classified:ReceiveItem(item)
        local replica = self._parent.replica.inventory
        for slot = 1, replica:GetNumSlots() do
            if replica:CanTakeItemInSlot(item, slot) and replica:GetItemInSlot(slot) == nil then
                replica.slots[slot] = item
                return 0
            end
        end
        return nil
    end

    for _, hook in ipairs(hooks) do
        hook(classified)
    end

    return player, inventory, classified
end

local function Reset(inventory, marked)
    inventory.slots = {}
    marks = marked
end

local player, inventory, classified = MakeWorld(3)
local_player = player

-- 1. 窗口没开时一切照旧：不干预任何格子。
Reset(inventory, { ["7:1"] = "grass" })
assert_equal(ISR.CanPredictIntoInventorySlot(inventory, const_meat, 1), true, "窗口外不干预")

-- 2. 预测期间：没有预留格的物品不得占用别人的预留格。
Reset(inventory, { ["7:1"] = "grass" })
assert_equal(classified:ReceiveItem(const_meat), 0, "跳过预留格后仍能在物品栏里找到落点")
assert_equal(inventory.slots[1], nil, "1 号格（草）不被肉占用")
assert_equal(inventory.slots[2], const_meat, "肉落到 2 号未预留格")

-- 3. 有自己的空预留格时，其它空格让出去，跟服务端的优先级一致。
Reset(inventory, { ["7:3"] = "grass" })
assert_equal(classified:ReceiveItem(const_grass), 0, "草能找到自己的预留格")
assert_equal(inventory.slots[3], const_grass, "草直接落到自己的 3 号预留格")
assert_equal(inventory.slots[1], nil, "1 号空格没有被提前占用")

-- 4. 物品栏全被预留、这个物品自己没有预留格：预测不得借用任何预留格。
--    这个桩里没有背包，等于「这一单本来就没有落点」，预测应当放弃（不画、也不发 RPC）。
Reset(inventory, { ["7:1"] = "grass", ["7:2"] = "twigs", ["7:3"] = "log" })
assert_equal(classified:ReceiveItem(const_meat), nil, "没有落点时不预测")
assert_equal(inventory.slots[1], nil, "预留格一个都没被占")
assert_equal(inventory.slots[2], nil, "预留格一个都没被占")
assert_equal(inventory.slots[3], nil, "预留格一个都没被占")

-- 5. 口袋里专用物品不受守卫约束（服务端也放行），照原样预测。
Reset(inventory, { ["7:1"] = "grass" })
assert_equal(classified:ReceiveItem(const_ember), 0, "余烬照常预测进物品栏")
assert_equal(inventory.slots[1], const_ember, "余烬可以落进被预留的 1 号格")

-- 6. 窗口在调用结束后必须关掉，不能影响后续的拖拽/交换判定。
assert_equal(ISR.CanPredictIntoInventorySlot(inventory, const_meat, 1), true, "预测窗口已关闭")
assert_equal(inventory.CanTakeItemInSlot(inventory, const_meat, 1), true, "守卫不残留")

-- 7. 没有标记时完全放行。
Reset(inventory, nil)
assert_equal(ISR.CanPredictIntoInventorySlot(inventory, const_meat, 1), true, "无标记时不拦路")
assert_equal(classified:ReceiveItem(const_meat), 0, "无标记时预测照常成功")
assert_equal(inventory.slots[1], const_meat, "无标记时落进 1 号格")

-- 8. 递归预测（同一单里的剩余部分）不会把窗口提前关掉。
Reset(inventory, { ["7:1"] = "grass" })
ISR.BeginClientPrediction(const_meat)
assert_equal(ISR.CanPredictIntoInventorySlot(inventory, const_meat, 1), false, "窗口对递归调用仍然有效")
ISR.EndClientPrediction(nil)
assert_equal(ISR.CanPredictIntoInventorySlot(inventory, const_meat, 1), true, "手动关闭后恢复")
