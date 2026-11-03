ISR = ISR or {}

local function NormalizePrefab(prefab)
    if ISR.NormalizePrefabKey ~= nil then
        return ISR.NormalizePrefabKey(prefab)
    end

    return prefab ~= nil and string.lower(tostring(prefab)) or nil
end

-- 标记就是一个 prefab 名（字符串）。历史版本里标记是 {eslot=..., kind=...} 表，
-- 这里统一取键，读到表时只看 prefab / eslot 字段。
local function GetMarkPrefab(mark)
    if mark == nil then
        return nil
    elseif type(mark) == "string" then
        return NormalizePrefab(mark)
    end

    return NormalizePrefab(mark.prefab ~= nil and mark.prefab or mark.eslot)
end

local function IsValidStoredMark(mark)
    local prefab = GetMarkPrefab(mark)
    if prefab == nil then
        return false
    end

    -- 测试桩可能没有 Prefabs 表；缺校验函数时按有效处理
    return ISR.IsValidPrefabKey == nil or ISR.IsValidPrefabKey(prefab)
end

function ISR.MarkMatchesItem(mark, item)
    local prefab = GetMarkPrefab(mark)
    return prefab ~= nil
        and item ~= nil
        and item.prefab ~= nil
        and NormalizePrefab(item.prefab) == prefab
end

-- 枚举该玩家所有带标记的容器。走注册表（有标记的容器都登记过），
-- 这样跟随型容器（切斯特、哈奇）和别的模组容器也能算进来。
function ISR.GetServerMarks(player)
    local marks = {}
    for _, inst in ipairs(ISR.GetMarkContainerInstances()) do
        if ISR.IsStorageOwnedByPlayer(player, inst) then
            local store = inst.components ~= nil and inst.components.isr_slotmarkstore or nil
            if store ~= nil then
                for slot, mark in pairs(store:GetMarks()) do
                    if IsValidStoredMark(mark) then
                        marks[ISR.GetSlotKey(inst.GUID, slot)] =
                        {
                            container_guid = inst.GUID,
                            slot = slot,
                            prefab = GetMarkPrefab(mark),
                            order = mark.order,
                        }
                    else
                        ISR.Log("Stored mark skipped", "reason", "prefab", "container", tostring(inst.GUID), "slot", tostring(slot))
                    end
                end
            end
        end
    end

    return marks
end

function ISR.GetServerSlotMark(player, container_guid, slot)
    local store = ISR.GetSlotMarkStoreForGUID(player, container_guid, false)
    local mark = store ~= nil and store:GetMark(slot) or nil
    return IsValidStoredMark(mark) and
    {
        container_guid = container_guid,
        slot = slot,
        prefab = GetMarkPrefab(mark),
        order = mark.order,
    } or nil
end

-- 「这一格对本物品开放吗」：没有标记，或标记就是这个 prefab。
-- 不构造标记表 —— 候选格搜索按格调用，一次拾取要跑几十次，临时表纯属垃圾。
function ISR.CanItemUseStoredMark(player, container_guid, slot, item)
    local store = ISR.GetSlotMarkStoreForGUID(player, container_guid, false)
    local mark = store ~= nil and store:GetMark(slot) or nil
    if not IsValidStoredMark(mark) then
        return true
    end

    return item ~= nil
        and item.prefab ~= nil
        and NormalizePrefab(item.prefab) == GetMarkPrefab(mark)
end

function ISR.IsServerSlotMarked(player, container_guid, slot)
    local store = ISR.GetSlotMarkStoreForGUID(player, container_guid, false)
    return store ~= nil and IsValidStoredMark(store:GetMark(slot))
end

function ISR.ClearServerSlotMark(player, container_guid, slot, play_clear_sound)
    local store = ISR.GetSlotMarkStoreForGUID(player, container_guid, false)
    if store == nil or not store:ClearMark(slot) then
        return false
    end

    ISR.SyncMarkToClient(player, container_guid, slot, nil, play_clear_sound == true)
    ISR.Log("Server mark cleared", "container", tostring(container_guid), "slot", tostring(slot), "clear_sound", tostring(play_clear_sound == true))
    return true
end

function ISR.ClearServerSlotMarkIfItemMismatches(player, container_guid, slot, item)
    local mark = ISR.GetServerSlotMark(player, container_guid, slot)
    if mark == nil then
        return false
    elseif ISR.MarkMatchesItem(mark, item) then
        ISR.Log(
            "Server mark kept by matching item",
            "container", tostring(container_guid),
            "slot", tostring(slot),
            "prefab", tostring(mark.prefab),
            "item", tostring(item ~= nil and item.prefab or nil)
        )
        return false
    end

    return ISR.ClearServerSlotMark(player, container_guid, slot, true)
end

local function FindPlayerByUserid(userid)
    if userid == nil then
        return nil
    end

    local all_players = ISR.GetGlobalValue("AllPlayers", nil)
    if all_players == nil then
        return nil
    end

    for _, player in pairs(all_players) do
        if player ~= nil and player.userid == userid then
            return player
        end
    end

    return nil
end

-- 容器的「逻辑主人」：基地箱子、没带眼骨的切斯特没有 inventoryitem 主人链，
-- 归属只记在 mark store 上。路由（回预留格 / 避开预留格）需要一个 player 去找标记，
-- 有标记的容器就用记下的 owner 当这个 player。
function ISR.GetMarkOwnerPlayer(container_inst)
    if container_inst == nil or container_inst.components == nil then
        return nil
    end

    local store = container_inst.components.isr_slotmarkstore
    if store == nil or store.GetOwner == nil then
        return nil
    end

    return FindPlayerByUserid(store:GetOwner())
end

-- 容器路径的解标记：不要求容器有「在线主人」。
-- 基地箱子、没带眼骨的切斯特只有 mark store 里的 owner userid，走
-- ResolvePlayerStorageOwner 会得到 nil，于是整段容器钩子早退、预留永远不解除，
-- 格子被别的东西占住就成了死格。这里按 store 自己的 owner 判、按它找人同步。
function ISR.ClearContainerSlotMarkOnMismatch(container_inst, slot, item)
    if container_inst == nil or slot == nil or item == nil then
        return false
    end

    local store = container_inst.components ~= nil and container_inst.components.isr_slotmarkstore or nil
    if store == nil then
        return false
    end

    local mark = store:GetMark(slot)
    if mark == nil then
        return false
    end

    if ISR.MarkMatchesItem(mark, item) then
        ISR.Log(
            "Container mark kept by matching item",
            "container", tostring(container_inst.GUID),
            "slot", tostring(slot),
            "prefab", tostring(GetMarkPrefab(mark)),
            "item", tostring(item.prefab)
        )
        return false
    end

    local owner_userid = store.GetOwner ~= nil and store:GetOwner() or nil
    if not store:ClearMark(slot) then
        return false
    end

    local owner = FindPlayerByUserid(owner_userid)
    if owner ~= nil then
        ISR.SyncMarkToClient(owner, container_inst.GUID, slot, nil, true)
    end

    ISR.Log(
        "Container mark cleared by foreign item",
        "container", tostring(container_inst.GUID),
        "slot", tostring(slot),
        "prefab", tostring(GetMarkPrefab(mark)),
        "item", tostring(item.prefab)
    )
    return true
end

local function SortMarks(player, candidates)
    table.sort(candidates, function(a, b)
        if a.order ~= nil and b.order ~= nil and a.order ~= b.order then
            return a.order < b.order
        elseif a.order ~= nil and b.order == nil then
            return true
        elseif a.order == nil and b.order ~= nil then
            return false
        elseif a.container_guid == b.container_guid then
            return a.slot < b.slot
        elseif player ~= nil and a.container_guid == player.GUID then
            return true
        elseif player ~= nil and b.container_guid == player.GUID then
            return false
        end
        return tostring(a.container_guid) < tostring(b.container_guid)
    end)

    return candidates
end

function ISR.GetSortedServerMarksForPrefab(player, prefab)
    local key = NormalizePrefab(prefab)
    if key == nil then
        return {}
    end

    local candidates = {}
    for _, mark in pairs(ISR.GetServerMarks(player)) do
        if type(mark) == "table" and mark.prefab == key then
            table.insert(candidates, mark)
        end
    end

    return SortMarks(player, candidates)
end

function ISR.HasServerMarksForItem(owner, item)
    return owner ~= nil
        and item ~= nil
        and item.prefab ~= nil
        and #ISR.GetSortedServerMarksForPrefab(owner, item.prefab) > 0
end

function ISR.GetNextServerMarkOrder(player)
    local store = ISR.GetSlotMarkStoreForGUID(player, player ~= nil and player.GUID or nil, true)
    if store == nil then
        return 0
    end

    local max_order = 0
    for _, mark in pairs(ISR.GetServerMarks(player)) do
        max_order = math.max(max_order, ISR.ToNumber(mark.order) or 0)
    end
    store:ReserveOrder(max_order)
    return store:NextOrder()
end

local function SyncAuthoritativeSlotMark(player, container_guid, slot)
    local mark = ISR.GetServerSlotMark(player, container_guid, slot)
    ISR.SyncMarkToClient(player, container_guid, slot, mark ~= nil and mark.prefab or nil)
end

function ISR.GetClientMarks()
    local player = ISR.GetLocalPlayer()
    if player == nil then
        return nil
    end

    player._item_slot_reservation_client_marks = player._item_slot_reservation_client_marks or {}
    return player._item_slot_reservation_client_marks
end

-- 客户端缓存直接存 prefab 字符串。
function ISR.GetClientSlotMark(slot)
    local guid = ISR.GetSlotContainerGUID(slot)
    local marks = ISR.GetClientMarks()
    return guid ~= nil and marks ~= nil and marks[ISR.GetSlotKey(guid, slot.num)] or nil
end

function ISR.PlayClientMarkClearSound()
    local focal_point = ISR.GetFocalPoint()
    if focal_point ~= nil and focal_point.SoundEmitter ~= nil then
        focal_point.SoundEmitter:PlaySound("dontstarve/HUD/click_negative")
    end
end

-- 物品被直接放进容器时，玩家的物品栏收不到 gotnewitem，原版拾取音效也就不会播
-- （声音在 inventory.lua 的 gotnewitem 分支里，见 player_common 的 OnGotNewItem）。
-- 这里照原版的方式查一遍 PICKUPSOUNDS，给玩家一个反馈。
--
-- 只在服务端调用：声音挂在玩家实体上，随实体同步给附近客户端（和原版 drop 音一个路子）。
-- 不要在这里查 IsMasterSimulation —— 它不是真正常驻的全局名，服务端开着 strict.lua，
-- GLOBAL["IsMasterSimulation"] 会直接抛 "variable is not declared" 把服务器打崩。
function ISR.PlayPickupSound(owner, item)
    if owner == nil or owner.SoundEmitter == nil then
        return
    end

    local sounds = ISR.GetGlobalValue("PICKUPSOUNDS", nil)
    if sounds == nil then
        return
    end

    -- 物品可以把 pickupsound 设成 "NONE"（原版就是这么屏蔽的），查不到就静音。
    local sound = sounds[item ~= nil and item.pickupsound or "DEFAULT_FALLBACK"]
    if sound ~= nil then
        owner.SoundEmitter:PlaySound(sound)
    end
end

function ISR.SetClientSlotMark(slot, prefab)
    local container_inst = ISR.GetContainerInstForSlot(slot)
    local guid = ISR.GetClientContainerGUID(container_inst)
    local marks = ISR.GetClientMarks()
    if guid == nil or marks == nil then
        return false
    end

    local key = NormalizePrefab(prefab)
    local slot_key = ISR.GetSlotKey(guid, slot.num)
    marks[slot_key] = key

    ISR.Log("SetClientSlotMark", "container", tostring(guid), "slot", tostring(slot.num), "prefab", tostring(key or "normal"))
    SendModRPCToServer(GetModRPC(ISR.RPC_NAMESPACE, ISR.RPC_SET_MARK), container_inst, slot.num, key or "")
    return true
end

function ISR.ApplySyncedClientSlotMark(container_inst, slotnum, prefab, play_clear_sound)
    local container_guid = ISR.GetClientContainerGUID(container_inst)
    slotnum = ISR.ToNumber(slotnum)
    prefab = prefab ~= "" and NormalizePrefab(prefab) or nil

    local marks = ISR.GetClientMarks()
    if container_guid == nil or slotnum == nil or marks == nil then
        return false
    end

    local key = ISR.GetSlotKey(container_guid, slotnum)
    local old_prefab = marks[key]
    marks[key] = prefab

    if not ISR._client_mark_snapshot_active then
        if ISR.QueueRefreshVisibleSlotIcons ~= nil then
            ISR.QueueRefreshVisibleSlotIcons()
        elseif ISR.RefreshVisibleSlotIcons ~= nil then
            ISR.RefreshVisibleSlotIcons()
        end
    end

    if prefab == nil and (play_clear_sound == true or old_prefab ~= nil) then
        if ISR._client_requested_clear_key == key then
            ISR._client_requested_clear_key = nil
        else
            ISR.PlayClientMarkClearSound()
        end
    elseif ISR._client_requested_clear_key == key then
        ISR._client_requested_clear_key = nil
    end

    ISR.Log("Client mark synced", "container", tostring(container_guid), "slot", tostring(slotnum), "prefab", tostring(prefab or "normal"), "clear_sound", tostring(play_clear_sound == true))
    return true
end

-- 把「这一格现在装的东西」固定下来：不用手持物品，草、树枝等资源同样适用。
-- 同一格再固定一次视为取消。
function ISR.PinClientSlotMark(slot)
    if slot == nil or slot.num == nil or slot.container == nil then
        return false
    end

    local item = slot.container.GetItemInSlot ~= nil and slot.container:GetItemInSlot(slot.num) or nil
    if item == nil or item.prefab == nil then
        ISR.Log("PinClientSlotMark skipped: empty slot", tostring(slot.num))
        return false
    end

    local key = NormalizePrefab(item.prefab)
    if key == nil then
        return false
    end

    if ISR.GetClientSlotMark(slot) == key then
        ISR.Log("PinClientSlotMark toggles off", "slot", tostring(slot.num), "prefab", tostring(key))
        return ISR.ClearClientSlotMark(slot)
    end

    if not ISR.SetClientSlotMark(slot, key) then
        ISR.Log("PinClientSlotMark failed", tostring(slot.num), tostring(key))
        return false
    end

    ISR.ApplyRuntimeIconToSlot(slot)
    if ISR.QueueRefreshVisibleSlotIcons ~= nil then
        ISR.QueueRefreshVisibleSlotIcons()
    end

    local focal_point = ISR.GetFocalPoint()
    if focal_point ~= nil and focal_point.SoundEmitter ~= nil then
        focal_point.SoundEmitter:PlaySound("dontstarve/HUD/click_object")
    end

    ISR.Log("PinClientSlotMark", "slot", tostring(slot.num), "prefab", tostring(key))
    return true
end

function ISR.ClearClientSlotMark(slot)
    local guid = ISR.GetSlotContainerGUID(slot)
    if guid ~= nil and slot ~= nil and slot.num ~= nil then
        ISR._client_requested_clear_key = ISR.GetSlotKey(guid, slot.num)
    end

    if not ISR.SetClientSlotMark(slot, nil) then
        ISR.Log("ClearClientSlotMark skipped", tostring(slot ~= nil and slot.num or nil))
        ISR._client_requested_clear_key = nil
        return false
    end

    ISR.ApplyRuntimeIconToSlot(slot)
    if ISR.QueueRefreshVisibleSlotIcons ~= nil then
        ISR.QueueRefreshVisibleSlotIcons()
    end
    ISR.PlayClientMarkClearSound()

    ISR.Log("ClearClientSlotMark", "slot", tostring(slot.num))
    return true
end

function ISR.ApplyRuntimeIconToSlot(slot)
    if not ISR.IsClientMarkableSlot(slot) then
        ISR.ClearSlotIcon(slot)
        ISR.ClearSlotBorder(slot)
        return false
    end

    local prefab = ISR.GetClientSlotMark(slot)
    if prefab ~= nil then
        if ISR.IsSlotEmpty(slot) then
            ISR.ApplyMarkIconToSlot(slot, prefab)
        else
            ISR.ClearSlotIcon(slot)
        end
        ISR.ApplySlotBorder(slot)
        return true
    end

    ISR.ClearSlotIcon(slot)
    ISR.ClearSlotBorder(slot)
    return false
end

local function IsValidMarkRequest(prefab)
    return prefab == nil or ISR.IsValidPrefabKey == nil or ISR.IsValidPrefabKey(prefab)
end

AddModRPCHandler(ISR.RPC_NAMESPACE, ISR.RPC_SET_MARK, function(player, container_inst, slot, prefab)
    if player == nil or player.components == nil or player.components.inventory == nil then
        return
    end

    -- 能发 RPC ⇒ 装了本模组，登记为能力客户端（之后才给它推同步）
    if ISR.MarkClientCapable ~= nil then
        ISR.MarkClientCapable(player)
    end

    slot = ISR.ToNumber(slot)
    prefab = prefab ~= "" and NormalizePrefab(prefab) or nil

    if container_inst == nil or slot == nil or slot < 1 then
        ISR.Log("Server mark rejected", "reason", "rpc_args", "container", tostring(container_inst), "slot", tostring(slot), "prefab", tostring(prefab))
        return
    end

    if not IsValidMarkRequest(prefab) then
        local rejected_guid = container_inst == player and player.GUID or container_inst.GUID
        ISR.Log("Server mark rejected", "reason", "prefab", "container", tostring(rejected_guid), "slot", tostring(slot), "prefab", tostring(prefab))
        SyncAuthoritativeSlotMark(player, rejected_guid, slot)
        return
    end

    local container_guid = container_inst == player and player.GUID or container_inst.GUID
    local container = container_inst == player
        and player.components.inventory
        or ISR.GetStorageFromEntity(container_inst)
    local adapter = ISR.GetStorageAdapter(container, container_inst == player and "inventory" or nil)
    local slot_count = adapter ~= nil and adapter:GetSlotCount(container) or 0
    -- 归属判定之外再放一条：容器此刻正被这名玩家打开。切斯特没眼骨时不跟随任何人，
    -- 组件语义判不出归属，但打开它的人显然就是使用者。
    local opened_here = container ~= nil
        and container.IsOpenedBy ~= nil
        and container:IsOpenedBy(player) == true
    if container == nil
        or adapter == nil
        or slot > slot_count
        or (not opened_here and not ISR.IsMarkableContainerForPlayer(player, container_guid))
    then
        ISR.Log(
            "Server mark rejected",
            "reason", container == nil and "container"
                or adapter == nil and "adapter"
                or slot > slot_count and "slot_range"
                or "not_markable",
            "container", tostring(container_guid),
            "slot", tostring(slot),
            "prefab", tostring(prefab)
        )
        ISR.SyncMarkToClient(player, container_guid, slot, nil)
        return
    end

    local store = ISR.GetSlotMarkStoreForGUID(player, container_guid, true)
    if store == nil then
        ISR.Log("Server mark rejected", "reason", "mark_store", "container", tostring(container_guid), "slot", tostring(slot))
        ISR.SyncMarkToClient(player, container_guid, slot, nil)
        return
    end

    -- 归属：容器上记过的 owner 说了算。第一个在这里落标记的人成为 owner，
    -- 之后别人打开同一个容器也改不了 —— 否则多人服会互相覆盖。
    local owner_userid = store.GetOwner ~= nil and store:GetOwner() or nil
    if owner_userid ~= nil and player.userid ~= nil and owner_userid ~= player.userid then
        ISR.Log(
            "Server mark rejected",
            "reason", "owner",
            "container", tostring(container_guid),
            "slot", tostring(slot),
            "owner", tostring(owner_userid),
            "player", tostring(player.userid)
        )
        SyncAuthoritativeSlotMark(player, container_guid, slot)
        return
    end

    if prefab == nil then
        store:ClearMark(slot)
        ISR.SyncMarkToClient(player, container_guid, slot, nil)
        return
    end

    if owner_userid == nil and store.SetOwner ~= nil then
        store:SetOwner(player.userid)
    end

    -- 空格才能标记；但格子里已经放着「正是要预留的那种东西」时也允许，
    -- 否则“V + 左键点已有物品的格子”永远会被 occupied 拒掉。
    local item_in_slot = adapter:GetItemInSlot(container, slot)
    if item_in_slot == nil or ISR.MarkMatchesItem(prefab, item_in_slot) then
        local mark = store:SetMark(slot, prefab, ISR.GetNextServerMarkOrder(player))
        ISR.Log("Server mark set", "container", tostring(container_guid), "slot", tostring(slot), "prefab", tostring(prefab), "order", tostring(mark.order))
        ISR.SyncMarkToClient(player, container_guid, slot, prefab)
    else
        ISR.Log("Server mark rejected", "reason", "occupied", "container", tostring(container_guid), "slot", tostring(slot), "prefab", tostring(prefab), "item", tostring(item_in_slot.prefab))
        SyncAuthoritativeSlotMark(player, container_guid, slot)
    end
end)

AddClientModRPCHandler(ISR.RPC_NAMESPACE, ISR.RPC_SYNC_MARK, function(container_inst, slot, prefab, play_clear_sound)
    ISR.ApplySyncedClientSlotMark(container_inst, slot, prefab, play_clear_sound)
end)

AddClientModRPCHandler(ISR.RPC_NAMESPACE, ISR.RPC_SYNC_BEGIN, function()
    ISR._client_snapshot_request_pending = nil
    local player = ISR.GetLocalPlayer()
    if player ~= nil then
        player._item_slot_reservation_client_marks = {}
    end
    ISR._client_mark_snapshot_active = true
end)

AddClientModRPCHandler(ISR.RPC_NAMESPACE, ISR.RPC_SYNC_END, function()
    ISR._client_mark_snapshot_active = nil
    if ISR.QueueRefreshVisibleSlotIcons ~= nil then
        ISR.QueueRefreshVisibleSlotIcons()
    elseif ISR.RefreshVisibleSlotIcons ~= nil then
        ISR.RefreshVisibleSlotIcons()
    end
end)
