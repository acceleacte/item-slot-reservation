ISR = ISR or {}

-- ---------------------------------------------------------------------------
-- 客户端能力登记
--   all_clients_require_mod = false：进世界的玩家可能没装本模组。
--   只有发过 ISR RPC 的玩家才确定带客户端部分，才往回收标记同步；
--   没装的玩家一条 RPC 都收不到，避免未知模组 RPC 落在客户端。
-- ---------------------------------------------------------------------------
ISR._capable_clients = ISR._capable_clients or {}

function ISR.MarkClientCapable(player)
    if player ~= nil and player.userid ~= nil and player.userid ~= "" then
        ISR._capable_clients[player.userid] = true
        return true
    end

    return false
end

function ISR.IsClientCapable(player)
    return player ~= nil
        and player.userid ~= nil
        and ISR._capable_clients[player.userid] == true
end

function ISR.SyncMarkToClient(player, container_guid, slot, prefab, play_clear_sound)
    if not ISR.IsClientCapable(player) then
        return
    end

    local container_inst = container_guid == player.GUID
        and player
        or ISR.GetContainerInstFromGUID(container_guid)
    SendModRPCToClient(
        GetClientModRPC(ISR.RPC_NAMESPACE, ISR.RPC_SYNC_MARK),
        player.userid,
        container_inst,
        slot,
        prefab or "",
        play_clear_sound == true
    )
end

function ISR.SyncAllMarksToClient(player)
    if not ISR.IsClientCapable(player) then
        return
    end

    SendModRPCToClient(GetClientModRPC(ISR.RPC_NAMESPACE, ISR.RPC_SYNC_BEGIN), player.userid)
    for _, mark in pairs(ISR.GetServerMarks(player)) do
        ISR.SyncMarkToClient(player, mark.container_guid, mark.slot, mark.prefab)
    end
    SendModRPCToClient(GetClientModRPC(ISR.RPC_NAMESPACE, ISR.RPC_SYNC_END), player.userid)
end

-- ---------------------------------------------------------------------------
-- 0.1.0 的旧存档迁移（当时标记按 eslot / player_inventory 等字段记录）
-- 新存档由 isr_slotmarkstore 组件自己负责，这里只在读到旧字段时跑一次。
-- ---------------------------------------------------------------------------
local function ResolveLegacyContainer(player, saved)
    local inventory = player ~= nil and player.components ~= nil and player.components.inventory or nil
    if inventory == nil or saved == nil then
        return nil
    elseif saved.kind == "player_inventory" then
        return player, inventory
    elseif saved.kind == "inventory_item" then
        local item = inventory:GetItemInSlot(saved.item_slot)
        return item, item ~= nil and item.components ~= nil and (item.components.container or item.components.inventory) or nil
    elseif saved.kind == "equipped_item" then
        local item = inventory:GetEquippedItem(saved.equip_slot)
        return item, item ~= nil and item.components ~= nil and (item.components.container or item.components.inventory) or nil
    end
end

local function ReservePlayerMarkOrder(player, order)
    local store = ISR.GetSlotMarkStoreForGUID(player, player ~= nil and player.GUID or nil, true)
    if store ~= nil then
        store:ReserveOrder(order)
    end
end

function ISR.RestorePersistentMarks(player, records)
    if player == nil or records == nil then
        return
    end

    for _, saved in ipairs(records) do
        local container_inst, container = ResolveLegacyContainer(player, saved)
        local slot = ISR.ToNumber(saved.slot)
        local prefab = ISR.NormalizePrefabKey ~= nil and ISR.NormalizePrefabKey(saved.prefab or saved.eslot) or nil
        local reason = container_inst == nil and "container"
            or container == nil and "component"
            or (slot == nil or slot < 1) and "slot"
            or slot > ISR.GetContainerSlotCount(container) and "slot_range"
            or prefab == nil and "prefab"
            or nil

        if reason == nil then
            local store = ISR.EnsureSlotMarkStore(container_inst)
            if store ~= nil and store:GetMark(slot) == nil then
                local order = ISR.ToNumber(saved.order) or ISR.GetNextServerMarkOrder(player)
                ReservePlayerMarkOrder(player, order)
                store:SetMark(slot, prefab, order)
                ISR.Log("Legacy mark migrated", "container", tostring(container_inst.GUID), "slot", tostring(slot), "prefab", tostring(prefab), "order", tostring(order))
            end
        else
            ISR.Log("Legacy mark skipped", "reason", tostring(reason), "kind", tostring(saved.kind), "slot", tostring(saved.slot))
        end
    end

    ISR.SyncAllMarksToClient(player)
end

function ISR.QueueRestorePersistentMarks(player, records)
    if player ~= nil and records ~= nil then
        player:DoTaskInTime(0, function(inst)
            ISR.RestorePersistentMarks(inst, records)
        end)
    end
end

AddComponentPostInit("inventory", function(self)
    if not ISR.IsPlayerInventoryComponent(self) then
        return
    end

    local old_OnLoad = self.OnLoad
    function self:OnLoad(data, newents)
        if old_OnLoad ~= nil then
            old_OnLoad(self, data, newents)
        end

        if data ~= nil and data.item_slot_reservation_marks ~= nil then
            ISR.QueueRestorePersistentMarks(self.inst, data.item_slot_reservation_marks)
        end
    end
end)

AddPlayerPostInit(function(inst)
    local old_OnLoad = inst.OnLoad
    function inst:OnLoad(data)
        if old_OnLoad ~= nil then
            old_OnLoad(self, data)
        end

        if data ~= nil and data.item_slot_reservation_marks ~= nil then
            ISR.QueueRestorePersistentMarks(self, data.item_slot_reservation_marks)
        end
    end
end)

AddModRPCHandler(ISR.RPC_NAMESPACE, ISR.RPC_REQUEST_SYNC, function(player)
    -- 客户端主动要快照 ⇒ 它装了本模组，登记为能力客户端
    ISR.MarkClientCapable(player)
    ISR.SyncAllMarksToClient(player)
end)

function ISR.RequestMarkSnapshot()
    local player = ISR.GetLocalPlayer()
    if player == nil or ISR._client_snapshot_request_pending then
        return false
    end

    ISR._client_snapshot_request_pending = true
    SendModRPCToServer(GetModRPC(ISR.RPC_NAMESPACE, ISR.RPC_REQUEST_SYNC))
    player:DoTaskInTime(0.25, function()
        ISR._client_snapshot_request_pending = nil
    end)
    return true
end
