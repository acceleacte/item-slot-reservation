ISR = ISR or {}
ISR.PERSONAL_STORAGE_DEPTH = ISR.PERSONAL_STORAGE_DEPTH or 3

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

-- ---------------------------------------------------------------------------
-- 标记容器注册表
--
-- 只靠「玩家身上有什么」去枚举会漏东西：跟随型容器（切斯特、哈奇）不在物品栏里，
-- 别的模组容器也不在。凡是带本组件、且写过标记的实体都登记在这里；读档时组件
-- OnLoad 会自己登记回来，所以不需要预先知道 prefab 名单。
-- ---------------------------------------------------------------------------
ISR._mark_containers = ISR._mark_containers or {}

function ISR.RegisterMarkContainer(inst)
    if inst ~= nil and inst.GUID ~= nil then
        ISR._mark_containers[inst.GUID] = inst
    end
end

function ISR.UnregisterMarkContainer(inst)
    if inst ~= nil and inst.GUID ~= nil then
        ISR._mark_containers[inst.GUID] = nil
    end
end

function ISR.GetMarkContainerInstances()
    local result = {}
    for guid, inst in pairs(ISR._mark_containers) do
        if inst == nil or (inst.IsValid ~= nil and not inst:IsValid()) then
            ISR._mark_containers[guid] = nil
        else
            table.insert(result, inst)
        end
    end

    return result
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

-- 随身容器实例：玩家自己 + 物品栏/装备栏里的容器 + 这些容器里的容器（背包里的桶）。
-- 递归有深度上限（ISR.PERSONAL_STORAGE_DEPTH），并且用 seen 防环。
function ISR.GetPersonalStorageInstances(player)
    local result = {}
    local seen = {}

    local function Add(inst, depth)
        if inst == nil or inst.GUID == nil or seen[inst.GUID] then
            return
        end

        seen[inst.GUID] = true
        table.insert(result, inst)

        local container = inst.components ~= nil and inst.components.container or nil
        if depth >= ISR.PERSONAL_STORAGE_DEPTH or container == nil or container.slots == nil then
            return
        end

        for _, item in pairs(container.slots) do
            Add(item, depth + 1)
        end
    end

    Add(player, 1)
    local inventory = player ~= nil and player.components ~= nil and player.components.inventory or nil
    if inventory ~= nil then
        for _, item in pairs(inventory.itemslots or {}) do
            Add(item, 2)
        end
        for _, item in pairs(inventory.equipslots or {}) do
            Add(item, 2)
        end
    end

    return result
end

AddComponentPostInit("container", function(self)
    -- 原版 Container:OnLoad 会按存档里的槽位号逐个 GiveItem，期间「标记与物品不匹配
    -- 就清除」属于误伤：读档不该改动用户设定。这里给加载过程打个标记，
    -- GiveItem 的包装据此跳过清除。
    local old_OnLoad = self.OnLoad
    if old_OnLoad ~= nil then
        function self:OnLoad(data, newents)
            self._isr_loading = true
            old_OnLoad(self, data, newents)
            self._isr_loading = nil
        end
    end

    -- 所有 container 实体在构造期就挂组件，不判 inventoryitem。
    -- 原判定漏两类：跟随型容器（切斯特、哈奇、Woby 只有 container）和「先 container
    -- 后 inventoryitem」的携带容器（原版 beargerrfur_sack、tacklecontainer）。
    -- 漏判的后果是存档数据只能靠 add_component_if_missing 让引擎补建组件，而那个标记
    -- 会让玩家关掉模组后永久进不了档（require 失败打断读档）。现在组件构造期就在，
    -- 存档数据不带任何重建标记；模组关掉时引擎找不到组件就静默丢弃这份数据。
    -- 空组件不产生存档数据（没标记时 OnSave 返回 nil），世界容器白挂一个空表。
    if IsMasterSimulation() and self.inst ~= nil and self.inst.components ~= nil then
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
