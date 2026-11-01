ISR = ISR or {}

local function IsMasterSimulation()
    local world = ISR.GetGlobalValue("TheWorld", nil)
    return world == nil or world.ismastersim == true
end

function ISR.EnsureSlotMarkStore(inst)
    if inst == nil or not IsMasterSimulation() then
        return nil
    end

    inst.components = inst.components or {}
    if inst.components.isr_slotmarkstore == nil and inst.AddComponent ~= nil then
        inst:AddComponent("isr_slotmarkstore")
    end

    return inst.components.isr_slotmarkstore
end

function ISR.GetSlotMarkStoreForGUID(player, container_guid, create)
    if player == nil or container_guid == nil then
        return nil
    end

    local inst = container_guid == player.GUID
        and player
        or ISR.GetContainerInstFromGUID(container_guid)
    if inst == nil then
        return nil
    end

    return create and ISR.EnsureSlotMarkStore(inst)
        or inst.components ~= nil and inst.components.isr_slotmarkstore
        or nil
end

function ISR.GetPersonalStorageInstances(player)
    local result = {}
    local seen = {}
    local function Add(inst)
        if inst ~= nil and inst.GUID ~= nil and not seen[inst.GUID] then
            seen[inst.GUID] = true
            table.insert(result, inst)
        end
    end

    Add(player)
    local inventory = player ~= nil and player.components ~= nil and player.components.inventory or nil
    if inventory ~= nil then
        for _, item in pairs(inventory.itemslots or {}) do
            Add(item)
        end
        for _, item in pairs(inventory.equipslots or {}) do
            Add(item)
        end
    end

    return result
end

AddComponentPostInit("container", function(self)
    if IsMasterSimulation()
        and self.inst ~= nil
        and self.inst.components ~= nil
        and self.inst.components.inventoryitem ~= nil
    then
        ISR.EnsureSlotMarkStore(self.inst)
    end
end)

AddPlayerPostInit(function(inst)
    if not IsMasterSimulation() then
        return
    end

    ISR.EnsureSlotMarkStore(inst)
    inst:DoTaskInTime(0, function(player)
        if ISR.SyncAllMarksToClient ~= nil then
            ISR.SyncAllMarksToClient(player, true)
        end
    end)
    inst:DoTaskInTime(1, function(player)
        if ISR.SyncAllMarksToClient ~= nil then
            ISR.SyncAllMarksToClient(player, false)
        end
    end)
end)
