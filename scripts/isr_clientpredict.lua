ISR = ISR or {}

-- 客户端落点预测守卫。
--
-- 原版的预测路径（prefabs/inventory_classified 的 ReceiveItem）不认预留标记，
-- 永远挑第一个能放的格。于是「自己没有预留格」的物品会被先画进别人的预留格，
-- 等服务端把它送进背包（或送回原处）后再回滚 —— 这一段（一个 RTT）里那格被假占用，
-- 真正属于它的物品反而进不去。
--
-- 两层处理：
-- 1. 计算：按客户端标记先算这一单在物品栏里有没有合法落点（CanPredictLandInInventory）。
--    没有的话服务端一定走背包兜底，这里直接把预测画进背包，不碰物品栏。
-- 2. 守卫：还有合法落点时，预测窗口内让别人的预留格返回假，原版自己的搜索就会跳过它们。

local prediction_item = nil

-- 统计用：记录窗口内被允许 / 被拒绝的格，只在日志里用。
local predict_allowed = nil
local predict_rejected = nil

local function GetPredictMarks(player)
    if player == nil or ISR.GetClientMarks == nil then
        return nil
    end

    local local_player = ISR.GetLocalPlayer()
    if local_player ~= nil and player ~= local_player then
        return nil
    end

    return ISR.GetClientMarks()
end

-- 客户端拿不到 components.inventoryitem，只能问 replica。
local function IsPocketOnlyOnClient(item)
    local replica = item ~= nil and item.replica ~= nil and item.replica.inventoryitem or nil
    if replica ~= nil then
        if replica.CanOnlyGoInPocket ~= nil and replica:CanOnlyGoInPocket() == true then
            return true
        elseif replica.CanOnlyGoInPocketOrPocketContainers ~= nil
            and replica:CanOnlyGoInPocketOrPocketContainers() == true
        then
            return true
        end
    end

    -- 主机自己开服时实体带真实组件，走同一套判断。
    return ISR.IsPocketOnlyItem ~= nil and ISR.IsPocketOnlyItem(item)
end

-- 客户端标记表的键和同步路径保持一致（GetClientContainerGUID 对玩家就是 player.GUID）。
local function GetMarkKey(player, slot)
    local guid = ISR.GetClientContainerGUID ~= nil and ISR.GetClientContainerGUID(player) or nil
    if guid == nil then
        guid = player ~= nil and player.GUID or nil
    end

    return guid ~= nil and ISR.GetSlotKey(guid, slot) or nil
end

local function GetSlotMark(player, slot)
    local marks = GetPredictMarks(player)
    local key = GetMarkKey(player, slot)
    return key ~= nil and marks ~= nil and marks[key] or nil
end

local function FindOwnEmptyMarkedSlot(inventory, player, prefab)
    if GetPredictMarks(player) == nil then
        return nil
    end

    for slot = 1, inventory:GetNumSlots() do
        if GetSlotMark(player, slot) == prefab and inventory:GetItemInSlot(slot) == nil then
            return slot
        end
    end

    return nil
end

local function CanStackOnClient(existing, item)
    local existing_stackable = existing ~= nil and existing.replica ~= nil and existing.replica.stackable or nil
    local item_stackable = item ~= nil and item.replica ~= nil and item.replica.stackable or nil
    return existing_stackable ~= nil
        and item_stackable ~= nil
        and not existing_stackable:IsFull()
        and existing_stackable:CanStackWith(item)
end

-- 按标记判断：这一单在物品栏里还有没有合法落点。
-- 顺序与服务端一致：自己的空预留格 → 同类未满堆（该格没被别人预留）→ 未预留空格 → 装备栏堆叠。
-- 返回假时服务端必定走「交给原版 GiveItem」，也就是背包/随身容器。
--
-- 注意：本函数判「有没有落点」，下面的 CanPredictIntoInventorySlot 判「这一格行不行」。
-- 两者的判定顺序必须一致，改一处就得同步另一处 —— 不一致的表现是预测说没位置、
-- 守卫却放行（或反过来），物品先闪进预留格再被服务端弹走。
function ISR.CanPredictLandInInventory(inventory, item)
    if inventory == nil or item == nil then
        return true
    end

    -- 口袋专用物品不受预留约束（服务端同样放行），物品栏永远算有位置。
    if IsPocketOnlyOnClient(item) then
        return true
    end

    local player = inventory.inst
    if player == nil or GetPredictMarks(player) == nil then
        return true
    end

    local prefab = ISR.NormalizePrefabKey(item.prefab)
    if prefab == nil then
        return true
    end

    if FindOwnEmptyMarkedSlot(inventory, player, prefab) ~= nil then
        return true
    end

    for slot = 1, inventory:GetNumSlots() do
        local existing = inventory:GetItemInSlot(slot)
        if existing ~= nil then
            if CanStackOnClient(existing, item) then
                local mark = GetSlotMark(player, slot)
                if mark == nil or mark == prefab then
                    return true
                end
            end
        elseif GetSlotMark(player, slot) == nil then
            return true
        end
    end

    if inventory.GetEquips ~= nil then
        for _, equipped in pairs(inventory:GetEquips()) do
            if CanStackOnClient(equipped, item) then
                return true
            end
        end
    end

    return false
end

-- 预测窗口内这一格能不能被这个物品占用。窗口外一律 true，不影响其它逻辑。
function ISR.CanPredictIntoInventorySlot(inventory, item, slot)
    if prediction_item == nil or inventory == nil or item == nil or slot == nil then
        return true
    end

    -- 口袋专用物品本来就不受预留约束（服务端同样放行），预测照旧。
    if IsPocketOnlyOnClient(item) then
        return true
    end

    local player = inventory.inst
    local marks = GetPredictMarks(player)
    if marks == nil or player == nil then
        return true
    end

    local prefab = ISR.NormalizePrefabKey(item.prefab)
    if prefab == nil then
        return true
    end

    -- 自己有空的预留格时服务端一定先放那里，其余空格让出去，预测才跟服务端一致。
    local own_slot = FindOwnEmptyMarkedSlot(inventory, player, prefab)
    if own_slot ~= nil then
        if slot == own_slot then
            if predict_allowed ~= nil then
                predict_allowed[#predict_allowed + 1] = slot
            end
            return true
        end

        if predict_rejected ~= nil then
            predict_rejected[#predict_rejected + 1] = slot
        end
        return false
    end

    local mark = GetSlotMark(player, slot)
    if mark == nil or mark == prefab then
        if predict_allowed ~= nil then
            predict_allowed[#predict_allowed + 1] = slot
        end
        return true
    end

    if predict_rejected ~= nil then
        predict_rejected[#predict_rejected + 1] = slot
    end
    return false
end

function ISR.BeginClientPrediction(item)
    local previous = prediction_item
    prediction_item = item
    return previous
end

function ISR.EndClientPrediction(previous)
    prediction_item = previous
end

local function EnsureReplicaGuard(player)
    local replica = player ~= nil and player.replica ~= nil and player.replica.inventory or nil
    if replica == nil
        or replica._isr_prediction_guard
        or replica.CanTakeItemInSlot == nil
    then
        return
    end

    replica._isr_prediction_guard = true
    local old_CanTakeItemInSlot = replica.CanTakeItemInSlot
    replica.CanTakeItemInSlot = function(self, item, slot)
        if ISR.CanPredictIntoInventorySlot(self, item, slot) then
            return old_CanTakeItemInSlot(self, item, slot)
        end

        return false
    end
end

-- 服务端在物品栏放不下时会把它交给原版 GiveItem，落到背包/随身容器。
-- 预测照做一次，回来的 remainder 就是给调用方的答案（含 Shift 转移要发 RPC 的 0）。
-- 第二个返回值说明失败原因：
--   busy  —— 背包正是刷新窗口，一会儿就好，值得退回原版预测保住这次点击
--   none  —— 没有背包 / 来源本身就是背包（ignoreoverflow）
--   full  —— 背包接不住；服务端同样失败，不该预测，也不该发 RPC
local function PredictIntoOverflow(inst, item, count)
    if inst == nil or item == nil or IsPocketOnlyOnClient(item) then
        return nil, "none"
    end

    if inst.GetOverflowContainer == nil then
        return nil, "none"
    end

    local overflow = inst:GetOverflowContainer() -- container replica，忽略 overflow 时是 nil
    local classified = overflow ~= nil and overflow.classified or nil
    if classified == nil or classified.ReceiveItem == nil then
        return nil, "none"
    end

    if classified.IsBusy ~= nil and classified:IsBusy() then
        return nil, "busy"
    end

    return classified:ReceiveItem(item, count), "full"
end

local function JoinSlots(slots)
    if slots == nil or #slots == 0 then
        return "-"
    end

    return table.concat(slots, ",")
end

-- 只有客户端实体带 ReceiveItem（服务端走 netvar 推送，没有这条预测路径）。
AddPrefabPostInit("inventory_classified", function(inst)
    local old_ReceiveItem = inst.ReceiveItem
    if old_ReceiveItem == nil then
        return
    end

    function inst:ReceiveItem(item, count)
        if prediction_item ~= nil then
            -- 已经在预测里了（原版对剩余部分的递归调用），沿用外层窗口。
            return old_ReceiveItem(self, item, count)
        end

        EnsureReplicaGuard(self._parent)

        local inventory = self._parent ~= nil
            and self._parent.replica ~= nil
            and self._parent.replica.inventory
            or nil
        local prefab = tostring(item ~= nil and item.prefab or nil)

        -- 物品栏按预留规则已经放不下：服务端会把它送进背包。预测直接画进背包，
        -- 既不会借用别人的预留格，也不会因为预测失败把这次点击吞掉。
        if inventory ~= nil and not ISR.CanPredictLandInInventory(inventory, item) then
            local overflow_remainder, overflow_reason = PredictIntoOverflow(self, item, count)
            if overflow_remainder ~= nil then
                ISR.Log("Client predict overflow", prefab, "remainder", tostring(overflow_remainder))
                return overflow_remainder
            end

            if overflow_reason == "busy" then
                -- 背包正在刷新，服务端大概率还是会接住；退回原版预测保住这次点击。
                ISR.Log("Client predict overflow busy", prefab)
                return old_ReceiveItem(self, item, count)
            end

            -- 背包不存在或者装不下：服务端同样失败。此时既不该预测（会先闪进别人的
            -- 预留格再弹回），也不该发 RPC —— 这一单本来就没有落点。
            ISR.Log("Client predict dropped", prefab, "overflow", tostring(overflow_reason))
            return nil
        end

        predict_allowed = {}
        predict_rejected = {}
        local previous = ISR.BeginClientPrediction(item)
        local remainder = old_ReceiveItem(self, item, count)
        ISR.EndClientPrediction(previous)

        if remainder == nil then
            ISR.Log(
                "Client predict blocked",
                prefab,
                "allowed", JoinSlots(predict_allowed),
                "rejected", JoinSlots(predict_rejected)
            )
            -- 守卫把预测逼到死角，原版会连 RPC 都不发 —— 玩家看到的是「按了没反应」。
            -- 退回原版预测：那一帧可能闪进预留格，但请求能发出去。
            remainder = old_ReceiveItem(self, item, count)
        end

        predict_allowed = nil
        predict_rejected = nil

        ISR.Log("Client predict end", prefab, "remainder", tostring(remainder))
        return remainder
    end
end)
