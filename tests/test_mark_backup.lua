local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

Class = function(constructor)
    local class = {}
    class.__index = class
    return setmetatable(class,
    {
        __call = function(_, ...)
            local instance = setmetatable({}, class)
            constructor(instance, ...)
            return instance
        end,
    })
end

local SlotMarkStore = dofile(ISR_TEST_ROOT.."/scripts/components/isr_slotmarkstore.lua")

local player_callbacks = {}
AddPlayerPostInit = function(fn) table.insert(player_callbacks, fn) end
AddComponentPostInit = function() end
AddModRPCHandler = function() end
AddClientModRPCHandler = function() end
SendModRPCToClient = function() end
GetClientModRPC = function(namespace, name) return { namespace = namespace, name = name } end

local syncs = 0
ISR =
{
    RPC_NAMESPACE = "test_namespace",
    RPC_SET_MARK = "set",
    RPC_SYNC_MARK = "sync",
    RPC_SYNC_BEGIN = "begin",
    RPC_SYNC_END = "end",
    RPC_REQUEST_SYNC = "request",
    GetServerMarks = function() return {} end,
    ToNumber = tonumber,
    NormalizePrefabKey = function(value)
        local key = value ~= nil and string.lower(tostring(value)) or nil
        return key ~= "" and key or nil
    end,
    Log = function() end,
    SyncAllMarksToClient = function() syncs = syncs + 1 end,
    EnsureSlotMarkStore = function(inst)
        if inst ~= nil and inst.components.isr_slotmarkstore == nil then
            inst.components.isr_slotmarkstore = SlotMarkStore(inst)
        end
        return inst ~= nil and inst.components.isr_slotmarkstore or nil
    end,
    -- 与 isr_markstores.lua 同一套语义：玩家 → 物品栏/装备栏 → 容器里的容器
    GetPersonalStorageInstances = function(player)
        local list, seen = {}, {}
        local function Add(inst, depth)
            if inst == nil or seen[inst.GUID] then
                return
            end
            seen[inst.GUID] = true
            table.insert(list, inst)

            local container = inst.components.container
            if depth >= 3 or container == nil or container.slots == nil then
                return
            end
            for _, item in pairs(container.slots) do
                Add(item, depth + 1)
            end
        end

        Add(player, 1)
        local inventory = player.components.inventory
        for _, item in pairs(inventory.itemslots) do
            Add(item, 2)
        end
        for _, item in pairs(inventory.equipslots) do
            Add(item, 2)
        end
        return list
    end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_persistence.lua")

-- 模块自己定义了 SyncAllMarksToClient，这里包一层只做计数
local sync_all = ISR.SyncAllMarksToClient
ISR.SyncAllMarksToClient = function(player)
    syncs = syncs + 1
    return sync_all(player)
end

local function NewPlayer(guid)
    local player = { GUID = guid, components = {} }
    player.components.inventory =
    {
        inst = player,
        itemslots = {},
        equipslots = {},
        GetNumSlots = function() return 15 end,
    }
    player.components.isr_slotmarkstore = SlotMarkStore(player)
    player.DoTaskInTime = function(self, _, fn) fn(self) end

    for _, callback in ipairs(player_callbacks) do
        callback(player)
    end
    return player
end

local function NewContainer(guid)
    local inst = { GUID = guid, components = {} }
    inst.components.container = { slots = {} }
    inst.components.isr_slotmarkstore = SlotMarkStore(inst)
    return inst
end

-- 存档：背后的装备栏里放着一个熊皮背包装了三个标记
local player = NewPlayer(1)
local backpack = NewContainer(200)
backpack.components.isr_slotmarkstore:SetMark(1, "goldnugget", 5)
backpack.components.isr_slotmarkstore:SetMark(11, "eyemaskhat", 30)
player.components.inventory.equipslots.back = backpack
player.components.isr_slotmarkstore:SetMark(1, "twigs", 6)

local save_data = {}
player:OnSave(save_data)
assert(save_data.isr_slot_marks ~= nil, "backup snapshot is written to the player save record")

local by_path = {}
for _, entry in ipairs(save_data.isr_slot_marks) do
    by_path[entry.path] = entry
end
assert(by_path.inv ~= nil, "player inventory marks are backed up")
assert(by_path["equip:back"] ~= nil, "equipped container marks are backed up")
assert_equal(#by_path["equip:back"].marks, 2, "both container marks are in the snapshot")

-- 读档：容器数据没跟过来（这里模拟跨 shard 后容器是全新实体）
syncs = 0
local reloaded = NewPlayer(2)
local fresh_backpack = NewContainer(201)
reloaded.components.inventory.equipslots.back = fresh_backpack
reloaded:OnLoad(save_data)

assert_equal(fresh_backpack.components.isr_slotmarkstore:GetMark(1).prefab, "goldnugget", "container mark is restored from backup")
assert_equal(fresh_backpack.components.isr_slotmarkstore:GetMark(11).prefab, "eyemaskhat", "second container mark is restored")
assert_equal(reloaded.components.isr_slotmarkstore:GetMark(1).prefab, "twigs", "inventory mark is restored")
assert_equal(syncs, 1, "restored marks are pushed to the client once")

-- 容器自己的数据还在时以实体为准，不覆盖已有标记
local kept_player = NewPlayer(3)
local kept_backpack = NewContainer(202)
kept_backpack.components.isr_slotmarkstore:SetMark(1, "log", 9)
kept_player.components.inventory.equipslots.back = kept_backpack
kept_player:OnLoad(save_data)
assert_equal(kept_backpack.components.isr_slotmarkstore:GetMark(1).prefab, "log", "existing mark wins over the backup")
assert_equal(kept_backpack.components.isr_slotmarkstore:GetMark(11).prefab, "eyemaskhat", "missing slot is still filled from the backup")

-- 容器不在了（丢地上/换角色）：不报错，也不写错地方
local gone_player = NewPlayer(4)
gone_player:OnLoad(save_data)
assert_equal(gone_player.components.isr_slotmarkstore:GetMark(1).prefab, "twigs", "player marks still restore when the container is gone")

-- 没有任何标记时不写备份字段
local blank = NewPlayer(5)
local blank_data = {}
blank:OnSave(blank_data)
assert_equal(blank_data.isr_slot_marks, nil, "no marks means no backup key")

-- 嵌套：背包第 3 格里的桶有自己的标记，路径要带层
local nested = NewPlayer(6)
local outer = NewContainer(300)
local inner = NewContainer(301)
outer.components.container.slots[3] = inner
nested.components.inventory.equipslots.back = outer
inner.components.isr_slotmarkstore:SetMark(2, "bonestew", 40)

local nested_data = {}
nested:OnSave(nested_data)

local nested_entry
for _, entry in ipairs(nested_data.isr_slot_marks) do
    if entry.path == "equip:back/3" then
        nested_entry = entry
    end
end
assert(nested_entry ~= nil, "nested container path is recorded")
assert_equal(#nested_entry.marks, 1, "nested container marks are backed up")
assert_equal(ISR.ResolveStoragePath(nested, "equip:back/3"), inner, "nested path resolves back to the sack")

-- 读档：外层背包还在，桶也在同一格，标记照样补回来
local nested_reload = NewPlayer(7)
local outer2 = NewContainer(310)
local inner2 = NewContainer(311)
outer2.components.container.slots[3] = inner2
nested_reload.components.inventory.equipslots.back = outer2
nested_reload:OnLoad(nested_data)
assert_equal(inner2.components.isr_slotmarkstore:GetMark(2).prefab, "bonestew", "nested mark is restored")

-- 桶换到别的格子：路径失效，不能把标记补到错误的容器
local moved = NewPlayer(8)
local outer3 = NewContainer(320)
local inner3 = NewContainer(321)
outer3.components.container.slots[5] = inner3
moved.components.inventory.equipslots.back = outer3
moved:OnLoad(nested_data)
assert_equal(inner3.components.isr_slotmarkstore:GetMark(2), nil, "mark is not written into the wrong slot")
