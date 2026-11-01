ISR = ISR or {}

function ISR.GetContainerSlotCount(container)
    if container == nil then
        return 0
    elseif container.GetNumSlots ~= nil then
        return container:GetNumSlots()
    else
        return container.numslots or container.maxslots or 0
    end
end

local function IsPlayerEntity(inst)
    return inst ~= nil
        and inst.HasTag ~= nil
        and inst:HasTag("player")
        and inst.components ~= nil
        and inst.components.inventory ~= nil
end

function ISR.GetContainerInstFromGUID(container_guid)
    local ents = ISR.GetEntitiesTable()
    return ents ~= nil and ents[container_guid] or nil
end

function ISR.GetContainerInstForSlot(slot)
    if slot == nil then
        return nil
    elseif slot.owner ~= nil
        and slot.container ~= nil
        and slot.container.inst == slot.owner
    then
        return slot.owner
    end

    return slot.container ~= nil and slot.container.inst or nil
end

function ISR.GetClientContainerGUID(container_inst)
    local player = ISR.GetLocalPlayer()
    if player ~= nil and container_inst == player then
        return player.GUID
    end

    return container_inst ~= nil and container_inst.GUID or nil
end

function ISR.IsMarkableContainerForPlayer(player, container_guid)
    if player == nil or container_guid == nil then
        return false
    elseif container_guid == player.GUID then
        return true
    end

    local inventory = player.components ~= nil and player.components.inventory or nil
    local container_inst = ISR.GetContainerInstFromGUID(container_guid)
    if inventory == nil or container_inst == nil then
        return false
    end

    for _, item in pairs(inventory.itemslots or {}) do
        if item == container_inst then
            return true
        end
    end

    for _, item in pairs(inventory.equipslots or {}) do
        if item == container_inst then
            return true
        end
    end

    return false
end

function ISR.IsClientMarkableContainerInst(container_inst)
    local player = ISR.GetLocalPlayer()
    if player == nil or container_inst == nil then
        return false
    elseif container_inst == player then
        return true
    end

    local inventory = player.replica ~= nil and player.replica.inventory or nil
    if inventory == nil then
        return false
    end

    for _, item in pairs(inventory.GetItems ~= nil and inventory:GetItems() or {}) do
        if item == container_inst then
            return true
        end
    end

    for _, item in pairs(inventory.GetEquips ~= nil and inventory:GetEquips() or {}) do
        if item == container_inst then
            return true
        end
    end

    return false
end

function ISR.IsClientMarkableSlot(slot)
    return slot ~= nil
        and not slot._isr_is_construction_slot
        and ISR.IsClientMarkableContainerInst(ISR.GetContainerInstForSlot(slot))
end

function ISR.GetSlotContainerGUID(slot)
    return ISR.GetClientContainerGUID(ISR.GetContainerInstForSlot(slot))
end

function ISR.IsSlotEmpty(slot)
    return slot ~= nil
        and slot.container ~= nil
        and slot.num ~= nil
        and slot.container:GetItemInSlot(slot.num) == nil
end

local storage_adapters = {}
local storage_adapter_indexes = {}

local REQUIRED_ADAPTER_METHODS =
{
    "CanHandle",
    "GetStorageFromEntity",
    "GetGUID",
    "GetSlotCount",
    "GetItemInSlot",
    "CanUseEmptySlot",
    "PlaceInSlot",
}

-- Custom adapters take precedence over built-ins. ResolvePlayerOwner opts a
-- storage into ISR routing; persistent nonstandard entities also need isr_slotmarkstore.
function ISR.RegisterStorageAdapter(name, adapter)
    if type(name) ~= "string" or type(adapter) ~= "table" then
        return false
    end
    for _, method in ipairs(REQUIRED_ADAPTER_METHODS) do
        if type(adapter[method]) ~= "function" then
            return false
        end
    end

    adapter.name = name
    local index = storage_adapter_indexes[name]
    if index ~= nil then
        storage_adapters[index] = adapter
    else
        table.insert(storage_adapters, adapter)
        storage_adapter_indexes[name] = #storage_adapters
    end
    return true
end

function ISR.GetStorageAdapter(storage, kind)
    if storage == nil then
        return nil
    end

    for index = #storage_adapters, 1, -1 do
        local adapter = storage_adapters[index]
        if adapter:CanHandle(storage, kind) then
            return adapter
        end
    end
end

function ISR.ResolvePlayerStorageOwner(storage, kind)
    local adapter = ISR.GetStorageAdapter(storage, kind)
    if adapter == nil or adapter.ResolvePlayerOwner == nil then
        return nil
    end

    local owner = adapter:ResolvePlayerOwner(storage)
    return IsPlayerEntity(owner) and owner or nil
end

function ISR.IsPlayerInventoryComponent(inventory)
    return inventory ~= nil
        and ISR.ResolvePlayerStorageOwner(inventory, "inventory") == inventory.inst
end

function ISR.GetStorageFromEntity(inst)
    if inst == nil then
        return nil
    end

    for index = #storage_adapters, 1, -1 do
        local adapter = storage_adapters[index]
        local storage = adapter:GetStorageFromEntity(inst)
        if storage ~= nil and adapter:CanHandle(storage) then
            return storage, adapter
        end
    end
end

function ISR.GetStorageForMark(owner, mark)
    if owner == nil or mark == nil then
        return nil
    elseif mark.container_guid == owner.GUID then
        return owner.components ~= nil and owner.components.inventory or nil
    end

    return ISR.GetStorageFromEntity(ISR.GetContainerInstFromGUID(mark.container_guid))
end

ISR.RegisterStorageAdapter("inventory",
{
    CanHandle = function(_, storage, kind)
        return kind == "inventory"
            or storage.itemslots ~= nil
                and storage.equipslots ~= nil
                and storage.GetOverflowContainer ~= nil
    end,
    GetStorageFromEntity = function(_, inst)
        return inst.components ~= nil and inst.components.inventory or nil
    end,
    ResolvePlayerOwner = function(_, storage)
        return storage.inst
    end,
    GetGUID = function(_, storage)
        return storage.inst ~= nil and storage.inst.GUID or nil
    end,
    GetSlotCount = function(_, storage)
        return storage.GetNumSlots ~= nil and storage:GetNumSlots() or storage.maxslots or 0
    end,
    GetItemInSlot = function(_, storage, slot)
        return storage:GetItemInSlot(slot)
    end,
    CanUseEmptySlot = function(_, storage, item, slot)
        if ISR.CanUseEmptyInventorySlot ~= nil then
            return ISR.CanUseEmptyInventorySlot(storage, item, slot)
        end
        return storage:GetItemInSlot(slot) == nil and storage:CanTakeItemInSlot(item, slot)
    end,
    PlaceInSlot = function(_, _, _, slot)
        return "inventory", slot
    end,
})

ISR.RegisterStorageAdapter("container",
{
    CanHandle = function(_, storage, kind)
        return kind == "container"
            or storage.slots ~= nil and storage.CanTakeItemInSlot ~= nil
    end,
    GetStorageFromEntity = function(_, inst)
        return inst.components ~= nil and inst.components.container or nil
    end,
    ResolvePlayerOwner = function(_, storage)
        local inventoryitem = storage.inst ~= nil
            and storage.inst.components ~= nil
            and storage.inst.components.inventoryitem
            or nil
        return inventoryitem ~= nil and (inventoryitem:GetGrandOwner() or inventoryitem.owner) or nil
    end,
    GetGUID = function(_, storage)
        return storage.inst ~= nil and storage.inst.GUID or nil
    end,
    GetSlotCount = function(_, storage)
        return ISR.GetContainerSlotCount(storage)
    end,
    GetItemInSlot = function(_, storage, slot)
        return storage:GetItemInSlot(slot)
    end,
    CanUseEmptySlot = function(_, storage, item, slot)
        if ISR.CanUseEmptyContainerSlot ~= nil then
            return ISR.CanUseEmptyContainerSlot(storage, item, slot)
        end
        return storage:GetItemInSlot(slot) == nil and storage:CanTakeItemInSlot(item, slot)
    end,
    PlaceInSlot = function(_, storage, item, slot, context)
        if context ~= nil and context.inventory ~= nil and ISR.TryGiveItemToContainer ~= nil then
            return ISR.TryGiveItemToContainer(context.inventory, item, storage, slot, context.src_pos)
        end
        return storage:GiveItem(item, slot, context ~= nil and context.src_pos or nil, false)
    end,
})
