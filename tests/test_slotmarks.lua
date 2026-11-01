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
local player = { GUID = 1, userid = "KU_player", components = {} }
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
    GetMarkContainerInstances = function() return { player, portable } end,
    IsStorageOwnedByPlayer = function(_, inst) return inst == player or inst == portable end,
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

-- 切斯特没有眼骨时不跟随任何人：组件语义判不出归属，
-- 但打开它的玩家可以直接标记，归属记在自己名下
local chester = { GUID = 50, components = {} }
chester.components.isr_slotmarkstore = SlotMarkStore(chester)
local chester_container =
{
    IsOpenedBy = function(_, doer) return doer == player end,
}
ISR.GetStorageFromEntity = function(inst) return inst == chester and chester_container or nil end
ISR.IsMarkableContainerForPlayer = function() return false end
ISR.GetStorageAdapter = function()
    return
    {
        GetSlotCount = function() return 15 end,
        GetItemInSlot = function() return nil end,
    }
end
ISR.GetSlotMarkStoreForGUID = function(_, guid)
    return guid == chester.GUID and chester.components.isr_slotmarkstore or nil
end
ISR.GetServerSlotMark = function(_, guid, slot)
    local store = guid == chester.GUID and chester.components.isr_slotmarkstore or nil
    local mark = store ~= nil and store:GetMark(slot) or nil
    return mark ~= nil and { container_guid = guid, slot = slot, prefab = mark.prefab } or nil
end
ISR.SyncMarkToClient = function() end

server_handlers.set(player, chester, 2, "twigs")
assert_equal(chester.components.isr_slotmarkstore:GetMark(2).prefab, "twigs",
    "an opened container accepts a mark even without a resolved owner")
assert_equal(chester.components.isr_slotmarkstore:GetOwner(), "KU_player",
    "the first player to mark becomes the owner")

-- 另一个玩家打开同一个容器也改不了
local other = { GUID = 3, userid = "KU_other", components = { inventory = {} } }
server_handlers.set(other, chester, 3, "log")
assert_equal(chester.components.isr_slotmarkstore:GetMark(3), nil,
    "another player cannot mark someone else's container")

-- 拾取音效：物品直接进容器时物品栏收不到 gotnewitem，得自己按 PICKUPSOUNDS 播一次
local played = {}
local sound_owner =
{
    SoundEmitter = { PlaySound = function(_, sound) table.insert(played, sound) end },
}

ISR.GetGlobalValue = function(name, fallback)
    if name == "PICKUPSOUNDS" then
        return
        {
            wood = "aqol/new_test/wood",
            DEFAULT_FALLBACK = "dontstarve/HUD/collect_resource",
        }
    end
    return fallback
end

ISR.PlayPickupSound(sound_owner, { prefab = "log", pickupsound = "wood" })
assert_equal(played[1], "aqol/new_test/wood", "the pickup sound follows the item's pickupsound")

-- 没设 pickupsound 的物品用原版兜底音
played = {}
ISR.PlayPickupSound(sound_owner, { prefab = "beargerfur_sack" })
assert_equal(played[1], "dontstarve/HUD/collect_resource", "items without a pickupsound use the fallback")

-- 物品自己声明 "NONE"（查不到）时不响
played = {}
ISR.PlayPickupSound(sound_owner, { prefab = "willow_ember", pickupsound = "NONE" })
assert_equal(#played, 0, "an item can silence its own pickup sound")

-- 没有 SoundEmitter 的实体不能炸：直接跳过
played = {}
ISR.PlayPickupSound({ prefab = "player" }, { prefab = "log", pickupsound = "wood" })
ISR.PlayPickupSound(nil, { prefab = "log", pickupsound = "wood" })
assert_equal(#played, 0, "missing sound emitters are skipped silently")
