ISR = ISR or {}

-- 读档时原版会用存档槽位号调 GiveItem（Inventory:OnLoad / Container:OnLoad）
-- 那是恢复既有数据，不是玩家往标记格里塞别的物品，期间不能清标记
local function IsStorageLoading(storage)
    return storage ~= nil
        and (storage.isloading == true or storage._isr_loading == true)
end

function ISR.TryGiveItemToContainer(inventory, item, container, slot, src_pos)
    if not ISR.CanUseContainerSlot(container, item, slot) then
        return false
    end

    local equipped_slot = inventory:IsItemEquipped(item)
    if equipped_slot ~= nil then
        inventory:Unequip(equipped_slot)
    elseif item.components.inventoryitem.owner ~= nil and item.components.inventoryitem.owner ~= inventory.inst then
        item.components.inventoryitem:RemoveFromOwner(true)
    end

    if item.components.inventoryitem:OnPickup(inventory.inst, src_pos) then
        return true
    end

    if container:GiveItem(item, slot, src_pos, false) then
        if item.components.equippable ~= nil then
            item.components.equippable:ToPocket()
        end
        return true
    end

    return false
end

local function GetFallbackUnmarkedEmptySlot(inventory, item, placement_context)
    if placement_context ~= nil
        and placement_context.reason == "shift_transfer"
        and inventory ~= nil
        and inventory.inst ~= nil
        and placement_context.target_guid == inventory.inst.GUID
    then
        for k = 1, inventory:GetNumSlots() do
            if ISR.CanStackIntoInventorySlot ~= nil
                and ISR.CanStackIntoInventorySlot(inventory, item, k)
                and ISR.CanItemUseMarkedSlot(inventory.inst, inventory.inst.GUID, k, item)
            then
                return k, inventory.itemslots
            end
        end

        for k = 1, inventory:GetNumSlots() do
            if ISR.CanUseEmptyInventorySlot(inventory, item, k)
                and ISR.CanItemUseMarkedSlot(inventory.inst, inventory.inst.GUID, k, item)
            then
                return k, inventory.itemslots
            end
        end

        return nil, inventory.itemslots
    end

    return ISR.GetNextUnmarkedEmptySlot(inventory, item)
end

local function AddPlayerInventoryPostInit(fn)
    AddComponentPostInit("inventory", function(self)
        if ISR.IsPlayerInventoryComponent(self) then
            fn(self)
        end
    end)
end

AddPlayerInventoryPostInit(function(self)
    local old_GetNextAvailableSlot = self.GetNextAvailableSlot
    function self:GetNextAvailableSlot(item)
        local slot, container = old_GetNextAvailableSlot(self, item)
        if not ISR.ShouldReserveMarkedSlotsForItem(self.inst, item) then
            return slot, container
        end

        local transfer = ISR.GetTransferContext()
        local target_inventory_only = transfer ~= nil
            and transfer.reason == "shift_transfer"
            and self.inst ~= nil
            and transfer.target_guid == self.inst.GUID
        if target_inventory_only then
            -- Shift 转移的落点顺序：该物品的空预留格（TryPlaceByMarks 已处理）
            -- → 物品栏同类未满堆 → 原版给的合法格 → 物品栏未预留空格
            -- → 背包（这里返回 nil，交给原版 GiveItem 落背包）
            for inventory_slot = 1, self:GetNumSlots() do
                if ISR.CanStackIntoInventorySlot ~= nil
                    and ISR.CanStackIntoInventorySlot(self, item, inventory_slot)
                    and ISR.CanItemUseMarkedSlot(self.inst, self.inst.GUID, inventory_slot, item)
                then
                    return inventory_slot, self.itemslots
                end
            end

            if container == self.itemslots
                and slot ~= nil
                and ISR.CanItemUseMarkedSlot(self.inst, self.inst.GUID, slot, item)
            then
                return slot, container
            end

            for inventory_slot = 1, self:GetNumSlots() do
                if ISR.CanUseEmptyInventorySlot(self, item, inventory_slot)
                    and ISR.CanItemUseMarkedSlot(self.inst, self.inst.GUID, inventory_slot, item)
                then
                    return inventory_slot, self.itemslots
                end
            end

            return nil, self.itemslots
        end

        local container_guid = ISR.GetInventorySlotContainerGUID(self, container)
        if slot == nil
            or container_guid == nil
            or ISR.CanItemUseMarkedSlot(self.inst, container_guid, slot, item)
        then
            return slot, container
        end

        local next_slot, next_container = ISR.GetNextUnmarkedAvailableSlot(self, item)
        ISR.Log(
            "Reserved slot skipped",
            tostring(item.prefab),
            "reserved_container", tostring(container_guid),
            "reserved_slot", tostring(slot),
            "next_slot", tostring(next_slot)
        )
        return next_slot, next_container
    end

    local old_GiveItem = self.GiveItem
    function self:GiveItem(inst, slot, src_pos)
        local requested_slot = slot
        local placement_context = ISR.MakePlacementContext({
            owner = self.inst,
            inventory = self,
            item = inst,
            slot = slot,
            src_pos = src_pos,
        })
        ISR.Log(
            "Inv give",
            tostring(inst ~= nil and inst.prefab or nil),
            "slot", tostring(slot),
            "reason", tostring(placement_context.reason),
            "target_guid", tostring(placement_context.target_guid),
            "self_guid", tostring(self.inst ~= nil and self.inst.GUID or nil),
            "overflow", tostring(self.GetOverflowContainer ~= nil and self:GetOverflowContainer() ~= nil),
            "ignoreoverflow", tostring(self.ignoreoverflow),
            "prevslot", tostring(inst ~= nil and inst.prevslot or nil),
            "prevcontainer", tostring(inst ~= nil and inst.prevcontainer ~= nil)
        )
        if ISR.ShouldRoutePlacementByMarks(placement_context) then
            local marked_result, marked_slot = ISR.TryPlaceByMarks(placement_context)
            if marked_result == "inventory" then
                slot = marked_slot
            elseif marked_result then
                return true
            end
        end

        -- 这个判定要枚举全部带标记的容器；下面两个分支问的是同一件事，算一次
        local reserve_marked = ISR.ShouldReserveMarkedSlotsForItem(self.inst, inst)
        if slot == nil
            and reserve_marked
            and not ISR.CanFullyStackIntoAvailableStorage(self, inst)
        then
            local marked_slot, marked_container = GetFallbackUnmarkedEmptySlot(self, inst, placement_context)
            if marked_slot == nil then
                -- 物品栏没有可用位：交回原版，物品落进背包/随身容器，而不是整单失败
                -- 背包也满、或来源本身就是背包（原版会置 ignoreoverflow）时，原版自己返回失败
                ISR.Log("Reserved inventory full", tostring(inst ~= nil and inst.prefab or nil))
                local fallback_result = old_GiveItem(self, inst, nil, src_pos)
                ISR.Log("Reserved inventory fallback result", tostring(fallback_result))
                return fallback_result
            elseif marked_container ~= self.itemslots then
                return ISR.TryGiveItemToContainer(self, inst, marked_container, marked_slot, src_pos)
            end

            slot = marked_slot
        elseif slot == nil and reserve_marked then
            ISR.Log("Reserved inventory stackable shortcut", tostring(inst ~= nil and inst.prefab or nil))
        end

        local result = old_GiveItem(self, inst, slot, src_pos)
        ISR.Log("Inv give result", tostring(inst ~= nil and inst.prefab or nil), "slot", tostring(slot), "result", tostring(result))
        if result then
            -- 只能放物品栏的物品（余烬 / 灵魂）绕过预留规则，可能直接落进被预留的格；
            -- 落进去了就把那格的预留解除，不留「装错东西的死格」
            local landed_slot = requested_slot
            if landed_slot == nil
                and type(result) == "number"
                and ISR.IsPocketOnlyItem ~= nil
                and ISR.IsPocketOnlyItem(inst)
            then
                landed_slot = result
            end

            if landed_slot ~= nil and not IsStorageLoading(self) then
                ISR.ClearServerSlotMarkIfItemMismatches(self.inst, self.inst.GUID, landed_slot, inst)
            end
        end
        return result
    end
end)

-- 原版 GiveItem 会自己挑格（slot 为 nil 时走 GetSpecificSlotForItem），落点只有事后
-- 回头看 GetItemSlot 才知道手动拖入、Swap、Shift 转移、自动放入都可能不给 slot，
-- 只按 slot 判就会漏掉「预留格被别的东西占住」的情况，预留留在那儿成了死格
local function ClearContainerMarkOnLandedSlot(container_comp, item, slot, result)
    if not result or item == nil or container_comp == nil or IsStorageLoading(container_comp) then
        return
    end

    local landed = slot
    if landed == nil and container_comp.GetItemSlot ~= nil then
        landed = container_comp:GetItemSlot(item)
    end

    if landed ~= nil and ISR.ClearContainerSlotMarkOnMismatch ~= nil then
        ISR.ClearContainerSlotMarkOnMismatch(container_comp.inst, landed, item)
    end
end

AddComponentPostInit("container", function(self)
    local old_GiveItem = self.GiveItem
    function self:GiveItem(item, slot, src_pos, drop_on_fail)
        local owner = ISR.ResolvePlayerStorageOwner(self, "container")
        if owner == nil and ISR.GetMarkOwnerPlayer ~= nil then
            -- 基地箱子 / 没带眼骨的切斯特：没有 inventoryitem 主人链，
            -- 归属记在 mark store 上。用记下的 owner 参与路由，
            -- 否则「回预留格」「避开预留格」这两条对它们完全不生效
            owner = ISR.GetMarkOwnerPlayer(self.inst)
        end

        if owner == nil then
            local result = old_GiveItem(self, item, slot, src_pos, drop_on_fail)
            ClearContainerMarkOnLandedSlot(self, item, slot, result)
            return result
        end

        local container_guid = self.inst ~= nil and self.inst.GUID or nil
        local placement_context = ISR.MakePlacementContext({
            owner = owner,
            item = item,
            slot = slot,
            target_container = self,
            target_kind = "container",
            src_pos = src_pos,
            target_guid = self.inst ~= nil and self.inst.GUID or nil,
        })
        if ISR.TryPlaceByMarks(placement_context) then
            return true
        end

        if slot == nil
            and ISR.ShouldReserveMarkedSlotsForItem(owner, item)
            and ISR.ContainerTreeHasMarkedEmptySlot(self, item, owner)
        then
            local next_slot, next_container = ISR.GetNextUnmarkedContainerAvailableSlot(self, item, owner)
            if next_slot == nil then
                -- 没有非预留的空位：交回原版（原版会用上预留格）
                -- 硬 return false 会让物品直接退回来源，比「先避开、实在没位再用」更差
                ISR.Log(
                    "Reserved container full",
                    tostring(item ~= nil and item.prefab or nil),
                    "container", tostring(container_guid),
                    "drop_on_fail", tostring(drop_on_fail)
                )
            elseif next_container ~= nil and next_container ~= self then
                return next_container:GiveItem(item, next_slot, src_pos, false)
            else
                slot = next_slot
            end
        end

        local result = old_GiveItem(self, item, slot, src_pos, drop_on_fail)
        ClearContainerMarkOnLandedSlot(self, item, slot, result)
        return result
    end
end)

local function GetTransferTargetGUID(target)
    return target ~= nil and target.GUID or nil
end

local function WithShiftTransferContext(source_guid, target_guid, fn, ...)
    ISR.Log("Shift transfer source", tostring(source_guid), "target", tostring(target_guid))
    return ISR.WithTransferContext(
        {
            source_guid = source_guid,
            target_guid = target_guid,
            reason = "shift_transfer",
        },
        fn,
        ...
    )
end

AddPlayerInventoryPostInit(function(self)
    local old_MoveItemFromAllOfSlot = self.MoveItemFromAllOfSlot
    if old_MoveItemFromAllOfSlot ~= nil then
        function self:MoveItemFromAllOfSlot(slot, container)
            local item = self.GetItemInSlot ~= nil and self:GetItemInSlot(slot) or nil
            ISR.Log(
                "Inventory shift out",
                "self", tostring(self.inst ~= nil and self.inst.GUID or nil),
                "slot", tostring(slot),
                "item", tostring(item ~= nil and item.prefab or nil),
                "target", tostring(GetTransferTargetGUID(container)),
                "overflow", tostring(self.GetOverflowContainer ~= nil and self:GetOverflowContainer() ~= nil),
                "ignoreoverflow", tostring(self.ignoreoverflow)
            )
            return WithShiftTransferContext(self.inst ~= nil and self.inst.GUID or nil, GetTransferTargetGUID(container), old_MoveItemFromAllOfSlot, self, slot, container)
        end
    end

    local old_MoveItemFromHalfOfSlot = self.MoveItemFromHalfOfSlot
    if old_MoveItemFromHalfOfSlot ~= nil then
        function self:MoveItemFromHalfOfSlot(slot, container)
            return WithShiftTransferContext(self.inst ~= nil and self.inst.GUID or nil, GetTransferTargetGUID(container), old_MoveItemFromHalfOfSlot, self, slot, container)
        end
    end

    local old_MoveItemFromCountOfSlot = self.MoveItemFromCountOfSlot
    if old_MoveItemFromCountOfSlot ~= nil then
        function self:MoveItemFromCountOfSlot(slot, container, count)
            return WithShiftTransferContext(self.inst ~= nil and self.inst.GUID or nil, GetTransferTargetGUID(container), old_MoveItemFromCountOfSlot, self, slot, container, count)
        end
    end
end)

AddComponentPostInit("container", function(self)
    local old_MoveItemFromAllOfSlot = self.MoveItemFromAllOfSlot
    if old_MoveItemFromAllOfSlot ~= nil then
        function self:MoveItemFromAllOfSlot(slot, container, opener)
            local item = self.GetItemInSlot ~= nil and self:GetItemInSlot(slot) or nil
            local opened = opener ~= nil
                and self.IsOpenedBy ~= nil
                and self:IsOpenedBy(opener) or nil
            ISR.Log(
                "Container shift out",
                "self", tostring(self.inst ~= nil and self.inst.GUID or nil),
                "slot", tostring(slot),
                "item", tostring(item ~= nil and item.prefab or nil),
                "target", tostring(GetTransferTargetGUID(container)),
                "opened", tostring(opened),
                "readonly", tostring(self.readonlycontainer)
            )
            return WithShiftTransferContext(self.inst ~= nil and self.inst.GUID or nil, GetTransferTargetGUID(container), old_MoveItemFromAllOfSlot, self, slot, container, opener)
        end
    end

    local old_MoveItemFromHalfOfSlot = self.MoveItemFromHalfOfSlot
    if old_MoveItemFromHalfOfSlot ~= nil then
        function self:MoveItemFromHalfOfSlot(slot, container, opener)
            return WithShiftTransferContext(self.inst ~= nil and self.inst.GUID or nil, GetTransferTargetGUID(container), old_MoveItemFromHalfOfSlot, self, slot, container, opener)
        end
    end

    local old_MoveItemFromCountOfSlot = self.MoveItemFromCountOfSlot
    if old_MoveItemFromCountOfSlot ~= nil then
        function self:MoveItemFromCountOfSlot(slot, container, count, opener)
            return WithShiftTransferContext(self.inst ~= nil and self.inst.GUID or nil, GetTransferTargetGUID(container), old_MoveItemFromCountOfSlot, self, slot, container, count, opener)
        end
    end
end)
