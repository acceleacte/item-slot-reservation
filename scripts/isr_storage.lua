ISR = ISR or {}

-- 随身容器最多向下几层：玩家(1) → 物品栏/装备栏里的容器(2) → 容器里的容器(3)。
-- 背包里的桶属于第 2 层，够用；再深就不展开了，避免套娃容器拖慢枚举。
ISR.PERSONAL_STORAGE_DEPTH = 3

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

-- 「属于这名玩家的随身实体」只看组件语义，不看 prefab 名单：
--   * 玩家自己
--   * 跟随者（切斯特、哈奇、Woby 这类 follower leader 是玩家的生物容器）
--   * 玩家正在骑的坐骑
-- 这样新容器、别的模组容器都不用逐个登记。
function ISR.IsEntityOwnedByPlayer(player, inst)
    if player == nil or inst == nil then
        return false
    elseif inst == player then
        return true
    end

    local components = inst.components
    if components == nil then
        return false
    end

    local follower = components.follower
    if follower ~= nil then
        local leader = follower.GetLeader ~= nil and follower:GetLeader() or follower.leader
        if leader == player then
            return true
        end
    end

    local rideable = components.rideable
    if rideable ~= nil and rideable.rider == player then
        return true
    end

    return false
end

-- 可标记的容器：玩家自己，以及随身携带的容器（物品栏、装备栏、背包这类
-- 随身容器里的容器、跟随者身上的容器）。地上箱子、别人的容器都不算。
function ISR.IsMarkableContainerForPlayer(player, container_guid)
    if player == nil or container_guid == nil then
        return false
    elseif container_guid == player.GUID then
        return true
    end

    local container_inst = ISR.GetContainerInstFromGUID(container_guid)
    return ISR.IsStorageOwnedByPlayer(player, container_inst)
end

-- 容器实体归属：优先看容器上记过的 owner（切斯特没眼骨时不跟随任何人，
-- 组件语义判不出来，只能靠这个字段），其次看 owner 链终点、follower、骑乘。
function ISR.IsStorageOwnedByPlayer(player, inst)
    if player == nil or inst == nil then
        return false
    end

    local store = inst.components ~= nil and inst.components.isr_slotmarkstore or nil
    if store ~= nil and store.GetOwner ~= nil then
        local owner_userid = store:GetOwner()
        if owner_userid ~= nil then
            return player.userid ~= nil and owner_userid == player.userid
        end
    end

    local inventoryitem = inst.components ~= nil and inst.components.inventoryitem or nil
    if inventoryitem ~= nil then
        local owner = inventoryitem.GetGrandOwner ~= nil
            and inventoryitem:GetGrandOwner()
            or inventoryitem.owner
        if ISR.IsEntityOwnedByPlayer(player, owner) then
            return true
        end
    end

    return ISR.IsEntityOwnedByPlayer(player, inst)
end

-- 自动落进容器要有距离限制，否则站在地图另一头也能把东西送进基地箱子。
-- 随身携带的容器（物品栏、装备栏、背包里、背包里的桶）永远算在手边；
-- 世界里的容器（地上的箱子、跟随中的切斯特/哈奇）按玩家到它的距离算。
function ISR.GetContainerRangeLimit()
    local key = ISR.Config ~= nil and ISR.Config.container_range or nil
    local limits = ISR.ContainerRangeLimits or {}
    return limits[key] or limits.medium or 24
end

local function GetWorldDistance(a, b)
    if a == nil or b == nil or a.Transform == nil or b.Transform == nil then
        return nil
    end

    local x1, y1, z1 = a.Transform:GetWorldPosition()
    local x2, y2, z2 = b.Transform:GetWorldPosition()
    local dx, dz = x1 - x2, z1 - z2
    return math.sqrt(dx * dx + dz * dz)
end

-- 容器的宿主：装着它的物品栏 / 容器实体。世界里的箱子、跟随中的切斯特没有宿主。
local function GetStorageHolder(storage)
    local inst = storage ~= nil and (storage.inst or storage) or nil
    local inventoryitem = inst ~= nil and inst.components ~= nil and inst.components.inventoryitem or nil
    if inventoryitem == nil then
        return nil
    end

    return inventoryitem.GetGrandOwner ~= nil and inventoryitem:GetGrandOwner() or inventoryitem.owner
end

-- 容器是否挂在玩家身上（物品栏、装备栏、背包里的桶……）。
-- 只看 owner 链：世界里的箱子、跟随中的切斯特/哈奇都不算 —— 它们按距离判。
function ISR.IsStorageCarriedByPlayer(owner, storage)
    if owner == nil or storage == nil then
        return false
    end

    local inst = storage.inst or storage
    return inst == owner or GetStorageHolder(storage) == owner
end

function ISR.IsStorageWithinRange(owner, storage, limit)
    if owner == nil or storage == nil then
        return true
    end

    -- 容器本身在玩家身上：永远在手边
    if ISR.IsStorageCarriedByPlayer(owner, storage) then
        return true
    end

    -- 装在别的容器里的（limbo）没有世界坐标，跟着宿主容器算距离
    local inst = storage.inst or storage
    local anchor = GetStorageHolder(storage) or inst
    if anchor.Transform == nil then
        return true
    elseif anchor.IsInLimbo ~= nil and anchor:IsInLimbo() then
        return true
    end

    local distance = GetWorldDistance(owner, anchor)
    return distance == nil or distance <= (limit or ISR.GetContainerRangeLimit())
end

-- 客户端侧的同一判定：客户端没有 owner 网络字段，只能看 follower / 骑乘，
-- 加上物品栏一层和已打开容器的 replica 树。
local function IsClientEntityOwnedByPlayer(player, inst)
    if player == nil or inst == nil then
        return false
    elseif inst == player then
        return true
    end

    local replica = inst.replica
    if replica == nil then
        return false
    end

    local follower = replica.follower
    if follower ~= nil
        and follower.GetLeader ~= nil
        and follower:GetLeader() == player
    then
        return true
    end

    return false
end

-- 客户端侧的同一判定：没有服务端组件，只能顺着 replica 的容器树找。
-- 只有玩家打开过的容器才有 classified 数据，够用 —— 要标记的时候容器本来就是开着的。
local function ReplicaContainerHolds(container_inst, target, depth)
    local replica = container_inst ~= nil and container_inst.replica or nil
    local container = replica ~= nil and replica.container or nil
    if container == nil
        or container.GetNumSlots == nil
        or container.GetItemInSlot == nil
    then
        return false
    end

    for index = 1, container:GetNumSlots() do
        local item = container:GetItemInSlot(index)
        if item == target then
            return true
        elseif depth > 1 and item ~= nil and ReplicaContainerHolds(item, target, depth - 1) then
            return true
        end
    end

    return false
end

-- 容器是否有打开中的数据：客户端只对「玩家自己打开的容器」拿到 classified。
-- 用它做最后一道放行，剩下的交给服务端裁决（拒绝时会回推真实状态）。
local function ClientContainerSlotCount(container_inst)
    local replica = container_inst ~= nil and container_inst.replica or nil
    local container = replica ~= nil and replica.container or nil
    if container == nil or container.GetNumSlots == nil then
        return 0
    end

    return container:GetNumSlots() or 0
end

function ISR.IsClientMarkableContainerInst(container_inst)
    local player = ISR.GetLocalPlayer()
    if player == nil or container_inst == nil then
        return false
    end

    -- 跟随者（切斯特、哈奇）与玩家自己
    if IsClientEntityOwnedByPlayer(player, container_inst) then
        return true
    end

    local inventory = player.replica ~= nil and player.replica.inventory or nil
    if inventory ~= nil then
        local function Holds(item)
            if item == container_inst then
                return true
            end

            return item ~= nil
                and ReplicaContainerHolds(item, container_inst, ISR.PERSONAL_STORAGE_DEPTH - 1)
        end

        for _, item in pairs(inventory.GetItems ~= nil and inventory:GetItems() or {}) do
            if Holds(item) then
                return true
            end
        end

        for _, item in pairs(inventory.GetEquips ~= nil and inventory:GetEquips() or {}) do
            if Holds(item) then
                return true
            end
        end
    end

    -- 兜底：inventoryitem 的 replica 不带 owner，客户端拼不出完整的归属链
    -- （例如切斯特身上的背包）。只要容器正开着就先放行，由服务端最终裁决。
    return ClientContainerSlotCount(container_inst) > 0
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
    -- 能放进这一格：空格，或者同类未满堆叠（拾取同种资源时要并进固定格里那堆）。
    CanUseSlot = function(_, storage, item, slot)
        if ISR.CanUseInventorySlot ~= nil then
            return ISR.CanUseInventorySlot(storage, item, slot)
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
    -- 能放进这一格：空格，或者同类未满堆叠（草、树枝这类资源要并进固定格里那堆）。
    CanUseSlot = function(_, storage, item, slot)
        if ISR.CanUseContainerSlot ~= nil then
            return ISR.CanUseContainerSlot(storage, item, slot)
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
