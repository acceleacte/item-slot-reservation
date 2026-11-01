ISR = ISR or {}

function ISR.CanUseInventorySlot(inventory, item, slot)
    local maxslots = inventory ~= nil
        and (
            inventory.GetNumSlots ~= nil and inventory:GetNumSlots()
            or inventory.maxslots
            or 0
        )
        or 0

    if slot == nil or slot < 1 or slot > maxslots then
        return false
    end

    local olditem = inventory:GetItemInSlot(slot)
    return inventory:CanTakeItemInSlot(item, slot)
        and (
            olditem == nil
            or (
                olditem.components ~= nil
                and olditem.components.stackable ~= nil
                and item.prefab == olditem.prefab
                and item.skinname == olditem.skinname
                and not olditem.components.stackable:IsFull()
            )
        )
end

function ISR.CanUseEmptyInventorySlot(inventory, item, slot)
    return ISR.CanUseInventorySlot(inventory, item, slot)
        and inventory:GetItemInSlot(slot) == nil
end

function ISR.CanUseContainerSlot(container, item, slot)
    if container == nil or slot == nil or slot < 1 or slot > ISR.GetContainerSlotCount(container) or container.inst == item then
        return false
    end

    local olditem = container:GetItemInSlot(slot)
    return container:CanTakeItemInSlot(item, slot)
        and (
            olditem == nil
            or (
                container:AcceptsStacks()
                and olditem.components ~= nil
                and olditem.components.stackable ~= nil
                and item.prefab == olditem.prefab
                and item.skinname == olditem.skinname
                and not olditem.components.stackable:IsFull()
            )
        )
end

function ISR.CanUseEmptyContainerSlot(container, item, slot)
    return ISR.CanUseContainerSlot(container, item, slot)
        and container:GetItemInSlot(slot) == nil
end

function ISR.GetInventorySlotContainerGUID(inventory, container)
    if container == inventory.itemslots then
        return inventory.inst.GUID
    elseif container ~= nil and container.inst ~= nil then
        return container.inst.GUID
    end
end

local function CanUseUnmarkedInventorySlot(inventory, item, slot)
    return ISR.CanUseEmptyInventorySlot(inventory, item, slot)
        and ISR.CanItemUseMarkedSlot(inventory.inst, inventory.inst.GUID, slot, item)
end

local function CanUseUnmarkedContainerSlot(inventory, container, item, slot)
    return ISR.CanUseEmptyContainerSlot(container, item, slot)
        and ISR.CanItemUseMarkedSlot(inventory.inst, container.inst ~= nil and container.inst.GUID or nil, slot, item)
end

local function CanUseOverflow(item, overflow)
    if overflow == nil then
        return false
    elseif item.components.inventoryitem == nil then
        return true
    elseif item.components.inventoryitem.canonlygoinpocket then
        return false
    elseif item.components.inventoryitem.canonlygoinpocketorpocketcontainers then
        return overflow.inst.components.inventoryitem ~= nil and overflow.inst.components.inventoryitem.canonlygoinpocket
    end
    return true
end

local function GetSpecializedContainersForItem(inventory, item)
    local specialized = inventory:GetSpecializedContainers()
    if specialized == nil then
        return nil
    end

    local filtered = {}
    for _, spoverflow in ipairs(specialized) do
        if spoverflow:ShouldPrioritizeContainer(item) and CanUseOverflow(item, spoverflow) then
            table.insert(filtered, spoverflow)
        end
    end

    return #filtered > 0 and filtered or nil
end

local function CanUseContainerOverflow(item, overflow)
    return overflow ~= nil
        and item.components ~= nil
        and item.components.inventoryitem ~= nil
        and not item.components.inventoryitem.canonlygoinpocket
        and not item.components.inventoryitem.canonlygoinpocketorpocketcontainers
end

local function GetSpecializedContainersForContainerItem(container, item)
    local specialized = container ~= nil and container.GetSpecializedContainers ~= nil and container:GetSpecializedContainers() or nil
    if specialized == nil then
        return nil
    end

    local filtered = {}
    for _, spoverflow in ipairs(specialized) do
        if spoverflow:ShouldPrioritizeContainer(item) and CanUseContainerOverflow(item, spoverflow) then
            table.insert(filtered, spoverflow)
        end
    end

    return #filtered > 0 and filtered or nil
end

local function GetFirstUnmarkedSlotInContainer(inventory, container, item)
    for k = 1, container:GetNumSlots() do
        if CanUseUnmarkedContainerSlot(inventory, container, item, k) then
            return k, container
        end
    end
end

local function GetFirstUnmarkedSlotInInventory(inventory, item)
    for k = 1, inventory.maxslots do
        if CanUseUnmarkedInventorySlot(inventory, item, k) then
            return k, inventory.itemslots
        end
    end
end

local function CanUseUnmarkedContainerStackSlot(inventory, container, item, slot)
    local olditem = container:GetItemInSlot(slot)
    return olditem ~= nil
        and item.components ~= nil
        and item.components.stackable ~= nil
        and olditem.components ~= nil
        and olditem.components.stackable ~= nil
        and container:AcceptsStacks()
        and container:CanTakeItemInSlot(item, slot)
        and item.components.stackable:CanStackWith(olditem)
        and not olditem.components.stackable:IsFull()
        and ISR.CanItemUseMarkedSlot(inventory.inst, container.inst ~= nil and container.inst.GUID or nil, slot, item)
end

local function GetFirstUnmarkedStackSlotInContainer(inventory, container, item)
    for k, _ in pairs(container.slots or {}) do
        if CanUseUnmarkedContainerStackSlot(inventory, container, item, k) then
            return k, container
        end
    end
end

local function CanUseUnmarkedInventoryStackSlot(inventory, item, slot)
    local olditem = inventory.itemslots[slot]
    return olditem ~= nil
        and item.components ~= nil
        and item.components.stackable ~= nil
        and olditem.components ~= nil
        and olditem.components.stackable ~= nil
        and inventory:CanTakeItemInSlot(item, slot)
        and item.components.stackable:CanStackWith(olditem)
        and not olditem.components.stackable:IsFull()
        and ISR.CanItemUseMarkedSlot(inventory.inst, inventory.inst.GUID, slot, item)
end

local function GetFirstUnmarkedStackSlotInInventory(inventory, item)
    for k, _ in pairs(inventory.itemslots or {}) do
        if CanUseUnmarkedInventoryStackSlot(inventory, item, k) then
            return k, inventory.itemslots
        end
    end
end

local function GetFirstEquipStackSlot(inventory, item)
    if item.components == nil or item.components.stackable == nil then
        return nil
    end

    for k, v in pairs(inventory.equipslots or {}) do
        if v.components ~= nil
            and v.components.equippable ~= nil
            and v.components.equippable.equipstack
            and v.components.stackable ~= nil
            and not v.components.stackable:IsFull()
            and v.components.stackable:CanStackWith(item)
        then
            return k, inventory.equipslots
        end
    end
end

function ISR.GetNextUnmarkedEmptySlot(inventory, item, preferred_container)
    local overflow = inventory:GetOverflowContainer()
    local prioritize_overflow = overflow ~= nil and overflow:ShouldPrioritizeContainer(item)
    local useoverflow = CanUseOverflow(item, overflow)
    local specialized = GetSpecializedContainersForItem(inventory, item)

    if preferred_container == inventory.itemslots then
        local slot, container = GetFirstUnmarkedSlotInInventory(inventory, item)
        if slot ~= nil then
            return slot, container
        end
    elseif preferred_container ~= nil then
        local slot, container = GetFirstUnmarkedSlotInContainer(inventory, preferred_container, item)
        if slot ~= nil then
            return slot, container
        end
    end

    if useoverflow and prioritize_overflow then
        local slot, container = GetFirstUnmarkedSlotInContainer(inventory, overflow, item)
        if slot ~= nil then
            return slot, container
        end
    end

    if specialized ~= nil then
        for _, spoverflow in ipairs(specialized) do
            local slot, container = GetFirstUnmarkedSlotInContainer(inventory, spoverflow, item)
            if slot ~= nil then
                return slot, container
            end
        end
    end

    local slot, container = GetFirstUnmarkedSlotInInventory(inventory, item)
    if slot ~= nil then
        return slot, container
    end

    if useoverflow and not prioritize_overflow then
        return GetFirstUnmarkedSlotInContainer(inventory, overflow, item)
    end

    return nil, inventory.itemslots
end

function ISR.GetNextUnmarkedAvailableSlot(inventory, item)
    local overflow = inventory:GetOverflowContainer()
    local prioritize_overflow = overflow ~= nil and overflow:ShouldPrioritizeContainer(item)
    local useoverflow = CanUseOverflow(item, overflow)
    local specialized = GetSpecializedContainersForItem(inventory, item)

    if item.components ~= nil and item.components.stackable ~= nil then
        local equip_slot, equip_container = GetFirstEquipStackSlot(inventory, item)
        if equip_slot ~= nil then
            return equip_slot, equip_container
        end

        local inv_slot, inv_container = GetFirstUnmarkedStackSlotInInventory(inventory, item)
        if inv_slot ~= nil and not (prioritize_overflow or specialized ~= nil) then
            return inv_slot, inv_container
        end

        if useoverflow and (prioritize_overflow or inv_slot == nil) then
            local overflow_slot, overflow_container = GetFirstUnmarkedStackSlotInContainer(inventory, overflow, item)
            if overflow_slot ~= nil then
                if specialized ~= nil and not prioritize_overflow then
                    inv_slot = overflow_slot
                    inv_container = overflow_container
                else
                    return overflow_slot, overflow_container
                end
            end
        end

        if specialized ~= nil then
            for _, spoverflow in ipairs(specialized) do
                local sp_slot, sp_container = GetFirstUnmarkedStackSlotInContainer(inventory, spoverflow, item)
                if sp_slot ~= nil then
                    return sp_slot, sp_container
                end
            end
        end

        if (prioritize_overflow or specialized ~= nil) and inv_slot ~= nil then
            return inv_slot, inv_container
        end
    end

    return ISR.GetNextUnmarkedEmptySlot(inventory, item, nil)
end

function ISR.CanItemUseMarkedSlot(player, container_guid, slot, item)
    local mark = ISR.GetServerSlotMark(player, container_guid, slot)
    return mark == nil or ISR.MarkMatchesItem(mark, item)
end

function ISR.GetNextUnmarkedContainerSlot(container, item, owner)
    if container == nil or item == nil or owner == nil then
        return nil
    end

    local container_guid = container.inst ~= nil and container.inst.GUID or nil
    for k = 1, ISR.GetContainerSlotCount(container) do
        if ISR.CanUseEmptyContainerSlot(container, item, k)
            and ISR.CanItemUseMarkedSlot(owner, container_guid, k, item)
        then
            return k
        end
    end

    return nil
end

local function GetNextUnmarkedSlotInSingleContainer(container, item, owner)
    if container == nil or item == nil or owner == nil then
        return nil, nil
    end

    local container_guid = container.inst ~= nil and container.inst.GUID or nil
    if item.components ~= nil and item.components.stackable ~= nil and container:AcceptsStacks() then
        local stack_size = item.components.stackable:StackSize()
        for k = 1, ISR.GetContainerSlotCount(container) do
            local olditem = container:GetItemInSlot(k)
            if olditem ~= nil
                and olditem.components ~= nil
                and olditem.components.stackable ~= nil
                and container:CanTakeItemInSlot(item, k)
                and item.components.stackable:CanStackWith(olditem)
                and not olditem.components.stackable:IsFull()
                and olditem.components.stackable:RoomLeft() >= stack_size
                and ISR.CanItemUseMarkedSlot(owner, container_guid, k, item)
            then
                return k, container
            end
        end
    end

    return ISR.GetNextUnmarkedContainerSlot(container, item, owner), container
end

function ISR.GetNextUnmarkedContainerAvailableSlot(container, item, owner)
    if container == nil or item == nil or owner == nil then
        return nil, nil
    end

    local specialized = GetSpecializedContainersForContainerItem(container, item)
    if specialized ~= nil then
        for _, spoverflow in ipairs(specialized) do
            local sp_slot, sp_container = GetNextUnmarkedSlotInSingleContainer(spoverflow, item, owner)
            if sp_slot ~= nil then
                return sp_slot, sp_container
            end
        end
    end

    return GetNextUnmarkedSlotInSingleContainer(container, item, owner)
end

function ISR.ContainerHasMarkedEmptySlot(container, owner)
    if container == nil or owner == nil then
        return false
    end

    local container_guid = container.inst ~= nil and container.inst.GUID or nil
    for k = 1, ISR.GetContainerSlotCount(container) do
        if container:GetItemInSlot(k) == nil and ISR.IsServerSlotMarked(owner, container_guid, k) then
            return true
        end
    end

    return false
end

function ISR.ContainerTreeHasMarkedEmptySlot(container, item, owner)
    if ISR.ContainerHasMarkedEmptySlot(container, owner) then
        return true
    end

    local specialized = GetSpecializedContainersForContainerItem(container, item)
    if specialized ~= nil then
        for _, spoverflow in ipairs(specialized) do
            if ISR.ContainerHasMarkedEmptySlot(spoverflow, owner) then
                return true
            end
        end
    end

    return false
end

function ISR.GetAvailableStackRoomInContainer(container, item, owner)
    if container == nil
        or item == nil
        or item.components == nil
        or item.components.stackable == nil
        or not (container.acceptsstacks or container.AcceptsStacks ~= nil and container:AcceptsStacks())
    then
        return 0
    end

    local room = 0
    local container_guid = container.inst ~= nil and container.inst.GUID or nil
    for k = 1, ISR.GetContainerSlotCount(container) do
        local other_item = container:GetItemInSlot(k)
        if other_item ~= nil
            and other_item.components ~= nil
            and other_item.components.stackable ~= nil
            and container:CanTakeItemInSlot(item, k)
            and item.components.stackable:CanStackWith(other_item)
            and not other_item.components.stackable:IsFull()
            and ISR.CanItemUseMarkedSlot(owner, container_guid, k, item)
        then
            room = room + other_item.components.stackable:RoomLeft()
        end
    end

    return room
end

function ISR.GetAvailableStackRoomInInventory(inventory, item)
    if inventory == nil
        or item == nil
        or item.components == nil
        or item.components.stackable == nil
        or not inventory.acceptsstacks
    then
        return 0
    end

    local room = 0
    for slot, other_item in pairs(inventory.itemslots or {}) do
        if other_item ~= nil
            and other_item.components ~= nil
            and other_item.components.stackable ~= nil
            and inventory:CanTakeItemInSlot(item, slot)
            and item.components.stackable:CanStackWith(other_item)
            and not other_item.components.stackable:IsFull()
            and ISR.CanItemUseMarkedSlot(inventory.inst, inventory.inst.GUID, slot, item)
        then
            room = room + other_item.components.stackable:RoomLeft()
        end
    end

    return room
end

function ISR.CanFullyStackIntoContainer(container, item, owner)
    return item ~= nil
        and item.components ~= nil
        and item.components.stackable ~= nil
        and ISR.GetAvailableStackRoomInContainer(container, item, owner) >= item.components.stackable:StackSize()
end

function ISR.CanFullyStackIntoInventory(inventory, item)
    return item ~= nil
        and item.components ~= nil
        and item.components.stackable ~= nil
        and ISR.GetAvailableStackRoomInInventory(inventory, item) >= item.components.stackable:StackSize()
end

function ISR.CanFullyStackIntoAvailableStorage(inventory, item)
    if inventory == nil
        or item == nil
        or item.components == nil
        or item.components.stackable == nil
    then
        return false
    end

    local room = ISR.GetAvailableStackRoomInInventory(inventory, item)
    local overflow = inventory ~= nil and inventory:GetOverflowContainer() or nil
    if CanUseOverflow(item, overflow) then
        room = room + ISR.GetAvailableStackRoomInContainer(overflow, item, inventory.inst)
    end

    local specialized = inventory ~= nil and GetSpecializedContainersForItem(inventory, item) or nil
    if specialized ~= nil then
        for _, spoverflow in ipairs(specialized) do
            room = room + ISR.GetAvailableStackRoomInContainer(spoverflow, item, inventory.inst)
        end
    end

    return room >= item.components.stackable:StackSize()
end
