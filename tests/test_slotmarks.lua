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

local server_handlers = {}
AddModRPCHandler = function(_, name, handler) server_handlers[name] = handler end
AddClientModRPCHandler = function() end

local SlotMarkStore = dofile(ISR_TEST_ROOT.."/scripts/components/isr_slotmarkstore.lua")
local slot_item = { prefab = "cutgrass" }
local player = { GUID = 1, components = {} }
local portable = { GUID = 2, components = {} }
player.components.isr_slotmarkstore = SlotMarkStore(player)
player.components.inventory =
{
    GetItemInSlot = function() return slot_item end,
}
portable.components.isr_slotmarkstore = SlotMarkStore(portable)
portable.components.isr_slotmarkstore:SetMark(3, "log", 8)

local known_prefabs = { cutgrass = true, twigs = true, log = true }

ISR =
{
    RPC_NAMESPACE = "test",
    RPC_SET_MARK = "set",
    RPC_SYNC_MARK = "sync",
    RPC_SYNC_BEGIN = "begin",
    RPC_SYNC_END = "end",
    GetPersonalStorageInstances = function() return { player, portable } end,
    GetSlotKey = function(guid, slot) return tostring(guid)..":"..tostring(slot) end,
    IsValidPrefabKey = function(key) return known_prefabs[key] == true end,
    GetSlotMarkStoreForGUID = function(_, guid)
        return guid == player.GUID and player.components.isr_slotmarkstore or portable.components.isr_slotmarkstore
    end,
    GetStorageAdapter = function()
        return
        {
            GetSlotCount = function() return 15 end,
            GetItemInSlot = function() return slot_item end,
        }
    end,
    IsMarkableContainerForPlayer = function() return true end,
    ToNumber = tonumber,
    Log = function() end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_slotmarks.lua")

assert_equal(ISR.GetNextServerMarkOrder(player), 9, "new order follows the maximum portable mark order")

-- 格子里是别的东西时拒绝下标记，并回推服务端真实状态
player.components.isr_slotmarkstore:SetMark(1, "log", 10)
local synced_prefab = false
ISR.SyncMarkToClient = function(_, _, _, prefab) synced_prefab = prefab end
server_handlers.set(player, player, 1, "twigs")
assert_equal(player.components.isr_slotmarkstore:GetMark(1).prefab, "log", "occupied slot keeps authoritative mark")
assert_equal(synced_prefab, "log", "rejected update syncs the authoritative mark")

-- 格子里放的正是要预留的那种物品时，服务端必须接受（V+左键固定已有物品的格子）
server_handlers.set(player, player, 2, "cutgrass")
assert_equal(player.components.isr_slotmarkstore:GetMark(2).prefab, "cutgrass", "matching occupied slot accepts the mark")

-- 未知 prefab 直接拒绝
server_handlers.set(player, player, 4, "no_such_thing")
assert_equal(player.components.isr_slotmarkstore:GetMark(4), nil, "unknown prefab is rejected")

-- 空串 = 清除
server_handlers.set(player, player, 2, "")
assert_equal(player.components.isr_slotmarkstore:GetMark(2), nil, "empty prefab clears the mark")

-- 越界槽位拒绝
server_handlers.set(player, player, 99, "twigs")
assert_equal(player.components.isr_slotmarkstore:GetMark(99), nil, "out-of-range slot is rejected")
