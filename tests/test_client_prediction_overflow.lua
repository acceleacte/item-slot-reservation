local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

-- 只用真实实现：scripts/isr_clientpredict.lua
-- 这一组专测「物品栏按预留规则已经没有落点」时的预测：应当直接画进背包，
-- 而不是让原版退回第一个空格（那往往正是别人的预留格）

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

local function MakeStack(prefab, full)
    return
    {
        prefab = prefab,
        replica =
        {
            inventoryitem = {},
            stackable =
            {
                IsFull = function() return full == true end,
                CanStackWith = function(_, other) return other ~= nil and other.prefab == prefab end,
            },
        },
    }
end

local const_grass = MakeItem("grass")
local const_meat = MakeItem("meat")
local const_meat_stack = MakeStack("meat", false)
local const_ember = MakeItem("willow_ember", true)

local function MakeWorld(slot_count, backpack_slots)
    local player = { GUID = 7 }
    local inventory =
    {
        inst = player,
        slots = {},
        equips = {},
        GetNumSlots = function() return slot_count end,
        GetItemInSlot = function(self, slot) return self.slots[slot] end,
        CanTakeItemInSlot = function(self, item, slot) return slot >= 1 and slot <= slot_count end,
        GetEquips = function(self) return self.equips end,
    }
    player.replica = { inventory = inventory }

    local backpack = { slots = {} }
    local backpack_replica =
    {
        slots = backpack.slots,
        GetNumSlots = function() return backpack_slots end,
        GetItemInSlot = function(self, slot) return self.slots[slot] end,
        CanTakeItemInSlot = function(self, item, slot) return slot >= 1 and slot <= backpack_slots end,
    }

    local backpack_classified = { _parent = player, _busy = false }
    backpack_classified.IsBusy = function(self) return self._busy end
    function backpack_classified:ReceiveItem(item)
        local replica = backpack_replica
        for slot = 1, replica:GetNumSlots() do
            if replica:GetItemInSlot(slot) == nil then
                replica.slots[slot] = item
                return 0
            end
        end
        return nil
    end
    backpack_replica.classified = backpack_classified

    -- 原版预测的近似：只看物品栏，不做背包兜底（这正是「回退后闪进预留格」的来源）
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
    classified.GetOverflowContainer = function() return backpack_replica end

    for _, hook in ipairs(hooks) do
        hook(classified)
    end

    return player, inventory, classified, backpack_replica, backpack_classified
end

local function Reset(inventory, backpack_replica, marked)
    inventory.slots = {}
    backpack_replica.slots = {}
    marks = marked
end

local player, inventory, classified, backpack_replica, backpack_classified = MakeWorld(3, 2)
local_player = player

local const_reserved_all = { ["7:1"] = "grass", ["7:2"] = "twigs", ["7:3"] = "log" }

-- 1. CanPredictLandInInventory：全预留 + 物品自己没有预留格 → 物品栏没有落点
Reset(inventory, backpack_replica, const_reserved_all)
assert_equal(ISR.CanPredictLandInInventory(inventory, const_meat), false, "全预留时物品栏没有落点")

-- 2. 有未预留空格 → 有落点
Reset(inventory, backpack_replica, { ["7:1"] = "grass" })
assert_equal(ISR.CanPredictLandInInventory(inventory, const_meat), true, "未预留空格算落点")

-- 3. 未预留格里堆着同类未满堆 → 有落点
inventory.slots[2] = const_meat_stack
assert_equal(ISR.CanPredictLandInInventory(inventory, const_meat_stack), true, "未预留格的同类未满堆算落点")

-- 4. 别人预留格里堆着同类未满堆 → 不算落点（服务端也不占别人的预留格）
Reset(inventory, backpack_replica, { ["7:1"] = "grass", ["7:2"] = "twigs", ["7:3"] = "log" })
inventory.slots[2] = const_meat_stack
assert_equal(ISR.CanPredictLandInInventory(inventory, const_meat_stack), false, "别人的预留格不算落点")

-- 5. 自己有空的预留格 → 有落点，即便其余格全被占
Reset(inventory, backpack_replica, { ["7:1"] = "grass", ["7:2"] = "twigs", ["7:3"] = "meat" })
assert_equal(ISR.CanPredictLandInInventory(inventory, const_meat), true, "自己的空预留格算落点")

-- 6. 装备栏里能堆叠的装备也算落点（原版会先堆在那里）
Reset(inventory, backpack_replica, const_reserved_all)
inventory.equips.body = const_meat_stack
assert_equal(ISR.CanPredictLandInInventory(inventory, const_meat_stack), true, "装备栏堆叠算落点")
inventory.equips = {}

-- 7. 口袋专用物品永远算有落点（服务端不受预留约束）
Reset(inventory, backpack_replica, const_reserved_all)
assert_equal(ISR.CanPredictLandInInventory(inventory, const_ember), true, "口袋专用物品不受预留限制")

-- 8. 核心场景：物品栏全预留 + 有背包 → 预测直接画进背包，物品栏一格都不动
Reset(inventory, backpack_replica, const_reserved_all)
assert_equal(classified:ReceiveItem(const_meat), 0, "预测给出背包落点")
assert_equal(inventory.slots[1], nil, "1 号预留格没被占")
assert_equal(inventory.slots[2], nil, "2 号预留格没被占")
assert_equal(inventory.slots[3], nil, "3 号预留格没被占")
assert_equal(backpack_replica.slots[1], const_meat, "肉直接预测进背包")

-- 9. 物品栏有落点时仍然进物品栏，不越过物品栏去背包
Reset(inventory, backpack_replica, { ["7:1"] = "grass" })
assert_equal(classified:ReceiveItem(const_meat), 0, "有落点时照常预测")
assert_equal(inventory.slots[2], const_meat, "落到未预留的 2 号格")
assert_equal(backpack_replica.slots[1], nil, "背包没被占用")

-- 10. 背包满：服务端同样放不下，预测直接放弃，不留残影
Reset(inventory, backpack_replica, const_reserved_all)
backpack_replica.slots[1] = const_grass
backpack_replica.slots[2] = const_grass
assert_equal(classified:ReceiveItem(const_meat), nil, "没有落点时不预测")
assert_equal(inventory.slots[1], nil, "预留格没被占")
assert_equal(backpack_replica.slots[1], const_grass, "背包内容不变")

-- 11. 背包正在刷新（busy）：退回原版预测，保证这次点击不丢
Reset(inventory, backpack_replica, const_reserved_all)
backpack_classified._busy = true
assert_equal(classified:ReceiveItem(const_meat), 0, "背包忙时退回原版预测")
assert_equal(inventory.slots[1], const_meat, "退回后临时占用第一个格（服务端会接管）")
backpack_classified._busy = false

-- 12. 窗口在调用结束后必须关掉
assert_equal(ISR.CanPredictIntoInventorySlot(inventory, const_meat, 1), true, "预测窗口已关闭")
