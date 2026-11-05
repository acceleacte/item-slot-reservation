ISR = ISR or {}
ISR.PERSONAL_STORAGE_DEPTH = ISR.PERSONAL_STORAGE_DEPTH or 3

-- ---------------------------------------------------------------------------
-- 客户端能力登记
--   all_clients_require_mod = false：进世界的玩家可能没装本模组
--   只有发过 ISR RPC 的玩家才确定带客户端部分，才往回收标记同步；
--   没装的玩家一条 RPC 都收不到，避免未知模组 RPC 落在客户端
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
-- 新存档由 isr_slotmarkstore 组件自己负责，这里只在读到旧字段时跑一次
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

-- ---------------------------------------------------------------------------
-- 随身容器的标记备份（存在玩家实体上）
--
-- 正常路径：标记随容器实体的 isr_slotmarkstore 一起存档但容器 prefab 若先
-- AddComponent("container") 再加 inventoryitem（原版 beargerrfur_sack 就是这样），
-- 实体构造时组件还没挂上，读档只会把数据丢掉；跨 shard（下地穴）也依赖引擎原样
-- 搬运组件数据
-- 所以额外存一份「容器在玩家身上的位置 → 标记」快照，读档 / 下地穴后按位置把
-- 空缺的格补回来容器位置只有一层（物品栏第 N 格 / 装备栏某槽 / 玩家自身），
-- 因为标记本来就只允许设在这三处
-- ---------------------------------------------------------------------------
ISR.MARK_BACKUP_KEY = "isr_slot_marks"

-- 路径格式：inv（玩家自己）、inv:3（物品栏第 3 格）、equip:back（装备栏背包）、
-- 以及往容器里再走一层：inv:5/2（物品栏第 5 格的桶里第 2 格）
local function FindStoragePath(inst, target, prefix, depth)
    local container = inst ~= nil and inst.components ~= nil and inst.components.container or nil
    if container == nil or container.slots == nil then
        return nil
    end

    for slot, item in pairs(container.slots) do
        local path = prefix..tostring(slot)
        if item == target then
            return path
        elseif depth < ISR.PERSONAL_STORAGE_DEPTH and item ~= nil then
            local found = FindStoragePath(item, target, path.."/", depth + 1)
            if found ~= nil then
                return found
            end
        end
    end

    return nil
end

local function BuildStoragePath(player, inst)
    if player == nil or inst == nil then
        return nil
    elseif inst == player then
        return "inv"
    end

    local inventory = player.components ~= nil and player.components.inventory or nil
    if inventory == nil then
        return nil
    end

    for slot, item in pairs(inventory.itemslots or {}) do
        local prefix = "inv:"..tostring(slot)
        if item == inst then
            return prefix
        end

        local found = FindStoragePath(item, inst, prefix.."/", 2)
        if found ~= nil then
            return found
        end
    end

    for eslot, item in pairs(inventory.equipslots or {}) do
        local prefix = "equip:"..tostring(eslot)
        if item == inst then
            return prefix
        end

        local found = FindStoragePath(item, inst, prefix.."/", 2)
        if found ~= nil then
            return found
        end
    end

    return nil
end

-- 路径格式，与 BuildStoragePath 的产出一一对应：
--   "inv"              玩家自己
--   "inv:<N>"          物品栏第 N 格里的容器
--   "equip:<槽>"       装备栏某槽（head / hands / body / back…）里的容器
--   "<上面任一>/<N>"   再往里一层：那个容器第 N 格里的容器（可继续接 /N）
function ISR.ResolveStoragePath(player, path)
    if player == nil or path == nil then
        return nil
    end

    local inventory = player.components ~= nil and player.components.inventory or nil
    if inventory == nil then
        return nil
    end

    local current = nil
    local pos = 1
    local first = true
    while pos <= #path do
        local slash = string.find(path, "/", pos, true)
        local segment = slash ~= nil and string.sub(path, pos, slash - 1) or string.sub(path, pos)
        pos = slash ~= nil and slash + 1 or #path + 1

        if first then
            first = false
            if segment == "inv" then
                current = player
            else
                local kind, key = string.match(segment, "^(%w+):(.+)$")
                if kind == "inv" then
                    current = inventory.itemslots ~= nil and inventory.itemslots[ISR.ToNumber(key)] or nil
                elseif kind == "equip" then
                    current = inventory.equipslots ~= nil and inventory.equipslots[key] or nil
                else
                    return nil
                end
            end
        else
            local container = current ~= nil
                and current.components ~= nil
                and current.components.container
                or nil
            local slot = ISR.ToNumber(segment)
            current = container ~= nil and slot ~= nil and container.slots ~= nil
                and container.slots[slot]
                or nil
        end

        if current == nil then
            return nil
        end
    end

    return current
end

function ISR.BuildMarkBackup(player)
    if player == nil then
        return nil
    end

    local snapshot = {}
    for _, inst in ipairs(ISR.GetPersonalStorageInstances(player)) do
        local store = inst.components ~= nil and inst.components.isr_slotmarkstore or nil
        local saved = store ~= nil and store.OnSave ~= nil and store:OnSave() or nil
        local path = saved ~= nil and BuildStoragePath(player, inst) or nil
        if path ~= nil then
            local marks = {}
            for _, record in ipairs(saved.marks or {}) do
                table.insert(marks,
                {
                    slot = record.slot,
                    prefab = record.prefab,
                    order = record.order,
                })
            end
            if #marks > 0 then
                table.insert(snapshot, { path = path, marks = marks })
            end
        end
    end

    return #snapshot > 0 and snapshot or nil
end

function ISR.RestoreMarkBackup(player, snapshot)
    if player == nil or snapshot == nil then
        return
    end

    local restored, kept, missing = 0, 0, 0
    for _, entry in ipairs(snapshot) do
        local inst = ISR.ResolveStoragePath(player, entry.path)
        local store = inst ~= nil and ISR.EnsureSlotMarkStore(inst) or nil
        if store == nil then
            missing = missing + 1
        else
            for _, record in ipairs(entry.marks or {}) do
                local slot = ISR.ToNumber(record.slot)
                local prefab = ISR.NormalizePrefabKey ~= nil and ISR.NormalizePrefabKey(record.prefab) or nil
                if slot ~= nil and slot >= 1 and prefab ~= nil then
                    if store:GetMark(slot) == nil then
                        store:SetMark(slot, prefab, record.order)
                        restored = restored + 1
                    else
                        kept = kept + 1
                    end
                end
            end
        end
    end

    ISR.Log(
        "Mark backup restored",
        "restored", tostring(restored),
        "kept", tostring(kept),
        "missing_container", tostring(missing)
    )

    if restored > 0 then
        ISR.SyncAllMarksToClient(player)
    end
end

function ISR.QueueRestoreMarkBackup(player, snapshot)
    if player ~= nil and snapshot ~= nil then
        player:DoTaskInTime(0, function(inst)
            ISR.RestoreMarkBackup(inst, snapshot)
        end)
    end
end

AddPlayerPostInit(function(inst)
    local old_OnLoad = inst.OnLoad
    function inst:OnLoad(data, newents)
        if old_OnLoad ~= nil then
            old_OnLoad(self, data, newents)
        end

        if data == nil then
            return
        end

        if data.item_slot_reservation_marks ~= nil then
            ISR.QueueRestorePersistentMarks(self, data.item_slot_reservation_marks)
        end

        if data[ISR.MARK_BACKUP_KEY] ~= nil then
            ISR.QueueRestoreMarkBackup(self, data[ISR.MARK_BACKUP_KEY])
        end
    end

    local old_OnSave = inst.OnSave
    function inst:OnSave(data)
        local refs = old_OnSave ~= nil and old_OnSave(self, data) or nil
        if data ~= nil then
            data[ISR.MARK_BACKUP_KEY] = ISR.BuildMarkBackup(self)
        end
        return refs
    end
end)

AddModRPCHandler(ISR.RPC_NAMESPACE, ISR.RPC_REQUEST_SYNC, function(player)
    -- 客户端主动要快照 ⇒ 它装了本模组，登记为能力客户端
    ISR.MarkClientCapable(player)
    ISR.SyncAllMarksToClient(player)
end)

-- 全量同步请求的去重窗口取值要求：大于一个 RTT（否则没等到回包就放行下一次问），
-- 小于玩家能察觉的延迟正常路径由 RPC_SYNC_BEGIN 清掉这个标记，这里的定时器只是兜底 ——
-- 回包丢了也不会永久卡住后续请求
ISR.SNAPSHOT_REQUEST_TIMEOUT = 0.25

function ISR.RequestMarkSnapshot()
    local player = ISR.GetLocalPlayer()
    if player == nil or ISR._client_snapshot_request_pending then
        return false
    end

    ISR._client_snapshot_request_pending = true
    SendModRPCToServer(GetModRPC(ISR.RPC_NAMESPACE, ISR.RPC_REQUEST_SYNC))
    player:DoTaskInTime(ISR.SNAPSHOT_REQUEST_TIMEOUT, function()
        ISR._client_snapshot_request_pending = nil
    end)
    return true
end
