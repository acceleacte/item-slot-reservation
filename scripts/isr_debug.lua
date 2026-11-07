ISR = ISR or {}

function ISR.GetInventoryBarWidget()
    local player = ISR.GetLocalPlayer()
    return player ~= nil
        and player.HUD ~= nil
        and player.HUD.controls ~= nil
        and player.HUD.controls.inv
        or nil
end

function ISR.DebugDumpInventoryBar()
    local player = ISR.GetLocalPlayer()
    local invbar = ISR.GetInventoryBarWidget()
    print("[ItemSlotReservation]", "ThePlayer", tostring(player))
    print("[ItemSlotReservation]", "HUD", tostring(player ~= nil and player.HUD or nil))
    print("[ItemSlotReservation]", "controls", tostring(player ~= nil and player.HUD ~= nil and player.HUD.controls or nil))
    print("[ItemSlotReservation]", "inventorybar", tostring(invbar))
    print("[ItemSlotReservation]", "main slots", tostring(invbar ~= nil and invbar.inv ~= nil and #invbar.inv or nil))
    print("[ItemSlotReservation]", "backpack slots", tostring(invbar ~= nil and invbar.backpackinv ~= nil and #invbar.backpackinv or nil))
end

local function GetInventoryBarSlot(slotnum, use_backpack)
    local invbar = ISR.GetInventoryBarWidget()
    local slotlist = use_backpack and invbar ~= nil and invbar.backpackinv or invbar ~= nil and invbar.inv or nil
    return invbar, slotlist ~= nil and slotlist[ISR.ToNumber(slotnum) or 1] or nil
end

-- 控制台入口：背包里没有该物品时也能预先标记格子
-- 在客户端控制台执行，例如：ISR.DebugSetPrefabMark(3, "grass")
function ISR.DebugSetPrefabMark(slotnum, prefab, use_backpack)
    local _, slot = GetInventoryBarSlot(slotnum, use_backpack)
    local key = prefab ~= nil and ISR.NormalizePrefabKey(prefab) or nil
    if slot == nil then
        print("[ItemSlotReservation]", "debug prefab mark failed: slot not found", tostring(slotnum))
        ISR.DebugDumpInventoryBar()
        return false
    elseif key == nil or ISR.SetClientSlotMark == nil then
        print("[ItemSlotReservation]", "debug prefab mark failed: bad prefab", tostring(prefab))
        return false
    end

    if not ISR.SetClientSlotMark(slot, key) then
        print("[ItemSlotReservation]", "debug prefab mark failed: mark not applied", key)
        return false
    end

    if ISR.ApplyRuntimeIconToSlot ~= nil then
        ISR.ApplyRuntimeIconToSlot(slot)
    end
    if ISR.QueueRefreshVisibleSlotIcons ~= nil then
        ISR.QueueRefreshVisibleSlotIcons()
    end

    print("[ItemSlotReservation]", "debug prefab mark applied", tostring(slot.num), key)
    return true
end

function ISR.DebugClearSlotMark(slotnum, use_backpack)
    local _, slot = GetInventoryBarSlot(slotnum, use_backpack)
    if slot == nil or ISR.SetClientSlotMark == nil then
        print("[ItemSlotReservation]", "debug clear failed: slot not found", tostring(slotnum))
        return false
    end

    ISR.SetClientSlotMark(slot, nil)
    if ISR.ApplyRuntimeIconToSlot ~= nil then
        ISR.ApplyRuntimeIconToSlot(slot)
    end
    if ISR.QueueRefreshVisibleSlotIcons ~= nil then
        ISR.QueueRefreshVisibleSlotIcons()
    end

    print("[ItemSlotReservation]", "debug mark cleared", tostring(slot.num))
    return true
end

function ISR.RunSelfTests()
    local failures = {}
    local function Check(condition, message)
        if not condition then
            table.insert(failures, message)
        end
    end

    Check(ISR.NormalizePrefabKey("Grass.TEX") == "grass", "prefab key normalization is broken")
    Check(ISR.NormalizePrefabKey("") == nil, "empty prefab key is not rejected")

    if ISR.MarkMatchesItem ~= nil then
        Check(ISR.MarkMatchesItem("grass", { prefab = "grass" }), "prefab mark does not match its own item")
        Check(not ISR.MarkMatchesItem("grass", { prefab = "twigs" }), "prefab mark matches a foreign item")
        Check(not ISR.MarkMatchesItem("grass", nil), "prefab mark matches a missing item")
        -- 0.1.0 存档里的表格式标记仍应可读
        Check(ISR.MarkMatchesItem({ eslot = "twigs" }, { prefab = "twigs" }), "legacy table mark is not readable")
    end

    if #failures == 0 then
        print("[ItemSlotReservation]", "self tests passed")
        return true, failures
    end

    for _, failure in ipairs(failures) do
        print("[ItemSlotReservation]", "self test failed", failure)
    end
    return false, failures
end
